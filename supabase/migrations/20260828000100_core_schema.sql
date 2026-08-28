-- Booking platform / Phase 1
-- SQL 1 of 3: extensions, system lookup data, tables, relationships, and indexes.
-- This migration intentionally contains NO business-specific records.

begin;

-- -----------------------------------------------------------------------------
-- 1. Extensions
-- -----------------------------------------------------------------------------
create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- -----------------------------------------------------------------------------
-- 2. Enums / controlled values
-- Booking statuses deliberately use the booking_statuses table instead of an
-- enum. That makes new statuses a data change rather than a risky type change.
-- -----------------------------------------------------------------------------
do $$
begin
  create type public.review_status as enum ('pending', 'approved', 'rejected', 'hidden');
exception when duplicate_object then null;
end $$;

do $$
begin
  create type public.promotion_type as enum ('percentage', 'fixed_amount');
exception when duplicate_object then null;
end $$;

do $$
begin
  create type public.time_off_type as enum ('vacation', 'holiday', 'sick_day', 'temporary_closure', 'other');
exception when duplicate_object then null;
end $$;

do $$
begin
  create type public.notification_channel as enum ('in_app', 'email', 'sms', 'whatsapp', 'telegram');
exception when duplicate_object then null;
end $$;

do $$
begin
  create type public.notification_delivery_status as enum ('queued', 'processing', 'sent', 'delivered', 'failed', 'cancelled');
exception when duplicate_object then null;
end $$;

-- -----------------------------------------------------------------------------
-- 3. Authorization and account tables
-- roles and permissions are platform configuration, not business seed content.
-- -----------------------------------------------------------------------------
create table if not exists public.roles (
  code text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  display_name text not null,
  description text,
  is_system boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.roles (code, display_name, description, is_system)
values
  ('admin', 'Administrator', 'Full platform management', true),
  ('barber', 'Barber', 'Own schedule and bookings according to assigned permissions', true),
  ('staff', 'Staff', 'Limited access controlled by permissions', true),
  ('customer', 'Customer', 'Customer self-service access', true)
on conflict (code) do nothing;

create table if not exists public.permissions (
  code text primary key check (code ~ '^[a-z][a-z0-9_.]*$'),
  display_name text not null,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.permissions (code, display_name, description)
values
  ('access.manage', 'Manage access', 'Assign roles and individual permissions'),
  ('assets.manage', 'Manage assets', 'Upload or remove public business media'),
  ('bookings.read', 'Read bookings', 'Read booking information'),
  ('bookings.manage', 'Manage bookings', 'Create, update, cancel, and reschedule bookings'),
  ('catalog.manage', 'Manage catalogue', 'Manage categories, services, barbers, and barber-service assignments'),
  ('content.manage', 'Manage site content', 'Manage site sections and public content'),
  ('customers.read', 'Read customers', 'Read customer contact records'),
  ('customers.manage', 'Manage customers', 'Manage customer records and private notes'),
  ('gallery.manage', 'Manage gallery', 'Manage gallery items'),
  ('notifications.manage', 'Manage notifications', 'Create and manage notifications and deliveries'),
  ('promotions.manage', 'Manage promotions', 'Manage promotions and eligibility mappings'),
  ('reviews.moderate', 'Moderate reviews', 'Approve, reject, hide, and manage reviews'),
  ('schedules.read', 'Read schedules', 'Read non-public availability exceptions'),
  ('schedules.manage', 'Manage schedules', 'Manage schedules, breaks, time off, and closures'),
  ('settings.manage', 'Manage settings', 'Manage global business settings and booking status definitions'),
  ('analytics.read', 'Read analytics', 'Read reporting data'),
  ('activity_logs.read', 'Read activity logs', 'Read administrative audit events')
on conflict (code) do nothing;

-- Auth identities live in auth.users. This is the application-safe companion row.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.user_roles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  role_code text not null references public.roles(code) on delete restrict,
  assigned_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, role_code)
);

create table if not exists public.role_permissions (
  role_code text not null references public.roles(code) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (role_code, permission_code)
);

-- Allows a staff member (or barber) to receive a narrow permission without
-- creating a new role. Admins always evaluate as having every permission.
create table if not exists public.user_permissions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  granted_by uuid references public.profiles(id) on delete set null,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, permission_code)
);

