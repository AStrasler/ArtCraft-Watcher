-- An already claimed scheduled tick must never produce a second crawl.
alter table public.watcher_dispatches
  add column if not exists claimed_at timestamptz,
  add column if not exists claimed_run_id bigint references public.crawl_runs(id) on delete set null;

create or replace function public.claim_artcraft_tick(
  p_tick timestamptz,
  p_lock_owner text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_tick is null or p_lock_owner is null then
    raise exception 'Invalid scheduled tick claim';
  end if;
  if not exists (
    select 1 from public.watcher_lock
    where singleton = true and locked_by = p_lock_owner and locked_until > now()
  ) then
    raise exception 'Watcher lock ownership required';
  end if;
  update public.watcher_dispatches
  set claimed_at = now()
  where tick_utc = p_tick and claimed_at is null;
  return found;
end;
$$;
revoke all on function public.claim_artcraft_tick(timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.claim_artcraft_tick(timestamptz,text)
  to service_role;

create or replace function public.link_artcraft_tick_run(
  p_tick timestamptz,
  p_lock_owner text,
  p_run_id bigint
)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.watcher_lock
    where singleton = true and locked_by = p_lock_owner and locked_until > now()
  ) then raise exception 'Watcher lock ownership required'; end if;
  update public.watcher_dispatches
  set claimed_run_id = p_run_id
  where tick_utc = p_tick and claimed_at is not null and claimed_run_id is null;
  if not found then raise exception 'Scheduled tick not claimable'; end if;
end;
$$;
revoke all on function public.link_artcraft_tick_run(timestamptz,text,bigint)
  from public, anon, authenticated;
grant execute on function public.link_artcraft_tick_run(timestamptz,text,bigint)
  to service_role;
