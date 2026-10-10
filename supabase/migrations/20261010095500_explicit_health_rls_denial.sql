-- Explicit policies document the intended deny-all client posture.
-- The service_role bypasses RLS and remains the only operational caller.
do $$
begin
  if not exists (select 1 from pg_policies
    where schemaname='public' and tablename='watcher_dispatches'
      and policyname='deny direct dispatch access') then
    create policy "deny direct dispatch access"
      on public.watcher_dispatches for all
      to anon, authenticated using (false) with check (false);
  end if;
  if not exists (select 1 from pg_policies
    where schemaname='public' and tablename='watcher_health_alerts'
      and policyname='deny direct health alert access') then
    create policy "deny direct health alert access"
      on public.watcher_health_alerts for all
      to anon, authenticated using (false) with check (false);
  end if;
end;
$$;
