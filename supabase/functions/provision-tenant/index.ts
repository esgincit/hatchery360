// Platform-admin only. Creates a tenant end to end in one call:
//   tenant row → owner auth user (phone login) with tenant_id/roles claims → app_user + role →
//   subscription/trial → welcome notification → WhatsApp invite with the OTP login link.
// Body: { name, legal_name?, gstin?, state, plan, trial_days, owner_name, owner_phone, language?, farm_types?, features? }
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

Deno.serve(async (req) => {
  // caller must be platform staff
  const caller = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await caller.auth.getUser();
  if (!user || user.app_metadata?.platform !== true) return new Response("forbidden", { status: 403 });

  const b = await req.json();
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const phone = "+" + String(b.owner_phone).replace(/\D/g, "");

  // 1. tenant
  const { data: tenant, error: tErr } = await admin.from("tenant").insert({
    name: b.name, legal_name: b.legal_name ?? b.name, gstin: b.gstin ?? null, state: b.state,
    plan: b.plan ?? "starter", status: (b.trial_days ?? 0) > 0 ? "trial" : "active",
  }).select().single();
  if (tErr) return new Response(tErr.message, { status: 400 });

  // 2. owner auth user — claims are what RLS reads
  const { data: created, error: uErr } = await admin.auth.admin.createUser({
    phone, phone_confirm: true,
    user_metadata: { full_name: b.owner_name },
    app_metadata: { tenant_id: tenant.id, roles: ["tenant_owner"], platform: false },
  });
  if (uErr) { await admin.from("tenant").delete().eq("id", tenant.id); return new Response(uErr.message, { status: 400 }); }
  const ownerId = created.user!.id;

  // 3. profile + role
  await admin.from("app_user").insert({ id: ownerId, tenant_id: tenant.id, full_name: b.owner_name, phone, language: b.language ?? "te" });
  await admin.from("user_role_assignment").insert({ tenant_id: tenant.id, user_id: ownerId, role: "tenant_owner", scope_type: "tenant" });

  // 4. subscription / trial / feature flags (tables added in 0002 — see below)
  const trialEnds = (b.trial_days ?? 0) > 0 ? new Date(Date.now() + b.trial_days * 864e5).toISOString().slice(0, 10) : null;
  await admin.from("subscription").insert({ tenant_id: tenant.id, plan: b.plan ?? "starter", status: trialEnds ? "trialing" : "active", trial_ends_on: trialEnds, farm_types: b.farm_types ?? ["layer"], features: b.features ?? { ai_triage: true, marketplace: true } });

  // 5. welcome + onboarding
  await admin.from("notification").insert([
    { tenant_id: tenant.id, user_id: ownerId, kind: "info", severity: "info", title: `Welcome to PoultryOS, ${b.owner_name.split(" ")[0]}`, body: "Finish setup: add your first farm, sheds and a batch." },
    { tenant_id: tenant.id, user_id: ownerId, kind: "reminder", severity: "warning", title: "Add your first farm", body: "Onboarding wizard · 5 steps · about 10 minutes." },
  ]);
  await admin.from("audit_log").insert({ tenant_id: tenant.id, user_id: user.id, action: "tenant.provisioned", entity_type: "tenant", entity_id: tenant.id, after: { plan: b.plan, trial_ends_on: trialEnds, by: user.id } });

  // 6. WhatsApp invite (template must be approved in Meta Business Manager)
  const token = Deno.env.get("WHATSAPP_TOKEN"), phoneId = Deno.env.get("WHATSAPP_PHONE_ID");
  if (token && phoneId) {
    await fetch(`https://graph.facebook.com/v19.0/${phoneId}/messages`, {
      method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ messaging_product: "whatsapp", to: phone.slice(1), type: "template",
        template: { name: "poultryos_welcome", language: { code: b.language ?? "te" }, components: [{ type: "body", parameters: [{ type: "text", text: b.owner_name }, { type: "text", text: b.name }] }] } }),
    });
  }
  return Response.json({ tenant_id: tenant.id, owner_user_id: ownerId, trial_ends_on: trialEnds });
});
