// deno run -A scripts/create_demo_users.ts
// Creates Supabase Auth users for every app_user row in seed.sql (phone login) and sets the JWT
// app_metadata that RLS reads: { tenant_id, roles[], platform }.
import { createClient } from "npm:@supabase/supabase-js@2.45.0";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const { data: users, error } = await admin.from("app_user").select("id, full_name, phone, tenant_id, is_platform_staff, user_role_assignment(role)");
if (error) throw error;

for (const u of users ?? []) {
  const roles = (u.user_role_assignment as Array<{ role: string }>).map((r) => r.role);
  const phone = u.phone?.replace(/\D/g, "");
  const { data, error } = await admin.auth.admin.createUser({
    id: u.id,                      // keep the same uuid as app_user.id
    phone: phone ? `+${phone}` : undefined,
    phone_confirm: true,
    user_metadata: { full_name: u.full_name },
    app_metadata: { tenant_id: u.tenant_id, roles, platform: u.is_platform_staff },
  });
  console.log(error ? `✗ ${u.full_name}: ${error.message}` : `✓ ${u.full_name} (${roles.join(",")}) ${data.user?.phone}`);
}
