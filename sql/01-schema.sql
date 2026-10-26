-- MONARC relational model. Run this first in a new Supabase project.
-- Do not use this script on the Atlas Wear project; MONARC should have its own database.
create extension if not exists pgcrypto;
create sequence if not exists public.monarc_order_sequence;

grant usage on schema public to anon, authenticated;

create table if not exists public.monarc_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null,
  role text not null check (role in ('owner','manager','order_agent','warehouse','finance')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.monarc_categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name_fr text not null,
  name_en text not null,
  name_ar text not null,
  sort_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.monarc_products (
  id uuid primary key default gen_random_uuid(),
  category_slug text not null references public.monarc_categories(slug),
  name_fr text not null,
  name_en text not null,
  name_ar text not null,
  description_fr text not null default '',
  description_en text not null default '',
  description_ar text not null default '',
  price_dzd integer not null check (price_dzd >= 0),
  compare_at_dzd integer check (compare_at_dzd is null or compare_at_dzd >= 0),
  purchase_cost_dzd integer check (purchase_cost_dzd is null or purchase_cost_dzd >= 0),
  sku text unique,
  images text[] not null default '{}',
  tags text[] not null default '{}',
  tag_fr text not null default '',
  status text not null default 'draft' check (status in ('draft','published','archived')),
  featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.monarc_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.monarc_products(id) on delete restrict,
  sku text not null unique,
  size text not null,
  color_fr text not null default '',
  color_en text not null default '',
  color_ar text not null default '',
  price_override_dzd integer check (price_override_dzd is null or price_override_dzd >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(product_id,size,color_fr)
);

create table if not exists public.monarc_inventory (
  variant_id uuid primary key references public.monarc_variants(id) on delete restrict,
  on_hand integer not null default 0 check (on_hand >= 0),
  reserved integer not null default 0 check (reserved >= 0 and reserved <= on_hand),
  low_stock_threshold integer not null default 3 check (low_stock_threshold >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.monarc_customers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text not null unique,
  email text,
  preferred_language text not null default 'fr' check (preferred_language in ('fr','ar','en')),
  consent_marketing boolean not null default false,
  internal_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.monarc_delivery_providers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default false,
  supports_home boolean not null default true,
  supports_office boolean not null default false,
  tracking_url_template text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.monarc_delivery_rates (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.monarc_delivery_providers(id) on delete cascade,
  wilaya_code text not null check (wilaya_code ~ '^(0[1-9]|[1-5][0-9])$'),
  delivery_type text not null check (delivery_type in ('home','office')),
  fee_dzd integer not null check (fee_dzd >= 0),
  estimated_days integer check (estimated_days is null or estimated_days >= 0),
  unique(provider_id,wilaya_code,delivery_type)
);

create table if not exists public.monarc_orders (
  id uuid primary key default gen_random_uuid(),
  order_no text not null unique,
  tracking_token uuid not null default gen_random_uuid() unique,
  customer_id uuid not null references public.monarc_customers(id) on delete restrict,
  status text not null default 'pending_confirmation' check (status in ('pending_confirmation','confirmed','rejected','preparing','shipped','delivered','delivery_failed','returned','cancelled')),
  payment_method text not null check (payment_method in ('cod','ccp')),
  payment_status text not null check (payment_status in ('cod_due','ccp_pending_contact','awaiting_transfer','partially_paid','paid','refunded')),
  provider_id uuid references public.monarc_delivery_providers(id) on delete set null,
  delivery_type text not null check (delivery_type in ('home','office')),
  wilaya_code text not null,
  commune text not null,
  address text not null,
  shipping_fee_dzd integer not null default 0 check (shipping_fee_dzd >= 0),
  shipping_quote_pending boolean not null default true,
  tracking_number text,
  subtotal_dzd integer not null check (subtotal_dzd >= 0),
  total_dzd integer not null check (total_dzd >= 0),
  customer_note text not null default '',
  privacy_consent boolean not null default false,
  internal_note text not null default '',
  confirmed_by uuid references public.monarc_staff(user_id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.monarc_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.monarc_orders(id) on delete restrict,
  product_id uuid not null references public.monarc_products(id) on delete restrict,
  variant_id uuid not null references public.monarc_variants(id) on delete restrict,
  sku_snapshot text not null,
  product_name_fr text not null,
  product_name_en text not null,
  product_name_ar text not null,
  size_snapshot text not null,
  color_fr_snapshot text not null default '',
  color_en_snapshot text not null default '',
  color_ar_snapshot text not null default '',
  unit_price_dzd integer not null check (unit_price_dzd >= 0),
  cost_snapshot_dzd integer not null default 0 check (cost_snapshot_dzd >= 0),
  quantity integer not null check (quantity > 0),
  line_total_dzd integer not null check (line_total_dzd >= 0)
);

create table if not exists public.monarc_payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.monarc_orders(id) on delete restrict,
  method text not null check (method in ('cod','ccp')),
  amount_dzd integer not null check (amount_dzd > 0),
  reference text not null default '',
  note text not null default '',
  status text not null default 'recorded' check (status in ('recorded','refunded','void')),
  recorded_by uuid references public.monarc_staff(user_id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.monarc_order_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.monarc_orders(id) on delete restrict,
  from_status text,
  to_status text not null,
  actor_id uuid references public.monarc_staff(user_id) on delete set null,
  actor_label text not null default 'System',
  reason text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.monarc_inventory_movements (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.monarc_variants(id) on delete restrict,
  order_id uuid references public.monarc_orders(id) on delete restrict,
  delta_on_hand integer not null default 0,
  delta_reserved integer not null default 0,
  reason text not null,
  actor_id uuid references public.monarc_staff(user_id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.monarc_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.monarc_staff(user_id) on delete set null,
  actor_label text not null default 'System',
  action text not null,
  entity_type text not null,
  entity_id uuid,
  reason text not null default '',
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.monarc_settings (
  id boolean primary key default true check (id = true),
  shop_name_fr text not null default 'MONARC',
  shop_name_en text not null default 'MONARC',
  shop_name_ar text not null default 'MONARC',
  whatsapp text not null default '',
  contact_email text not null default '',
  announcement_fr text not null default 'NOUVELLE COLLECTION · LIVRAISON DANS LES 58 WILAYAS',
  announcement_en text not null default 'NEW COLLECTION · DELIVERY ACROSS ALGERIA',
  announcement_ar text not null default 'مجموعة جديدة · توصيل إلى كل الولايات',
  cod_enabled boolean not null default true,
  ccp_enabled boolean not null default true,
  ccp_account_name text not null default '',
  ccp_account_number text not null default '',
  ccp_instructions_fr text not null default 'Après la demande, notre équipe vous contacte pour les instructions de paiement CCP.',
  ccp_instructions_en text not null default 'After your request, our team will contact you with CCP payment instructions.',
  ccp_instructions_ar text not null default 'بعد الطلب، سيتواصل معك فريقنا لإعطائك تعليمات الدفع عبر CCP.',
  returns_policy_fr text not null default '',
  returns_policy_en text not null default '',
  returns_policy_ar text not null default '',
  meta_pixel_id text not null default '',
  store_active boolean not null default true,
  updated_at timestamptz not null default now()
);

create index if not exists monarc_orders_created_idx on public.monarc_orders(created_at desc);
create index if not exists monarc_orders_status_idx on public.monarc_orders(status,created_at desc);
create index if not exists monarc_orders_customer_idx on public.monarc_orders(customer_id,created_at desc);
create index if not exists monarc_items_order_idx on public.monarc_order_items(order_id);
create index if not exists monarc_items_variant_idx on public.monarc_order_items(variant_id);
create index if not exists monarc_inventory_low_idx on public.monarc_inventory(on_hand,reserved);
create index if not exists monarc_audit_created_idx on public.monarc_audit_log(created_at desc);

-- Lock down direct table access. The browser uses narrowly-scoped RPCs below.
alter table public.monarc_staff enable row level security;
alter table public.monarc_categories enable row level security;
alter table public.monarc_products enable row level security;
alter table public.monarc_variants enable row level security;
alter table public.monarc_inventory enable row level security;
alter table public.monarc_customers enable row level security;
alter table public.monarc_delivery_providers enable row level security;
alter table public.monarc_delivery_rates enable row level security;
alter table public.monarc_orders enable row level security;
alter table public.monarc_order_items enable row level security;
alter table public.monarc_payments enable row level security;
alter table public.monarc_order_history enable row level security;
alter table public.monarc_inventory_movements enable row level security;
alter table public.monarc_audit_log enable row level security;
alter table public.monarc_settings enable row level security;

revoke all on table public.monarc_staff, public.monarc_categories, public.monarc_products, public.monarc_variants, public.monarc_inventory, public.monarc_customers, public.monarc_delivery_providers, public.monarc_delivery_rates, public.monarc_orders, public.monarc_order_items, public.monarc_payments, public.monarc_order_history, public.monarc_inventory_movements, public.monarc_audit_log, public.monarc_settings from anon, authenticated;

insert into public.monarc_settings (id) values (true) on conflict (id) do nothing;
insert into public.monarc_categories (slug,name_fr,name_en,name_ar,sort_order) values
('outfits','Ensembles','Outfits','أطقم',10),
('hoodies','Sweat-shirts','Hoodies','سترات بغطاء',20),
('jackets','Vestes','Jackets','جاكيتات',30),
('tshirts','T-shirts','T-shirts','قمصان',40),
('shoes','Chaussures','Shoes','أحذية',45),
('bottoms','Bas','Bottoms','سراويل',50)
on conflict (slug) do nothing;

-- Public product photos; uploads are restricted by storage policies in 02-functions.sql.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('monarc-product-images','monarc-product-images',true,4194304,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true,file_size_limit=4194304,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
