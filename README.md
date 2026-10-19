# PoultryOS — multi-tenant poultry farm SaaS (India)

Layer · broiler · hatchery · 360° operations on Supabase + Flutter.

```
poultryos/
├─ supabase/
│  ├─ config.toml                    Supabase CLI project config
│  ├─ migrations/0001_schema.sql     tables, enums, RLS policies, KPI views
│  ├─ seed.sql                       demo data: VKR Poultry Farms + KS Farms (generated)
│  └─ functions/
│     ├─ market-rates/index.ts       scheduled: pull NECC / broiler rates into market_rate
│     ├─ daily-alerts/index.ts       scheduled: mortality spikes, vaccinations due, low stock → notification + WhatsApp
│     ├─ sync-apply/index.ts         mobile outbox replay (idempotent, LWW, append-only events)
│     ├─ ai-triage/index.ts          photo → disease triage via Claude vision → disease_case
│     └─ razorpay-webhook/index.ts   payment webhook → payment rows → bill/invoice status
├─ mobile/                           Flutter app (Riverpod + Drift offline store + supabase_flutter)
├─ scripts/
│  ├─ gen_seed.py                    regenerates supabase/seed.sql and demo/data.json
│  └─ create_demo_users.ts           creates the seed users in Supabase Auth with tenant claims
├─ demo/index.html + data.json       clickable mobile-view demo (published as a Claude artifact)
└─ .github/workflows/                CI: db migrate on main, Flutter build on tag
```

## 1. Supabase project (10 minutes)

```bash
npm i -g supabase
supabase login
supabase projects create poultryos --region ap-south-1 --org-id <your-org>   # Mumbai
supabase link --project-ref <project-ref>

# apply schema + RLS + views, then the demo seed
supabase db push                                   # runs supabase/migrations/*
psql "$SUPABASE_DB_URL" -f supabase/seed.sql       # DB URL from Project Settings → Database

# storage buckets (photos are private, served by signed URL)
supabase storage create evidence --private
supabase storage create documents --private
```

### Auth: tenant_id and roles as JWT claims

RLS reads `request.jwt.claims -> app_metadata -> tenant_id`. Set it on each user with the
service role (`scripts/create_demo_users.ts` does this for the seed users):

```ts
await admin.auth.admin.updateUserById(userId, {
  app_metadata: { tenant_id: '<tenant uuid>', roles: ['farm_manager'], platform: false }
})
```

Enable **Phone (OTP)** in Authentication → Providers with MSG91 or Twilio as the SMS provider.
Run `deno run -A scripts/create_demo_users.ts` with `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
set; demo logins are the phone numbers in `seed.sql` (OTP delivered by your SMS provider; in
local dev use the Auth “test OTP” setting).

### Edge functions

```bash
supabase secrets set ANTHROPIC_API_KEY=... RAZORPAY_WEBHOOK_SECRET=... WHATSAPP_TOKEN=... WHATSAPP_PHONE_ID=...
supabase functions deploy market-rates daily-alerts sync-apply ai-triage razorpay-webhook provision-tenant

# schedules (pg_cron + pg_net are enabled on Supabase)
psql "$SUPABASE_DB_URL" -c "select cron.schedule('market-rates','5 7,19 * * *',
  \$\$select net.http_post(url:='https://<ref>.functions.supabase.co/market-rates',
  headers:='{\"Authorization\":\"Bearer <anon-key>\"}'::jsonb)\$\$);"
psql "$SUPABASE_DB_URL" -c "select cron.schedule('daily-alerts','30 20 * * *',
  \$\$select net.http_post(url:='https://<ref>.functions.supabase.co/daily-alerts',
  headers:='{\"Authorization\":\"Bearer <anon-key>\"}'::jsonb)\$\$);"
```

## 2. Mobile app (Flutter)

```bash
cd mobile
flutter pub get
dart run build_runner build -d                      # Drift tables
cp lib/env.example.dart lib/env.dart                # paste SUPABASE_URL + anon key
flutter run                                         # Android emulator / device
```

Release builds: `flutter build appbundle --release` (Play) and `flutter build ipa --release`
(App Store); `.github/workflows/mobile.yml` does both on a `v*` tag with Fastlane lanes in
`mobile/android/fastlane` and `mobile/ios/fastlane` (add your store credentials as secrets).

## 3. Admin web (optional, Phase 1 end)

`web/` is not in this scaffold. Create with `npm create vite@latest web -- --template react-ts`
and `npm i @supabase/supabase-js @tanstack/react-query`; the same anon key + RLS apply.
Deploy on Vercel/Netlify or Supabase-hosted static.

## 4. Local development

```bash
supabase start                                      # local Postgres + Auth + Storage (Docker)
supabase db reset                                   # migrations + seed.sql
supabase functions serve                            # edge functions with hot reload
```

## 5. Regenerate demo data

`python3 scripts/gen_seed.py` rewrites `supabase/seed.sql` and `demo/data.json` from one
deterministic generator (same UUIDs every run). Edit tenants, vendors, items or batch shapes
there, not in the SQL.

## 6. What's verified

* `0001_schema.sql` + `seed.sql` apply cleanly on PostgreSQL 16.
* `v_batch_kpi`, `v_ap_ageing`, `v_ar_ageing`, `v_stock_balance` return expected numbers.
* RLS: a JWT with VKR's `tenant_id` sees 5 of 9 batches and 0 KS rows; an unknown tenant sees 0 rows.
