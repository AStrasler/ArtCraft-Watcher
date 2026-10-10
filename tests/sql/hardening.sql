\set ON_ERROR_STOP on
-- Disposable PostgreSQL service only. Never run against production.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;

\ir ../../supabase/migrations/20261009071051_artcraft_watcher.sql
\ir ../../supabase/migrations/20261010085000_app_failure_tracking.sql
\ir ../../supabase/migrations/20261010090000_atomic_crawl_app_update.sql

-- Minimal fixtures for watcher lock and simulated, in-memory pg_net/Vault delivery.
create table public.watcher_lock (
  singleton boolean primary key default true check(singleton),
  locked_until timestamptz,
  locked_by text,
  updated_at timestamptz not null default now()
);
insert into public.watcher_lock(singleton,locked_until,locked_by)
values(true, now() + interval '5 minutes','test-lock');
\ir ../../supabase/migrations/20261010091500_recover_stale_crawl_runs.sql

create table public.watcher_settings (
  singleton boolean primary key default true check(singleton),
  edge_function_url text,
  timezone text not null default 'UTC',
  schedule_hours smallint[] not null default array[8,20]::smallint[],
  enabled boolean not null default true
);
insert into public.watcher_settings(singleton,edge_function_url)
values(true,'https://example.test/functions/v1/crawl-artcraft');
create schema vault;
create table vault.decrypted_secrets (
  name text,
  decrypted_secret text,
  created_at timestamptz default now()
);
insert into vault.decrypted_secrets(name,decrypted_secret)
values('artcraft_cron_secret','local-disposable-only');
create schema net;
create table net.queued (
  id bigint generated always as identity primary key,
  url text,
  headers jsonb,
  body jsonb
);
create function net.http_post(
  url text, headers jsonb, body jsonb, timeout_milliseconds integer
) returns bigint language plpgsql as $$
declare new_id bigint;
begin
  insert into net.queued(url,headers,body) values(url,headers,body)
  returning id into new_id;
  return new_id;
end;
$$;
\ir ../../supabase/migrations/20261010093000_dispatch_idempotency.sql
\ir ../../supabase/migrations/20261010093500_claim_scheduled_ticks.sql
\ir ../../supabase/migrations/20261010094000_health_and_recovery.sql
\ir ../../supabase/migrations/20261010094500_health_alert_events.sql

do $$
declare
  v_app_id bigint;
  v_run_id bigint;
  count_inserted integer;
  previous_sha text;
  old_updated timestamptz;
  failures integer;
  tick timestamptz := date_trunc('hour', now());
  first_request bigint;
  other_request bigint;
  completed boolean;