-- Adding a booking status later is safe: insert a new row with its operational
-- flags instead of changing application enums or an exclusion constraint.
create table if not exists public.booking_statuses (
  code text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  display_name text not null,
  description text,
  blocks_availability boolean not null default false,
  counts_as_promotion_usage boolean not null default false,
  customer_cancellable boolean not null default false,
  review_eligible boolean not null default false,
  counts_toward_revenue boolean not null default false,
  is_cancellation boolean not null default false,
  is_no_show boolean not null default false,
  is_terminal boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.booking_statuses
  (code, display_name, blocks_availability, counts_as_promotion_usage, customer_cancellable, review_eligible, counts_toward_revenue, is_cancellation, is_no_show, is_terminal, sort_order)
values
  ('pending', 'Pending', true, true, true, false, false, false, false, false, 10),
  ('confirmed', 'Confirmed', true, true, true, false, false, false, false, false, 20),
  ('in_progress', 'In progress', true, true, false, false, false, false, false, false, 30),
  ('completed', 'Completed', false, true, false, true, true, false, false, true, 40),
  ('cancelled', 'Cancelled', false, false, false, false, false, true, false, true, 50),
  ('no_show', 'No show', false, true, false, false, false, false, true, true, 60)
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- 4. Dynamic public business content
-- No settings row is inserted: an owner must create it with real business data.
-- -----------------------------------------------------------------------------
create table if not exists public.business_settings (
  id uuid primary key default gen_random_uuid(),
  is_primary boolean not null default true,
  business_name text,
  logo_path text,
  favicon_path text,
  description text,
  phone text,
  email text,
  address text,
  google_maps_url text,
  instagram_url text,
  telegram_url text,
  whatsapp_url text,
  facebook_url text,
  tiktok_url text,
  currency char(3),
  timezone text,
  booking_enabled boolean not null default false,
  minimum_booking_notice_minutes integer,
  maximum_booking_days integer,
  cancellation_policy text,
  booking_buffer_minutes integer,
  default_slot_interval_minutes integer,
  allow_any_barber boolean,
  require_phone boolean,
  require_email boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_settings_currency_check
    check (currency is null or currency = upper(currency)),
  constraint business_settings_numbers_check
    check (
      (minimum_booking_notice_minutes is null or minimum_booking_notice_minutes >= 0)
      and (maximum_booking_days is null or maximum_booking_days >= 1)
      and (booking_buffer_minutes is null or booking_buffer_minutes >= 0)
      and (default_slot_interval_minutes is null or default_slot_interval_minutes >= 1)
    ),
  constraint business_settings_booking_configuration_check
    check (
      not booking_enabled or (
        nullif(btrim(business_name), '') is not null
        and currency is not null
        and timezone is not null
        and minimum_booking_notice_minutes is not null
        and maximum_booking_days is not null
        and booking_buffer_minutes is not null
        and default_slot_interval_minutes is not null
        and allow_any_barber is not null
        and require_phone is not null
        and require_email is not null
      )
    )
);

create unique index if not exists business_settings_one_primary_idx
  on public.business_settings (is_primary)
  where is_primary;

-- Generic CMS records allow the future frontend to render hero, home, contact,
-- and other sections from content JSON without hardcoded business copy.
create table if not exists public.site_sections (
  id uuid primary key default gen_random_uuid(),
  page_slug text not null check (page_slug ~ '^[a-z0-9][a-z0-9/-]*$'),
  section_key text not null check (section_key ~ '^[a-z0-9][a-z0-9_-]*$'),
  content jsonb not null default '{}'::jsonb check (jsonb_typeof(content) = 'object'),
  media_path text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (page_slug, section_key)
);

-- -----------------------------------------------------------------------------
-- 5. Catalogue, staff, and availability
-- -----------------------------------------------------------------------------
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  image_path text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete restrict,
  name text not null,
  description text,
  price numeric(12,2) not null check (price >= 0),
  currency char(3) not null check (currency = upper(currency)),
  duration_minutes integer not null check (duration_minutes > 0),
  image_path text,
  is_active boolean not null default true,
  is_popular boolean not null default false,
  consultation_only boolean not null default false,
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.barbers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete set null,
  name text not null,
  profile_image_path text,
  bio text,
  position text,
  specialties text[] not null default '{}'::text[],
  is_active boolean not null default true,
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.barber_services (
  barber_id uuid not null references public.barbers(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (barber_id, service_id)
);

-- A barber can have multiple shifts for a weekday. Breaks are normalized into a
-- child table, allowing each shift to have zero or many non-overlapping breaks.
create table if not exists public.barber_schedules (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references public.barbers(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6), -- 0 = Sunday, PostgreSQL EXTRACT(DOW)
  start_time time not null,
  end_time time not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint barber_schedule_time_check check (end_time > start_time),
  unique (barber_id, day_of_week, start_time)
);

create table if not exists public.barber_schedule_breaks (
  id uuid primary key default gen_random_uuid(),
  barber_schedule_id uuid not null references public.barber_schedules(id) on delete cascade,
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint barber_schedule_break_time_check check (end_time > start_time),
  unique (barber_schedule_id, start_time)
);

create table if not exists public.barber_time_off (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references public.barbers(id) on delete cascade,
  time_off_type public.time_off_type not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint barber_time_off_range_check check (ends_at > starts_at)
);

-- Required for real temporary business-wide closures. It avoids copying the
-- same holiday record into every barber_time_off row.
create table if not exists public.business_closures (
  id uuid primary key default gen_random_uuid(),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_closure_range_check check (ends_at > starts_at)
);

-- -----------------------------------------------------------------------------
-- 6. Customers, promotions, bookings, reviews, and gallery
-- Private operational notes are deliberately separated from customers so a
-- customer can read their own profile without reading staff-only notes.
-- -----------------------------------------------------------------------------
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete set null,
  full_name text not null,
  phone text,
  email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_notes (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  note text not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  code text not null check (nullif(btrim(code), '') is not null),
  promotion_type public.promotion_type not null,
  discount_value numeric(12,2) not null check (discount_value > 0),
  currency char(3) check (currency is null or currency = upper(currency)),
  start_date date,
  end_date date,
  minimum_booking_amount numeric(12,2) check (minimum_booking_amount is null or minimum_booking_amount >= 0),
  maximum_usage integer check (maximum_usage is null or maximum_usage > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint promotion_date_range_check check (end_date is null or start_date is null or end_date >= start_date),
  constraint promotion_percentage_check check (promotion_type <> 'percentage' or discount_value <= 100),
  constraint promotion_currency_check check (
    (promotion_type = 'percentage' and currency is null)
    or (promotion_type = 'fixed_amount' and currency is not null)
  )
);

-- If a promotion has no rows in either mapping table, it applies to all active
-- services. If mappings exist, the booking function discounts eligible lines.
create table if not exists public.promotion_services (
  promotion_id uuid not null references public.promotions(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  primary key (promotion_id, service_id)
);

create table if not exists public.promotion_categories (
  promotion_id uuid not null references public.promotions(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete restrict,
  primary key (promotion_id, category_id)
);

-- starts_at/ends_at are canonical instants. booking_date/start_time/end_time are
-- stored local-time snapshots for UI and analytics. appointment_range includes
-- the buffer and is protected by an exclusion constraint below.
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  barber_id uuid not null references public.barbers(id) on delete restrict,
  booking_date date not null,
  start_time time not null,
  end_time time not null,
  booking_timezone text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  service_duration_minutes integer not null check (service_duration_minutes > 0),
  booking_buffer_minutes integer not null default 0 check (booking_buffer_minutes >= 0),
  appointment_range tstzrange not null,
  status text not null default 'pending' references public.booking_statuses(code) on delete restrict,
  blocks_availability boolean not null default true,
  currency char(3) not null check (currency = upper(currency)),
  subtotal_amount numeric(12,2) not null default 0 check (subtotal_amount >= 0),
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  total_amount numeric(12,2) not null default 0 check (total_amount >= 0),
  promotion_id uuid references public.promotions(id) on delete set null,
  promotion_code_snapshot text,
  notes text,
  cancellation_reason text,
  cancelled_at timestamptz,
  status_updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint booking_time_range_check check (ends_at > starts_at),
  constraint booking_amounts_check check (discount_amount <= subtotal_amount and total_amount = subtotal_amount - discount_amount),
  constraint booking_range_not_empty check (not isempty(appointment_range))
);

-- The snapshot columns never refer back to a live service field after insert.
-- This guarantees a later service/price edit cannot rewrite historical revenue.
create table if not exists public.booking_items (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  service_name_snapshot text not null,
  price_snapshot numeric(12,2) not null check (price_snapshot >= 0),
  currency_snapshot char(3) not null check (currency_snapshot = upper(currency_snapshot)),
  duration_minutes_snapshot integer not null check (duration_minutes_snapshot > 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (booking_id, sort_order)
);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  booking_id uuid not null references public.bookings(id) on delete restrict,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  status public.review_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (booking_id)
);

-- Public review projection intentionally excludes customer_id and booking_id.
-- Grant this view to anonymous visitors instead of the raw reviews table.
create or replace view public.public_reviews as
select id, rating, comment, created_at, updated_at
from public.reviews
where status = 'approved';

create table if not exists public.gallery (
  id uuid primary key default gen_random_uuid(),
  image_path text not null,
  title text,
  description text,
  category text,
  is_featured boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 7. Notifications and immutable audit records
-- notification_deliveries makes external delivery channels extensible without
-- putting provider tokens, webhook secrets, or message credentials in SQL.
-- -----------------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_profile_id uuid references public.profiles(id) on delete cascade,
  recipient_customer_id uuid references public.customers(id) on delete cascade,
  notification_type text not null check (notification_type ~ '^[a-z][a-z0-9_.-]*$'),
  title text not null,
  message text not null,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint notification_recipient_check check (num_nonnulls(recipient_profile_id, recipient_customer_id) >= 1)
);

create table if not exists public.notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  channel public.notification_channel not null,
  destination text,
  delivery_status public.notification_delivery_status not null default 'queued',
  provider_message_id text,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  last_error text,
  sent_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.activity_logs (
  id uuid primary key default gen_random_uuid(),
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 8. Indexes and database-level conflict protection
-- -----------------------------------------------------------------------------
create unique index if not exists categories_name_unarchived_key
  on public.categories (lower(name)) where archived_at is null;
create unique index if not exists services_name_unarchived_key
  on public.services (lower(name)) where archived_at is null;
create unique index if not exists promotions_code_key
  on public.promotions (lower(code));

create index if not exists site_sections_public_order_idx
  on public.site_sections (page_slug, sort_order) where is_active;
create index if not exists categories_public_order_idx
  on public.categories (sort_order, name) where is_active and archived_at is null;
create index if not exists services_category_idx
  on public.services (category_id, sort_order);
create index if not exists services_active_category_order_idx
  on public.services (category_id, sort_order) where is_active and archived_at is null;
create index if not exists barbers_public_order_idx
  on public.barbers (sort_order, name) where is_active and archived_at is null;
create index if not exists barber_services_service_idx
  on public.barber_services (service_id, barber_id) where is_active;
create index if not exists barber_schedules_barber_day_idx
  on public.barber_schedules (barber_id, day_of_week, start_time) where is_active;
create index if not exists barber_time_off_barber_range_idx
  on public.barber_time_off (barber_id, starts_at, ends_at) where is_active;
create index if not exists business_closures_range_idx
  on public.business_closures (starts_at, ends_at) where is_active;

create index if not exists customers_phone_idx
  on public.customers (phone) where phone is not null;
create index if not exists customers_email_lower_idx
  on public.customers (lower(email)) where email is not null;
create index if not exists customers_profile_idx
  on public.customers (profile_id) where profile_id is not null;
create index if not exists customer_notes_customer_created_idx
  on public.customer_notes (customer_id, created_at desc);

create index if not exists bookings_date_idx
  on public.bookings (booking_date desc, start_time);
create index if not exists bookings_barber_date_idx
  on public.bookings (barber_id, booking_date, start_time);
create index if not exists bookings_customer_date_idx
  on public.bookings (customer_id, booking_date desc);
create index if not exists bookings_status_date_idx
  on public.bookings (status, booking_date desc);
create index if not exists bookings_promotion_idx
  on public.bookings (promotion_id) where promotion_id is not null;
create index if not exists booking_items_service_idx
  on public.booking_items (service_id);
create index if not exists reviews_status_created_idx
  on public.reviews (status, created_at desc);
create index if not exists reviews_approved_created_idx
  on public.reviews (created_at desc) where status = 'approved';
create index if not exists gallery_public_order_idx
  on public.gallery (sort_order, created_at desc) where is_active;
create index if not exists promotions_active_dates_idx
  on public.promotions (start_date, end_date) where is_active;
create index if not exists notifications_profile_unread_idx
  on public.notifications (recipient_profile_id, created_at desc) where read_at is null;
create index if not exists notifications_customer_unread_idx
  on public.notifications (recipient_customer_id, created_at desc) where read_at is null;
create index if not exists notification_deliveries_queue_idx
  on public.notification_deliveries (delivery_status, created_at) where delivery_status in ('queued', 'processing');
create index if not exists activity_logs_entity_idx
  on public.activity_logs (entity_type, entity_id, created_at desc);
create index if not exists activity_logs_actor_idx
  on public.activity_logs (actor_profile_id, created_at desc);

-- This is the final authority for double-booking prevention. Two concurrent
-- inserts for the same barber with overlapping active appointment_range values
-- cannot both commit. The range includes the snapshot booking buffer.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bookings_no_overlap_per_barber'
      and conrelid = 'public.bookings'::regclass
  ) then
    alter table public.bookings
      add constraint bookings_no_overlap_per_barber
      exclude using gist (
        barber_id with =,
        appointment_range with &&
      ) where (blocks_availability);
  end if;
end $$;

commit;
