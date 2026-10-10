export type ReleaseInfo = {
  tag_name: string;
  html_url: string | null;
  name: string | null;
  published_at: string | null;
  prerelease: boolean;
  draft: boolean;
};

export type CommitInfo = {
  sha: string;
  html_url: string | null;
  message: string | null;
  committed_at: string | null;
};

function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function optionalText(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0
    ? value.slice(0, 1000)
    : null;
}

function optionalGithubUrl(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !/^https:\/\/github\.com\//.test(value)) {
    throw new Error("Invalid GitHub payload URL");
  }
  return value;
}

function optionalDate(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) {
    throw new Error("Invalid GitHub payload date");
  }
  return value;
}

export function parseRelease(value: unknown): ReleaseInfo | null {
  if (value === null) return null; // /releases/latest legitimately returns 404 without releases.
  const raw = object(value);
  if (!raw || typeof raw.tag_name !== "string" || !raw.tag_name.trim() ||
    raw.tag_name.length > 256) {
    throw new Error("Invalid GitHub payload release");
  }
  return {
    tag_name: raw.tag_name,
    html_url: optionalGithubUrl(raw.html_url),
    name: optionalText(raw.name),
    published_at: optionalDate(raw.published_at),
    prerelease: raw.prerelease === true,
    draft: raw.draft === true,
  };
}

export function parseCommit(value: unknown): CommitInfo {
  const raw = object(value);
  if (!raw || typeof raw.sha !== "string" || !/^[a-f\d]{40,64}$/i.test(raw.sha)) {
    throw new Error("Invalid GitHub payload commit");
  }
  const details = object(raw.commit);
  if (!details || typeof details.message !== "string") {
    throw new Error("Invalid GitHub payload commit message");
  }
  const committer = object(details.committer);
  const author = object(details.author);
  return {
    sha: raw.sha,
    html_url: optionalGithubUrl(raw.html_url),
    message: details.message.split("\n")[0]?.slice(0, 1000) ?? null,
    committed_at: optionalDate(committer?.date ?? author?.date ?? null),
  };
}

export function classifyCrawlError(error: unknown): string {
  if (!(error instanceof Error)) return "unexpected_error";
  if (error.name === "TimeoutError" || error.name === "AbortError") {
    return "github_timeout";
  }
  if (error.message.includes("Invalid GitHub payload")) {
    return "github_invalid_payload";
  }
  if (/^GitHub HTTP \d{3}/.test(error.message)) {
    return "github_http_error";
  }
  if ("code" in error || "details" in error) return "database_error";
  return "unexpected_error";
}

export function parseCrawlRequest(value: unknown): {
  source: "manual" | "supabase-cron";
  tickUtc: string | null;
  appSlug: string | null;
} {
  if (value !== undefined && value !== null && !object(value)) {
    throw new Error("Invalid crawl request");
  }
  const request = object(value) ?? {};
  const source = request.source === undefined ? "manual" : request.source;
  if (source !== "manual" && source !== "supabase-cron") {
    throw new Error("Invalid request source");
  }
  const appSlug = request.app_slug === undefined ? null : request.app_slug;
  if (appSlug !== null && (source !== "manual" ||
    typeof appSlug !== "string" || !/^[a-z0-9-]{1,80}$/.test(appSlug))) {
    throw new Error("Invalid manual app filter");
  }
  if (source === "manual") {
    if (request.tick_utc != null) throw new Error("Manual crawl cannot claim scheduled tick");
    return { source, tickUtc: null, appSlug };
  }
  const tick = request.tick_utc;
  if (typeof tick !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:00:00(?:\.\d+)?(?:\+00:00|Z)$/.test(tick) ||
    !Number.isFinite(Date.parse(tick))) {
    throw new Error("Invalid scheduled tick");
  }
  return { source, tickUtc: new Date(tick).toISOString(), appSlug: null };
}

export function eventSummary(inserted: number, candidateLabels: string[]): string[] {
  if (inserted === candidateLabels.length) return candidateLabels;
  return [`${inserted} new of ${candidateLabels.length} candidate events`];
}
