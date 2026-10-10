-- Read-only, service-role-only operational summary. No secrets or full repository URLs.
create or replace function public.artcraft_watcher_health(p_stale_minutes integer default 240)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  response jsonb;
begin
  if p_stale_minutes < 60 or p_stale_minutes > 10080 then
    raise exception 'Invalid freshness threshold';
  end if;

  select jsonb_build_object(
    'generated_at', now(),
    'last_success_at', (select max(finished_at) from public.crawl_runs where status = 'success'),
    'last_failure_at', (select max(finished_at) from public.crawl_runs where status = 'failed'),
    'runs_24h', (select count(*) from public.crawl_runs where started_at >= now() - interval '24 hours'),
    'failed_runs_24h', (select count(*) from public.crawl_runs
                        where status = 'failed' and started_at >= now() - interval '24 hours'),
    'unfinalized_runs', (select count(*) from public.crawl_runs where status = 'running'
                         and started_at < now() - interval '10 minutes'),
    'stale_apps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', slug, 'last_checked_at', last_checked_at, 'failure_streak', consecutive_failures
      ) order by slug)
      from public.craft_apps
      where enabled = true and (last_checked_at is null
        or last_checked_at < now() - make_interval(mins => p_stale_minutes))
    ), '[]'::jsonb),
    'repeated_failure_apps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', slug, 'failure_streak', consecutive_failures, 'error_code', last_error
      ) order by slug)
      from public.craft_apps where enabled = true and consecutive_failures >= 3
    ), '[]'::jsonb),
    'missed_dispatches', (select count(*) from public.watcher_dispatches
      where queued_at < now() - interval '15 minutes'
        and queued_at >= now() - interval '24 hours' and claimed_at is null),
    'unlinked_claims', (select count(*) from public.watcher_dispatches
      where claimed_at < now() - interval '15 minutes'
        and claimed_run_id is null),
    'dispatches_24h', (select count(*) from public.watcher_dispatches
      where queued_at >= now() - interval '24 hours'),
    'lock_active', coalesce((select locked_until > now()
      from public.watcher_lock where singleton = true),false),
    'schedule_enabled', coalesce((select enabled
      from public.watcher_settings where singleton = true),false)
  ) into response;
  return response;
end;
$$;
revoke all on function public.artcraft_watcher_health(integer)
  from public, anon, authenticated;
grant execute on function public.artcraft_watcher_health(integer)
  to service_role;

-- Privileged, targeted recheck is provided by the authenticated Edge Function
-- manual app_slug filter; changing observed version fields is unnecessary.
