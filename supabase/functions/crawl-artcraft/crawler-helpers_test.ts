import {
  classifyCrawlError,
  eventSummary,
  parseCommit,
  parseCrawlRequest,
  parseRelease,
} from "./crawler-helpers.ts";

function expect(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}
function rejects(f: () => unknown) {
  let threw = false;
  try { f(); } catch { threw = true; }
  expect(threw, "Expected invalid input rejection");
}
const sha = "a".repeat(40);

Deno.test("release parsing allows no releases but rejects malformed releases", () => {
  expect(parseRelease(null) === null, "No releases should be allowed");
  rejects(() => parseRelease({ tag_name: "" }));
  rejects(() => parseRelease({ tag_name: "v2", published_at: "bad-date" }));
  rejects(() => parseRelease({ tag_name: "v2", html_url: "http://invalid.test" }));
  const release = parseRelease({
    tag_name: "v2", html_url: "https://github.com/storytold/example/releases/tag/v2",
    prerelease: true,
  });
  expect(release?.tag_name === "v2" && release.prerelease, "Release fields lost");
});

Deno.test("commit parsing refuses missing, malformed, or unexpected responses", () => {
  rejects(() => parseCommit(null));
  rejects(() => parseCommit({ sha: "invalid" }));
  rejects(() => parseCommit({ sha, commit: null }));
  rejects(() => parseCommit({ sha, commit: { message: "hi", committer: { date: "wrong" } } }));
  const commit = parseCommit({
    sha, html_url: "https://github.com/storytold/example/commit/" + sha,
    commit: { message: "first line\nsecond line", committer: { date: "2026-10-10T00:00:00Z" } },
  });
  expect(commit.sha === sha && commit.message === "first line", "Commit parsing failed");
});

Deno.test("scheduled request requires a valid UTC tick and rejects app filters", () => {
  const scheduled = parseCrawlRequest({
    source: "supabase-cron", tick_utc: "2026-10-10T08:00:00+00:00",
  });
  expect(scheduled.tickUtc === "2026-10-10T08:00:00.000Z", "Tick normalization wrong");
  rejects(() => parseCrawlRequest({ source: "supabase-cron" }));
  rejects(() => parseCrawlRequest({ source: "supabase-cron", tick_utc: "bad" }));
  rejects(() => parseCrawlRequest({
    source: "supabase-cron", tick_utc: "2026-10-10T08:00:00Z", app_slug: "designcraft",
  }));
  rejects(() => parseCrawlRequest({ source: "manual", tick_utc: "2026-10-10T08:00:00Z" }));
  rejects(() => parseCrawlRequest({ source: "unknown" }));
  expect(parseCrawlRequest({ source: "manual", app_slug: "designcraft" }).appSlug === "designcraft",
    "Manual single-app filter lost");
});

Deno.test("safe failure classification and exact duplicate summaries", () => {
  expect(classifyCrawlError(new DOMException("deadline", "TimeoutError")) === "github_timeout",
    "Timeout classification incorrect");
  expect(classifyCrawlError(new Error("Invalid GitHub payload commit")) === "github_invalid_payload",
    "Payload classification incorrect");
  expect(classifyCrawlError(new Error("GitHub HTTP 404")) === "github_http_error",
    "HTTP classification incorrect");
  expect(eventSummary(1, ["release:v2", "commit:abc"])[0] === "1 new of 2 candidate events",
    "Partial deduplication should not claim which event was inserted");
  expect(eventSummary(2, ["release:v2", "commit:abc"]).length === 2,
    "Full insertion should preserve labels");
});
