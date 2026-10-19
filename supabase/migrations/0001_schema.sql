-- PoultryOS — Supabase schema (multi-tenant, RLS)
-- Apply with: supabase db push   (or psql -f on a local Postgres for testing)

create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------
create type farm_type as enum ('layer','broiler','breeder','hatchery');
create type shed_type as enum ('cage','deep_litter','environment_controlled');
create type batch_state as enum ('planned','placed','brooding','growing','laying','finishing','lifting','closed');
create type app_role as enum ('platform_admin','platform_support','tenant_owner','finance','farm_manager','shed_supervisor','veterinarian','store_keeper','vendor','customer','contract_farmer','auditor');
create type vendor_category as enum ('doc_hatchery','feed','feed_ingredient','medicine','vaccine','equipment','transport','labour_contractor','packaging','fuel','other');
create type item_category as enum ('feed','feed_ingredient','medicine','vaccine','disinfectant','equipment','spare','packaging','fuel','egg','bird','manure','other');
create type stock_move_type as enum ('grn','issue','transfer','adjust','count','sale','return');
create type doc_status as enum ('draft','submitted','approved','partial','closed','cancelled');
create type pay_status as enum ('unpaid','partial','paid','overdue');
create type egg_grade as enum ('jumbo','large','medium','small','cracked','dirty');

-- ---------------------------------------------------------------
-- Tenancy
-- ---------------------------------------------------------------
create table tenant (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  legal_name text,
  gstin text,
  pan text,
  state text,
  plan text not null default 'starter',
  status text not null default 'active',
  created_at timestamptz not null default now()
);

create table farm (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  name text not null,
  farm_type farm_type not null,
  district text, state text, village text,
  lat numeric(9,6), lng numeric(9,6),
  capacity_birds int,
  created_at timestamptz not null default now()
);

create table shed (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id) on delete cascade,
  name text not null,
  shed_type shed_type not null default 'cage',
  capacity_birds int not null,
  area_sqft int,
  created_at timestamptz not null default now()
);

-- Profile row per auth.users row
create table app_user (
  id uuid primary key,                         -- = auth.users.id
  tenant_id uuid references tenant(id) on delete cascade,  -- null for platform staff
  full_name text not null,
  phone text,
  language text not null default 'te',
  is_platform_staff boolean not null default false,
  created_at timestamptz not null default now()
);

create table user_role_assignment (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenant(id) on delete cascade,
  user_id uuid not null references app_user(id) on delete cascade,
  role app_role not null,
  scope_type text not null default 'tenant',   -- tenant | farm | shed
  scope_id uuid,
  unique (user_id, role, scope_type, scope_id)
);

-- ---------------------------------------------------------------
-- Masters (platform-level, tenant_id null = global)
-- ---------------------------------------------------------------
create table breed (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenant(id),
  name text not null,
  farm_type farm_type not null,
  supplier text
);

create table breed_standard_curve (
  id bigserial primary key,
  breed_id uuid not null references breed(id) on delete cascade,
  age_week int not null,
  std_egg_pct numeric(5,2),
  std_weight_g int,
  std_feed_g_per_bird int,
  std_cum_mortality_pct numeric(5,2),
  unique (breed_id, age_week)
);

create table vaccine_master (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenant(id),
  name text not null,
  disease text not null,
  route text,                                   -- eye drop, drinking water, s/c, wing web
  farm_type farm_type not null,
  age_day int not null
);

create table disease_master (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  category text,                                -- viral, bacterial, protozoal, metabolic
  signs text,
  first_actions text
);

create table market_rate (
  id bigserial primary key,
  source text not null,                         -- NECC | trade | crowd | tenant
  zone text not null,                           -- Hyderabad, Vijayawada, Namakkal...
  product text not null,                        -- egg | broiler_farmgate | broiler_retail | doc | maize | soya
  rate_date date not null,
  rate numeric(10,2) not null,
  unit text not null default 'per_unit',
  tenant_id uuid references tenant(id),
  unique (source, zone, product, rate_date, tenant_id)
);

