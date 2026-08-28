-- Booking platform / Phase 1
-- SQL 3 of 3: least-privilege grants, RLS, Supabase Storage policies, Realtime.
-- Run after 20260828000100_core_schema.sql and 20260828000200_database_functions_and_triggers.sql.

begin;

-- -----------------------------------------------------------------------------
-- 1. Privileges
-- RLS is the authorization layer. Revoke broad defaults first, then grant only
-- the SQL verbs that RLS policies intentionally govern.
-- -----------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke create on schema public from public, anon, authenticated;
grant usage on schema public to anon, authenticated;

grant select on table
  public.business_settings,
  public.site_sections,
  public.categories,
  public.services,
  public.barbers,
  public.barber_services,
  public.barber_schedules,
  public.barber_schedule_breaks,
  public.gallery,
  public.public_reviews
  to anon;

grant select on public.public_reviews to authenticated;

-- Authenticated users receive table verbs only where a matching RLS policy can
-- authorize the row. A missing policy remains a hard denial.
grant select, insert, update, delete on all tables in schema public to authenticated;

-- PostgreSQL grants EXECUTE to PUBLIC by default. Remove that default and grant
-- only the narrow helpers/RPCs required by policies and client flows.
revoke all on all functions in schema public from public;

grant execute on function public.has_role(text) to anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.has_permission(text) to anon, authenticated;
grant execute on function public.owns_barber(uuid) to anon, authenticated;
grant execute on function public.owns_schedule(uuid) to anon, authenticated;
grant execute on function public.owns_customer(uuid) to anon, authenticated;
grant execute on function public.can_view_booking(uuid) to anon, authenticated;
grant execute on function public.create_my_booking(uuid[], date, time without time zone, uuid, text, text, text, text, text) to authenticated;
grant execute on function public.cancel_my_booking(uuid, text) to authenticated;
grant execute on function public.mark_my_notification_read(uuid) to authenticated;
grant execute on function public.assign_user_role(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Enable RLS everywhere. Do not force RLS: trusted SECURITY DEFINER booking
-- and audit functions need to write coordinated rows atomically.
-- -----------------------------------------------------------------------------
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_permissions enable row level security;
alter table public.booking_statuses enable row level security;
alter table public.business_settings enable row level security;
alter table public.site_sections enable row level security;
alter table public.categories enable row level security;
alter table public.services enable row level security;
alter table public.barbers enable row level security;
alter table public.barber_services enable row level security;
alter table public.barber_schedules enable row level security;
alter table public.barber_schedule_breaks enable row level security;
alter table public.barber_time_off enable row level security;
alter table public.business_closures enable row level security;
alter table public.customers enable row level security;
alter table public.customer_notes enable row level security;
alter table public.promotions enable row level security;
alter table public.promotion_services enable row level security;
alter table public.promotion_categories enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_items enable row level security;
alter table public.reviews enable row level security;
alter table public.gallery enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_deliveries enable row level security;
alter table public.activity_logs enable row level security;

-- -----------------------------------------------------------------------------
-- 3. RLS policies: account and RBAC configuration
-- -----------------------------------------------------------------------------
drop policy if exists roles_authenticated_read on public.roles;
create policy roles_authenticated_read on public.roles
  for select to authenticated using (true);
drop policy if exists roles_admin_manage on public.roles;
create policy roles_admin_manage on public.roles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists permissions_authenticated_read on public.permissions;
create policy permissions_authenticated_read on public.permissions
  for select to authenticated using (true);
drop policy if exists permissions_admin_manage on public.permissions;
create policy permissions_admin_manage on public.permissions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists profiles_own_or_admin_read on public.profiles;
create policy profiles_own_or_admin_read on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_own_or_admin_update on public.profiles;
create policy profiles_own_or_admin_update on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

drop policy if exists user_roles_own_or_admin_read on public.user_roles;
create policy user_roles_own_or_admin_read on public.user_roles
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists user_roles_admin_manage on public.user_roles;
create policy user_roles_admin_manage on public.user_roles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists role_permissions_authenticated_read on public.role_permissions;
create policy role_permissions_authenticated_read on public.role_permissions
  for select to authenticated using (true);
drop policy if exists role_permissions_admin_manage on public.role_permissions;
create policy role_permissions_admin_manage on public.role_permissions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists user_permissions_own_or_admin_read on public.user_permissions;
create policy user_permissions_own_or_admin_read on public.user_permissions
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists user_permissions_admin_manage on public.user_permissions;
create policy user_permissions_admin_manage on public.user_permissions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists booking_statuses_authenticated_read on public.booking_statuses;
create policy booking_statuses_authenticated_read on public.booking_statuses
  for select to authenticated using (true);
drop policy if exists booking_statuses_admin_manage on public.booking_statuses;
create policy booking_statuses_admin_manage on public.booking_statuses
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- 4. RLS policies: intentionally public website data
-- -----------------------------------------------------------------------------
drop policy if exists business_settings_public_read on public.business_settings;
create policy business_settings_public_read on public.business_settings
  for select to anon, authenticated using (is_primary);
drop policy if exists business_settings_manage on public.business_settings;
create policy business_settings_manage on public.business_settings
  for all to authenticated
  using (public.has_permission('settings.manage'))
  with check (public.has_permission('settings.manage'));

drop policy if exists site_sections_public_read on public.site_sections;
create policy site_sections_public_read on public.site_sections
  for select to anon, authenticated using (is_active);
drop policy if exists site_sections_manage on public.site_sections;
create policy site_sections_manage on public.site_sections
  for all to authenticated
  using (public.has_permission('content.manage'))
  with check (public.has_permission('content.manage'));

drop policy if exists categories_public_read on public.categories;
create policy categories_public_read on public.categories
  for select to anon, authenticated using (is_active and archived_at is null);
drop policy if exists categories_manage on public.categories;
create policy categories_manage on public.categories
  for all to authenticated
  using (public.has_permission('catalog.manage'))
  with check (public.has_permission('catalog.manage'));

drop policy if exists services_public_read on public.services;
create policy services_public_read on public.services
  for select to anon, authenticated
  using (
    is_active and archived_at is null
    and exists (
      select 1 from public.categories c
      where c.id = category_id and c.is_active and c.archived_at is null
    )
  );
drop policy if exists services_manage on public.services;
create policy services_manage on public.services
  for all to authenticated
  using (public.has_permission('catalog.manage'))
  with check (public.has_permission('catalog.manage'));

drop policy if exists barbers_public_read on public.barbers;
create policy barbers_public_read on public.barbers
  for select to anon, authenticated using (is_active and archived_at is null);
drop policy if exists barbers_manage on public.barbers;
create policy barbers_manage on public.barbers
  for all to authenticated
  using (public.has_permission('catalog.manage'))
  with check (public.has_permission('catalog.manage'));

drop policy if exists barber_services_public_read on public.barber_services;
create policy barber_services_public_read on public.barber_services
  for select to anon, authenticated
  using (
    is_active
    and exists (
      select 1 from public.barbers b
      where b.id = barber_id and b.is_active and b.archived_at is null
    )
    and exists (
      select 1 from public.services s
      where s.id = service_id and s.is_active and s.archived_at is null
    )
  );
drop policy if exists barber_services_manage on public.barber_services;
create policy barber_services_manage on public.barber_services
  for all to authenticated
  using (public.has_permission('catalog.manage'))
  with check (public.has_permission('catalog.manage'));

-- Active recurring hours are public so the booking UI can render availability.
-- Time-off reasons remain private; detailed availability is also enforced by RPC.
drop policy if exists barber_schedules_public_or_owner_read on public.barber_schedules;
create policy barber_schedules_public_or_owner_read on public.barber_schedules
  for select to anon, authenticated
  using (
    (is_active and exists (
      select 1 from public.barbers b
      where b.id = barber_id and b.is_active and b.archived_at is null
    ))
    or public.owns_barber(barber_id)
    or public.has_permission('schedules.read')
    or public.has_permission('schedules.manage')
  );
drop policy if exists barber_schedules_manage on public.barber_schedules;
create policy barber_schedules_manage on public.barber_schedules
  for all to authenticated
  using (public.has_permission('schedules.manage'))
  with check (public.has_permission('schedules.manage'));

drop policy if exists barber_schedule_breaks_public_or_owner_read on public.barber_schedule_breaks;
create policy barber_schedule_breaks_public_or_owner_read on public.barber_schedule_breaks
  for select to anon, authenticated
  using (
    exists (
      select 1
      from public.barber_schedules bs
      join public.barbers b on b.id = bs.barber_id
      where bs.id = barber_schedule_id
        and bs.is_active
        and b.is_active
        and b.archived_at is null
    )
    or public.owns_schedule(barber_schedule_id)
    or public.has_permission('schedules.read')
    or public.has_permission('schedules.manage')
  );
drop policy if exists barber_schedule_breaks_manage on public.barber_schedule_breaks;
create policy barber_schedule_breaks_manage on public.barber_schedule_breaks
  for all to authenticated
  using (public.has_permission('schedules.manage'))
  with check (public.has_permission('schedules.manage'));

drop policy if exists reviews_public_owner_or_moderator_read on public.reviews;
drop policy if exists reviews_owner_or_moderator_read on public.reviews;
create policy reviews_owner_or_moderator_read on public.reviews
  for select to authenticated
  using (
    public.owns_customer(customer_id)
    or public.has_permission('reviews.moderate')
  );
-- Anonymous visitors use public.public_reviews, a projection that exposes only
-- approved content and no customer_id or booking_id.
drop policy if exists reviews_customer_submit on public.reviews;
create policy reviews_customer_submit on public.reviews
  for insert to authenticated
  with check (status = 'pending' and public.owns_customer(customer_id));
drop policy if exists reviews_moderator_manage on public.reviews;
create policy reviews_moderator_manage on public.reviews
  for all to authenticated
  using (public.has_permission('reviews.moderate'))
  with check (public.has_permission('reviews.moderate'));

drop policy if exists gallery_public_read on public.gallery;
create policy gallery_public_read on public.gallery
  for select to anon, authenticated using (is_active);
drop policy if exists gallery_manage on public.gallery;
create policy gallery_manage on public.gallery
  for all to authenticated
  using (public.has_permission('gallery.manage'))
  with check (public.has_permission('gallery.manage'));

-- -----------------------------------------------------------------------------
-- 5. RLS policies: schedules, customers, bookings, and promotions
-- -----------------------------------------------------------------------------
drop policy if exists barber_time_off_owner_or_scheduler_read on public.barber_time_off;
create policy barber_time_off_owner_or_scheduler_read on public.barber_time_off
  for select to authenticated
  using (
    public.owns_barber(barber_id)
    or public.has_permission('schedules.read')
    or public.has_permission('schedules.manage')
  );
drop policy if exists barber_time_off_manage on public.barber_time_off;
create policy barber_time_off_manage on public.barber_time_off
  for all to authenticated
  using (public.has_permission('schedules.manage'))
  with check (public.has_permission('schedules.manage'));

drop policy if exists business_closures_scheduler_read on public.business_closures;
create policy business_closures_scheduler_read on public.business_closures
  for select to authenticated
  using (public.has_permission('schedules.read') or public.has_permission('schedules.manage'));
drop policy if exists business_closures_manage on public.business_closures;
create policy business_closures_manage on public.business_closures
  for all to authenticated
  using (public.has_permission('schedules.manage'))
  with check (public.has_permission('schedules.manage'));

drop policy if exists customers_own_or_staff_read on public.customers;
create policy customers_own_or_staff_read on public.customers
  for select to authenticated
  using (
    profile_id = auth.uid()
    or public.has_permission('customers.read')
    or public.has_permission('customers.manage')
  );
drop policy if exists customers_own_insert on public.customers;
create policy customers_own_insert on public.customers
  for insert to authenticated
  with check (profile_id = auth.uid());
drop policy if exists customers_staff_insert on public.customers;
create policy customers_staff_insert on public.customers
  for insert to authenticated
  with check (public.has_permission('customers.manage'));
drop policy if exists customers_own_update on public.customers;
create policy customers_own_update on public.customers
  for update to authenticated
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());
drop policy if exists customers_staff_update on public.customers;
create policy customers_staff_update on public.customers
  for update to authenticated
  using (public.has_permission('customers.manage'))
  with check (public.has_permission('customers.manage'));
