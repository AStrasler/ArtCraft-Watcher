-- Guardrails for watcher configuration and nonnegative crawl counters.
-- Validated against current production data before authoring; deploy only after CI and migration tests.
alter table public.craft_apps
  add constraint craft_apps_nonblank_fields check (
    length(btrim(slug)) between 1 and 100
    and length(btrim(display_name)) between 1 and 200
    and length(btrim(repo_owner)) between 1 and 39
    and length(btrim(repo_name)) between 1 and 100
    and length(btrim(default_branch)) between 1 and 255
  ) not valid;

alter table public.craft_apps
  add constraint craft_apps_repository_format check (
    repo_owner ~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'
    and repo_name ~ '^[A-Za-z0-9_.-]+$'
    and default_branch !~ '[[:cntrl:]]'
  ) not valid;

alter table public.crawl_runs
  add constraint crawl_runs_nonnegative_counts check (
    apps_checked >= 0 and changes_found >= 0 and error_count >= 0
  ) not valid;

alter table public.craft_apps validate constraint craft_apps_nonblank_fields;
alter table public.craft_apps validate constraint craft_apps_repository_format;
alter table public.crawl_runs validate constraint crawl_runs_nonnegative_counts;