-- ---------------------------------------------------------------
-- Flock
-- ---------------------------------------------------------------
create table batch (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  shed_id uuid not null references shed(id),
  code text not null,
  farm_type farm_type not null,
  breed_id uuid references breed(id),
  source_vendor_id uuid,                        -- hatchery
  placed_on date not null,
  doc_count int not null,
  doc_rate numeric(10,2),                       -- ₹ per chick
  state batch_state not null default 'placed',
  expected_close_on date,
  closed_on date,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

create table batch_state_history (
  id bigserial primary key,
  batch_id uuid not null references batch(id) on delete cascade,
  state batch_state not null,
  changed_on date not null,
  changed_by uuid
);

-- ---------------------------------------------------------------
-- Daily operations
-- ---------------------------------------------------------------
create table daily_shed_log (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  batch_id uuid not null references batch(id),
  shed_id uuid not null references shed(id),
  log_date date not null,
  birds_opening int not null,
  mortality int not null default 0,
  culls int not null default 0,
  feed_kg numeric(10,2) not null default 0,
  water_litres numeric(10,2),
  temp_min_c numeric(4,1), temp_max_c numeric(4,1), humidity_pct numeric(4,1),
  avg_weight_g int,                             -- broiler sample
  remarks text,
  locked boolean not null default false,
  created_by uuid, created_at timestamptz not null default now(),
  unique (batch_id, log_date),
  sync_version int not null default 1
);

create table egg_production (
  id bigserial primary key,
  tenant_id uuid not null references tenant(id) on delete cascade,
  daily_log_id uuid not null references daily_shed_log(id) on delete cascade,
  grade egg_grade not null,
  count int not null,
  unique (daily_log_id, grade)
);

create table mortality_event (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  batch_id uuid not null references batch(id),
  event_date date not null,
  count int not null,
  cause_code text references disease_master(code),
  notes text,
  created_by uuid, created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- Health
-- ---------------------------------------------------------------
create table vaccination_schedule (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  batch_id uuid not null references batch(id) on delete cascade,
  vaccine_id uuid not null references vaccine_master(id),
  due_date date not null,
  done_on date,
  done_by uuid,
  doses int,
  lot_no text,
  notes text,
  sync_version int not null default 1
);

create table vet_visit (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  batch_id uuid references batch(id),
  visit_date date not null,
  vet_name text not null,
  findings text,
  prescription text,
  follow_up_on date,
  fee numeric(10,2),
  sync_version int not null default 1
);

create table disease_case (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  batch_id uuid not null references batch(id),
  opened_on date not null,
  disease_code text references disease_master(code),
  ai_top_condition text,
  ai_confidence numeric(4,3),
  ai_model_version text,
  vet_confirmed boolean,
  status text not null default 'open',
  notes text
);

-- ---------------------------------------------------------------
-- Inventory, vendors, procurement
-- ---------------------------------------------------------------
create table vendor (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  name text not null,
  category vendor_category not null,
  contact_name text, phone text, email text,
  gstin text, pan text,
  address text, district text, state text,
  bank_account_last4 text, ifsc text,
  payment_terms_days int not null default 15,
  rating numeric(2,1),
  is_verified boolean not null default false,
  created_at timestamptz not null default now()
);

alter table batch add constraint batch_source_vendor_fk foreign key (source_vendor_id) references vendor(id);

create table item (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  name text not null,
  category item_category not null,
  unit text not null,                            -- kg, bag50, litre, vial, dose, nos, tray
  hsn text,
  gst_pct numeric(4,2) not null default 0,
  reorder_level numeric(12,2),
  default_vendor_id uuid references vendor(id),
  unique (tenant_id, name)
);

create table store (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  name text not null
);

create table purchase_order (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  vendor_id uuid not null references vendor(id),
  po_no text not null,
  po_date date not null,
  expected_on date,
  status doc_status not null default 'submitted',
  total numeric(14,2) not null default 0,
  unique (tenant_id, po_no)
);

create table po_line (
  id bigserial primary key,
  po_id uuid not null references purchase_order(id) on delete cascade,
  item_id uuid not null references item(id),
  qty numeric(12,2) not null,
  rate numeric(12,2) not null,
  gst_pct numeric(4,2) not null default 0
);

create table stock_movement (
  id bigserial primary key,
  tenant_id uuid not null references tenant(id) on delete cascade,
  store_id uuid not null references store(id),
  item_id uuid not null references item(id),
  move_type stock_move_type not null,
  qty numeric(12,2) not null,                    -- +in / -out
  rate numeric(12,2),
  batch_id uuid references batch(id),
  ref_type text, ref_id uuid,
  lot_no text, expiry_on date,
  moved_on date not null,
  created_by uuid, created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------
create table customer (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  name text not null,
  kind text not null default 'trader',          -- trader | retailer | integrator | wholesaler
  phone text, gstin text, district text, state text,
  credit_limit numeric(14,2) default 0,
  credit_days int default 7
);

create table invoice (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  customer_id uuid not null references customer(id),
  invoice_no text not null,
  invoice_date date not null,
  due_date date not null,
  product text not null,                         -- egg | bird | doc | manure | spent_hen
  qty numeric(12,2) not null,
  unit text not null,
  rate numeric(12,2) not null,
  gst_pct numeric(4,2) not null default 0,
  total numeric(14,2) not null,
  paid numeric(14,2) not null default 0,
  status pay_status not null default 'unpaid',
  batch_id uuid references batch(id),
  unique (tenant_id, invoice_no)
);

create table bill (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  vendor_id uuid not null references vendor(id),
  po_id uuid references purchase_order(id),
  bill_no text not null,
  bill_date date not null,
  due_date date not null,
  category text not null,                        -- chick | feed | medicine | equipment | transport | labour | fuel | other
  total numeric(14,2) not null,
  paid numeric(14,2) not null default 0,
  status pay_status not null default 'unpaid',
  batch_id uuid references batch(id)
);

create table payment (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  direction text not null,                       -- in | out
  party_type text not null,                      -- vendor | customer
  party_id uuid not null,
  ref_type text, ref_id uuid,                    -- bill | invoice
  amount numeric(14,2) not null,
  mode text not null,                            -- upi | neft | cash | cheque
  paid_on date not null,
  utr text
);

-- ---------------------------------------------------------------
-- Labour, assets
-- ---------------------------------------------------------------
create table worker (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  name text not null,
  role text not null,                            -- supervisor | helper | driver | security
  wage_type text not null default 'monthly',     -- monthly | daily | piece
  wage_rate numeric(10,2) not null,
  phone text,
  active boolean not null default true
);

create table attendance (
  id bigserial primary key,
  tenant_id uuid not null references tenant(id) on delete cascade,
  worker_id uuid not null references worker(id),
  att_date date not null,
  status text not null,                          -- present | absent | half | leave
  unique (worker_id, att_date)
);

create table asset (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  farm_id uuid not null references farm(id),
  shed_id uuid references shed(id),
  name text not null,
  category text not null,                        -- feeder | drinker | fan | generator | incubator | grader | vehicle
  purchased_on date, cost numeric(14,2),
  next_service_on date,
  status text not null default 'ok'
);

create table maintenance_ticket (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  asset_id uuid not null references asset(id),
  opened_on date not null,
  issue text not null,
  priority text not null default 'medium',
  status text not null default 'open',
  closed_on date, cost numeric(12,2),
  sync_version int not null default 1
);

-- ---------------------------------------------------------------
-- Evidence, notifications, audit
-- ---------------------------------------------------------------
create table media (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  storage_path text not null,
  sha256 text,
  lat numeric(9,6), lng numeric(9,6),
  taken_at timestamptz,
  device_id text,
  entity_type text not null,
  entity_id uuid not null,
  created_by uuid, created_at timestamptz not null default now()
);

create table notification (
  id bigserial primary key,
  tenant_id uuid not null references tenant(id) on delete cascade,
  user_id uuid references app_user(id),
  kind text not null,                            -- alert | reminder | info
  severity text not null default 'info',
  title text not null,
  body text,
  entity_type text, entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table audit_log (
  id bigserial primary key,
  tenant_id uuid,
  user_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before jsonb, after jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- Sync support
-- ---------------------------------------------------------------
create table sync_outbox_receipt (
  client_op_id uuid primary key,                 -- idempotency for mobile outbox replay
  tenant_id uuid not null,
  device_id text not null,
  applied_at timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- Helper: current tenant / role from JWT claims
-- ---------------------------------------------------------------
create or replace function auth_tenant_id() returns uuid
language sql stable as $$
  select nullif(coalesce(
    current_setting('request.jwt.claims', true)::jsonb ->> 'tenant_id',
    (current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'tenant_id')
  ), '')::uuid
$$;

create or replace function auth_is_platform() returns boolean
language sql stable as $$
  select coalesce(
    (current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'platform')::boolean,
    false)
$$;

-- ---------------------------------------------------------------
-- RLS: one policy pattern for every tenant table
-- ---------------------------------------------------------------
do $$
declare t text;
begin
  for t in select unnest(array[
    'farm','shed','app_user','user_role_assignment','batch','daily_shed_log','egg_production',
    'mortality_event','vaccination_schedule','vet_visit','disease_case','vendor','item','store','purchase_order',
    'stock_movement','customer','invoice','bill','payment','worker','attendance','asset','maintenance_ticket',
    'media','notification','audit_log'])
  loop
    execute format('alter table %I enable row level security', t);
    execute format($p$create policy %I_tenant_isolation on %I
      using (auth_is_platform() or tenant_id = auth_tenant_id())
      with check (auth_is_platform() or tenant_id = auth_tenant_id())$p$, t, t);
  end loop;
end $$;

-- tenant table: a user sees only their own tenant row
alter table tenant enable row level security;
create policy tenant_self on tenant using (auth_is_platform() or id = auth_tenant_id());

-- child tables without tenant_id inherit through their parent (RLS on the parent filters the join)
alter table batch_state_history enable row level security;
create policy bsh_via_batch on batch_state_history using (exists (select 1 from batch b where b.id = batch_id));

-- po_line has no tenant_id: inherit through PO
alter table po_line enable row level security;
create policy po_line_via_po on po_line using (exists (select 1 from purchase_order p where p.id = po_id));

-- global masters readable by all authenticated users; tenant extensions isolated
alter table breed enable row level security;
create policy breed_read on breed for select using (tenant_id is null or tenant_id = auth_tenant_id() or auth_is_platform());
create policy breed_write on breed for all using (auth_is_platform() or tenant_id = auth_tenant_id()) with check (auth_is_platform() or tenant_id = auth_tenant_id());
alter table breed_standard_curve enable row level security;
create policy curve_read on breed_standard_curve for select using (true);
alter table vaccine_master enable row level security;
create policy vaccine_read on vaccine_master for select using (tenant_id is null or tenant_id = auth_tenant_id() or auth_is_platform());
alter table disease_master enable row level security;
create policy disease_read on disease_master for select using (true);
alter table market_rate enable row level security;
create policy rate_read on market_rate for select using (tenant_id is null or tenant_id = auth_tenant_id() or auth_is_platform());
create policy rate_write on market_rate for all using (auth_is_platform() or tenant_id = auth_tenant_id()) with check (auth_is_platform() or tenant_id = auth_tenant_id());

-- ---------------------------------------------------------------
-- Views for dashboards
-- ---------------------------------------------------------------
create or replace view v_batch_kpi as
with logs as (
  select l.batch_id,
         sum(l.mortality + l.culls) as dead,
         sum(l.feed_kg) as feed_kg,
         max(l.log_date) as last_log,
         min(l.birds_opening) as birds_now
  from daily_shed_log l group by l.batch_id
), eggs as (
  select l.batch_id, sum(e.count) as eggs,
         sum(e.count) filter (where e.grade not in ('cracked','dirty')) as saleable_eggs
  from egg_production e join daily_shed_log l on l.id = e.daily_log_id group by l.batch_id
), cost as (
  select batch_id, sum(total) as cost from bill where batch_id is not null group by batch_id
), rev as (
  select batch_id, sum(total) as revenue from invoice where batch_id is not null group by batch_id
)
select b.id as batch_id, b.tenant_id, b.farm_id, b.shed_id, b.code, b.farm_type, b.state, b.placed_on,
       (current_date - b.placed_on) as age_days,
       b.doc_count,
       coalesce(l.dead,0) as cum_mortality,
       round(100.0 * coalesce(l.dead,0) / nullif(b.doc_count,0), 2) as mortality_pct,
       b.doc_count - coalesce(l.dead,0) as birds_alive,
       coalesce(l.feed_kg,0) as feed_kg,
       coalesce(e.eggs,0) as eggs,
       coalesce(e.saleable_eggs,0) as saleable_eggs,
       coalesce(c.cost,0) + coalesce(b.doc_count * b.doc_rate,0) as cost_total,
       coalesce(r.revenue,0) as revenue,
       case when coalesce(e.saleable_eggs,0) > 0
            then round((coalesce(c.cost,0) + coalesce(b.doc_count*b.doc_rate,0)) / e.saleable_eggs, 2) end as cost_per_egg,
       l.last_log
from batch b
left join logs l on l.batch_id = b.id
left join eggs e on e.batch_id = b.id
left join cost c on c.batch_id = b.id
left join rev r on r.batch_id = b.id;

create or replace view v_ap_ageing as
select tenant_id, vendor_id,
       sum(total - paid) filter (where current_date - due_date <= 0) as not_due,
       sum(total - paid) filter (where current_date - due_date between 1 and 30) as d1_30,
       sum(total - paid) filter (where current_date - due_date between 31 and 60) as d31_60,
       sum(total - paid) filter (where current_date - due_date > 60) as d60_plus,
       sum(total - paid) as outstanding
from bill where status <> 'paid' group by tenant_id, vendor_id;

create or replace view v_ar_ageing as
select tenant_id, customer_id,
       sum(total - paid) filter (where current_date - due_date <= 0) as not_due,
       sum(total - paid) filter (where current_date - due_date between 1 and 30) as d1_30,
       sum(total - paid) filter (where current_date - due_date between 31 and 60) as d31_60,
       sum(total - paid) filter (where current_date - due_date > 60) as d60_plus,
       sum(total - paid) as outstanding
from invoice where status <> 'paid' group by tenant_id, customer_id;

create or replace view v_stock_balance as
select tenant_id, store_id, item_id, sum(qty) as qty
from stock_movement group by tenant_id, store_id, item_id;

-- Indexes
create index on daily_shed_log (tenant_id, log_date desc);
create index on daily_shed_log (batch_id, log_date desc);
create index on stock_movement (tenant_id, item_id, moved_on desc);
create index on bill (tenant_id, status, due_date);
create index on invoice (tenant_id, status, due_date);
create index on market_rate (product, zone, rate_date desc);
create index on notification (tenant_id, user_id, read_at);
