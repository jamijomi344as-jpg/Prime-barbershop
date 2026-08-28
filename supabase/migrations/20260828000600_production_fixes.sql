-- Booking platform / Phase 3.5 production hardening
-- Run AFTER migrations 20260828000100 through 20260828000500.
--
-- Why: Earlier migrations correctly fixed SECURITY DEFINER functions to the
-- public schema and revoke CREATE there. This migration adds the explicit
-- pg_catalog/public/pg_temp search path hardening recommended for every current
-- public-schema SECURITY DEFINER function, removes accidental PUBLIC execute
-- fallback on any such function, and marks intentional public views as security
-- barriers. It does not alter application data, RLS policies, or functionality.

begin;

-- Qualify all function resolution, including a safe trailing pg_temp entry.
-- The loop is intentionally metadata-driven so it covers Phase 1–3 functions
-- without silently missing a SECURITY DEFINER function added by a prior migration.
do $$
declare
  v_function text;
begin
  for v_function in
    select format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
  loop
    execute format(
      'alter function %s set search_path = pg_catalog, public, pg_temp',
      v_function
    );
    execute format('revoke all on function %s from public', v_function);
  end loop;
end;
$$;

-- Explicitly preserve the narrow grants required by policies and browser flows.
-- REVOKE FROM PUBLIC above does not remove grants made directly to anon or
-- authenticated, but these grants make the intended contract auditable.
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
grant execute on function public.create_admin_booking(uuid, uuid[], date, time without time zone, uuid, text, text, text) to authenticated;
grant execute on function public.admin_update_booking(uuid, text, uuid, date, time without time zone, text, boolean, text) to authenticated;
grant execute on function public.admin_available_slots(uuid[], date, uuid) to authenticated;
grant execute on function public.admin_customer_summary(uuid) to authenticated;
grant execute on function public.admin_analytics(date, date) to authenticated;
grant execute on function public.get_booking_slots(uuid[], date, uuid) to authenticated;

-- Public views intentionally operate with the migration-owner's access so they
-- can expose a safe projection while their raw protected tables remain private.
-- security_barrier prevents predicates supplied by a caller being pushed beneath
-- the view's safety filter.
alter view public.public_reviews set (security_barrier = true);
alter view public.public_review_summary set (security_barrier = true);
alter view public.public_promotions set (security_barrier = true);
alter view public.public_business_hours set (security_barrier = true);

commit;
