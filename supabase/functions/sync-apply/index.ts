// Mobile outbox replay. The app POSTs a batch of client operations; each has a client-generated
// op_id (idempotency), a table, an action and a payload. Append-only tables are inserted; LWW
// tables are upserted field-by-field when the client's base_version matches, otherwise returned
// as a conflict for the manager to resolve in-app.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const APPEND_ONLY = new Set(["mortality_event", "stock_movement", "payment", "media", "attendance"]);
const LWW = new Set(["daily_shed_log", "egg_production", "vaccination_schedule", "vet_visit", "maintenance_ticket"]);

type Op = { op_id: string; table: string; action: "insert" | "update"; payload: Record<string, unknown>; base_version?: number };

Deno.serve(async (req) => {
  const auth = req.headers.get("Authorization") ?? "";
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response("unauthorized", { status: 401 });
  const tenantId = (user.app_metadata as Record<string, string>).tenant_id;
  const { device_id, ops } = (await req.json()) as { device_id: string; ops: Op[] };

  const results: Array<{ op_id: string; status: "applied" | "duplicate" | "conflict" | "error"; detail?: unknown }> = [];
  for (const op of ops) {
    // idempotency receipt
    const { error: rErr } = await supabase.from("sync_outbox_receipt").insert({ client_op_id: op.op_id, tenant_id: tenantId, device_id });
    if (rErr?.code === "23505") { results.push({ op_id: op.op_id, status: "duplicate" }); continue; }
    if (!APPEND_ONLY.has(op.table) && !LWW.has(op.table)) { results.push({ op_id: op.op_id, status: "error", detail: "table not syncable" }); continue; }
    const row: Record<string, unknown> = { ...op.payload, tenant_id: tenantId, created_by: user.id };
    // the phone knows the farm and the feed name, not store/item ids: resolve them here
    if (op.table === "stock_movement" && row.farm_id && row.item_name_hint) {
      const { data: store } = await supabase.from("store").select("id").eq("farm_id", row.farm_id as string).limit(1).maybeSingle();
      const { data: item } = await supabase.from("item").select("id").eq("name", row.item_name_hint as string).maybeSingle();
      Object.assign(row, { store_id: store?.id, item_id: item?.id }); delete row.farm_id; delete row.item_name_hint;
    }
    if (APPEND_ONLY.has(op.table) || op.action === "insert") {
      const { error } = await supabase.from(op.table).insert(row);
      results.push(error ? { op_id: op.op_id, status: "error", detail: error.message } : { op_id: op.op_id, status: "applied" });
      continue;
    }
    // LWW update guarded by version
    const { data: current } = await supabase.from(op.table).select("sync_version").eq("id", row.id as string).maybeSingle();
    if (current && op.base_version !== undefined && current.sync_version !== op.base_version) {
      results.push({ op_id: op.op_id, status: "conflict", detail: { server_version: current.sync_version } });
      continue;
    }
    const { error } = await supabase.from(op.table).update({ ...row, sync_version: (current?.sync_version ?? 0) + 1 }).eq("id", row.id as string);
    results.push(error ? { op_id: op.op_id, status: "error", detail: error.message } : { op_id: op.op_id, status: "applied" });
  }
  return Response.json({ results });
});
