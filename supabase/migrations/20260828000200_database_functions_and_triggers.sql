-- Booking platform / Phase 1
-- SQL 2 of 3: database functions, integrity triggers, booking RPCs, and audit.
-- Run after 20260828000100_core_schema.sql.

begin;

-- -----------------------------------------------------------------------------
-- 1. Generic and authorization helper functions
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.validate_business_settings()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.timezone is not null
     and not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'Unknown IANA timezone: %', new.timezone using errcode = '22023';
  end if;
  return new;
end;
$$;

-- These helpers are SECURITY DEFINER because RLS policies must be able to make
-- authorization decisions without recursively querying a protected table.
create or replace function public.has_role(p_role_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1
       from public.user_roles ur
       where ur.user_id = auth.uid()
         and ur.role_code = p_role_code
     );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.has_role('admin');
$$;

create or replace function public.has_permission(p_permission_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (
       public.is_admin()
       or exists (
         select 1
         from public.user_permissions up
         where up.user_id = auth.uid()
           and up.permission_code = p_permission_code
           and (up.expires_at is null or up.expires_at > now())
       )
       or exists (
         select 1
         from public.user_roles ur
         join public.role_permissions rp on rp.role_code = ur.role_code
         where ur.user_id = auth.uid()
           and rp.permission_code = p_permission_code
       )
     );
$$;

create or replace function public.owns_barber(p_barber_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1 from public.barbers b
       where b.id = p_barber_id and b.profile_id = auth.uid()
     );
$$;

create or replace function public.owns_schedule(p_schedule_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1
       from public.barber_schedules bs
       join public.barbers b on b.id = bs.barber_id
       where bs.id = p_schedule_id and b.profile_id = auth.uid()
     );
$$;

create or replace function public.owns_customer(p_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1 from public.customers c
       where c.id = p_customer_id and c.profile_id = auth.uid()
     );
$$;

create or replace function public.can_view_booking(p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (
       public.has_permission('bookings.read')
       or public.has_permission('bookings.manage')
       or exists (
         select 1
         from public.bookings b
         join public.customers c on c.id = b.customer_id
         where b.id = p_booking_id and c.profile_id = auth.uid()
       )
       or exists (
         select 1
         from public.bookings b
         join public.barbers br on br.id = b.barber_id
         where b.id = p_booking_id and br.profile_id = auth.uid()
       )
     );
$$;

-- -----------------------------------------------------------------------------
-- 2. Auth lifecycle and access-management functions
-- Every Supabase Auth user receives a profile and only the customer role.
-- There is intentionally no path here that grants admin privileges.
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_path)
  values (
    new.id,
    nullif(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), ''),
    nullif(new.raw_user_meta_data ->> 'avatar_path', '')
  )
  on conflict (id) do nothing;

  insert into public.user_roles (user_id, role_code)
  values (new.id, 'customer')
  on conflict (user_id, role_code) do nothing;

  return new;
end;
$$;

