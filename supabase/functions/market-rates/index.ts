// Scheduled 2x daily. Pulls egg rates for configured NECC zones and broiler trade rates into
// market_rate (platform rows, tenant_id null). NECC publishes a daily declared rate page with no
// public API, so this parser is defensive: any zone that fails to parse keeps yesterday's rate
// and raises a platform notification instead of writing garbage. Confirm NECC's terms before
// commercial use; the adapter interface lets you swap to a licensed feed without touching callers.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const ZONES = ["Hyderabad", "Vijayawada", "Namakkal", "Barwala", "Pune", "Bengaluru"];

interface RateSource { name: string; fetch(): Promise<Array<{ zone: string; product: string; rate: number; unit: string }>>; }

const neccSource: RateSource = {
  name: "NECC",
  async fetch() {
    const html = await (await fetch("https://www.necc.org.in/")).text();
    const out = [];
    for (const zone of ZONES) {
      // table cell pattern: <td>Hyderabad</td><td>595</td>  (paise per egg)
      const m = html.match(new RegExp(`${zone}[^<]*</t[dh]>\\s*<t[dh][^>]*>\\s*(\\d{3})`, "i"));
      if (m) out.push({ zone, product: "egg", rate: Number(m[1]) / 100, unit: "per_egg" });
    }
    return out;
  },
};

const broilerCrowdSource: RateSource = {
  name: "crowd",
  async fetch() { return []; }, // filled by tenant-submitted rates; aggregated below
};

Deno.serve(async () => {
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const today = new Date().toISOString().slice(0, 10);
  let written = 0; const failures: string[] = [];

  for (const src of [neccSource]) {
    try {
      const rows = await src.fetch();
      const got = new Set(rows.map((r) => r.zone));
      for (const z of ZONES) if (!got.has(z)) failures.push(`${src.name}:${z}`);
      if (rows.length) {
        const { error } = await admin.from("market_rate").upsert(rows.map((r) => ({ ...r, source: src.name, rate_date: today, tenant_id: null })), { onConflict: "source,zone,product,rate_date,tenant_id" });
        if (error) failures.push(`${src.name}: ${error.message}`); else written += rows.length;
      }
    } catch (e) { failures.push(`${src.name}: ${String(e)}`); }
  }

  // broiler farm-gate: median of tenant-submitted rates today, per state (crowd source)
  const { data: crowd } = await admin.from("market_rate").select("zone, rate").eq("product", "broiler_farmgate").eq("rate_date", today).not("tenant_id", "is", null);
  const byZone: Record<string, number[]> = {};
  for (const r of crowd ?? []) (byZone[r.zone] ??= []).push(Number(r.rate));
  for (const [zone, vals] of Object.entries(byZone)) {
    vals.sort((a, b) => a - b); const med = vals[Math.floor(vals.length / 2)];
    await admin.from("market_rate").upsert({ source: "crowd", zone, product: "broiler_farmgate", rate_date: today, rate: med, unit: "per_kg", tenant_id: null }, { onConflict: "source,zone,product,rate_date,tenant_id" });
    written++;
  }

  if (failures.length) {
    await admin.from("notification").insert({ tenant_id: null, kind: "alert", severity: "warning", title: "Market-rate feed: parse failures", body: failures.join(", ") });
  }
  return Response.json({ written, failures });
});
