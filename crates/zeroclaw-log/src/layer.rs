//! `tracing-subscriber` Layer that captures every `tracing::*` event and
//! routes it through the zeroclaw-log pipeline: persisted JSONL +
//! broadcast hook + Observer bridge.
//!
//! Install this layer alongside the existing `fmt::Subscriber` formatter
//! in the daemon's tracing setup. Doing so makes zeroclaw-log THE
//! emission surface for all logging without rewriting 1,300+ call sites.
//! Direct `tracing::info!/warn!/error!/debug!/trace!` calls keep working
//! exactly as they do today (terminal output via the formatter) AND now
//! also land in the JSONL log + the dashboard's SSE stream.
//!
//! High-value sites use the [`crate::record!`] macro for explicit
//! alias-bound attribution. Bare `tracing::*` calls produce log events
//! with whatever structured fields the caller passed; the Layer picks up
//! anything that names a known field name.

use std::fmt::Write;

use serde_json::{Map as JsonMap, Value};
use tracing::field::{Field, Visit};
use tracing::span::Attributes;
use tracing::{Event, Id, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;

use crate::event::{EventCategory, EventOutcome, LogEvent, Severity};
use crate::writer::record_event;

/// Field name a span/event can set to override the inferred
/// `event.action`. Defaults to the tracing target's last segment when
/// absent.
const ACTION_FIELD: &str = "event";

/// Field name a span/event can set to override the inferred
/// `event.category`.
const CATEGORY_FIELD: &str = "category";

const FIELD_OUTCOME: &str = "outcome";
const FIELD_AGENT: &str = "agent";
const FIELD_AGENT_ALIAS: &str = "agent_alias";
const FIELD_CHANNEL: &str = "channel";
const FIELD_MODEL_PROVIDER: &str = "model_provider";
const FIELD_MODEL: &str = "model";
const FIELD_TOOL: &str = "tool";
const FIELD_SESSION_KEY: &str = "session_key";
const FIELD_CRON_JOB_ID: &str = "cron_job_id";
const FIELD_DURATION_MS: &str = "duration_ms";
const FIELD_TRACE_ID: &str = "trace_id";
const FIELD_SPAN_ID: &str = "span_id";
const FIELD_MESSAGE: &str = "message";
const FIELD_TARGET_OVERRIDE_PREFIX: &str = "zeroclaw_log_internal";

/// tracing-subscriber Layer that emits LogEvents into zeroclaw-log AND
/// captures span-context attribution (agent_alias, channel composite,
/// session_key, cron_job_id) from span attributes on span creation.
/// Stashing happens on `on_new_span`; emission happens on `on_event`.
pub struct LogCaptureLayer;

impl<S> tracing_subscriber::Layer<S> for LogCaptureLayer
where
    S: Subscriber + for<'lookup> LookupSpan<'lookup>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        let mut visitor = FieldCollector::default();
        attrs.record(&mut visitor);
        let Some(span) = ctx.span(id) else {
            return;
        };
        let mut exts = span.extensions_mut();
        if let Some(alias) = visitor.agent_alias.or(visitor.agent) {
            exts.insert(AgentAliasField { alias });
        }
        if let Some(composite) = visitor.channel {
            exts.insert(ChannelContextField { composite });
        }
        if let Some(key) = visitor.session_key {
            exts.insert(SessionKeyField { key });
        }
        if let Some(id) = visitor.cron_job_id {
            exts.insert(CronJobIdField { id });
        }
    }

    fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let target = metadata.target();

        if target.starts_with(FIELD_TARGET_OVERRIDE_PREFIX) {
            return;
        }

        let severity = match *metadata.level() {
            tracing::Level::ERROR => Severity::Error,
            tracing::Level::WARN => Severity::Warn,
            tracing::Level::INFO => Severity::Info,
            tracing::Level::DEBUG => Severity::Debug,
            tracing::Level::TRACE => Severity::Trace,
        };

        let mut visitor = FieldCollector::default();
        event.record(&mut visitor);

        let category = visitor
            .category
            .as_deref()
            .and_then(EventCategory::parse)
            .unwrap_or_else(|| infer_category(target));

        let action = visitor
            .action
            .as_deref()
            .map(str::to_string)
            .unwrap_or_else(|| metadata.name().to_string());

        let mut log_event = LogEvent::new(severity, &action, category);

        if let Some(outcome) = visitor.outcome.as_deref().and_then(EventOutcome::parse) {
            log_event.set_outcome(outcome);
        }

        log_event.message = Some(visitor.message_or_summary());
        log_event.zeroclaw.agent_alias =
            visitor.agent_alias.take().or_else(|| visitor.agent.take());
        if let Some(channel) = visitor.channel.as_deref() {
            log_event.zeroclaw.set_channel_composite(channel);
        }
        if let Some(mp) = visitor.model_provider.as_deref() {
            log_event.zeroclaw.set_model_provider_composite(mp);
        }
        log_event.zeroclaw.model = visitor.model.take();
        log_event.zeroclaw.tool = visitor.tool.take();
        log_event.zeroclaw.session_key = visitor.session_key.take();
        log_event.zeroclaw.cron_job_id = visitor.cron_job_id.take();
        log_event.zeroclaw.duration_ms = visitor.duration_ms.take();
        log_event.trace_id = visitor.trace_id.take();
        log_event.span_id = visitor.span_id.take();

        if !visitor.extra.is_empty() {
            log_event.attributes = Value::Object(std::mem::take(&mut visitor.extra));
        }

        // Recover attribution from span context for any field the
        // event didn't explicitly set. Walks parent spans for each
        // marker type.
        if let Some(span_ref) = ctx.lookup_current() {
            let mut current = Some(span_ref);
            while let Some(span) = current {
                let exts = span.extensions();
                if log_event.zeroclaw.agent_alias.is_none()
                    && let Some(alias) = exts.get::<AgentAliasField>()
                {
                    log_event.zeroclaw.agent_alias = Some(alias.alias.clone());
                }
                if log_event.zeroclaw.channel.is_none()
                    && let Some(channel) = exts.get::<ChannelContextField>()
                {
                    let composite = channel.composite.clone();
                    log_event.zeroclaw.set_channel_composite(&composite);
                }
                if log_event.zeroclaw.session_key.is_none()
                    && let Some(session) = exts.get::<SessionKeyField>()
                {
                    log_event.zeroclaw.session_key = Some(session.key.clone());
                }
                if log_event.zeroclaw.cron_job_id.is_none()
                    && let Some(cron) = exts.get::<CronJobIdField>()
                {
                    log_event.zeroclaw.cron_job_id = Some(cron.id.clone());
                }
                drop(exts);
                if log_event.zeroclaw.agent_alias.is_some()
                    && log_event.zeroclaw.channel.is_some()
                    && log_event.zeroclaw.session_key.is_some()
                    && log_event.zeroclaw.cron_job_id.is_some()
                {
                    break;
                }
                current = span.parent();
            }
        }

        record_event(log_event);
    }
}