begin
  select id into v_app_id from public.craft_apps where slug='designcraft';
  insert into public.crawl_runs(status) values('running') returning id into v_run_id;

  -- A real event and app patch commit together.
  select public.record_artcraft_app_result(
    v_app_id,v_run_id,
    jsonb_build_object('latest_commit_sha','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                       'latest_release_tag','v1'),
    jsonb_build_array(jsonb_build_object(
      'event_type','release','new_value','v1','title','First release'))
  ) into count_inserted;
  if count_inserted <> 1 then raise exception 'Initial insert count was %', count_inserted; end if;
  if (select latest_commit_sha from public.craft_apps where id=v_app_id) <>
     'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' then
    raise exception 'App state not updated';
  end if;
  if (select count(*) from public.update_events where app_id=v_app_id) <> 1 then
    raise exception 'Event insert failed';
  end if;

  -- The exact same event is a duplicate, not a new change.
  select public.record_artcraft_app_result(
    v_app_id,v_run_id,jsonb_build_object('latest_release_tag','v1'),
    jsonb_build_array(jsonb_build_object('event_type','release','new_value','v1'))
  ) into count_inserted;
  if count_inserted <> 0 then raise exception 'Duplicate incorrectly counted'; end if;

  -- A null patch value must clear the corresponding nullable state.
  perform public.record_artcraft_app_result(
    v_app_id,v_run_id,'{"latest_release_tag":null}'::jsonb,'[]'::jsonb
  );
  if (select latest_release_tag from public.craft_apps where id=v_app_id) is not null
  then raise exception 'Explicit null was not applied'; end if;

  -- Invalid later event rolls back earlier valid inserts AND state update.
  select latest_commit_sha,updated_at
    into previous_sha,old_updated from public.craft_apps where id=v_app_id;
  begin
    perform public.record_artcraft_app_result(
      v_app_id,v_run_id,jsonb_build_object('latest_commit_sha','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      jsonb_build_array(
        jsonb_build_object('event_type','commit','new_value','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
        jsonb_build_object('event_type','commit','new_value',null))
    );
    raise exception 'Malformed event was accepted';
  exception when others then
    if sqlerrm <> 'Invalid event payload' then raise; end if;
  end;
  if (select latest_commit_sha from public.craft_apps where id=v_app_id) <> previous_sha
  then raise exception 'State advanced despite failed transaction'; end if;
  if exists (select 1 from public.update_events where new_value='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
  then raise exception 'Partial event persisted after rollback'; end if;

  -- Per-app failures accrue, then reset after successful observation.
  select public.record_artcraft_app_failure(v_app_id,v_run_id,'github_http_error')
    into failures;
  if failures <> 1 then raise exception 'Failure streak did not increase'; end if;
  select public.record_artcraft_app_failure(v_app_id,v_run_id,'github_timeout')
    into failures;
  if failures <> 2 then raise exception 'Failure streak did not increase to 2'; end if;
  perform public.record_artcraft_app_result(v_app_id,v_run_id,'{}'::jsonb,'[]'::jsonb);
  if (select consecutive_failures from public.craft_apps where id=v_app_id) <> 0
     or (select last_error from public.craft_apps where id=v_app_id) is not null
  then raise exception 'Successful observation did not reset failure streak'; end if;

  -- Scheduled dispatch is recorded once, whereas manual dispatch is separate.
  select public.dispatch_artcraft_tick(tick) into first_request;
  select public.dispatch_artcraft_tick(tick) into other_request;
  if first_request is null or other_request is not null then
    raise exception 'Scheduled duplicate dispatch was not blocked';
  end if;
  if (select count(*) from net.queued) <> 1 then
    raise exception 'Scheduled HTTP request was duplicated';
  end if;
  if (select body->>'source' from net.queued where id=first_request) <> 'supabase-cron'
  then raise exception 'Scheduled origin not identified'; end if;
  select public.invoke_artcraft_crawl() into other_request;
  if (select body->>'source' from net.queued where id=other_request) <> 'manual'
  then raise exception 'Manual origin not identified'; end if;

  -- Claims bind to a real lock owner and can never be repeated.
  select public.claim_artcraft_tick(tick,'test-lock') into completed;
  if not completed then raise exception 'Scheduled first claim failed'; end if;
  select public.claim_artcraft_tick(tick,'test-lock') into completed;
  if completed then raise exception 'Scheduled duplicate claim succeeded'; end if;
  perform public.link_artcraft_tick_run(tick,'test-lock',v_run_id);
  if (select claimed_run_id from public.watcher_dispatches where tick_utc=tick) <> v_run_id
  then raise exception 'Scheduled run link missing'; end if;
  begin
    perform public.claim_artcraft_tick(tick,'wrong-owner');
    raise exception 'Invalid lock owner was permitted';
  exception when others then
    if sqlerrm <> 'Watcher lock ownership required' then raise; end if;
  end;

  -- RLS access remains denied to anon/authenticated.
  if has_function_privilege('anon','public.claim_artcraft_tick(timestamptz,text)','EXECUTE')
    or has_function_privilege('authenticated','public.record_artcraft_app_result(bigint,bigint,jsonb,jsonb)','EXECUTE')
    or has_table_privilege('anon','public.watcher_dispatches','SELECT')
  then raise exception 'Unauthorized access grant detected'; end if;
end;
$$;

-- Fall-back DST repeats 01:00 local time, but it must dispatch only once.
do $
declare
  first_id bigint;
  second_id bigint;
  first_tick timestamptz := '2026-11-01 06:00:00+00'::timestamptz;
  second_tick timestamptz := '2026-11-01 07:00:00+00'::timestamptz;
  summary jsonb;
begin
  update public.watcher_settings set timezone='America/Chicago' where singleton=true;
  select public.dispatch_artcraft_tick(first_tick) into first_id;
  select public.dispatch_artcraft_tick(second_tick) into second_id;
  if first_id is null or second_id is not null then
    raise exception 'Repeated local DST hour dispatched twice';
  end if;
  if (select count(*) from net.queued) <> 3 then
    raise exception 'DST dispatch count incorrect';
  end if;
  select public.artcraft_watcher_health() into summary;
  if summary is null or summary->'stale_apps' is null
     or summary->'repeated_failure_apps' is null
     or summary->'missed_dispatches' is null then
    raise exception 'Operational health response incomplete';
  end if;
  if has_function_privilege('anon','public.artcraft_watcher_health(integer)','EXECUTE') then
    raise exception 'Health RPC is readable by anon';
  end if;
end;
$;

-- Recovery is locked, bounded by age, and idempotent.
do $$
declare
  stale_id bigint;
  fresh_id bigint;
  count_recovered integer;
begin
  insert into public.crawl_runs(started_at,status)
  values (now()-interval '20 minutes','running') returning id into stale_id;
  insert into public.crawl_runs(started_at,status)
  values (now(),'running') returning id into fresh_id;
  select public.recover_stale_artcraft_runs('test-lock',600) into count_recovered;
  if count_recovered <> 1 then
    raise exception 'Expected exactly one recovered run, got %',count_recovered;
  end if;
  if (select status from public.crawl_runs where id=stale_id) <> 'failed'
     or (select finished_at from public.crawl_runs where id=stale_id) is null
  then raise exception 'Abandoned run not finalized'; end if;
  if (select status from public.crawl_runs where id=fresh_id) <> 'running'
  then raise exception 'Fresh run incorrectly recovered'; end if;
  if public.recover_stale_artcraft_runs('test-lock',600) <> 0
  then raise exception 'Recovery was not idempotent'; end if;
end;
$$;

-- Health checks persist active conditions, deduplicate, and resolve on recovery.
do $
declare
  response jsonb;
  first_count integer;
begin
  select public.evaluate_artcraft_health() into response;
  if (response->>'new_alerts')::integer < 1 then
    raise exception 'No alert created for stale apps';
  end if;
  select occurrences into first_count
    from public.watcher_health_alerts where alert_key='stale_apps';
  perform public.evaluate_artcraft_health();
  if (select occurrences from public.watcher_health_alerts where alert_key='stale_apps')
      <> first_count + 1 then
    raise exception 'Repeated health check did not update existing alert';
  end if;
  update public.craft_apps set last_checked_at=now(),consecutive_failures=0,last_error=null;
  perform public.evaluate_artcraft_health();
  if (select active from public.watcher_health_alerts where alert_key='stale_apps') then
    raise exception 'Recovered alert did not resolve';
  end if;
  if has_function_privilege('anon','public.evaluate_artcraft_health()','EXECUTE')
     or has_table_privilege('authenticated','public.watcher_health_alerts','SELECT') then
    raise exception 'Health alerts are exposed publicly';
  end if;
end;
$;

select 'Atomic, duplicate, rollback, null, failure, dispatch, claim, permission and stale recovery tests passed' as result;
