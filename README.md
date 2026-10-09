# ArtCraft Watcher

ArtCraft Watcher is a small, self-hosted update watcher for the public ArtCraft repositories. It runs remotely on Supabase, checks upstream releases and commits, stores the latest known state, and records deduplicated change events.

The repository contains deployment code only. It does **not** contain a live deployment URL, project reference, credentials, notification destination, device name, local path, account identifier, or any other operator-specific information.

## What it watches

The default configuration tracks:

- DesignCraft
- EffectCraft
- FilmCraft
- LightCraft
- PdfCraft
- PhotoCraft
- VectorCraft

All upstream repositories are configured from database rows and can be changed without modifying the Edge Function.

## Architecture

```text
GitHub upstream repositories
          |
          v
Supabase Cron
          |
          v
crawl-artcraft Edge Function
          |
          v
Postgres
  - craft_apps
  - crawl_runs
  - update_events
          |
          v
optional downstream notifier
```

The crawler is independent of any local workstation. A computer does not need to remain powered on for scheduled checks to run.

## Security model

The deployment is designed so the infrastructure stays under the operator's control even when this repository is public.

- Direct `anon` and `authenticated` access to watcher tables is revoked.
- Row Level Security is enabled on watcher tables.
- The Edge Function does not accept unauthenticated crawl requests.
- Supabase Cron authenticates with a randomly generated private secret.
- Only a SHA-256 hash of that secret is stored in the public schema.
- The original secret is stored in Supabase Vault.
- The live Edge Function URL is stored as private runtime configuration in the database, not in this repository.
- The optional GitHub token is read from an Edge Function secret and is never required in source control.
- `.env`, local Supabase state, and dependency folders are ignored by Git.

The function intentionally uses `verify_jwt = false` because it performs its own server-to-server secret verification. Requests without the private cron secret receive `401 Unauthorized`.

## Database model

### `craft_apps`

Stores watcher configuration and last-seen upstream state.

Important fields include:

- repository owner and name
- default branch
- optional installed version
- latest release tag
- latest commit SHA
- last checked timestamp
- enabled state

### `crawl_runs`

Stores one row per crawler execution, including:

- start and finish times
- run status
- apps checked
- changes found
- error count
- per-app result details

### `update_events`

Stores deduplicated release and commit changes.

A unique constraint on `(app_id, event_type, new_value)` prevents the same release or commit from being recorded more than once.

### `watcher_runtime_secrets`

Stores only the hash of the private cron secret.

### `watcher_settings`

Stores deployment-specific runtime configuration such as:

- Edge Function URL
- timezone
- local schedule hours
- enabled state

This table is intentionally not seeded with a live deployment URL.

## Deployment

### 1. Create a Supabase project

Create a Supabase project and install:

- Cron / `pg_cron`
- `pg_net`
- Vault

Vault is normally available by default on hosted Supabase projects.

### 2. Link the repository

Link the local Supabase CLI to your own project:

```bash
supabase link --project-ref YOUR_PROJECT_REF
```

Do not commit the generated project reference.

### 3. Apply migrations

```bash
supabase db push
```

The migrations create the tables, indexes, RLS policies, private cron authentication state, runtime settings, and scheduled dispatcher.

### 4. Deploy the Edge Function

```bash
supabase functions deploy crawl-artcraft --no-verify-jwt
```

### 5. Configure the private runtime URL and schedule

Run this in the Supabase SQL editor, replacing the example values with your own deployment details:

```sql
update public.watcher_settings
set
  edge_function_url = 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/crawl-artcraft',
  timezone = 'UTC',
  schedule_hours = array[8,20]::smallint[],
  enabled = true,
  updated_at = now()
where singleton = true;
```

The cron dispatcher wakes once per hour and only invokes the crawler when the current hour in the configured timezone matches one of `schedule_hours`. This avoids hard-coding UTC offsets and keeps local schedules stable across daylight-saving changes.

### 6. Optional GitHub token

The watcher can read public repositories without a GitHub token. For higher GitHub API rate limits, set an optional Edge Function secret:

```bash
supabase secrets set GITHUB_TOKEN=YOUR_TOKEN
```

Never commit the token.

## Installed-version tracking

Installed versions are intentionally not hard-coded into the public repository.

Set them privately in your deployment when useful:

```sql
update public.craft_apps
set installed_version = '0.0.0'
where slug = 'pdfcraft';
```

The watcher can still track upstream releases and commits when `installed_version` is null.

## Testing

### Trigger one crawl manually

From the Supabase SQL editor:

```sql
select public.invoke_artcraft_crawl();
```

Because `pg_net` is asynchronous, the call returns a request ID first. Then inspect:

```sql
select *
from public.crawl_runs
order by id desc
limit 1;
```

A healthy run should finish with:

- `status = 'success'`
- all enabled apps checked
- `error_count = 0`

### Verify deduplication

Run a second crawl without any upstream changes:

```sql
select public.invoke_artcraft_crawl();
```

The next completed run should report zero new changes, and the number of rows in `update_events` should remain unchanged.

### Inspect the production cron job

```sql
select jobid, jobname, schedule, active, command
from cron.job
where jobname = 'artcraft-watcher-hourly-dispatch';
```

## Notifications

Notifications are deliberately outside the crawler core. Any downstream service can read completed `crawl_runs` and new `update_events` and decide whether to notify.

This keeps the watcher deterministic and prevents notification-provider credentials from being coupled to the crawler.

## Privacy

This repository is deployment-neutral by design. Public source control should not contain:

- project references
- Supabase deployment URLs
- access tokens
- service-role keys
- cron secrets
- user names
- email addresses
- device names
- local filesystem paths
- private notification endpoints
- operator-specific installed-version state

Keep all deployment-specific values in Supabase runtime configuration, Vault, or Edge Function secrets.

## Project status

The current implementation:

- tracks releases and default-branch commits
- records crawl history
- deduplicates events
- supports private installed-version state
- runs independently through Supabase Cron
- supports operator-controlled schedules and timezones
- keeps runtime deployment details out of the public repository

A downstream notification layer may classify changes as **Update**, **Hold**, or **No Action**, but that policy is intentionally separate from the crawler.

## Disclaimer

ArtCraft Watcher is an independent utility and is not affiliated with or endorsed by the maintainers of the upstream ArtCraft projects.
