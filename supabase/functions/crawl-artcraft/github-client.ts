const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function retryDelayMs(res: Response, attempt: number) {
  const retryAfter = res.headers.get("retry-after");
  if (retryAfter) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds)) return Math.max(0, Math.min(seconds * 1000, 10_000));
  }

  const reset = Number(res.headers.get("x-ratelimit-reset"));
  if (Number.isFinite(reset) && reset > 0) {
    return Math.min(Math.max(reset * 1000 - Date.now(), 500), 10_000);
  }

  return Math.min(500 * 2 ** attempt, 4_000);
}

export async function githubJson(
  url: string,
  allowNotFound = false,
  options: {
    fetchImpl?: typeof fetch;
    sleepImpl?: (ms: number) => Promise<void>;
    token?: string;
  } = {},
) {
  const headers: Record<string, string> = {
    accept: "application/vnd.github+json",
    "user-agent": "ArtCraft-Watcher/1.0",
    "x-github-api-version": "2022-11-28",
  };

  const token = options.token ?? Deno.env.get("GITHUB_TOKEN");
  if (token) headers.authorization = `Bearer ${token}`;

  for (let attempt = 0; attempt < 4; attempt++) {
    let res: Response;
    try {
      res = await (options.fetchImpl ?? fetch)(url, { headers, signal: AbortSignal.timeout(10_000) });
    } catch (error) {
      if (attempt < 3 && (
        (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError")) ||
        error instanceof TypeError
      )) {
        await (options.sleepImpl ?? sleep)(Math.min(500 * 2 ** attempt, 4_000));
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

    if (retryable) {
      console.warn(JSON.stringify({
        event: "github_http_retry", http_status: res.status,
        retry_attempt: attempt + 1, retries_remaining: 3 - attempt,
      }));
    }
    if (retryable && attempt < 3) {
      await (options.sleepImpl ?? sleep)(retryDelayMs(res, attempt));
      continue;
    }

    throw new Error(`GitHub HTTP ${res.status}`);
  }

  throw new Error("GitHub request retry budget exhausted");
}