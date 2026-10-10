// deno-lint-ignore no-unversioned-import -- Supabase runtime-provided type declaration.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  classifyCrawlError,
  eventSummary,
  parseCommit,
  parseCrawlRequest,
  parseRelease,
} from "./crawler-helpers.ts";

type AppRow = {
  id: number;
  slug: string;
  display_name: string;
  repo_owner: string;
  repo_name: string;
  default_branch: string;
  installed_version: string | null;
  latest_release_tag: string | null;
  latest_commit_sha: string | null;
};

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function sha256Hex(value: string) {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function retryDelayMs(res: Response, attempt: number) {
  const retryAfter = res.headers.get("retry-after");
  if (retryAfter) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds)) return Math.min(seconds * 1000, 10_000);
  }

  const reset = Number(res.headers.get("x-ratelimit-reset"));
  if (Number.isFinite(reset) && reset > 0) {
    return Math.min(Math.max(reset * 1000 - Date.now(), 500), 10_000);
  }

  return Math.min(500 * 2 ** attempt, 4_000);
}

async function githubJson(url: string, allowNotFound = false) {
  const headers: Record<string, string> = {
    accept: "application/vnd.github+json",
    "user-agent": "ArtCraft-Watcher/1.0",
    "x-github-api-version": "2022-11-28",
  };

  const token = Deno.env.get("GITHUB_TOKEN");
  if (token) headers.authorization = `Bearer ${token}`;

  for (let attempt = 0; attempt < 4; attempt++) {
    let res: Response;
    try {
      res = await fetch(url, { headers, signal: AbortSignal.timeout(10_000) });
    } catch (error) {
      if (attempt < 3 && (
        (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError")) ||
        error instanceof TypeError
      )) {
        await sleep(Math.min(500 * 2 ** attempt, 4_000));
        continue;
      }
      throw error;
    }

    if (res.status === 404 && allowNotFound) return null;
    if (res.ok) return await res.json();

    const remaining = res.headers.get("x-ratelimit-remaining");
    const retryable =
      res.status === 429 ||
      res.status >= 500 ||
      (res.status === 403 && remaining === "0");

    if (retryable && attempt < 3) {
      await sleep(retryDelayMs(res, attempt));
      continue;
    }

    throw new Error(`GitHub HTTP ${res.status}`);
  }

  throw new Error("GitHub request retry budget exhausted");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !serviceKey) {
    return new Response(
      JSON.stringify({ error: "Supabase environment is incomplete" }),
      { status: 500, headers: jsonHeaders },
    );
  }

  const db = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const presentedSecret = req.headers.get("x-artcraft-cron");
  if (!presentedSecret) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: jsonHeaders,
    });
  }

  const { data: storedSecret, error: secretError } = await db
    .from("watcher_runtime_secrets")
    .select("secret_hash")
    .eq("name", "cron")
    .single();

  if (secretError || !storedSecret?.secret_hash) {
    console.error("Cron secret lookup failed", secretError);
    return new Response(
      JSON.stringify({ error: "Authentication unavailable" }),
      { status: 500, headers: jsonHeaders },
    );
  }

  const presentedHash = await sha256Hex(presentedSecret);
  if (!constantTimeEqual(presentedHash, storedSecret.secret_hash)) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: jsonHeaders,
    });
  }

  let crawlRequest: ReturnType<typeof parseCrawlRequest>;
  try {
    const body = await req.text();
    crawlRequest = parseCrawlRequest(body.trim() ? JSON.parse(body) : {});
  } catch {
    return new Response(JSON.stringify({ error: "Invalid crawl request" }), {
      status: 400, headers: jsonHeaders,
    });
  }

  const lockOwner = crypto.randomUUID();
  const { data: lockAcquired, error: lockError } = await db.rpc(
    "try_acquire_watcher_lock",
    { p_owner: lockOwner, p_ttl_seconds: 300 },
  );

  if (lockError) {
    console.error("Could not acquire watcher lock", lockError);
    return new Response(
      JSON.stringify({ error: "Crawler lock unavailable" }),
      { status: 500, headers: jsonHeaders },
    );
  }

  if (!lockAcquired) {
    return new Response(
      JSON.stringify({
        status: "skipped",
        reason: "another crawl is already running",
      }),
      { status: 200, headers: jsonHeaders },
    );
  }

  let activeRunId: number | null = null;
  try {
    if (crawlRequest.tickUtc !== null) {
      const { data: claimed, error: claimError } = await db.rpc(
        "claim_artcraft_tick",
        { p_tick: crawlRequest.tickUtc, p_lock_owner: lockOwner },
      );
      if (claimError) throw claimError;
      if (!claimed) {
        return new Response(JSON.stringify({
          status: "skipped", reason: "scheduled tick already claimed",
        }), { status: 200, headers: jsonHeaders });
      }
    }
    const { data: recovered, error: recoveryError } = await db.rpc(
      "recover_stale_artcraft_runs",
      { p_lock_owner: lockOwner, p_min_age_seconds: 600 },
    );
    if (recoveryError) throw recoveryError;
    if (recovered > 0) console.warn("Recovered stale crawler runs", recovered);
    const { data: run, error: runError } = await db
      .from("crawl_runs")
      .insert({ status: "running" })
      .select("id")
      .single();

    if (runError || !run) {
      return new Response(
        JSON.stringify({ error: "Could not create crawl run" }),
        { status: 500, headers: jsonHeaders },
      );
    }

    activeRunId = run.id;
    if (crawlRequest.tickUtc !== null) {
      const { error: linkError } = await db.rpc("link_artcraft_tick_run", {
        p_tick: crawlRequest.tickUtc,
        p_lock_owner: lockOwner,
        p_run_id: run.id,
      });
      if (linkError) throw linkError;
    }

    let appQuery = db.from("craft_apps")
      .select(
        "id,slug,display_name,repo_owner,repo_name,default_branch,installed_version,latest_release_tag,latest_commit_sha",
      ).eq("enabled", true);
    if (crawlRequest.appSlug !== null) {
      appQuery = appQuery.eq("slug", crawlRequest.appSlug);
    }
    const { data: apps, error: appsError } = await appQuery
      .order("display_name");

    if (appsError) throw new Error("Could not load app configuration");

    let changes = 0;
    let errors = 0;
    const results: unknown[] = [];

    for (const app of (apps ?? []) as AppRow[]) {
      const appStarted = Date.now();
      try {
        const base =
          `https://api.github.com/repos/${app.repo_owner}/${app.repo_name}`;

        const [releaseRaw, commitRaw] = await Promise.all([
          githubJson(`${base}/releases/latest`, true),
          githubJson(
            `${base}/commits/${encodeURIComponent(app.default_branch)}`,
          ),
        ]);
        const release = parseRelease(releaseRaw);
        const commit = parseCommit(commitRaw);

        const patch: Record<string, unknown> = {
          last_checked_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        };

        const candidateEvents: Record<string, unknown>[] = [];
        const candidateLabels: string[] = [];

        if (release) {
          const newTag = release.tag_name ?? null;
          patch.latest_release_tag = newTag;
          patch.latest_release_url = release.html_url ?? null;
          patch.latest_release_published_at = release.published_at ?? null;

          const isBaseline = app.latest_release_tag === null;

          if (
            !isBaseline &&
            newTag &&
            newTag !== app.latest_release_tag
          ) {
            candidateEvents.push({
                app_id: app.id,
                crawl_run_id: run.id,
                event_type: "release",
                old_value: app.latest_release_tag,
                new_value: newTag,
                title: release.name ?? newTag,
                url: release.html_url ?? null,
                metadata: {
                  prerelease: Boolean(release.prerelease),
                  draft: Boolean(release.draft),
                  installed_version: app.installed_version,
                  published_at: release.published_at ?? null,
                },
              });
            candidateLabels.push(`release:${newTag}`);
          }
        }

        if (commit.sha) {
          const commitSha = commit.sha;
          const message = commit.message;
          const commitAt = commit.committed_at;

          patch.latest_commit_sha = commitSha;
          patch.latest_commit_url = commit.html_url ?? null;
          patch.latest_commit_message = message;
          patch.latest_commit_at = commitAt;

          const isBaseline = app.latest_commit_sha === null;

          if (!isBaseline && commitSha !== app.latest_commit_sha) {
            candidateEvents.push({
                app_id: app.id,
                crawl_run_id: run.id,
                event_type: "commit",
                old_value: app.latest_commit_sha,
                new_value: commitSha,
                title: message,
                url: commit.html_url ?? null,
                metadata: { committed_at: commitAt },
              });
            candidateLabels.push(`commit:${commitSha.slice(0, 7)}`);
          }
        }

        const { data: insertedCount, error: persistError } = await db.rpc(
          "record_artcraft_app_result",
          {
            p_app_id: app.id,
            p_run_id: run.id,
            p_patch: patch,
            p_events: candidateEvents,
          },
        );
        if (persistError) throw persistError;
        if (typeof insertedCount !== "number" || insertedCount < 0 ||
          insertedCount > candidateEvents.length) {
          throw new Error("Unexpected atomic persistence result");
        }
        changes += insertedCount;
        const appChanges = eventSummary(insertedCount, candidateLabels);
        console.info(JSON.stringify({
          event: "app_checked", run_id: run.id, app_slug: app.slug,
          duration_ms: Date.now() - appStarted, changes: insertedCount,
        }));

        results.push({
          app: app.display_name,
          ok: true,
          changes: appChanges,
        });
      } catch (error) {
        errors++;
        const code = classifyCrawlError(error);
        const { data: failures, error: trackingError } = await db.rpc(
          "record_artcraft_app_failure",
          { p_app_id: app.id, p_run_id: run.id, p_error_code: code },
        );
        if (trackingError) console.error("Failure tracking unavailable", app.slug);
        console.warn(JSON.stringify({
          event: "app_failed", run_id: run.id, app_slug: app.slug,
          error_code: code, duration_ms: Date.now() - appStarted,
          consecutive_failures: failures ?? null,
          repeated_failure: typeof failures === "number" && failures >= 3,
        }));
        results.push({
          app: app.display_name, ok: false, error_code: code,
          consecutive_failures: failures ?? null,
        });
      }
    }

    const status =
      errors === 0
        ? "success"
        : errors < (apps?.length ?? 0)
          ? "partial"
          : "failed";

    const { error: finishError } = await db
      .from("crawl_runs")
      .update({
        status,
        finished_at: new Date().toISOString(),
        apps_checked: apps?.length ?? 0,
        changes_found: changes,
        error_count: errors,
        details: { results },
      })
      .eq("id", run.id);
    if (finishError) throw finishError;
    activeRunId = null;

    return new Response(
      JSON.stringify(
        {
          run_id: run.id,
          status,
          apps_checked: apps?.length ?? 0,
          changes_found: changes,
          error_count: errors,
          results,
        },
        null,
        2,
      ),
      { headers: jsonHeaders },
    );
  } catch (error) {
    console.error("Crawler failed unexpectedly", classifyCrawlError(error));
    if (activeRunId !== null) {
      const { error: finalizationError } = await db.from("crawl_runs")
        .update({
          status: "failed",
          finished_at: new Date().toISOString(),
          error_count: 1,
          details: { error: "Unexpected crawler failure" },
        }).eq("id", activeRunId);
      if (finalizationError) console.error("Could not finalize failed crawl", finalizationError);
    }
    return new Response(JSON.stringify({ error: "Crawler execution failed" }), {
      status: 500,
      headers: jsonHeaders,
    });
  } finally {
    const { error } = await db.rpc("release_watcher_lock", {
      p_owner: lockOwner,
    });

    if (error) console.error("Could not release watcher lock", error);
  }
});
