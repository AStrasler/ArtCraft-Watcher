-- Unique UTC hourly tick prevents repeated scheduled HTTP dispatch.
create table if not exists public.watcher_dispatches (
  tick_utc timestamptz primary key,
  local_slot text not null unique,
  request_id bigint,
  queued_at timestamptz not null default now()
);
alter table public.watcher_dispatches enable row level security;
revoke all on table public.watcher_dispatches from anon, authenticated;

-- Shared delivery primitive. Manual invocation is not deduplicated against scheduled ticks.
create or replace function public.send_artcraft_crawl(p_source text, p_tick timestamptz default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  cron_secret text;
  function_url text;
  request_id bigint;
begin
  if p_source not in ('manual', 'supabase-cron') then
    raise exception 'Invalid crawl dispatch source';
  end if;
  select edge_function_url into function_url
  from public.watcher_settings
  where singleton = true and enabled = true;
  if function_url is null or function_url = '' then
    raise exception 'ArtCraft watcher edge function URL is not configured';
  end if;
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets
  where name = 'artcraft_cron_secret'
  order by created_at desc limit 1;
  if cron_secret is null then
    raise exception 'ArtCraft cron secret is unavailable';
  end if;
  select net.http_post(
    url := function_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-artcraft-cron', cron_secret),
    body := jsonb_build_object('source', p_source, 'tick_utc', case when p_tick is null then null
      else to_char(p_tick at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      end, 'requested_at', now()),
    timeout_milliseconds := 10000
  ) into request_id;
  if request_id is null then raise exception 'HTTP dispatch was not queued'; end if;
  return request_id;
end;
$$;
revoke all on function public.send_artcraft_crawl(text,timestamptz) from public, anon, authenticated;
grant execute on function public.send_artcraft_crawl(text,timestamptz) to postgres, service_role;

create or replace function public.invoke_artcraft_crawl()
returns bigint language sql security definer set search_path = ''
as $$
  select public.send_artcraft_crawl('manual', null);
$$;
revoke all on function public.invoke_artcraft_crawl() from public, anon, authenticated;
grant execute on function public.invoke_artcraft_crawl() to postgres, service_role;

create or replace function public.dispatch_artcraft_tick(p_tick timestamptz)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  queued_id bigint;
  local_key text;
begin
  if p_tick is null or p_tick <> date_trunc('hour', p_tick) then
    raise exception 'Tick must be aligned to a UTC hour';
  end if;
  -- Duplicate ticks are safely ignored; the insert and HTTP queue run in one DB transaction.
  select to_char(p_tick at time zone timezone, 'YYYY-MM-DD"T"HH24') || '@' || timezone
    into local_key from public.watcher_settings where singleton = true;
  if local_key is null then raise exception 'Watcher schedule is unavailable'; end if;
  insert into public.watcher_dispatches(tick_utc,local_slot) values (p_tick,local_key)
  on conflict do nothing;
  if not found then return null; end if;
  queued_id := public.send_artcraft_crawl('supabase-cron', p_tick);
  update public.watcher_dispatches set request_id = queued_id
  where tick_utc = p_tick;
  return queued_id;
end;
$$;
revoke all on function public.dispatch_artcraft_tick(timestamptz) from public, anon, authenticated;
grant execute on function public.dispatch_artcraft_tick(timestamptz) to postgres, service_role;

create or replace function public.invoke_artcraft_crawl_if_due()
returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  configured_timezone text;
  configured_hours smallint[];
  watcher_enabled boolean;
  local_hour integer;
begin
  select timezone, schedule_hours, enabled
    into configured_timezone, configured_hours, watcher_enabled
  from public.watcher_settings where singleton = true;
  if not coalesce(watcher_enabled, false) then return null; end if;
  local_hour := extract(hour from (now() at time zone configured_timezone))::integer;
  if not (local_hour = any(configured_hours)) then return null; end if;
  return public.dispatch_artcraft_tick(date_trunc('hour', now()));
end;
$$;
revoke all on function public.invoke_artcraft_crawl_if_due() from public, anon, authenticated;
grant execute on function public.invoke_artcraft_crawl_if_due() to postgres, service_role;
