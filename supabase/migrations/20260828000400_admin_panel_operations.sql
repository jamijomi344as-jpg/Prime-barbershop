-- Booking platform / Phase 2
-- Admin panel support: global hours, status transitions, secure manual bookings,
-- secure booking lifecycle updates, and operational notifications.
--
-- Run AFTER the three Phase 1 migrations. This migration tightens booking writes;
-- it does not remove or weaken Phase 1 RLS or Auth controls.

begin;

-- -----------------------------------------------------------------------------
-- 1. Small schema extensions required by Phase 2 operations
-- -----------------------------------------------------------------------------
-- Global business hours power the Settings > Working Hours screen. No rows are
-- inserted; when this table is empty, existing barber schedules remain the only
-- availability restriction. Once an owner configures rows, inactive days close
-- the business and active rows constrain all barber availability.
create table if not exists public.business_hours (
  id uuid primary key default gen_random_uuid(),
  day_of_week smallint not null unique check (day_of_week between 0 and 6),
  is_active boolean not null default false,
  start_time time,
  end_time time,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_hours_time_check check (
    (not is_active and start_time is null and end_time is null)
    or (is_active and start_time is not null and end_time is not null and end_time > start_time)
  )
);

-- A configurable transition map prevents invalid lifecycle jumps while allowing
-- a future status to be introduced without editing application source code.
create table if not exists public.booking_status_transitions (
  from_status text not null references public.booking_statuses(code) on delete cascade,
  to_status text not null references public.booking_statuses(code) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_status, to_status),
  constraint booking_status_transition_not_self check (from_status <> to_status)
);

insert into public.booking_status_transitions (from_status, to_status)
values
  ('pending', 'confirmed'),
  ('pending', 'cancelled'),
  ('confirmed', 'in_progress'),
  ('confirmed', 'cancelled'),
  ('confirmed', 'no_show'),
  ('in_progress', 'completed'),
  ('in_progress', 'cancelled')
on conflict do nothing;

alter table public.booking_statuses
  add column if not exists manual_creation_allowed boolean not null default false;

-- These are operational defaults for the system-provided statuses, not business
-- content. An owner can refine status configuration later through an admin-only
-- workflow.
update public.booking_statuses
set manual_creation_allowed = true
where code in ('pending', 'confirmed');

alter table public.promotions
  add column if not exists archived_at timestamptz;

alter table public.reviews
  add column if not exists is_featured boolean not null default false;

create index if not exists business_hours_active_day_idx
  on public.business_hours (day_of_week) where is_active;
create index if not exists promotions_available_dates_idx
  on public.promotions (start_date, end_date) where is_active and archived_at is null;
create index if not exists reviews_featured_approved_idx
  on public.reviews (created_at desc) where is_featured and status = 'approved';