/// Span-extension marker stashing the agent alias the
/// `AgentAliasCaptureLayer` extracted from a span's
/// `agent_alias`/`parent_alias` field. `LogCaptureLayer` walks the span
/// stack looking for this so every emission inside an agent-bound span
/// inherits the attribution.
#[derive(Clone)]
pub struct AgentAliasField {
    pub alias: String,
}

/// Span-extension marker stashing the alias-bound channel composite
/// (`<type>.<alias>`) any code can stamp on a span. Channel listeners
/// install this when they spawn so every tracing call inside the
/// listener task picks up the channel context for free.
#[derive(Clone)]
pub struct ChannelContextField {
    pub composite: String,
}

/// Span-extension marker stashing the session key for code running
/// inside a gateway WS / channel session. Allows the dashboard to
/// filter logs by exact session.
#[derive(Clone)]
pub struct SessionKeyField {
    pub key: String,
}

/// Span-extension marker stashing the cron job id for tasks running as
/// a scheduled cron run.
#[derive(Clone)]
pub struct CronJobIdField {
    pub id: String,
}

#[derive(Default)]
struct FieldCollector {
    action: Option<String>,
    category: Option<String>,
    outcome: Option<String>,
    agent: Option<String>,
    agent_alias: Option<String>,
    channel: Option<String>,
    model_provider: Option<String>,
    model: Option<String>,
    tool: Option<String>,
    session_key: Option<String>,
    cron_job_id: Option<String>,
    duration_ms: Option<u64>,
    trace_id: Option<String>,
    span_id: Option<String>,
    message: Option<String>,
    extra: JsonMap<String, Value>,
}

