-- Recover runs abandoned by a terminated Edge Function invocation.
-- The caller must already hold the exclusive watcher lock.
create or replace function public.recover_stale_artcraft_runs(
  p_lock_owner text,
  p_min_age_seconds integer default 600
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  recovered integer;
begin
  if p_min_age_seconds < 300 or p_min_age_seconds > 86400 then
    raise exception 'Invalid stale-run age';
  end if;
  if not exists (
    select 1 from public.watcher_lock
    where singleton = true and locked_by = p_lock_owner
      and locked_until > now()
  ) then
    raise exception 'Watcher lock ownership required';
  end if;

  update public.crawl_runs
  set status = 'failed', finished_at = now(),
      error_count = greatest(error_count, 1),
      details = coalesce(details, '{}'::jsonb) ||
        jsonb_build_object('recovery_reason', 'stale running crawl recovered')
  where status = 'running'
    and started_at < now() - make_interval(secs => p_min_age_seconds);
  get diagnostics recovered = row_count;
  return recovered;
end;
$$;

revoke all on function public.recover_stale_artcraft_runs(text,integer) from public, anon, authenticated;
grant execute on function public.recover_stale_artcraft_runs(text,integer) to service_role;
