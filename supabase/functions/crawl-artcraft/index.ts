import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

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

async function sha256Hex(value: string) {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function githubJson(url: string) {
  const headers: Record<string, string> = {
    accept: "application/vnd.github+json",
    "user-agent": "ArtCraft-Watcher/1.0",
    "x-github-api-version": "2022-11-28",
  };
  const token = Deno.env.get("GITHUB_TOKEN");
  if (token) headers.authorization = `Bearer ${token}`;

  const res = await fetch(url, { headers });
  if (res.status === 404) return null;
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`GitHub ${res.status}: ${body.slice(0, 300)}`);
  }
  return await res.json();
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: jsonHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return new Response(JSON.stringify({ error: "Supabase environment is incomplete" }), { status: 500, headers: jsonHeaders });
  }

  const db = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const presentedSecret = req.headers.get("x-artcraft-cron");
  if (!presentedSecret) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: jsonHeaders });
  }

  const { data: storedSecret, error: secretError } = await db
    .from("watcher_runtime_secrets")
    .select("secret_hash")
    .eq("name", "cron")
    .single();

  if (secretError || !storedSecret?.secret_hash) {
    console.error("Cron secret lookup failed", secretError);
    return new Response(JSON.stringify({ error: "Authentication unavailable" }), { status: 500, headers: jsonHeaders });
  }

  const presentedHash = await sha256Hex(presentedSecret);
  if (!constantTimeEqual(presentedHash, storedSecret.secret_hash)) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: jsonHeaders });
  }

  const { data: run, error: runError } = await db
    .from("crawl_runs")
    .insert({ status: "running" })
    .select("id")
    .single();

  if (runError || !run) {
    return new Response(JSON.stringify({ error: "Could not create crawl run" }), { status: 500, headers: jsonHeaders });
  }

  const { data: apps, error: appsError } = await db
    .from("craft_apps")
    .select("id,slug,display_name,repo_owner,repo_name,default_branch,installed_version,latest_release_tag,latest_commit_sha")
    .eq("enabled", true)
    .order("display_name");

  if (appsError) {
    await db.from("crawl_runs").update({
      status: "failed",
      finished_at: new Date().toISOString(),
      error_count: 1,
      details: { error: "Could not load app configuration" },
    }).eq("id", run.id);
    return new Response(JSON.stringify({ error: "Could not load app configuration" }), { status: 500, headers: jsonHeaders });
  }

  let changes = 0;
  let errors = 0;
  const results: unknown[] = [];

  for (const app of (apps ?? []) as AppRow[]) {
    try {
      const base = `https://api.github.com/repos/${app.repo_owner}/${app.repo_name}`;
      const [release, commit] = await Promise.all([
        githubJson(`${base}/releases/latest`),
        githubJson(`${base}/commits/${encodeURIComponent(app.default_branch)}`),
      ]);

      const patch: Record<string, unknown> = {
        last_checked_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      const appChanges: string[] = [];

      if (release) {
        const newTag = release.tag_name ?? null;
        patch.latest_release_tag = newTag;
        patch.latest_release_url = release.html_url ?? null;
        patch.latest_release_published_at = release.published_at ?? null;

        if (newTag && newTag !== app.latest_release_tag) {
          const { error } = await db.from("update_events").upsert({
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
          }, { onConflict: "app_id,event_type,new_value", ignoreDuplicates: true });
          if (!error) {
            changes++;
            appChanges.push(`release:${newTag}`);
          }
        }
      }

      if (commit?.sha) {
        const commitSha = String(commit.sha);
        const message = commit.commit?.message?.split("\n")[0] ?? null;
        const commitAt = commit.commit?.committer?.date ?? commit.commit?.author?.date ?? null;
        patch.latest_commit_sha = commitSha;
        patch.latest_commit_url = commit.html_url ?? null;
        patch.latest_commit_message = message;
        patch.latest_commit_at = commitAt;

        if (commitSha !== app.latest_commit_sha) {
          const { error } = await db.from("update_events").upsert({
            app_id: app.id,
            crawl_run_id: run.id,
            event_type: "commit",
            old_value: app.latest_commit_sha,
            new_value: commitSha,
            title: message,
            url: commit.html_url ?? null,
            metadata: { committed_at: commitAt },
          }, { onConflict: "app_id,event_type,new_value", ignoreDuplicates: true });
          if (!error) {
            changes++;
            appChanges.push(`commit:${commitSha.slice(0, 7)}`);
          }
        }
      }

      const { error: updateError } = await db.from("craft_apps").update(patch).eq("id", app.id);
      if (updateError) throw updateError;

      results.push({ app: app.display_name, ok: true, changes: appChanges });
    } catch (error) {
      errors++;
      results.push({
        app: app.display_name,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const status = errors === 0 ? "success" : errors < (apps?.length ?? 0) ? "partial" : "failed";

  await db.from("crawl_runs").update({
    status,
    finished_at: new Date().toISOString(),
    apps_checked: apps?.length ?? 0,
    changes_found: changes,
    error_count: errors,
    details: { results },
  }).eq("id", run.id);

  return new Response(JSON.stringify({
    run_id: run.id,
    status,
    apps_checked: apps?.length ?? 0,
    changes_found: changes,
    error_count: errors,
    results,
  }, null, 2), { headers: jsonHeaders });
});
