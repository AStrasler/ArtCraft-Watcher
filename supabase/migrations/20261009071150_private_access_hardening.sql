create policy "deny direct craft_apps access"
  on public.craft_apps
  for all
  to anon, authenticated
  using (false)
  with check (false);

create policy "deny direct crawl_runs access"
  on public.crawl_runs
  for all
  to anon, authenticated
  using (false)
  with check (false);

create policy "deny direct update_events access"
  on public.update_events
  for all
  to anon, authenticated
  using (false)
  with check (false);

create index if not exists update_events_crawl_run_id_idx
  on public.update_events(crawl_run_id);
