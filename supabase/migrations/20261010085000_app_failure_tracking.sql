-- Per-app failure tracking, without auto-disabling a repository.
-- Each scheduled crawl keeps retrying failed apps; recovery resets the streak.
alter table public.craft_apps
  add column if not exists consecutive_failures integer not null default 0,
  add column if not exists last_failure_at timestamptz,
  add column if not exists last_error text;
alter table public.craft_apps
  add constraint craft_apps_nonnegative_failures check (consecutive_failures >= 0);

create or replace function public.record_artcraft_app_failure(
  p_app_id bigint,
  p_run_id bigint,
  p_error_code text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare failures integer;
begin
  if p_error_code is null or p_error_code !~ '^[a-z_]{2,40}$' then
    raise exception 'Invalid failure code';
  end if;
  perform 1 from public.crawl_runs where id = p_run_id and status = 'running';
  if not found then raise exception 'Unknown or finalized crawl run'; end if;
  update public.craft_apps
  set consecutive_failures = consecutive_failures + 1,
      last_failure_at = now(),
      last_error = p_error_code,
      updated_at = now()
  where id = p_app_id
  returning consecutive_failures into failures;
  if failures is null then raise exception 'Unknown app id'; end if;
  return failures;
end;
$$;
revoke all on function public.record_artcraft_app_failure(bigint,bigint,text)
  from public, anon, authenticated;
grant execute on function public.record_artcraft_app_failure(bigint,bigint,text)
  to service_role;
