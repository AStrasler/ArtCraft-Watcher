create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create table if not exists public.watcher_settings (
  singleton boolean primary key default true check (singleton),
  edge_function_url text,
  timezone text not null default 'UTC',
  schedule_hours smallint[] not null default array[8,20]::smallint[],
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.watcher_settings enable row level security;
revoke all on table public.watcher_settings from anon, authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'watcher_settings'
      and policyname = 'deny direct watcher settings access'
  ) then
    create policy "deny direct watcher settings access"
      on public.watcher_settings
      for all
      to anon, authenticated
      using (false)
      with check (false);
  end if;
end
$$;

insert into public.watcher_settings(singleton)
values (true)
on conflict (singleton) do nothing;

create or replace function public.invoke_artcraft_crawl()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  cron_secret text;
  function_url text;
  request_id bigint;
begin
  select edge_function_url
    into function_url
  from public.watcher_settings
  where singleton = true
    and enabled = true;

  if function_url is null or function_url = '' then
    raise exception 'ArtCraft watcher edge function URL is not configured';
  end if;

  select decrypted_secret
    into cron_secret
  from vault.decrypted_secrets
  where name = 'artcraft_cron_secret'
  order by created_at desc
  limit 1;

  if cron_secret is null then
    raise exception 'ArtCraft cron secret is unavailable';
  end if;

  select net.http_post(
    url := function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-artcraft-cron', cron_secret
    ),
    body := jsonb_build_object(
      'source', 'supabase-cron',
      'requested_at', now()
    ),
    timeout_milliseconds := 10000
  )
  into request_id;

  return request_id;
end;
$$;

revoke all on function public.invoke_artcraft_crawl()
  from public, anon, authenticated;
grant execute on function public.invoke_artcraft_crawl()
  to postgres, service_role;

create or replace function public.invoke_artcraft_crawl_if_due()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  configured_timezone text;
  configured_hours smallint[];
  watcher_enabled boolean;
  local_hour integer;
begin
  select timezone, schedule_hours, enabled
    into configured_timezone, configured_hours, watcher_enabled
  from public.watcher_settings
  where singleton = true;

  if coalesce(watcher_enabled, false) = false then
    return null;
  end if;

  local_hour :=
    extract(hour from (now() at time zone configured_timezone))::integer;

  if not (local_hour = any(configured_hours)) then
    return null;
  end if;

  return public.invoke_artcraft_crawl();
end;
$$;

revoke all on function public.invoke_artcraft_crawl_if_due()
  from public, anon, authenticated;
grant execute on function public.invoke_artcraft_crawl_if_due()
  to postgres, service_role;

select cron.unschedule(jobid)
from cron.job
where jobname in (
  'artcraft-crawl-local-8-and-20',
  'artcraft-watcher-hourly-dispatch'
);

select cron.schedule(
  'artcraft-watcher-hourly-dispatch',
  '0 * * * *',
  $$select public.invoke_artcraft_crawl_if_due();$$
);