impl FieldCollector {
    fn message_or_summary(&mut self) -> String {
        self.message.take().unwrap_or_default()
    }
}

impl Visit for FieldCollector {
    fn record_str(&mut self, field: &Field, value: &str) {
        self.record_field(field.name(), Value::String(value.to_string()));
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.record_field(field.name(), Value::Bool(value));
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.record_field(field.name(), Value::from(value));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        if field.name() == FIELD_DURATION_MS {
            self.duration_ms = Some(value);
            return;
        }
        self.record_field(field.name(), Value::from(value));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        self.record_field(
            field.name(),
            serde_json::Number::from_f64(value)
                .map(Value::Number)
                .unwrap_or(Value::Null),
        );
    }

    fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
        let mut buf = String::new();
        let _ = write!(&mut buf, "{value}");
        let mut current = value.source();
        while let Some(src) = current {
            let _ = write!(&mut buf, ": {src}");
            current = src.source();
        }
        self.record_field(field.name(), Value::String(buf));
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let mut buf = String::new();
        let _ = write!(&mut buf, "{value:?}");
        // `tracing` records the `"message"` field via the Debug visitor.
        if field.name() == FIELD_MESSAGE {
            self.message = Some(strip_outer_quotes(&buf));
            return;
        }
        self.record_field(field.name(), Value::String(buf));
    }
}

impl FieldCollector {
    fn record_field(&mut self, name: &str, value: Value) {
        match name {
            ACTION_FIELD => {
                if let Value::String(s) = value {
                    self.action = Some(s);
                }
            }
            CATEGORY_FIELD => {
                if let Value::String(s) = value {
                    self.category = Some(s);
                }
            }
            FIELD_OUTCOME => {
                if let Value::String(s) = value {
                    self.outcome = Some(s);
                }
            }
            FIELD_AGENT => {
                if let Value::String(s) = value {
                    self.agent = Some(s);
                }
            }
            FIELD_AGENT_ALIAS | "parent_alias" => {
                if let Value::String(s) = value {
                    self.agent_alias = Some(s);
                }
            }
            FIELD_CHANNEL => {
                if let Value::String(s) = value {
                    self.channel = Some(s);
                }
            }
            FIELD_MODEL_PROVIDER => {
                if let Value::String(s) = value {
                    self.model_provider = Some(s);
                }
            }
            FIELD_MODEL => {
                if let Value::String(s) = value {
                    self.model = Some(s);
                }
            }
            FIELD_TOOL => {
                if let Value::String(s) = value {
                    self.tool = Some(s);
                }
            }
            FIELD_SESSION_KEY => {
                if let Value::String(s) = value {
                    self.session_key = Some(s);
                }
            }
            FIELD_CRON_JOB_ID => {
                if let Value::String(s) = value {
                    self.cron_job_id = Some(s);
                }
            }
            FIELD_TRACE_ID => {
                if let Value::String(s) = value {
                    self.trace_id = Some(s);
                }
            }
            FIELD_SPAN_ID => {
                if let Value::String(s) = value {
                    self.span_id = Some(s);
                }
            }
            FIELD_MESSAGE => {
                if let Value::String(s) = value {
                    self.message = Some(s);
                }
            }
            _ => {
                self.extra.insert(name.to_string(), value);
            }
        }
    }
}

fn infer_category(target: &str) -> EventCategory {
    let head = target.split("::").next().unwrap_or(target);
    match head {
        "zeroclaw_runtime" => EventCategory::System,
        "zeroclaw_channels" => EventCategory::Channel,
        "zeroclaw_memory" => EventCategory::Memory,
        "zeroclaw_providers" => EventCategory::Provider,
        "zeroclaw_gateway" => EventCategory::System,
        "zeroclaw_log" => EventCategory::Internal,
        "matrix_sdk" | "matrix_sdk_base" | "matrix_sdk_crypto" => EventCategory::Internal,
        _ => EventCategory::System,
    }
}

fn strip_outer_quotes(s: &str) -> String {
    let trimmed = s.trim();
    if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2 {
        return trimmed[1..trimmed.len() - 1].to_string();
    }
    trimmed.to_string()
}
