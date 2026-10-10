# ArtCraft Watcher operations and recovery

This document is intentionally free of deployment identifiers, secrets, personal data,
account email addresses, and local-machine paths.

## Release gate

Do **not** merge, deploy, change production cron, or apply database migrations solely
because the PR checks pass. The operator must explicitly approve the release.
Everything below is a procedure, not authorization to execute it.

Before approval:
1. Review the PR diff and its passing Deno and disposable-Postgres CI jobs.
2. Review the live Supabase migration history against the repository. The hardening
   migrations must not already have been applied manually or out of order.
3. Confirm live configuration and version-state data will not be overwritten.
4. Arrange a free/manual export of essential non-secret table rows as a recovery
   reference where permitted. Supabase Free must not be assumed to provide point-in-time
   recovery or automated backups.
5. Record the current deployed Edge Function version so it can be restored.

## Deployment order (after explicit approval only)

Apply migrations strictly in filename order:

1. `20261010084500_validate_watcher_data.sql` (validate existing rows first).
2. `20261010085000_app_failure_tracking.sql`.
3. `20261010090000_atomic_crawl_app_update.sql`.
4. `20261010091500_recover_stale_crawl_runs.sql`.
5. `20261010093000_dispatch_idempotency.sql`.
6. `20261010093500_claim_scheduled_ticks.sql`.
7. `20261010094000_health_and_recovery.sql`.
8. `20261010094500_health_alert_events.sql`.
9. `20261010095000_schedule_health_cron.sql`.

Deploy the matching `crawl-artcraft` Edge Function only after the database changes
succeed. **Do not** deploy the new function against the old schema: its new RPC calls
will fail. Existing deployed crawlers should continue to run during additive migrations.

Run `scripts/post_deploy_smoke.sql` with the appropriate privileged SQL access.
It checks extensions, function placement, cron jobs, migration versions, function
permissions, run freshness, and a secret-free health summary. The script is read-only.

Run one supervised manual crawl, inspect the resulting `crawl_runs` status and
`update_events` count, then verify a scheduled dispatch was claimed once.
Do not artificially invent release/commit events in production.

## Scheduled-run correctness

- Cron dispatch uses `watcher_dispatches` and a unique local schedule-hour slot.
  Retries of the same dispatch, including a fall DST repeat, do not queue a second request.
- Every scheduled HTTP body contains its source and stable UTC tick.
- A scheduled request must claim its tick under the watcher lock before creating a run.
  Already claimed ticks are skipped, including replays after an unknown HTTP outcome.
- A terminated request with a claimed-but-unlinked tick will appear in the health summary.
  **Do not automatically requeue it**, because its prior outcome may be unknown.
  Inspect the run/event history, then use a supervised manual crawl for safe recovery.
- Manual runs are intentionally distinguishable and are not deduplicated against
  scheduled ticks. A missing spring-forward local hour does not occur that day.

## Failure and data recovery

- Each app is independent. A bad upstream response marks that app failed, increments
  its `consecutive_failures`, and leaves its last successfully observed state intact.
- Successful observations reset the app failure streak.
- No app is automatically disabled. Repeated failures remain visible and are
  retried on later scheduled crawls. A maintainer can temporarily set `enabled=false`
  and explicitly re-enable it after correcting the cause.
- Malformed GitHub JSON, missing commits, and unexpected HTTP failures are not
  treated as successful updates.
- A failed event write cannot advance observed app state; both operations are in
  the same PostgreSQL transaction.
- A terminated crawl older than ten minutes is marked failed by the next authorized
  lock holder. The existing five-minute lock TTL permits eventual recovery.
- A transient database outage can prevent immediate failure finalization. The next
  healthy crawler invocation attempts stale-run recovery; the health summary reports
  remaining stale runs.

### Manual recovery

Use `select public.invoke_artcraft_crawl();` through an approved privileged SQL
session to queue a full manual run. For a *single* app, use an authenticated POST
to the Edge Function with `{"source":"manual","app_slug":"designcraft"}`,
substituting an existing configured slug. The POST must have the private
`x-artcraft-cron` header. Never write the secret in logs, Git, tickets, or commands
that may be retained in shell history.

Do not clear `latest_release_tag` or `latest_commit_sha` just to force a recheck:
the crawler checks enabled apps on every execution. Clearing those values would
change baseline semantics and could hide real changes.

## Observability and alerts

- `select public.artcraft_watcher_health();` returns a read-only JSON summary:
  last success/failure, run failure counts, stale apps, repeated app errors,
  abandoned runs, unclaimed dispatches, unlinked claims, and lock status.
- `select public.evaluate_artcraft_health();` evaluates current alert conditions
  and stores deduplicated active/resolved states in `watcher_health_alerts`.
- The lightweight `artcraft-watcher-health-hourly` Cron job evaluates alert
  conditions hourly, independent of the normal twice-daily crawl schedule.
- New/repeated alerts contain only safe codes, counts, and slugs. The alert table
  stores **no** credentials, external endpoints, or raw upstream response bodies.
- This repository does **not** deliver SMS, email, or other push messages: an
  external downstream notifier must deliberately subscribe to these states.
  Do not claim delivery or a configured recipient before that integration exists.

Useful queries:

```sql
select public.artcraft_watcher_health();
select alert_key,active,last_seen_at,occurrences,last_count
from public.watcher_health_alerts order by alert_key;
select id,status,started_at,finished_at,changes_found,error_count
from public.crawl_runs order by id desc limit 10;
select slug,consecutive_failures,last_error,last_checked_at
from public.craft_apps where enabled=true order by slug;
select tick_utc,local_slot,queued_at,claimed_at,claimed_run_id
from public.watcher_dispatches order by tick_utc desc limit 10;
```

## Rollback and recovery

The schema changes add columns, tables and RPCs. **There is no safe automatic schema
downgrade** while new event rows, dispatch tickets or alert states may exist.

If the new crawler fails:
1. Disable scheduled dispatch temporarily through the existing validated watcher
   settings, retaining a record of its previous value.
2. Record the failing run IDs and diagnostics without recording secrets.
3. Restore the previously deployed Edge Function version.
4. Review differences in the SQL dispatch wrappers. Older functions may not
   recognize the new tick contract, causing missed-dispatch alerts.
5. Prefer a forward-fix over dropping tables/functions. Only remove schema changes
   after an explicit, separately reviewed data-preserving rollback plan.
6. Re-enable scheduling and repeat the smoke check once the compatible crawler is
   deployed and operating normally.

## Test coverage and remaining limits

CI uses Deno lint/type-check, pure helper and mocked GitHub HTTP tests, and a
**disposable PostgreSQL 17 service** for core RPC transaction, duplicate, rollback,
permission, stale-run, scheduled claim, and alert-state checks. It does not use
production secrets or incur additional cloud infrastructure charges.

The fake `net.http_post` and Vault fixtures in tests do not replace a full
production integration test of pg_net, pg_cron, Supabase Vault, or downstream
notification delivery. The post-deploy smoke and supervised crawl remain required.