create or replace function public.prevent_removing_last_admin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.role_code = 'admin'
     and (tg_op = 'DELETE' or new.role_code <> 'admin')
     and not exists (
       select 1 from public.user_roles ur
       where ur.role_code = 'admin'
         and ur.user_id <> old.user_id
     ) then
    raise exception 'Cannot remove or replace the final admin role' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Future authenticated administrators call this RPC (or an equivalent protected
-- server endpoint). Project owners bootstrap the first admin from SQL Editor,
-- because this function correctly refuses callers who are not already admins.
create or replace function public.assign_user_role(p_user_id uuid, p_role_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_permission('access.manage') then
    raise exception 'Not authorized to assign roles' using errcode = '42501';
  end if;

  -- Only an existing admin can grant the admin role, even if a non-admin staff
  -- member happens to have access.manage.
  if p_role_code = 'admin' and not public.is_admin() then
    raise exception 'Only an admin may grant the admin role' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'Target profile does not exist' using errcode = '23503';
  end if;

  if not exists (select 1 from public.roles where code = p_role_code) then
    raise exception 'Unknown role: %', p_role_code using errcode = '22023';
  end if;

  insert into public.user_roles (user_id, role_code, assigned_by)
  values (p_user_id, p_role_code, auth.uid())
  on conflict (user_id, role_code) do update set assigned_by = excluded.assigned_by;

  insert into public.activity_logs (actor_profile_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    'role.assigned',
    'user_role',
    p_user_id,
    jsonb_build_object('role_code', p_role_code)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Schedule, snapshot, and review integrity
-- -----------------------------------------------------------------------------
create or replace function public.validate_barber_schedule()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.barber_schedules other_shift
    where other_shift.barber_id = new.barber_id
      and other_shift.day_of_week = new.day_of_week
      and other_shift.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
      and other_shift.start_time < new.end_time
      and other_shift.end_time > new.start_time
  ) then
    raise exception 'A barber schedule shift cannot overlap another shift on the same weekday'
      using errcode = '23P01';
  end if;

  if tg_op = 'UPDATE' and exists (
    select 1
    from public.barber_schedule_breaks br
    where br.barber_schedule_id = new.id
      and (br.start_time < new.start_time or br.end_time > new.end_time)
  ) then
    raise exception 'A schedule cannot exclude one of its existing breaks' using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function public.validate_barber_schedule_break()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift public.barber_schedules%rowtype;
begin
  select * into v_shift
  from public.barber_schedules
  where id = new.barber_schedule_id;

  if not found then
    raise exception 'Schedule does not exist' using errcode = '23503';
  end if;

  if new.start_time < v_shift.start_time or new.end_time > v_shift.end_time then
    raise exception 'A break must be entirely inside its parent schedule shift' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.barber_schedule_breaks other_break
    where other_break.barber_schedule_id = new.barber_schedule_id
      and other_break.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
      and other_break.start_time < new.end_time
      and other_break.end_time > new.start_time
  ) then
    raise exception 'Schedule breaks cannot overlap' using errcode = '23P01';
  end if;

  return new;
end;
$$;

-- The booking duration is a booking snapshot. Every write recalculates derived
-- local fields and the protected availability range from the canonical instant.
create or replace function public.set_booking_derived_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_blocks_availability boolean;
begin
  if new.booking_timezone is null
     or not exists (select 1 from pg_timezone_names where name = new.booking_timezone) then
    raise exception 'A valid IANA booking timezone is required' using errcode = '22023';
  end if;

  select bs.blocks_availability into v_blocks_availability
  from public.booking_statuses bs
  where bs.code = new.status;

  if not found then
    raise exception 'Unknown booking status: %', new.status using errcode = '22023';
  end if;

  new.blocks_availability := v_blocks_availability;
  new.ends_at := new.starts_at + make_interval(mins => new.service_duration_minutes);
  new.booking_date := (new.starts_at at time zone new.booking_timezone)::date;
  new.start_time := (new.starts_at at time zone new.booking_timezone)::time;
  new.end_time := (new.ends_at at time zone new.booking_timezone)::time;
  new.appointment_range := tstzrange(
    new.starts_at,
    new.ends_at + make_interval(mins => new.booking_buffer_minutes),
    '[)'
  );

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.status_updated_at := now();
  end if;

  return new;
end;
$$;

-- Snapshot live service fields exactly once. Snapshot data is never updated by
-- service changes; booking_items are made immutable below.
create or replace function public.snapshot_booking_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_booking_currency char(3);
begin
  select * into v_service from public.services where id = new.service_id;
  if not found then
    raise exception 'Service does not exist' using errcode = '23503';
  end if;

  select currency into v_booking_currency from public.bookings where id = new.booking_id;
  if not found then
    raise exception 'Booking does not exist' using errcode = '23503';
  end if;

  if v_service.currency <> v_booking_currency then
    raise exception 'Service currency must match booking currency' using errcode = '22023';
  end if;

  new.service_name_snapshot := v_service.name;
  new.price_snapshot := v_service.price;
  new.currency_snapshot := v_service.currency;
  new.duration_minutes_snapshot := v_service.duration_minutes;
  return new;
end;
$$;

-- There must be no mutation or deletion of price/name/duration snapshots after
-- an item is booked. Correct a booking with a separate audit process, not by
-- rewriting financial history.
create or replace function public.prevent_booking_item_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'Booking items are immutable after creation' using errcode = '55000';
end;
$$;

