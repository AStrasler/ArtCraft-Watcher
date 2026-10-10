-- Run in a privileged SQL editor AFTER approved migrations + function deployment.
-- Read-only: raises descriptive errors and never changes application data.
do $$
declare
  missing_count integer;
begin
  if not exists(select 1 from pg_extension where extname='pg_cron')
     or not exists(select 1 from pg_extension where extname='pg_net') then
    raise exception 'Required pg_cron/pg_net extension missing';
  end if;
  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='net' and p.proname='http_post') then
    raise exception 'net.http_post not located in net schema';
  end if;
  if not exists(select 1 from cron.job
     where jobname='artcraft-watcher-hourly-dispatch' and active=true)
     or not exists(select 1 from cron.job
     where jobname='artcraft-watcher-health-hourly' and active=true) then
    raise exception 'Expected scheduled jobs missing or disabled';
  end if;
  if not exists(select 1 from public.watcher_settings
      where singleton=true and enabled=true and edge_function_url is not null) then
    raise exception 'Watcher schedule is disabled or runtime URL is unset';
  end if;
  -- The management API generates its own migration versions; compare stable names.
  select count(*) into missing_count from (values
      ('validate_watcher_data'), ('app_failure_tracking'),
      ('atomic_crawl_app_update'), ('recover_stale_crawl_runs'),
      ('dispatch_idempotency'), ('claim_scheduled_ticks'),
      ('health_and_recovery'), ('health_alert_events'),
      ('schedule_health_cron')
    ) as expected(name)
    where not exists(select 1 from supabase_migrations.schema_migrations m
                     where m.name=expected.name);
  if missing_count <> 0 then
    raise exception '% hardening migrations not applied',missing_count;
  end if;
  if has_function_privilege('anon',
       'public.record_artcraft_app_result(bigint,bigint,jsonb,jsonb)','EXECUTE')
     or has_function_privilege('authenticated',
       'public.artcraft_watcher_health(integer)','EXECUTE') then
    raise exception 'Privileged RPC execute permission exposed';
  end if;
  if exists(select 1 from public.crawl_runs where status='running'
            and started_at < now()-interval '10 minutes') then
    raise exception 'A stale running crawl still needs recovery';
  end if;
end;
$$;

-- Operational summary, without secrets.
select public.artcraft_watcher_health() as health;
select alert_key,active,first_seen_at,last_seen_at,occurrences,last_count
from public.watcher_health_alerts
order by alert_key;
