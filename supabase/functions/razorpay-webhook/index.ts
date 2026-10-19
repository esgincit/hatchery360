// Razorpay webhook: payment.captured → payment row → allocate to the invoice/bill named in notes.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { createHmac } from "node:crypto";

Deno.serve(async (req) => {
  const raw = await req.text();
  const sig = req.headers.get("x-razorpay-signature") ?? "";
  const expected = createHmac("sha256", Deno.env.get("RAZORPAY_WEBHOOK_SECRET")!).update(raw).digest("hex");
  if (sig !== expected) return new Response("bad signature", { status: 400 });

  const evt = JSON.parse(raw);
  if (evt.event !== "payment.captured") return Response.json({ ignored: evt.event });
  const p = evt.payload.payment.entity;
  const { tenant_id, ref_type, ref_id, party_type, party_id } = p.notes ?? {};
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const amount = p.amount / 100;

  const { error } = await admin.from("payment").insert({ tenant_id, direction: ref_type === "invoice" ? "in" : "out", party_type, party_id, ref_type, ref_id, amount, mode: p.method === "upi" ? "upi" : "neft", paid_on: new Date(p.created_at * 1000).toISOString().slice(0, 10), utr: p.acquirer_data?.rrn ?? p.id });
  if (error) return new Response(error.message, { status: 500 });

  const table = ref_type === "invoice" ? "invoice" : "bill";
  const { data: doc } = await admin.from(table).select("total, paid").eq("id", ref_id).single();
  if (doc) {
    const paid = Number(doc.paid) + amount;
    await admin.from(table).update({ paid, status: paid >= Number(doc.total) ? "paid" : "partial" }).eq("id", ref_id);
  }
  return Response.json({ ok: true });
});
