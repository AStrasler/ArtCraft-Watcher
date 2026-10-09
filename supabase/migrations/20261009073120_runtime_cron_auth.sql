create table if not exists public.watcher_runtime_secrets (
  name text primary key,
  secret_hash text not null,
  created_at timestamptz not null default now()
);

alter table public.watcher_runtime_secrets enable row level security;
revoke all on table public.watcher_runtime_secrets from anon, authenticated;

create policy "deny direct runtime secret access"
  on public.watcher_runtime_secrets
  for all
  to anon, authenticated
  using (false)
  with check (false);

do $$
declare
  generated_secret text;
begin
  if not exists (select 1 from public.watcher_runtime_secrets where name = 'cron') then
    generated_secret := encode(extensions.gen_random_bytes(32), 'hex');

    insert into public.watcher_runtime_secrets(name, secret_hash)
    values (
      'cron',
      encode(extensions.digest(generated_secret, 'sha256'), 'hex')
    );

    perform vault.create_secret(
      generated_secret,
      'artcraft_cron_secret',
      'Secret used only by the ArtCraft Watcher Supabase cron job'
    );
  end if;
end
$$;
