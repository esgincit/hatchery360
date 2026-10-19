// Scheduled nightly. For every tenant: mortality spike vs 7-day baseline, vaccinations due in
// 3 days or overdue, stock below reorder, bills due in 7 days, invoices overdue. Writes
// notification rows (push via Realtime/FCM) and sends the owner a WhatsApp daily summary.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const inr = (n: number) => "₹" + Math.round(n).toLocaleString("en-IN");

async function whatsapp(to: string, body: string) {
  const token = Deno.env.get("WHATSAPP_TOKEN"), phoneId = Deno.env.get("WHATSAPP_PHONE_ID");
  if (!token || !phoneId) return;
  await fetch(`https://graph.facebook.com/v19.0/${phoneId}/messages`, {
    method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", to, type: "text", text: { body } }),
  });
}

Deno.serve(async () => {
  const today = new Date().toISOString().slice(0, 10);
  const { data: tenants } = await admin.from("tenant").select("id,name").eq("status", "active");
  const summary: Record<string, number> = {};

  for (const t of tenants ?? []) {
    const notes: Array<{ severity: string; title: string; body: string; entity_type?: string; entity_id?: string }> = [];

    // mortality spike: today's deaths vs mean of previous 7 days, per active batch
    const { data: kpi } = await admin.from("v_batch_kpi").select("batch_id, code").eq("tenant_id", t.id).neq("state", "closed");
    for (const b of kpi ?? []) {
      const { data: logs } = await admin.from("daily_shed_log").select("log_date, mortality").eq("batch_id", b.batch_id).order("log_date", { ascending: false }).limit(8);
      if (!logs || logs.length < 4) continue;
      const [todayLog, ...prev] = logs; const base = prev.reduce((a, l) => a + l.mortality, 0) / prev.length;
      if (todayLog.mortality > 5 && todayLog.mortality > 1.8 * base) {
        notes.push({ severity: "critical", title: `Mortality ${(todayLog.mortality / Math.max(base, 1)).toFixed(1)}× baseline — ${b.code}`, body: `${todayLog.mortality} deaths today vs 7-day baseline ${base.toFixed(1)}/day. Upload photos for AI triage and call the vet.`, entity_type: "batch", entity_id: b.batch_id });
      }
    }
    // vaccinations due / overdue
    const { data: vacc } = await admin.from("vaccination_schedule").select("batch_id, due_date, vaccine_master(name)").eq("tenant_id", t.id).is("done_on", null).lte("due_date", new Date(Date.now() + 3 * 864e5).toISOString().slice(0, 10));
    for (const v of vacc ?? []) {
      const overdue = v.due_date < today;
      notes.push({ severity: overdue ? "critical" : "warning", title: `${overdue ? "Overdue" : "Due"}: ${(v as any).vaccine_master?.name}`, body: `Due ${v.due_date}.`, entity_type: "batch", entity_id: v.batch_id });
    }
    // stock below reorder
    const { data: stock } = await admin.from("v_stock_balance").select("item_id, qty, item(name, reorder_level, unit)").eq("tenant_id", t.id);
    for (const s of stock ?? []) {
      const it = (s as any).item; if (it?.reorder_level != null && Number(s.qty) <= Number(it.reorder_level)) notes.push({ severity: "warning", title: `Stock below reorder: ${it.name}`, body: `${s.qty} ${it.unit} on hand, reorder level ${it.reorder_level}.` });
    }
    // money
    const { data: ap } = await admin.from("bill").select("total, paid").eq("tenant_id", t.id).neq("status", "paid").lte("due_date", new Date(Date.now() + 7 * 864e5).toISOString().slice(0, 10));
    const apDue = (ap ?? []).reduce((a, b) => a + Number(b.total) - Number(b.paid), 0);
    const { data: ar } = await admin.from("invoice").select("total, paid").eq("tenant_id", t.id).neq("status", "paid").lt("due_date", today);
    const arOver = (ar ?? []).reduce((a, b) => a + Number(b.total) - Number(b.paid), 0);
    if (apDue) notes.push({ severity: "info", title: `${inr(apDue)} payable in next 7 days`, body: `${ap!.length} bills.` });
    if (arOver) notes.push({ severity: "warning", title: `${inr(arOver)} receivable overdue`, body: `${ar!.length} invoices. Send WhatsApp reminders?` });

    if (notes.length) await admin.from("notification").insert(notes.map((n) => ({ ...n, tenant_id: t.id, kind: n.severity === "info" ? "info" : "alert" })));

    // WhatsApp summary to owner(s)
    const { data: owners } = await admin.from("user_role_assignment").select("app_user(phone)").eq("tenant_id", t.id).eq("role", "tenant_owner");
    const text = `PoultryOS daily summary — ${t.name}\n` + notes.slice(0, 6).map((n) => `• ${n.title}`).join("\n") + (notes.length > 6 ? `\n…and ${notes.length - 6} more in the app` : "");
    for (const o of owners ?? []) { const ph = (o as any).app_user?.phone?.replace(/\D/g, ""); if (ph) await whatsapp(ph, text); }
    summary[t.name] = notes.length;
  }
  return Response.json(summary);
});
