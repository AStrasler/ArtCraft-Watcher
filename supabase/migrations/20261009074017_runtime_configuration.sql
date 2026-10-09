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

-- Deployment-specific values such as the live Edge Function URL,
-- timezone, and installed app versions are intentionally configured
-- after migrations and are never committed to this repository.
