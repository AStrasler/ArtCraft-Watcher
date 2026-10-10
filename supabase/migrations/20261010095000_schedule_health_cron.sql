-- Uses existing pg_cron; one small SQL evaluation per hour, no extra service.
-- Safe to rerun under the named-job upsert behavior of cron.schedule.
select cron.schedule(
  'artcraft-watcher-health-hourly',
  '15 * * * *',
  $$select public.evaluate_artcraft_health();$$
);