drop policy if exists customers_staff_delete on public.customers;
create policy customers_staff_delete on public.customers
  for delete to authenticated
  using (public.has_permission('customers.manage'));

drop policy if exists customer_notes_staff_read on public.customer_notes;
create policy customer_notes_staff_read on public.customer_notes
  for select to authenticated
  using (public.has_permission('customers.manage'));
drop policy if exists customer_notes_staff_manage on public.customer_notes;
create policy customer_notes_staff_manage on public.customer_notes
  for all to authenticated
  using (public.has_permission('customers.manage'))
  with check (public.has_permission('customers.manage'));

-- Customers can read only bookings that belong to their profile. Barbers can
-- read only bookings assigned to their linked barber row. Direct customer
-- booking writes are intentionally absent; the secure booking/cancel RPCs own
-- that state transition and the snapshot logic.
drop policy if exists bookings_owner_barber_or_staff_read on public.bookings;
create policy bookings_owner_barber_or_staff_read on public.bookings
  for select to authenticated using (public.can_view_booking(id));
drop policy if exists bookings_staff_insert on public.bookings;
create policy bookings_staff_insert on public.bookings
  for insert to authenticated
  with check (public.has_permission('bookings.manage'));
drop policy if exists bookings_staff_update on public.bookings;
create policy bookings_staff_update on public.bookings
  for update to authenticated
  using (public.has_permission('bookings.manage'))
  with check (public.has_permission('bookings.manage'));
