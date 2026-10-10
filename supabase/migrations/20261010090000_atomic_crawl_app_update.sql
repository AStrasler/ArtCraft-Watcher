-- Atomically persist a single app's state and its deduplicated events.
-- The function executes in one PostgreSQL transaction: failures roll back both writes.
create or replace function public.record_artcraft_app_result(
  p_app_id bigint,
  p_run_id bigint,
  p_patch jsonb,
  p_events jsonb default '[]'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  inserted_count integer := 0;
  affected integer;
begin
  if jsonb_typeof(p_patch) is distinct from 'object'
     or jsonb_typeof(p_events) is distinct from 'array' then
    raise exception 'Invalid crawl payload';
  end if;

  -- Serialize concurrent updates for this app.
  perform 1 from public.craft_apps where id = p_app_id for update;
  if not found then raise exception 'Unknown app id %', p_app_id; end if;
  perform 1 from public.crawl_runs where id = p_run_id and status = 'running';
  if not found then raise exception 'Unknown or finalized run id %', p_run_id; end if;

  for item in select value from jsonb_array_elements(p_events) loop
    if item->>'event_type' not in ('release', 'commit')
       or nullif(item->>'new_value', '') is null then
      raise exception 'Invalid event payload';
    end if;

    insert into public.update_events (
      app_id, crawl_run_id, event_type, old_value, new_value, title, url, metadata
    ) values (
      p_app_id, p_run_id, item->>'event_type', item->>'old_value',
      item->>'new_value', item->>'title', item->>'url',
      coalesce(item->'metadata', '{}'::jsonb)
    ) on conflict (app_id, event_type, new_value) do nothing;
    get diagnostics affected = row_count;
    inserted_count := inserted_count + affected;
  end loop;

  update public.craft_apps set
    latest_release_tag = case when p_patch ? 'latest_release_tag' then (p_patch->>'latest_release_tag') else latest_release_tag end,
    latest_release_url = case when p_patch ? 'latest_release_url' then (p_patch->>'latest_release_url') else latest_release_url end,
    latest_release_published_at = case when p_patch ? 'latest_release_published_at' then (p_patch->>'latest_release_published_at')::timestamptz else latest_release_published_at end,
    latest_commit_sha = case when p_patch ? 'latest_commit_sha' then (p_patch->>'latest_commit_sha') else latest_commit_sha end,
    latest_commit_url = case when p_patch ? 'latest_commit_url' then (p_patch->>'latest_commit_url') else latest_commit_url end,
    latest_commit_message = case when p_patch ? 'latest_commit_message' then (p_patch->>'latest_commit_message') else latest_commit_message end,
    latest_commit_at = case when p_patch ? 'latest_commit_at' then (p_patch->>'latest_commit_at')::timestamptz else latest_commit_at end,
    consecutive_failures = 0, last_failure_at = null, last_error = null,
    last_checked_at = now(), updated_at = now()
  where id = p_app_id;

  return inserted_count;
end;
$$;

revoke all on function public.record_artcraft_app_result(bigint,bigint,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.record_artcraft_app_result(bigint,bigint,jsonb,jsonb) to service_role;