-- A deferred constraint permits the booking RPC to insert the header followed by
-- its items in one transaction, while rejecting an accidental empty booking at
-- commit time.
create or replace function public.ensure_booking_has_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.booking_items where booking_id = new.id) then
    raise exception 'A booking requires at least one booking item' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function public.sync_booking_from_items()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal numeric(12,2);
  v_duration integer;
begin
  select coalesce(sum(price_snapshot), 0), coalesce(sum(duration_minutes_snapshot), 0)
    into v_subtotal, v_duration
  from public.booking_items
  where booking_id = new.booking_id;

  if v_duration <= 0 then
    raise exception 'A booking requires at least one service item' using errcode = '23514';
  end if;

  -- Line inserts happen one at a time. Clamp a previously calculated final
  -- discount while the item set is incomplete so the booking amount constraint
  -- remains valid inside this transaction; create_my_booking restores its
  -- validated final discount after all snapshots have been inserted.
  update public.bookings b
  set subtotal_amount = v_subtotal,
      service_duration_minutes = v_duration,
      discount_amount = least(b.discount_amount, v_subtotal),
      total_amount = v_subtotal - least(b.discount_amount, v_subtotal)
  where b.id = new.booking_id;

  return new;
end;
$$;

create or replace function public.validate_review_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.bookings b
    join public.booking_statuses bs on bs.code = b.status
    where b.id = new.booking_id
      and b.customer_id = new.customer_id
      and bs.review_eligible
  ) then
    raise exception 'A review must belong to the same customer and an eligible completed booking'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Availability and customer booking RPCs
-- The public client must use create_my_booking; it must never use a service-role
-- key. The function is transactional, checks schedule/time-off, and relies on
-- the exclusion constraint as the final concurrent-write guarantee.
-- -----------------------------------------------------------------------------
create or replace function public.barber_is_available(
  p_barber_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_local_date date,
  p_local_start time,
  p_local_end time,
  p_buffer_minutes integer
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.barbers b
    where b.id = p_barber_id
      and b.is_active
      and b.archived_at is null
  )
  and exists (
    select 1
    from public.barber_schedules bs
    where bs.barber_id = p_barber_id
      and bs.is_active
      and bs.day_of_week = extract(dow from p_local_date)::smallint
      and bs.start_time <= p_local_start
      and bs.end_time >= p_local_end
  )
  and not exists (
    select 1
    from public.barber_schedule_breaks br
    join public.barber_schedules bs on bs.id = br.barber_schedule_id
    where bs.barber_id = p_barber_id
      and bs.is_active
      and bs.day_of_week = extract(dow from p_local_date)::smallint
      and br.start_time < p_local_end
      and br.end_time > p_local_start
  )
  and not exists (
    select 1
    from public.barber_time_off bto
    where bto.barber_id = p_barber_id
      and bto.is_active
      and tstzrange(bto.starts_at, bto.ends_at, '[)') &&
          tstzrange(p_starts_at, p_ends_at + make_interval(mins => p_buffer_minutes), '[)')
  )
  and not exists (
    select 1
    from public.business_closures bc
    where bc.is_active
      and tstzrange(bc.starts_at, bc.ends_at, '[)') &&
          tstzrange(p_starts_at, p_ends_at + make_interval(mins => p_buffer_minutes), '[)')
  )
  and not exists (
    select 1
    from public.bookings existing_booking
    where existing_booking.barber_id = p_barber_id
      and existing_booking.blocks_availability
      and existing_booking.appointment_range &&
          tstzrange(p_starts_at, p_ends_at + make_interval(mins => p_buffer_minutes), '[)')
  );
$$;