-- No DELETE policy: bookings are historical records and are cancelled instead.

drop policy if exists booking_items_owner_barber_or_staff_read on public.booking_items;
create policy booking_items_owner_barber_or_staff_read on public.booking_items
  for select to authenticated using (public.can_view_booking(booking_id));
-- No direct INSERT/UPDATE/DELETE policy: booking_items are written atomically by
-- create_my_booking and are immutable thereafter.

drop policy if exists promotions_manage on public.promotions;
create policy promotions_manage on public.promotions
  for all to authenticated
  using (public.has_permission('promotions.manage'))
  with check (public.has_permission('promotions.manage'));
drop policy if exists promotion_services_manage on public.promotion_services;
create policy promotion_services_manage on public.promotion_services
  for all to authenticated
  using (public.has_permission('promotions.manage'))
  with check (public.has_permission('promotions.manage'));
drop policy if exists promotion_categories_manage on public.promotion_categories;
create policy promotion_categories_manage on public.promotion_categories
  for all to authenticated
  using (public.has_permission('promotions.manage'))
  with check (public.has_permission('promotions.manage'));

-- -----------------------------------------------------------------------------
-- 6. RLS policies: notifications and audit
-- -----------------------------------------------------------------------------
drop policy if exists notifications_owner_or_manager_read on public.notifications;
create policy notifications_owner_or_manager_read on public.notifications
  for select to authenticated
  using (
    recipient_profile_id = auth.uid()
    or public.owns_customer(recipient_customer_id)
    or public.has_permission('notifications.manage')
  );
