// Schema-driven enumeration of every `providers.<category>.<type>.<alias>.<resource_field>`
// the operator has configured. Two consumers right now:
//   - Dashboard Cost tab — resolves a recorded upstream model id back to
//     its provider type so the "Spend by model" rows can deep-link to
//     `cost.rates.providers.models.<type>` editor pages.
//   - CostRatesEditor — suggests upstream resource ids on the +Add
//     input when the operator is filling in the rate sheet.
//
// Source of truth for the slot list is the macros in
// `crates/zeroclaw-config/src/providers.rs`; this helper just walks the
// live config via the existing map-keyed-section + prop endpoints.
// There is no separate "list configured models" gateway endpoint —
// adding one would just duplicate `getMapKeys` + `getProp`.

import { getMapKeys, getProp } from './api';

export type ConfiguredModelCategory = 'models' | 'tts' | 'transcription';

export interface ConfiguredModelBinding {
  /** Provider type slot (e.g. "anthropic", "openai"). */
  type: string;
  /** Operator-chosen alias (e.g. "glados", "production"). */
  alias: string;
  /** Upstream resource id (model / voice / pipeline name) — the key
   *  the rate sheet uses. May contain hyphens / dots / slashes. */
  resource: string;
}

/** Walk every configured alias under `providers.<category>` and resolve its
 *  bound resource id. Returns one entry per alias whose resource field is
 *  populated; aliases without a resource set are skipped. */
export async function walkConfiguredModelBindings(
  category: ConfiguredModelCategory,
): Promise<ConfiguredModelBinding[]> {
  const root = `providers.${category}`;
  const out: ConfiguredModelBinding[] = [];
  let types: string[];
  try {
    types = (await getMapKeys(root)).keys;
  } catch {
    return out;
  }
  for (const type of types) {
    let aliases: string[];
    try {
      aliases = (await getMapKeys(`${root}.${type}`)).keys;
    } catch {
      continue;
    }
    const results = await Promise.all(
      aliases.map((alias) =>
        getProp(`${root}.${type}.${alias}.model`).catch(() => null),
      ),
    );
    aliases.forEach((alias, i) => {
      const r = results[i];
      const v = r && typeof r.value === 'string' ? r.value : '';
      if (v && v !== '<unset>') {
        out.push({ type, alias, resource: v });
      }
    });
  }
  return out;
}

/** Build `{ <resource_id>: <provider_type> }` from configured bindings.
 *  First binding wins on duplicates — sufficient for deep-link targets
 *  where any plausible owning provider type is good enough. */
export async function resolveModelToProviderType(
  category: ConfiguredModelCategory,
): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const b of await walkConfiguredModelBindings(category)) {
    if (!(b.resource in out)) out[b.resource] = b.type;
  }
  return out;
}

/** Distinct list of configured resource ids for a given (category, type),
 *  preserving config order so suggestion UIs can present them
 *  deterministically. */
export async function configuredResourceIds(
  category: ConfiguredModelCategory,
  type: string,
): Promise<string[]> {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const b of await walkConfiguredModelBindings(category)) {
    if (b.type !== type) continue;
    if (seen.has(b.resource)) continue;
    seen.add(b.resource);
    out.push(b.resource);
  }
  return out;
}