-- -----------------------------------------------------------------------------
-- 2. Availability helpers with optional booking exclusion for rescheduling
-- -----------------------------------------------------------------------------
create or replace function public.barber_is_available_excluding(
  p_barber_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_local_date date,
  p_local_start time,
  p_local_end time,
  p_buffer_minutes integer,
  p_exclude_booking_id uuid default null
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
  and (
    not exists (select 1 from public.business_hours)
    or exists (
      select 1
      from public.business_hours bh
      where bh.day_of_week = extract(dow from p_local_date)::smallint
        and bh.is_active
        and bh.start_time <= p_local_start
        and bh.end_time >= p_local_end
    )
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
      and existing_booking.id is distinct from p_exclude_booking_id
      and existing_booking.appointment_range &&
          tstzrange(p_starts_at, p_ends_at + make_interval(mins => p_buffer_minutes), '[)')
  );
$$;

-- Keep the Phase 1 customer booking function and its signature intact while
-- extending its availability check to honor configured global business hours.
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
  select public.barber_is_available_excluding(
    p_barber_id,
    p_starts_at,
    p_ends_at,
    p_local_date,
    p_local_start,
    p_local_end,
    p_buffer_minutes,
    null
  );
$$;

-- -----------------------------------------------------------------------------
-- 3. Shared secure admin operations
-- -----------------------------------------------------------------------------
create or replace function public.create_admin_booking(
  p_customer_id uuid,
  p_service_ids uuid[],
  p_booking_date date,
  p_start_time time,
  p_barber_id uuid default null,
  p_notes text default null,
  p_promotion_code text default null,
  p_initial_status text default 'confirmed'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.business_settings%rowtype;
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
  if auth.uid() is null or not public.has_permission('bookings.manage') then
    raise exception 'Not authorized to create manual bookings' using errcode = '42501';
  end if;

  if p_service_ids is null
     or cardinality(p_service_ids) = 0
     or array_position(p_service_ids, null) is not null then
    raise exception 'At least one service is required' using errcode = '22023';
  end if;

  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'Selected customer does not exist' using errcode = '23503';
  end if;

  select * into v_settings from public.business_settings where is_primary limit 1;
  if not found then
    raise exception 'Business settings have not been configured' using errcode = '55000';
  end if;
  if not v_settings.booking_enabled then
    raise exception 'Online and manual booking are currently disabled' using errcode = '55000';
  end if;
  if p_booking_date > ((now() at time zone v_settings.timezone)::date + v_settings.maximum_booking_days) then
    raise exception 'This date is outside the maximum booking window' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.booking_statuses
    where code = p_initial_status and manual_creation_allowed
  ) then
    raise exception 'The selected initial booking status is not allowed for manual bookings' using errcode = '22023';
  end if;

  select count(*), coalesce(sum(s.price), 0), coalesce(sum(s.duration_minutes), 0)
    into v_service_count, v_subtotal, v_duration
  from unnest(p_service_ids) requested(service_id)
  join public.services s on s.id = requested.service_id
  join public.categories c on c.id = s.category_id
  where s.is_active and s.archived_at is null and c.is_active and c.archived_at is null;

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

  v_starts_at := (p_booking_date + p_start_time) at time zone v_settings.timezone;
  if v_starts_at < now() + make_interval(mins => v_settings.minimum_booking_notice_minutes) then
    raise exception 'This time does not meet the minimum booking notice' using errcode = '22023';
  end if;
  v_ends_at := v_starts_at + make_interval(mins => v_duration);
  v_local_end_date := (v_ends_at at time zone v_settings.timezone)::date;
  v_local_end_time := (v_ends_at at time zone v_settings.timezone)::time;

  if v_local_end_date <> p_booking_date or v_local_end_time <= p_start_time then
    raise exception 'A booking may not cross the local business day boundary' using errcode = '22023';
  end if;

  if p_barber_id is not null then
    v_barber_id := p_barber_id;
    if exists (
      select 1 from unnest(p_service_ids) requested(service_id)
      where not exists (
        select 1 from public.barber_services bs
        where bs.barber_id = v_barber_id and bs.service_id = requested.service_id and bs.is_active
      )
    ) then
      raise exception 'Selected barber does not provide every selected service' using errcode = '22023';
    end if;
  elsif v_settings.allow_any_barber then
    select b.id into v_barber_id
    from public.barbers b
    where b.is_active and b.archived_at is null
      and not exists (
        select 1 from unnest(p_service_ids) requested(service_id)
        where not exists (
          select 1 from public.barber_services bs
          where bs.barber_id = b.id and bs.service_id = requested.service_id and bs.is_active
        )
      )
      and public.barber_is_available_excluding(
        b.id, v_starts_at, v_ends_at, p_booking_date, p_start_time,
        v_local_end_time, v_settings.booking_buffer_minutes, null
      )
    order by b.sort_order, b.name, b.id
    limit 1;
  else
    raise exception 'A barber selection is required' using errcode = '22023';
  end if;

  if v_barber_id is null or not public.barber_is_available_excluding(
    v_barber_id, v_starts_at, v_ends_at, p_booking_date, p_start_time,
    v_local_end_time, v_settings.booking_buffer_minutes, null
  ) then
    raise exception 'Selected barber is not available for this time' using errcode = '23P01';
  end if;

  if not exists (
    select 1 from public.barber_schedules bs
    where bs.barber_id = v_barber_id
      and bs.is_active
      and bs.day_of_week = extract(dow from p_booking_date)::smallint
      and bs.start_time <= p_start_time
      and bs.end_time >= v_local_end_time
      and mod(extract(epoch from (p_start_time - bs.start_time))::integer,
              v_settings.default_slot_interval_minutes) = 0
  ) then
    raise exception 'Start time is not aligned to the configured slot interval' using errcode = '22023';
  end if;

  if nullif(btrim(p_promotion_code), '') is not null then
    select * into v_promotion
    from public.promotions p
    where lower(p.code) = lower(btrim(p_promotion_code))
      and p.is_active and p.archived_at is null
      and (p.start_date is null or p.start_date <= p_booking_date)
      and (p.end_date is null or p.end_date >= p_booking_date)
    for update;

    if not found then
      raise exception 'Promotion code is invalid or inactive' using errcode = '22023';
    end if;
    if v_promotion.promotion_type = 'fixed_amount' and v_promotion.currency <> v_settings.currency then
      raise exception 'Promotion currency does not match the booking currency' using errcode = '22023';
    end if;
    if v_promotion.minimum_booking_amount is not null and v_subtotal < v_promotion.minimum_booking_amount then
      raise exception 'This booking does not meet the promotion minimum amount' using errcode = '22023';
    end if;
    if v_promotion.maximum_usage is not null then
      select count(*) into v_promotion_usage
      from public.bookings b
      join public.booking_statuses bs on bs.code = b.status
      where b.promotion_id = v_promotion.id and bs.counts_as_promotion_usage;
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
       or exists (select 1 from public.promotion_services ps where ps.promotion_id = v_promotion.id and ps.service_id = s.id)
       or exists (select 1 from public.promotion_categories pc where pc.promotion_id = v_promotion.id and pc.category_id = s.category_id);
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
  ) values (
    p_customer_id, v_barber_id, p_booking_date, p_start_time, v_local_end_time,
    v_settings.timezone, v_starts_at, v_ends_at, v_duration,
    v_settings.booking_buffer_minutes, tstzrange(v_starts_at, v_ends_at, '[)'),
    p_initial_status, v_settings.currency, v_subtotal, v_discount,
    v_subtotal - v_discount, v_promotion.id,
    case when v_promotion.id is null then null else v_promotion.code end,
    nullif(btrim(p_notes), '')
  ) returning id into v_booking_id;

  insert into public.booking_items (booking_id, service_id, service_name_snapshot,
                                    price_snapshot, currency_snapshot, duration_minutes_snapshot, sort_order)
  select v_booking_id, requested.service_id, '', 0, v_settings.currency, 1, requested.ordinality - 1
  from unnest(p_service_ids) with ordinality as requested(service_id, ordinality);

  update public.bookings
  set discount_amount = v_discount,
      total_amount = subtotal_amount - v_discount,
      promotion_id = v_promotion.id,
      promotion_code_snapshot = case when v_promotion.id is null then null else v_promotion.code end
  where id = v_booking_id;

  return v_booking_id;