drop policy if exists notifications_manager_manage on public.notifications;
create policy notifications_manager_manage on public.notifications
  for all to authenticated
  using (public.has_permission('notifications.manage'))
  with check (public.has_permission('notifications.manage'));
-- Recipients use mark_my_notification_read; there is no direct recipient UPDATE.

drop policy if exists notification_deliveries_manager_manage on public.notification_deliveries;
create policy notification_deliveries_manager_manage on public.notification_deliveries
  for all to authenticated
  using (public.has_permission('notifications.manage'))
  with check (public.has_permission('notifications.manage'));

drop policy if exists activity_logs_authorized_read on public.activity_logs;
create policy activity_logs_authorized_read on public.activity_logs
  for select to authenticated
  using (public.has_permission('activity_logs.read'));
-- No direct insert/update/delete policy: audit functions own the write path.

-- -----------------------------------------------------------------------------
-- 7. Supabase Storage
-- One public bucket contains only public website assets. Store paths, not a
-- hardcoded project URL, in *_path columns. The frontend resolves public URLs
-- through Supabase Storage at runtime. Review-image storage is intentionally not
-- provisioned until that product feature exists; review attachments should be a
-- separate private bucket plus a review_images mapping table when introduced.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'business-assets',
  'business-assets',
  true,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/svg+xml']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists business_assets_public_read on storage.objects;
create policy business_assets_public_read on storage.objects
  for select to anon, authenticated
  using (
    bucket_id = 'business-assets'
    and split_part(name, '/', 1) = any (array['logos', 'favicons', 'hero', 'barbers', 'services', 'gallery'])
  );

drop policy if exists business_assets_authorized_insert on storage.objects;
create policy business_assets_authorized_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'business-assets'
    and split_part(name, '/', 1) = any (array['logos', 'favicons', 'hero', 'barbers', 'services', 'gallery'])
    and public.has_permission('assets.manage')
  );

drop policy if exists business_assets_authorized_update on storage.objects;
create policy business_assets_authorized_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'business-assets'
    and public.has_permission('assets.manage')
  )
  with check (
    bucket_id = 'business-assets'
    and split_part(name, '/', 1) = any (array['logos', 'favicons', 'hero', 'barbers', 'services', 'gallery'])
    and public.has_permission('assets.manage')
  );

drop policy if exists business_assets_authorized_delete on storage.objects;
create policy business_assets_authorized_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'business-assets'
    and public.has_permission('assets.manage')
  );

-- -----------------------------------------------------------------------------
-- 8. Supabase Realtime
-- RLS is also evaluated for Realtime subscriptions. Booking subscribers must
-- therefore be the owning customer, linked barber, or authorized staff; a URL
-- alone can never subscribe a caller to all booking events.
-- -----------------------------------------------------------------------------
alter table public.bookings replica identity full;
alter table public.notifications replica identity full;

do $$
declare
  v_table text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach v_table in array array['public.bookings', 'public.notifications']
    loop
      begin
        execute format('alter publication supabase_realtime add table %s', v_table);
      exception when duplicate_object then
        null;
      end;
    end loop;
  end if;
end $$;

commit;
