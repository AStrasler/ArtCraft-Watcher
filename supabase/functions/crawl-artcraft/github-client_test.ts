import { githubJson } from "./github-client.ts";

function expect(ok: boolean, reason: string) {
  if (!ok) throw new Error(reason);
}
function fakeFetch(handler: (n: number) => Response | Promise<Response>) {
  let attempts = 0;
  return {
    fetchImpl: (async (_input: Request | URL | string, _init?: RequestInit) =>
      await handler(++attempts)) as typeof fetch,
    attempts: () => attempts,
  };
}
const noDelay = async (_ms: number) => {};

Deno.test("200 returns response JSON without leaking credentials", async () => {
  const mock = fakeFetch(() => Response.json({ ok: true }));
  const result = await githubJson("https://api.github.com/repos/test/test", false,
    { fetchImpl: mock.fetchImpl, sleepImpl: noDelay, token: "" });
  expect(result.ok === true && mock.attempts() === 1, "200 fetch failed");
});

Deno.test("404 is optional for latest release but fatal for a commit", async () => {
  const mock = fakeFetch(() => new Response(null, { status: 404 }));
  const release = await githubJson("test", true,
    { fetchImpl: mock.fetchImpl, sleepImpl: noDelay, token: "" });
  expect(release === null, "No release should be accepted");
  let failed = false;
  try {
    await githubJson("test", false, {
      fetchImpl: mock.fetchImpl, sleepImpl: noDelay, token: "",
    });
  } catch (error) {
    failed = error instanceof Error && error.message === "GitHub HTTP 404";
  }
  expect(failed && mock.attempts() === 2, "Missing commits must not count as a successful check");
});

Deno.test("rate limit 429 and 5xx retry with bounded attempts", async () => {
  const mock = fakeFetch((n) =>
    n < 4 ? new Response(null, { status: n === 1 ? 429 : 503 }) :
      Response.json({ ok: true }));
  const result = await githubJson("test", false,
    { fetchImpl: mock.fetchImpl, sleepImpl: noDelay, token: "" });
  expect(result.ok === true && mock.attempts() === 4, "Bounded retry did not recover");
});

Deno.test("403 retries only on exhausted rate-limit headroom", async () => {
  const mock = fakeFetch((n) => n === 1
    ? new Response(null, { status: 403, headers: { "x-ratelimit-remaining": "0" } })
    : Response.json({ ok: true }));
  const result = await githubJson("test", false,
    { fetchImpl: mock.fetchImpl, sleepImpl: noDelay, token: "" });
  expect(result.ok === true && mock.attempts() === 2, "403 rate-limit retry failed");
});

Deno.test("401 refuses retry, repeated timeouts stop after four attempts", async () => {
  const unauthorized = fakeFetch(() => new Response(null, { status: 401 }));
  let failed = false;
  try {
    await githubJson("test", false, {
      fetchImpl: unauthorized.fetchImpl, sleepImpl: noDelay, token: "",
    });
  } catch { failed = true; }
  expect(failed && unauthorized.attempts() === 1, "401 was retried");

  const timedOut = fakeFetch(() => {
    throw new DOMException("deadline", "TimeoutError");
  });
  failed = false;
  try {
    await githubJson("test", false, {
      fetchImpl: timedOut.fetchImpl, sleepImpl: noDelay, token: "",
    });
  } catch (error) {
    failed = error instanceof DOMException && error.name === "TimeoutError";
  }
  expect(failed && timedOut.attempts() === 4, "Timeout retries were not bounded");
});
