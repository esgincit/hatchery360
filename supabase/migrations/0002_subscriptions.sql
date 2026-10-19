-- Platform billing / entitlements, written by provision-tenant and the Razorpay subscription webhook.
create table subscription (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  plan text not null,                                   -- starter | growth | pro | enterprise
  status text not null default 'trialing',              -- trialing | active | past_due | suspended | cancelled
  trial_ends_on date,
  current_period_end date,
  razorpay_subscription_id text,
  bird_limit int,
  farm_limit int,
  farm_types text[] not null default '{layer}',
  features jsonb not null default '{}'::jsonb,          -- {"ai_triage":true,"marketplace":true,"integrator_mode":false,...}
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index on subscription (tenant_id);

create table usage_daily (
  tenant_id uuid not null references tenant(id) on delete cascade,
  usage_date date not null,
  birds int not null default 0,
  farms int not null default 0,
  users int not null default 0,
  photos int not null default 0,
  ai_calls int not null default 0,
  messages int not null default 0,
  primary key (tenant_id, usage_date)
);

alter table subscription enable row level security;
create policy subscription_read on subscription for select using (auth_is_platform() or tenant_id = auth_tenant_id());
create policy subscription_write on subscription for all using (auth_is_platform()) with check (auth_is_platform());
alter table usage_daily enable row level security;
create policy usage_read on usage_daily for select using (auth_is_platform() or tenant_id = auth_tenant_id());

-- platform staff may insert/update tenant rows; tenants only read their own (policy from 0001 covers select)
create policy tenant_platform_write on tenant for all using (auth_is_platform()) with check (auth_is_platform());

-- nightly metering (called by pg_cron: select cron.schedule('meter','15 0 * * *', $$select meter_usage()$$))
create or replace function meter_usage() returns void language sql as $$
  insert into usage_daily (tenant_id, usage_date, birds, farms, users, photos)
  select t.id, current_date,
         coalesce((select sum(birds_alive) from v_batch_kpi k where k.tenant_id = t.id and k.state <> 'closed'), 0),
         (select count(*) from farm f where f.tenant_id = t.id),
         (select count(*) from app_user u where u.tenant_id = t.id),
         (select count(*) from media m where m.tenant_id = t.id and m.created_at::date = current_date)
  from tenant t
  on conflict (tenant_id, usage_date) do update set birds = excluded.birds, farms = excluded.farms, users = excluded.users, photos = excluded.photos;
$$;
