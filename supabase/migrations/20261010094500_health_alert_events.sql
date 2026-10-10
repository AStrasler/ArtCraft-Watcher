-- Persist alert state for a downstream notifier without requiring another service.
create table if not exists public.watcher_health_alerts (
  alert_key text primary key
    check (alert_key in ('stale_apps','repeated_failures','missed_dispatches',
                        'unfinalized_runs','unlinked_claims','failed_runs')),
  active boolean not null default true,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  resolved_at timestamptz,
  occurrences integer not null default 1 check (occurrences >= 1),
  last_count integer not null default 0 check (last_count >= 0)
);
alter table public.watcher_health_alerts enable row level security;
revoke all on table public.watcher_health_alerts from anon, authenticated;
grant select on table public.watcher_health_alerts to service_role;

create or replace function public.evaluate_artcraft_health()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  health jsonb;
  record_item record;
  previous_active boolean;
  opened integer := 0;
  resolved integer := 0;
begin
  health := public.artcraft_watcher_health();
  for record_item in
    select * from (
      values
        ('stale_apps', jsonb_array_length(health->'stale_apps')),
        ('repeated_failures', jsonb_array_length(health->'repeated_failure_apps')),
        ('missed_dispatches', (health->>'missed_dispatches')::integer),
        ('unfinalized_runs', (health->>'unfinalized_runs')::integer),
        ('unlinked_claims', (health->>'unlinked_claims')::integer),
        ('failed_runs', case when (health->>'failed_runs_24h')::integer >= 3
                            then (health->>'failed_runs_24h')::integer else 0 end)
    ) as conditions(alert_key, issue_count)
  loop
    select active into previous_active from public.watcher_health_alerts
    where alert_key = record_item.alert_key;
    if record_item.issue_count > 0 then
      if not coalesce(previous_active,false) then opened := opened + 1; end if;
      insert into public.watcher_health_alerts(
        alert_key,active,first_seen_at,last_seen_at,resolved_at,occurrences,last_count
      ) values(record_item.alert_key,true,now(),now(),null,1,record_item.issue_count)
      on conflict(alert_key) do update
        set active=true,
            first_seen_at=case when public.watcher_health_alerts.active
              then public.watcher_health_alerts.first_seen_at else now() end,
            last_seen_at=now(),
            resolved_at=null,
            occurrences=public.watcher_health_alerts.occurrences + 1,
            last_count=excluded.last_count;
    else
      update public.watcher_health_alerts
      set active=false, resolved_at=now(), last_seen_at=now(), last_count=0
      where alert_key=record_item.alert_key and active=true;
      if found then resolved := resolved + 1; end if;
    end if;
  end loop;
  return jsonb_build_object('new_alerts',opened,'resolved_alerts',resolved,'checked_at',now());
end;
$$;
revoke all on function public.evaluate_artcraft_health() from public, anon, authenticated;
grant execute on function public.evaluate_artcraft_health() to postgres, service_role;