end;
$$;

-- Returns server-validated candidate slots for the manual-booking flow. The
-- final create_admin_booking call repeats every validation and remains the
-- authority in case a concurrent booking takes the slot after this query.
create or replace function public.admin_available_slots(
  p_service_ids uuid[],
  p_booking_date date,
  p_barber_id uuid default null
)
returns table (barber_id uuid, start_time time, end_time time)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.business_settings%rowtype;
  v_duration integer;
  v_service_count integer;
begin
  if auth.uid() is null or not public.has_permission('bookings.manage') then
    raise exception 'Not authorized to view manual-booking availability' using errcode = '42501';
  end if;
  if p_service_ids is null or cardinality(p_service_ids) = 0 or array_position(p_service_ids, null) is not null then
    raise exception 'At least one service is required' using errcode = '22023';
  end if;

  select * into v_settings from public.business_settings where is_primary limit 1;
  if not found or not v_settings.booking_enabled then
    raise exception 'Booking is not configured or enabled' using errcode = '55000';
  end if;

  select count(*), coalesce(sum(s.duration_minutes), 0) into v_service_count, v_duration
  from unnest(p_service_ids) requested(service_id)
  join public.services s on s.id = requested.service_id
  join public.categories c on c.id = s.category_id
  where s.is_active and s.archived_at is null and c.is_active and c.archived_at is null;
  if v_service_count <> cardinality(p_service_ids) or v_duration <= 0 then
    raise exception 'One or more selected services are unavailable' using errcode = '22023';
  end if;

  return query
  select
    b.id,
    (slot.starts_at at time zone v_settings.timezone)::time,
    ((slot.starts_at + make_interval(mins => v_duration)) at time zone v_settings.timezone)::time
  from public.barbers b
  join public.barber_schedules bs
    on bs.barber_id = b.id
   and bs.is_active
   and bs.day_of_week = extract(dow from p_booking_date)::smallint
  cross join lateral generate_series(
    (p_booking_date + bs.start_time) at time zone v_settings.timezone,
    ((p_booking_date + bs.end_time) at time zone v_settings.timezone) - make_interval(mins => v_duration),
    make_interval(mins => v_settings.default_slot_interval_minutes)
  ) as slot(starts_at)
  where b.is_active
    and b.archived_at is null
    and (p_barber_id is null or b.id = p_barber_id)
    and not exists (
      select 1 from unnest(p_service_ids) requested(service_id)
      where not exists (
        select 1 from public.barber_services b_service
        where b_service.barber_id = b.id and b_service.service_id = requested.service_id and b_service.is_active
      )
    )
    and public.barber_is_available_excluding(
      b.id,
      slot.starts_at,
      slot.starts_at + make_interval(mins => v_duration),
      p_booking_date,
      (slot.starts_at at time zone v_settings.timezone)::time,
      ((slot.starts_at + make_interval(mins => v_duration)) at time zone v_settings.timezone)::time,
      v_settings.booking_buffer_minutes,
      null
    )
  order by 1, 2;
