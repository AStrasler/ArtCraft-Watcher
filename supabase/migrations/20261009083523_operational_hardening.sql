create table if not exists public.notification_state (
  singleton boolean primary key default true check (singleton),
  last_event_id bigint not null default 0,
  last_crawl_run_id bigint not null default 0,
  last_notified_at timestamptz,
  last_health_alert_key text,
  last_health_alert_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.notification_state enable row level security;
revoke all on table public.notification_state from anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'notification_state'
      and policyname = 'deny direct notification state access'
  ) then
    create policy "deny direct notification state access"
      on public.notification_state
      for all
      to anon, authenticated
      using (false)
      with check (false);
  end if;
end
$$;

insert into public.notification_state(singleton)
values (true)
on conflict (singleton) do nothing;

create table if not exists public.watcher_lock (
  singleton boolean primary key default true check (singleton),
  locked_until timestamptz,
  locked_by text,
  updated_at timestamptz not null default now()
);

alter table public.watcher_lock enable row level security;
revoke all on table public.watcher_lock from anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'watcher_lock'
      and policyname = 'deny direct watcher lock access'
  ) then
    create policy "deny direct watcher lock access"
      on public.watcher_lock
      for all
      to anon, authenticated
      using (false)
      with check (false);
  end if;
end
$$;

insert into public.watcher_lock(singleton)
values (true)
on conflict (singleton) do nothing;

create or replace function public.try_acquire_watcher_lock(
  p_owner text,
  p_ttl_seconds integer default 300
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  acquired boolean;
begin
  if p_ttl_seconds < 30 or p_ttl_seconds > 1800 then
    raise exception 'Lock TTL must be between 30 and 1800 seconds';
  end if;

  update public.watcher_lock
  set
    locked_until = now() + make_interval(secs => p_ttl_seconds),
    locked_by = p_owner,
    updated_at = now()
  where singleton = true
    and (locked_until is null or locked_until < now() or locked_by = p_owner);

  acquired := found;
  return acquired;
end;
$$;

create or replace function public.release_watcher_lock(p_owner text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.watcher_lock
  set
    locked_until = null,
    locked_by = null,
    updated_at = now()
  where singleton = true
    and locked_by = p_owner;
end;
$$;

revoke all on function public.try_acquire_watcher_lock(text, integer)
  from public, anon, authenticated;
revoke all on function public.release_watcher_lock(text)
  from public, anon, authenticated;
grant execute on function public.try_acquire_watcher_lock(text, integer)
  to service_role;
grant execute on function public.release_watcher_lock(text)
  to service_role;

create or replace function public.validate_watcher_settings_row()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  if new.timezone is null
     or not exists (
       select 1 from pg_timezone_names where name = new.timezone
     ) then
    raise exception 'Invalid timezone: %', new.timezone;
  end if;

  if new.schedule_hours is null or cardinality(new.schedule_hours) = 0 then
    raise exception 'schedule_hours must contain at least one hour';
  end if;

  if exists (
    select 1
    from unnest(new.schedule_hours) as h
    where h < 0 or h > 23
  ) then
    raise exception 'schedule_hours must contain only values from 0 through 23';
  end if;

  if (
    select count(*) <> count(distinct h)
    from unnest(new.schedule_hours) as h
  ) then
    raise exception 'schedule_hours cannot contain duplicates';
  end if;

  if new.edge_function_url is not null
     and new.edge_function_url !~ '^https://[A-Za-z0-9.-]+/functions/v1/crawl-artcraft$' then
    raise exception 'edge_function_url must be an HTTPS crawl-artcraft function URL';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists watcher_settings_validate on public.watcher_settings;
create trigger watcher_settings_validate
before insert or update on public.watcher_settings
for each row execute function public.validate_watcher_settings_row();

create or replace function public.cleanup_artcraft_watcher_history()
returns jsonb
language plpgsql
security definer
set search_path = public, cron
as $$
declare
  deleted_runs integer := 0;
  deleted_cron_rows integer := 0;
begin
  delete from public.crawl_runs
  where started_at < now() - interval '90 days';
  get diagnostics deleted_runs = row_count;

  delete from cron.job_run_details
  where start_time < now() - interval '30 days';
  get diagnostics deleted_cron_rows = row_count;

  return jsonb_build_object(
    'crawl_runs_deleted', deleted_runs,
    'cron_rows_deleted', deleted_cron_rows
  );
end;
$$;

revoke all on function public.cleanup_artcraft_watcher_history()
  from public, anon, authenticated;
grant execute on function public.cleanup_artcraft_watcher_history()
  to postgres, service_role;

select cron.unschedule(jobid)
from cron.job
where jobname = 'artcraft-watcher-retention';

select cron.schedule(
  'artcraft-watcher-retention',
  '17 3 * * *',
  $$select public.cleanup_artcraft_watcher_history();$$
);