create or replace function public.create_my_booking(
  p_service_ids uuid[],
  p_booking_date date,
  p_start_time time,
  p_barber_id uuid default null,
  p_notes text default null,
  p_promotion_code text default null,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_customer_email text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.business_settings%rowtype;
  v_customer_id uuid;
  v_existing_name text;
  v_existing_phone text;
  v_existing_email text;
  v_name text;
  v_phone text;
  v_email text;
  v_service_count integer;
  v_subtotal numeric(12,2);
  v_duration integer;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
  v_local_end_date date;
  v_local_end_time time;
  v_barber_id uuid;
  v_booking_id uuid;
  v_promotion public.promotions%rowtype;
  v_has_promotion_targets boolean;
  v_eligible_subtotal numeric(12,2);
  v_promotion_usage integer;
  v_discount numeric(12,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to create a booking' using errcode = '42501';
  end if;

  if p_service_ids is null
     or cardinality(p_service_ids) = 0
     or array_position(p_service_ids, null) is not null then
    raise exception 'At least one service is required' using errcode = '22023';
  end if;

  select * into v_settings
  from public.business_settings
  where is_primary
  limit 1;

  if not found then
    raise exception 'Business settings have not been configured' using errcode = '55000';
  end if;

  if not v_settings.booking_enabled then
    raise exception 'Online booking is currently disabled' using errcode = '55000';
  end if;

  v_starts_at := (p_booking_date + p_start_time) at time zone v_settings.timezone;

  if v_starts_at < now() + make_interval(mins => v_settings.minimum_booking_notice_minutes) then
    raise exception 'This time does not meet the minimum booking notice' using errcode = '22023';
  end if;

  if p_booking_date > ((now() at time zone v_settings.timezone)::date + v_settings.maximum_booking_days) then
    raise exception 'This date is outside the maximum booking window' using errcode = '22023';
  end if;

  select count(*), coalesce(sum(s.price), 0), coalesce(sum(s.duration_minutes), 0)
    into v_service_count, v_subtotal, v_duration
  from unnest(p_service_ids) requested(service_id)
  join public.services s on s.id = requested.service_id
  join public.categories c on c.id = s.category_id
  where s.is_active
    and s.archived_at is null
    and c.is_active
    and c.archived_at is null;

  if v_service_count <> cardinality(p_service_ids) then
    raise exception 'One or more selected services are unavailable' using errcode = '22023';
  end if;

  if exists (
    select 1
    from unnest(p_service_ids) requested(service_id)
    join public.services s on s.id = requested.service_id
    where s.currency <> v_settings.currency
  ) then
    raise exception 'All selected services must use the configured business currency' using errcode = '22023';
  end if;

  v_ends_at := v_starts_at + make_interval(mins => v_duration);
  v_local_end_date := (v_ends_at at time zone v_settings.timezone)::date;
  v_local_end_time := (v_ends_at at time zone v_settings.timezone)::time;

  if v_local_end_date <> p_booking_date or v_local_end_time <= p_start_time then
    raise exception 'A booking may not cross the local business day boundary' using errcode = '22023';
  end if;

  -- Lock an existing personal customer record if present, then retain any
  -- contact values the caller omitted. No customer can write another profile's row.
  select c.id, c.full_name, c.phone, c.email
    into v_customer_id, v_existing_name, v_existing_phone, v_existing_email
  from public.customers c
  where c.profile_id = auth.uid()
  for update;

  v_name := nullif(btrim(coalesce(p_customer_name, v_existing_name)), '');
  v_phone := nullif(btrim(coalesce(p_customer_phone, v_existing_phone)), '');
  v_email := nullif(lower(btrim(coalesce(p_customer_email, v_existing_email))), '');

  if v_name is null then
    raise exception 'Customer name is required' using errcode = '22023';
  end if;
  if v_settings.require_phone and v_phone is null then
    raise exception 'A phone number is required for booking' using errcode = '22023';
  end if;
  if v_settings.require_email and v_email is null then
    raise exception 'An email address is required for booking' using errcode = '22023';
  end if;

  if v_customer_id is null then
    insert into public.customers (profile_id, full_name, phone, email)
    values (auth.uid(), v_name, v_phone, v_email)
    returning id into v_customer_id;
  else
    update public.customers
    set full_name = v_name,
        phone = v_phone,
        email = v_email
    where id = v_customer_id;
  end if;

  if p_barber_id is not null then
    v_barber_id := p_barber_id;

    if exists (
      select 1
      from unnest(p_service_ids) requested(service_id)
      where not exists (
        select 1
        from public.barber_services bs
        where bs.barber_id = v_barber_id
          and bs.service_id = requested.service_id
          and bs.is_active
      )
    ) then
      raise exception 'Selected barber does not provide every selected service' using errcode = '22023';
    end if;

    if not public.barber_is_available(
      v_barber_id, v_starts_at, v_ends_at, p_booking_date, p_start_time,
      v_local_end_time, v_settings.booking_buffer_minutes
    ) then
      raise exception 'Selected barber is not available for this time' using errcode = '23P01';
    end if;
  else
    if not v_settings.allow_any_barber then
      raise exception 'A barber selection is required' using errcode = '22023';
    end if;

    select b.id into v_barber_id
    from public.barbers b
    where b.is_active
      and b.archived_at is null
      and not exists (
        select 1
        from unnest(p_service_ids) requested(service_id)
        where not exists (
          select 1
          from public.barber_services bs
          where bs.barber_id = b.id
            and bs.service_id = requested.service_id
            and bs.is_active
        )
      )
      and public.barber_is_available(
        b.id, v_starts_at, v_ends_at, p_booking_date, p_start_time,
        v_local_end_time, v_settings.booking_buffer_minutes
      )
    order by b.sort_order, b.name, b.id
    limit 1;

    if v_barber_id is null then
      raise exception 'No available barber can provide the selected services at this time' using errcode = '23P01';
    end if;
  end if;

  -- Enforce the configured slot interval relative to the chosen working shift,
  -- not merely relative to midnight. This keeps the server authoritative when
  -- a client attempts to post an arbitrary minute value.
  if not exists (
    select 1
    from public.barber_schedules bs
    where bs.barber_id = v_barber_id
      and bs.is_active
      and bs.day_of_week = extract(dow from p_booking_date)::smallint
      and bs.start_time <= p_start_time
      and bs.end_time >= v_local_end_time
      and mod(
        extract(epoch from (p_start_time - bs.start_time))::integer,
        v_settings.default_slot_interval_minutes
      ) = 0
  ) then
    raise exception 'Start time is not aligned to the configured slot interval' using errcode = '22023';
  end if;

  if nullif(btrim(p_promotion_code), '') is not null then
    -- FOR UPDATE serializes redemption checks for this promotion code.
    select * into v_promotion
    from public.promotions p
    where lower(p.code) = lower(btrim(p_promotion_code))
      and p.is_active
      and (p.start_date is null or p.start_date <= p_booking_date)
      and (p.end_date is null or p.end_date >= p_booking_date)
    for update;

    if not found then
      raise exception 'Promotion code is invalid or inactive' using errcode = '22023';
    end if;

    if v_promotion.promotion_type = 'fixed_amount'
       and v_promotion.currency <> v_settings.currency then
      raise exception 'Promotion currency does not match the booking currency' using errcode = '22023';
    end if;

    if v_promotion.minimum_booking_amount is not null
       and v_subtotal < v_promotion.minimum_booking_amount then
      raise exception 'This booking does not meet the promotion minimum amount' using errcode = '22023';
    end if;

    if v_promotion.maximum_usage is not null then
      select count(*) into v_promotion_usage
      from public.bookings b
      join public.booking_statuses bs on bs.code = b.status
      where b.promotion_id = v_promotion.id
        and bs.counts_as_promotion_usage;

      if v_promotion_usage >= v_promotion.maximum_usage then
        raise exception 'This promotion has reached its maximum usage' using errcode = '22023';
      end if;
    end if;

    select exists(select 1 from public.promotion_services ps where ps.promotion_id = v_promotion.id)
        or exists(select 1 from public.promotion_categories pc where pc.promotion_id = v_promotion.id)
      into v_has_promotion_targets;

    select coalesce(sum(s.price), 0) into v_eligible_subtotal
    from unnest(p_service_ids) requested(service_id)
    join public.services s on s.id = requested.service_id
    where not v_has_promotion_targets
       or exists (
         select 1 from public.promotion_services ps
         where ps.promotion_id = v_promotion.id and ps.service_id = s.id
       )
       or exists (
         select 1 from public.promotion_categories pc
         where pc.promotion_id = v_promotion.id and pc.category_id = s.category_id
       );

    if v_has_promotion_targets and v_eligible_subtotal = 0 then
      raise exception 'This promotion does not apply to selected services' using errcode = '22023';
    end if;

    if v_promotion.promotion_type = 'percentage' then
      v_discount := round(v_eligible_subtotal * v_promotion.discount_value / 100, 2);
    else
      v_discount := least(v_eligible_subtotal, v_promotion.discount_value);
    end if;
  end if;

  insert into public.bookings (
    customer_id, barber_id, booking_date, start_time, end_time, booking_timezone,
    starts_at, ends_at, service_duration_minutes, booking_buffer_minutes,
    appointment_range, status, currency, subtotal_amount, discount_amount,
    total_amount, promotion_id, promotion_code_snapshot, notes
  )
  values (
    v_customer_id, v_barber_id, p_booking_date, p_start_time, v_local_end_time,
    v_settings.timezone, v_starts_at, v_ends_at, v_duration,
    v_settings.booking_buffer_minutes, tstzrange(v_starts_at, v_ends_at, '[)'),
    'pending', v_settings.currency, v_subtotal, v_discount, v_subtotal - v_discount,
    v_promotion.id, case when v_promotion.id is null then null else v_promotion.code end,
    nullif(btrim(p_notes), '')
  )
  returning id into v_booking_id;

  insert into public.booking_items (booking_id, service_id, service_name_snapshot,
                                    price_snapshot, currency_snapshot, duration_minutes_snapshot, sort_order)
  select v_booking_id, requested.service_id, '', 0, v_settings.currency, 1, requested.ordinality - 1
  from unnest(p_service_ids) with ordinality as requested(service_id, ordinality);

  -- booking_items trigger recomputes subtotal/duration. Apply the already
  -- validated discount after it so total_amount remains an exact snapshot.
  update public.bookings
  set discount_amount = v_discount,
      total_amount = subtotal_amount - v_discount,
      promotion_id = v_promotion.id,
      promotion_code_snapshot = case when v_promotion.id is null then null else v_promotion.code end
  where id = v_booking_id;

  return v_booking_id;
end;
$$;

create or replace function public.cancel_my_booking(p_booking_id uuid, p_cancellation_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_cancellable boolean;
  v_starts_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;

  select b.status, bs.customer_cancellable, b.starts_at
    into v_status, v_cancellable, v_starts_at
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  join public.booking_statuses bs on bs.code = b.status
  where b.id = p_booking_id
    and c.profile_id = auth.uid()
  for update of b;

  if not found then
    raise exception 'Booking not found or not owned by the current customer' using errcode = '42501';
  end if;

  if not v_cancellable or v_starts_at <= now() then
    raise exception 'This booking can no longer be cancelled by the customer' using errcode = '22023';
  end if;

  update public.bookings
  set status = 'cancelled',
      cancellation_reason = nullif(btrim(p_cancellation_reason), ''),
      cancelled_at = now()
  where id = p_booking_id;
end;
$$;

create or replace function public.mark_my_notification_read(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;

  update public.notifications n
  set read_at = coalesce(n.read_at, now())
  where n.id = p_notification_id
    and (
      n.recipient_profile_id = auth.uid()
      or exists (
        select 1 from public.customers c
        where c.id = n.recipient_customer_id and c.profile_id = auth.uid()
      )
    );

  if not found then
    raise exception 'Notification not found or not owned by the current user' using errcode = '42501';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Admin activity audit
-- Metadata intentionally records changed field names rather than full records,
-- so the audit log does not duplicate customer contact data or private notes.
-- -----------------------------------------------------------------------------
create or replace function public.audit_admin_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new jsonb;
  v_old jsonb;
  v_changed jsonb;
  v_metadata jsonb;
  v_entity_id uuid;
begin
  -- Changes made through a customer RPC are not administrative actions. Every
  -- audited table is otherwise protected by a matching management permission.
  if auth.uid() is null or not (
    public.is_admin()
    or public.has_permission('access.manage')
    or public.has_permission('bookings.manage')
    or public.has_permission('catalog.manage')
    or public.has_permission('content.manage')
    or public.has_permission('gallery.manage')
    or public.has_permission('promotions.manage')
    or public.has_permission('reviews.moderate')
    or public.has_permission('schedules.manage')
    or public.has_permission('settings.manage')
  ) then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_old := to_jsonb(old);
    v_new := null;
  else
    v_new := to_jsonb(new);
    if tg_op = 'UPDATE' then
      v_old := to_jsonb(old);
    end if;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(jsonb_agg(changed_key order by changed_key), '[]'::jsonb)
      into v_changed
    from (
      select n.key as changed_key
      from jsonb_each(v_new) n
      where n.key <> 'updated_at'
        and n.value is distinct from (v_old -> n.key)
    ) changed;
  else
    v_changed := '[]'::jsonb;
  end if;

  v_metadata := jsonb_build_object(
    'operation', lower(tg_op),
    'changed_fields', v_changed
  );

  if tg_table_name = 'services' and tg_op = 'UPDATE'
     and (v_new -> 'price') is distinct from (v_old -> 'price') then
    v_metadata := v_metadata || jsonb_build_object(
      'old_price', v_old -> 'price',
      'new_price', v_new -> 'price'
    );
  end if;

  begin
    v_entity_id := coalesce(v_new, v_old) ->> 'id';
  exception when invalid_text_representation then
    v_entity_id := null;
  end;

  insert into public.activity_logs (actor_profile_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    lower(tg_table_name) || '.' || lower(tg_op),
    tg_table_name,
    v_entity_id,
    v_metadata
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Triggers (dropped first so re-running this migration is safe)
-- -----------------------------------------------------------------------------
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

drop trigger if exists prevent_removing_last_admin on public.user_roles;
create trigger prevent_removing_last_admin
  before delete or update of role_code on public.user_roles
  for each row execute function public.prevent_removing_last_admin();

drop trigger if exists validate_business_settings_timezone on public.business_settings;
create trigger validate_business_settings_timezone
  before insert or update on public.business_settings
  for each row execute function public.validate_business_settings();

drop trigger if exists validate_barber_schedule_before_write on public.barber_schedules;
create trigger validate_barber_schedule_before_write
  before insert or update on public.barber_schedules
  for each row execute function public.validate_barber_schedule();

drop trigger if exists validate_barber_schedule_break_before_write on public.barber_schedule_breaks;
create trigger validate_barber_schedule_break_before_write
  before insert or update on public.barber_schedule_breaks
  for each row execute function public.validate_barber_schedule_break();

drop trigger if exists set_booking_derived_fields_before_write on public.bookings;
create trigger set_booking_derived_fields_before_write
  before insert or update on public.bookings
  for each row execute function public.set_booking_derived_fields();

drop trigger if exists booking_requires_item_after_insert on public.bookings;
create constraint trigger booking_requires_item_after_insert
  after insert on public.bookings
  deferrable initially deferred
  for each row execute function public.ensure_booking_has_item();

drop trigger if exists snapshot_booking_item_before_insert on public.booking_items;
create trigger snapshot_booking_item_before_insert
  before insert on public.booking_items
  for each row execute function public.snapshot_booking_item();

drop trigger if exists prevent_booking_item_mutation_before_write on public.booking_items;
create trigger prevent_booking_item_mutation_before_write
  before update or delete on public.booking_items
  for each row execute function public.prevent_booking_item_mutation();

drop trigger if exists sync_booking_from_items_after_insert on public.booking_items;
create trigger sync_booking_from_items_after_insert
  after insert on public.booking_items
  for each row execute function public.sync_booking_from_items();

drop trigger if exists validate_review_booking_before_write on public.reviews;
create trigger validate_review_booking_before_write
  before insert or update on public.reviews
  for each row execute function public.validate_review_booking();

-- Updated-at triggers

drop trigger if exists set_updated_at_roles on public.roles;
create trigger set_updated_at_roles before update on public.roles for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_permissions on public.permissions;
create trigger set_updated_at_permissions before update on public.permissions for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_profiles on public.profiles;
create trigger set_updated_at_profiles before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_booking_statuses on public.booking_statuses;
create trigger set_updated_at_booking_statuses before update on public.booking_statuses for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_business_settings on public.business_settings;
create trigger set_updated_at_business_settings before update on public.business_settings for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_site_sections on public.site_sections;
create trigger set_updated_at_site_sections before update on public.site_sections for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_categories on public.categories;
create trigger set_updated_at_categories before update on public.categories for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_services on public.services;
create trigger set_updated_at_services before update on public.services for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_barbers on public.barbers;
create trigger set_updated_at_barbers before update on public.barbers for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_barber_services on public.barber_services;
create trigger set_updated_at_barber_services before update on public.barber_services for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_barber_schedules on public.barber_schedules;
create trigger set_updated_at_barber_schedules before update on public.barber_schedules for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_barber_schedule_breaks on public.barber_schedule_breaks;
create trigger set_updated_at_barber_schedule_breaks before update on public.barber_schedule_breaks for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_barber_time_off on public.barber_time_off;
create trigger set_updated_at_barber_time_off before update on public.barber_time_off for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_business_closures on public.business_closures;
create trigger set_updated_at_business_closures before update on public.business_closures for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_customers on public.customers;
create trigger set_updated_at_customers before update on public.customers for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_customer_notes on public.customer_notes;
create trigger set_updated_at_customer_notes before update on public.customer_notes for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_promotions on public.promotions;
create trigger set_updated_at_promotions before update on public.promotions for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_bookings on public.bookings;
create trigger set_updated_at_bookings before update on public.bookings for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_reviews on public.reviews;
create trigger set_updated_at_reviews before update on public.reviews for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_gallery on public.gallery;
create trigger set_updated_at_gallery before update on public.gallery for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_notification_deliveries on public.notification_deliveries;
create trigger set_updated_at_notification_deliveries before update on public.notification_deliveries for each row execute function public.set_updated_at();

-- Activity triggers: customer/contact tables are intentionally excluded.
drop trigger if exists audit_business_settings on public.business_settings;
create trigger audit_business_settings after insert or update or delete on public.business_settings for each row execute function public.audit_admin_change();
drop trigger if exists audit_site_sections on public.site_sections;
create trigger audit_site_sections after insert or update or delete on public.site_sections for each row execute function public.audit_admin_change();
drop trigger if exists audit_categories on public.categories;
create trigger audit_categories after insert or update or delete on public.categories for each row execute function public.audit_admin_change();
drop trigger if exists audit_services on public.services;
create trigger audit_services after insert or update or delete on public.services for each row execute function public.audit_admin_change();
drop trigger if exists audit_barbers on public.barbers;
create trigger audit_barbers after insert or update or delete on public.barbers for each row execute function public.audit_admin_change();
drop trigger if exists audit_barber_services on public.barber_services;
create trigger audit_barber_services after insert or update or delete on public.barber_services for each row execute function public.audit_admin_change();
drop trigger if exists audit_barber_schedules on public.barber_schedules;
create trigger audit_barber_schedules after insert or update or delete on public.barber_schedules for each row execute function public.audit_admin_change();
drop trigger if exists audit_barber_schedule_breaks on public.barber_schedule_breaks;
create trigger audit_barber_schedule_breaks after insert or update or delete on public.barber_schedule_breaks for each row execute function public.audit_admin_change();
drop trigger if exists audit_barber_time_off on public.barber_time_off;
create trigger audit_barber_time_off after insert or update or delete on public.barber_time_off for each row execute function public.audit_admin_change();
drop trigger if exists audit_business_closures on public.business_closures;
create trigger audit_business_closures after insert or update or delete on public.business_closures for each row execute function public.audit_admin_change();
drop trigger if exists audit_promotions on public.promotions;
create trigger audit_promotions after insert or update or delete on public.promotions for each row execute function public.audit_admin_change();
drop trigger if exists audit_bookings on public.bookings;
create trigger audit_bookings after insert or update or delete on public.bookings for each row execute function public.audit_admin_change();
drop trigger if exists audit_reviews on public.reviews;
create trigger audit_reviews after insert or update or delete on public.reviews for each row execute function public.audit_admin_change();
drop trigger if exists audit_gallery on public.gallery;
create trigger audit_gallery after insert or update or delete on public.gallery for each row execute function public.audit_admin_change();
drop trigger if exists audit_booking_statuses on public.booking_statuses;
create trigger audit_booking_statuses after insert or update or delete on public.booking_statuses for each row execute function public.audit_admin_change();

commit;
