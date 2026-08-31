-- Customer review submission for completed bookings.
-- The browser never supplies a customer id: both listing and insertion derive it
-- from the current (including anonymous) Supabase Auth session.
begin;

create or replace function public.get_my_reviewable_bookings()
returns table (
  booking_id uuid,
  booking_date date,
  barber_name text,
  services text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.booking_date,
    br.name,
    string_agg(bi.service_name_snapshot, ', ' order by bi.sort_order)
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  join public.booking_statuses bs on bs.code = b.status and bs.review_eligible
  join public.barbers br on br.id = b.barber_id
  join public.booking_items bi on bi.booking_id = b.id
  left join public.reviews r on r.booking_id = b.id
  where auth.uid() is not null
    and c.profile_id = auth.uid()
    and r.id is null
  group by b.id, b.booking_date, br.name
  order by b.booking_date desc
  limit 20;
$$;

create or replace function public.submit_my_review(
  p_booking_id uuid,
  p_rating smallint,
  p_comment text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_review_id uuid;
begin
  if auth.uid() is null then
    raise exception 'A customer session is required' using errcode = '42501';
  end if;
  if p_rating not between 1 and 5 then
    raise exception 'Rating must be between 1 and 5' using errcode = '22023';
  end if;
  if length(coalesce(btrim(p_comment), '')) > 1000 then
    raise exception 'Review is too long' using errcode = '22023';
  end if;

  select b.customer_id into v_customer_id
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  join public.booking_statuses bs on bs.code = b.status and bs.review_eligible
  where b.id = p_booking_id and c.profile_id = auth.uid();

  if v_customer_id is null then
    raise exception 'This booking is not eligible for a review' using errcode = '42501';
  end if;

  insert into public.reviews (customer_id, booking_id, rating, comment, status)
  values (v_customer_id, p_booking_id, p_rating, nullif(btrim(p_comment), ''), 'pending')
  returning id into v_review_id;
  return v_review_id;
exception
  when unique_violation then
    raise exception 'A review has already been submitted for this booking' using errcode = '23505';
end;
$$;

revoke all on function public.get_my_reviewable_bookings() from public;
revoke all on function public.submit_my_review(uuid, smallint, text) from public;
grant execute on function public.get_my_reviewable_bookings() to authenticated;
grant execute on function public.submit_my_review(uuid, smallint, text) to authenticated;

commit;
