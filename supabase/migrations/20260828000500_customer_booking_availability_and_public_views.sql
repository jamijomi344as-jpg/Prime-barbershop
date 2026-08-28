-- Booking platform / Phase 3
-- Customer-facing availability RPC and narrowly scoped public projections.
-- Run AFTER all Phase 1 and Phase 2 migrations.
-- This migration does not weaken raw-table RLS policies or create anonymous table writes.

begin;

-- -----------------------------------------------------------------------------
-- 1. Public projections
-- Views expose only content intended for a public website. Raw reviews,
-- promotions, customers, and closed hours retain their existing protected RLS.
-- -----------------------------------------------------------------------------
create or replace view public.public_reviews as
select
  r.id,
  r.rating,
  r.comment,
  r.created_at,
  r.updated_at,
  r.is_featured,
  split_part(btrim(c.full_name), ' ', 1)
    || case
      when position(' ' in btrim(c.full_name)) > 0
        then ' ' || left(split_part(btrim(c.full_name), ' ', 2), 1) || '.'
      else ''
    end as customer_display_name
from public.reviews r
join public.customers c on c.id = r.customer_id
where r.status = 'approved';

create or replace view public.public_review_summary as
select
  count(*)::integer as total_reviews,
  round(avg(rating)::numeric, 2) as average_rating
from public.reviews
where status = 'approved';

create or replace view public.public_promotions as
select
  id,
  code,
  promotion_type,
  discount_value,
  currency,
  start_date,
  end_date,
  minimum_booking_amount
from public.promotions
where is_active
  and archived_at is null
  and (start_date is null or start_date <= current_date)
  and (end_date is null or end_date >= current_date);

-- Closed/open hours are public operational information, while the raw table's
-- existing policy remains active-hours-only for direct table access.
create or replace view public.public_business_hours as
select day_of_week, is_active, start_time, end_time
from public.business_hours
order by day_of_week;

grant select on public.public_reviews, public.public_review_summary,
  public.public_promotions, public.public_business_hours to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. Customer availability RPC
-- A visitor is represented by a Supabase Anonymous Auth session when they begin
-- booking. The function has no anonymous table write policy: it requires auth.uid,
-- returns only safe slot data, and delegates conflict checks to Phase 1/2 helpers.
-- Final booking creation remains create_my_booking(), which recalculates price,
-- duration, promotion rules, and the exclusion-constraint conflict check.
-- -----------------------------------------------------------------------------
create or replace function public.get_booking_slots(
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
  if auth.uid() is null then
    raise exception 'An authenticated or anonymous booking session is required' using errcode = '42501';
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

  if not found or not v_settings.booking_enabled then
    raise exception 'Booking is not currently available' using errcode = '55000';
  end if;

  if p_booking_date > ((now() at time zone v_settings.timezone)::date + v_settings.maximum_booking_days) then
    raise exception 'This date is outside the booking window' using errcode = '22023';
  end if;

  if p_barber_id is null and not v_settings.allow_any_barber then
    raise exception 'A barber selection is required' using errcode = '22023';
  end if;

  select count(*), coalesce(sum(s.duration_minutes), 0)
    into v_service_count, v_duration
  from unnest(p_service_ids) requested(service_id)
  join public.services s on s.id = requested.service_id
  join public.categories c on c.id = s.category_id
  where s.is_active
    and s.archived_at is null
    and c.is_active
    and c.archived_at is null;

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
    and slot.starts_at >= now() + make_interval(mins => v_settings.minimum_booking_notice_minutes)
    and not exists (
      select 1
      from unnest(p_service_ids) requested(service_id)
      where not exists (
        select 1 from public.barber_services bs_service
        where bs_service.barber_id = b.id
          and bs_service.service_id = requested.service_id
          and bs_service.is_active
      )
    )
    and public.barber_is_available(
      b.id,
      slot.starts_at,
      slot.starts_at + make_interval(mins => v_duration),
      p_booking_date,
      (slot.starts_at at time zone v_settings.timezone)::time,
      ((slot.starts_at + make_interval(mins => v_duration)) at time zone v_settings.timezone)::time,
      v_settings.booking_buffer_minutes
    )
  order by b.sort_order, b.name, (slot.starts_at at time zone v_settings.timezone)::time;
end;
$$;

revoke all on function public.get_booking_slots(uuid[], date, uuid) from public;
grant execute on function public.get_booking_slots(uuid[], date, uuid) to authenticated;

commit;