end;
$$;

-- All privileged booking transitions/reschedules pass through this RPC. The
-- Phase 1 direct booking UPDATE RLS policy is removed below, so an admin cannot
-- bypass transition/schedule validation through direct PostgREST updates.
create or replace function public.admin_update_booking(
  p_booking_id uuid,
  p_status text default null,
  p_barber_id uuid default null,
  p_booking_date date default null,
  p_start_time time default null,
  p_notes text default null,
  p_notes_set boolean default false,
  p_cancellation_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_settings public.business_settings%rowtype;
  v_target_status text;
  v_target_barber uuid;
  v_target_date date;
  v_target_time time;
  v_target_starts_at timestamptz;
  v_target_ends_at timestamptz;
  v_target_end_date date;
  v_target_end_time time;
  v_current_terminal boolean;
  v_target_terminal boolean;
  v_target_is_cancellation boolean;
begin
  if auth.uid() is null or not public.has_permission('bookings.manage') then
    raise exception 'Not authorized to manage bookings' using errcode = '42501';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if not found then
    raise exception 'Booking does not exist' using errcode = '23503';
  end if;

  v_target_status := coalesce(nullif(btrim(p_status), ''), v_booking.status);
  v_target_barber := coalesce(p_barber_id, v_booking.barber_id);
  v_target_date := coalesce(p_booking_date, v_booking.booking_date);
  v_target_time := coalesce(p_start_time, v_booking.start_time);

  select is_terminal into v_current_terminal from public.booking_statuses where code = v_booking.status;
  select is_terminal, is_cancellation into v_target_terminal, v_target_is_cancellation
  from public.booking_statuses where code = v_target_status;
  if not found then
    raise exception 'Unknown booking status: %', v_target_status using errcode = '22023';
  end if;

  if v_target_status <> v_booking.status and not exists (
    select 1 from public.booking_status_transitions
    where from_status = v_booking.status and to_status = v_target_status
  ) then
    raise exception 'Invalid booking status transition from % to %', v_booking.status, v_target_status
      using errcode = '22023';
  end if;

  if p_barber_id is not null or p_booking_date is not null or p_start_time is not null then
    if v_current_terminal or v_target_terminal then
      raise exception 'Terminal bookings cannot be rescheduled or reassigned' using errcode = '22023';
    end if;

    select * into v_settings from public.business_settings where is_primary limit 1;
    if not found then
      raise exception 'Business settings have not been configured' using errcode = '55000';
    end if;
    if v_target_date > ((now() at time zone v_settings.timezone)::date + v_settings.maximum_booking_days) then
      raise exception 'This date is outside the maximum booking window' using errcode = '22023';
    end if;

    v_target_starts_at := (v_target_date + v_target_time) at time zone v_settings.timezone;
    if v_target_starts_at < now() + make_interval(mins => v_settings.minimum_booking_notice_minutes) then
      raise exception 'This time does not meet the minimum booking notice' using errcode = '22023';
    end if;
    v_target_ends_at := v_target_starts_at + make_interval(mins => v_booking.service_duration_minutes);
    v_target_end_date := (v_target_ends_at at time zone v_settings.timezone)::date;
    v_target_end_time := (v_target_ends_at at time zone v_settings.timezone)::time;

    if v_target_end_date <> v_target_date or v_target_end_time <= v_target_time then
      raise exception 'A booking may not cross the local business day boundary' using errcode = '22023';
    end if;

    if exists (
      select 1 from public.booking_items bi
      where bi.booking_id = p_booking_id
        and not exists (
          select 1 from public.barber_services bs
          where bs.barber_id = v_target_barber and bs.service_id = bi.service_id and bs.is_active
        )
    ) then
      raise exception 'Selected barber does not provide every booked service' using errcode = '22023';
    end if;

    if not public.barber_is_available_excluding(
      v_target_barber, v_target_starts_at, v_target_ends_at, v_target_date,
      v_target_time, v_target_end_time, v_booking.booking_buffer_minutes, p_booking_id
    ) then
      raise exception 'Selected barber is not available for this time' using errcode = '23P01';
    end if;

    if not exists (
      select 1 from public.barber_schedules bs
      where bs.barber_id = v_target_barber
        and bs.is_active
        and bs.day_of_week = extract(dow from v_target_date)::smallint
        and bs.start_time <= v_target_time
        and bs.end_time >= v_target_end_time
        and mod(extract(epoch from (v_target_time - bs.start_time))::integer,
                v_settings.default_slot_interval_minutes) = 0
    ) then
      raise exception 'Start time is not aligned to the configured slot interval' using errcode = '22023';
    end if;
  else
    v_target_starts_at := v_booking.starts_at;
  end if;

  update public.bookings
  set status = v_target_status,
      barber_id = v_target_barber,
      starts_at = v_target_starts_at,
      notes = case when p_notes_set then nullif(btrim(p_notes), '') else notes end,
      cancellation_reason = case
        when v_target_is_cancellation then nullif(btrim(p_cancellation_reason), '')
        else cancellation_reason
      end,
      cancelled_at = case when v_target_is_cancellation then now() else cancelled_at end
  where id = p_booking_id;

  return p_booking_id;
end;
$$;

-- Customer detail totals are also computed server-side so the customer profile
-- remains correct without downloading an unbounded appointment history.
create or replace function public.admin_customer_summary(p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not (
    public.has_permission('customers.read') or public.has_permission('customers.manage')
  ) then
    raise exception 'Not authorized to view customer summaries' using errcode = '42501';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'Customer does not exist' using errcode = '23503';
  end if;

  return jsonb_build_object(
    'bookings', (select count(*) from public.bookings where customer_id = p_customer_id),
    'completed_bookings', (select count(*) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.customer_id = p_customer_id and bs.counts_toward_revenue),
    'cancelled_bookings', (select count(*) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.customer_id = p_customer_id and bs.is_cancellation),
    'total_spending', (select coalesce(sum(b.total_amount), 0) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.customer_id = p_customer_id and bs.counts_toward_revenue),
    'last_visit', (select max(b.booking_date) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.customer_id = p_customer_id and bs.counts_toward_revenue),
    'services', coalesce((
      select jsonb_agg(service_row order by (service_row ->> 'uses')::integer desc)
      from (
        select jsonb_build_object('name', bi.service_name_snapshot, 'uses', count(*)) as service_row
        from public.booking_items bi
        join public.bookings b on b.id = bi.booking_id
        join public.booking_statuses bs on bs.code = b.status
        where b.customer_id = p_customer_id and bs.counts_toward_revenue
        group by bi.service_name_snapshot
        order by count(*) desc, bi.service_name_snapshot
        limit 12
      ) service_rows
    ), '[]'::jsonb)
  );
end;
$$;

-- Server-side analytics avoids downloading unbounded booking/item tables into a
-- browser. It returns only aggregates that an authorized analytics user can see.
create or replace function public.admin_analytics(p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_permission('analytics.read') then
    raise exception 'Not authorized to view analytics' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'A valid analytics date range is required' using errcode = '22023';
  end if;

  select jsonb_build_object(
    'summary', jsonb_build_object(
      'bookings', (select count(*) from public.bookings b where b.booking_date between p_from and p_to),
      'revenue', (select coalesce(sum(b.total_amount), 0) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.booking_date between p_from and p_to and bs.counts_toward_revenue),
      'average_booking_value', (select coalesce(avg(b.total_amount), 0) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.booking_date between p_from and p_to and bs.counts_toward_revenue),
      'cancelled', (select count(*) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.booking_date between p_from and p_to and bs.is_cancellation),
      'no_shows', (select count(*) from public.bookings b join public.booking_statuses bs on bs.code = b.status where b.booking_date between p_from and p_to and bs.is_no_show),
      'new_customers', (select count(*) from public.customers c where c.created_at::date between p_from and p_to),
      'returning_customers', (select count(*) from (select b.customer_id from public.bookings b where b.booking_date between p_from and p_to group by b.customer_id having count(*) > 1) returning_customers_rows)
    ),
    'status_counts', coalesce((
      select jsonb_object_agg(status, booking_count)
      from (
        select b.status, count(*)::integer as booking_count
        from public.bookings b
        where b.booking_date between p_from and p_to
        group by b.status
      ) counts
    ), '{}'::jsonb),
    'daily', coalesce((
      select jsonb_agg(day_row order by (day_row ->> 'date'))
      from (
        select jsonb_build_object(
          'date', b.booking_date,
          'bookings', count(*),
          'revenue', coalesce(sum(b.total_amount) filter (where bs.counts_toward_revenue), 0)
        ) as day_row
        from public.bookings b
        join public.booking_statuses bs on bs.code = b.status
        where b.booking_date between p_from and p_to
        group by b.booking_date
      ) daily_rows
    ), '[]'::jsonb),
    'top_services', coalesce((
      select jsonb_agg(service_row order by (service_row ->> 'bookings')::integer desc)
      from (
        select jsonb_build_object(
          'service_id', bi.service_id,
          'name', bi.service_name_snapshot,
          'bookings', count(*),
          'revenue', coalesce(sum(bi.price_snapshot) filter (where bs.counts_toward_revenue), 0)
        ) as service_row
        from public.booking_items bi
        join public.bookings b on b.id = bi.booking_id
        join public.booking_statuses bs on bs.code = b.status
        where b.booking_date between p_from and p_to
          and not bs.is_cancellation
        group by bi.service_id, bi.service_name_snapshot
        order by count(*) desc, bi.service_name_snapshot
        limit 8
      ) service_rows
    ), '[]'::jsonb),
    'top_barbers', coalesce((
      select jsonb_agg(barber_row order by (barber_row ->> 'bookings')::integer desc)
      from (
        select jsonb_build_object(
          'barber_id', br.id,
          'name', br.name,
          'bookings', count(*),
          'revenue', coalesce(sum(b.total_amount) filter (where bs.counts_toward_revenue), 0)
        ) as barber_row
        from public.bookings b
        join public.barbers br on br.id = b.barber_id
        join public.booking_statuses bs on bs.code = b.status
        where b.booking_date between p_from and p_to
          and not bs.is_cancellation
        group by br.id, br.name
        order by count(*) desc, br.name
        limit 8
      ) barber_rows
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Operational notification triggers
-- The notification data is visible only through notification RLS to recipients.
-- -----------------------------------------------------------------------------
create or replace function public.notify_admins_of_new_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid := new.booking_id;
  v_customer_name text;
  v_barber_name text;
  v_services text;
  v_booking_date date;
  v_start_time time;
begin
  -- This function is a deferred booking_items trigger. By commit time every
  -- line item snapshot exists, so the realtime toast has the complete service list.
  if exists (
    select 1 from public.notifications n
    where n.notification_type = 'booking.new'
      and n.data ->> 'booking_id' = v_booking_id::text
  ) then
    return new;
  end if;

  select c.full_name, b.name, booking.booking_date, booking.start_time
    into v_customer_name, v_barber_name, v_booking_date, v_start_time
  from public.bookings booking
  join public.customers c on c.id = booking.customer_id
  join public.barbers b on b.id = booking.barber_id
  where booking.id = v_booking_id;

  select string_agg(bi.service_name_snapshot, ', ' order by bi.sort_order)
    into v_services
  from public.booking_items bi
  where bi.booking_id = v_booking_id;

  insert into public.notifications (
    recipient_profile_id, notification_type, title, message, data
  )
  select
    ur.user_id,
    'booking.new',
    'Новая запись',
    'A new booking requires attention.',
    jsonb_build_object(
      'booking_id', v_booking_id,
      'customer_name', v_customer_name,
      'barber_name', v_barber_name,
      'services', coalesce(v_services, ''),
      'booking_date', v_booking_date,
      'start_time', v_start_time
    )
  from public.user_roles ur
  where ur.role_code = 'admin';

  return new;
end;
$$;

create or replace function public.notify_customer_of_booking_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  select profile_id into v_profile_id from public.customers where id = new.customer_id;
  if v_profile_id is not null then
    insert into public.notifications (
      recipient_profile_id, recipient_customer_id, notification_type, title, message, data
    ) values (
      v_profile_id,
      new.customer_id,
      'booking.status_changed',
      'Booking status updated',
      'Your booking status has changed.',
      jsonb_build_object('booking_id', new.id, 'status', new.status)
    );
  end if;
  return new;
end;
$$;

create or replace function public.notify_admins_of_new_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_name text;
begin
  select full_name into v_customer_name from public.customers where id = new.customer_id;

  insert into public.notifications (
    recipient_profile_id, notification_type, title, message, data
  )
  select
    ur.user_id,
    'review.new',
    'New review',
    'A new review is waiting for moderation.',
    jsonb_build_object('review_id', new.id, 'customer_name', v_customer_name, 'rating', new.rating)
  from public.user_roles ur
  where ur.role_code = 'admin';

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. RLS, grants, audit, and trigger registration
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on public.business_hours to authenticated;
grant select, insert, update, delete on public.booking_status_transitions to authenticated;
grant select on public.business_hours to anon;
alter table public.business_hours enable row level security;
alter table public.booking_status_transitions enable row level security;

drop policy if exists business_hours_public_read on public.business_hours;
create policy business_hours_public_read on public.business_hours
  for select to anon, authenticated using (is_active);
drop policy if exists business_hours_manage on public.business_hours;
create policy business_hours_manage on public.business_hours
  for all to authenticated
  using (public.has_permission('settings.manage'))
  with check (public.has_permission('settings.manage'));

drop policy if exists booking_status_transitions_authenticated_read on public.booking_status_transitions;
create policy booking_status_transitions_authenticated_read on public.booking_status_transitions
  for select to authenticated using (true);
drop policy if exists booking_status_transitions_admin_manage on public.booking_status_transitions;
create policy booking_status_transitions_admin_manage on public.booking_status_transitions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Reviews retain raw RLS protection; the Phase 1 public view remains the only
-- anonymous public review source. Moderators can set is_featured.
-- Promotions are archived by setting archived_at/is_active, not by deleting
-- referenced historical records.

drop policy if exists bookings_staff_update on public.bookings;

revoke all on function public.create_admin_booking(uuid, uuid[], date, time without time zone, uuid, text, text, text) from public;
revoke all on function public.admin_update_booking(uuid, text, uuid, date, time without time zone, text, boolean, text) from public;
revoke all on function public.admin_analytics(date, date) from public;
revoke all on function public.admin_customer_summary(uuid) from public;
revoke all on function public.admin_available_slots(uuid[], date, uuid) from public;
revoke all on function public.barber_is_available_excluding(uuid, timestamptz, timestamptz, date, time without time zone, time without time zone, integer, uuid) from public;
revoke all on function public.notify_admins_of_new_booking() from public;
revoke all on function public.notify_customer_of_booking_status_change() from public;
revoke all on function public.notify_admins_of_new_review() from public;
grant execute on function public.create_admin_booking(uuid, uuid[], date, time without time zone, uuid, text, text, text) to authenticated;
grant execute on function public.admin_update_booking(uuid, text, uuid, date, time without time zone, text, boolean, text) to authenticated;
grant execute on function public.admin_analytics(date, date) to authenticated;
grant execute on function public.admin_customer_summary(uuid) to authenticated;
grant execute on function public.admin_available_slots(uuid[], date, uuid) to authenticated;

-- Existing generic admin audit function is reused, preserving audit consistency.
drop trigger if exists set_updated_at_business_hours on public.business_hours;
create trigger set_updated_at_business_hours
  before update on public.business_hours
  for each row execute function public.set_updated_at();
drop trigger if exists audit_business_hours on public.business_hours;
create trigger audit_business_hours
  after insert or update or delete on public.business_hours
  for each row execute function public.audit_admin_change();

drop trigger if exists notify_admins_new_booking on public.bookings;
drop trigger if exists notify_admins_new_booking_after_items on public.booking_items;
create constraint trigger notify_admins_new_booking_after_items
  after insert on public.booking_items
  deferrable initially deferred
  for each row execute function public.notify_admins_of_new_booking();
drop trigger if exists notify_customer_booking_status_change on public.bookings;
create trigger notify_customer_booking_status_change
  after update of status on public.bookings
  for each row execute function public.notify_customer_of_booking_status_change();
drop trigger if exists notify_admins_new_review on public.reviews;
create trigger notify_admins_new_review
  after insert on public.reviews
  for each row execute function public.notify_admins_of_new_review();

-- Realtime is already configured for notifications/bookings in Phase 1. Newly
-- created notification rows and booking updates therefore reach authorized
-- subscribers immediately.

commit;
