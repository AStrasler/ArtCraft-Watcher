// Static regression guards. Integration tests will exercise the HTTP handler separately.
const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));

Deno.test("crawler accepts POST only", () => {
  if (!source.includes('req.method !== "POST"')) {
    throw new Error("POST-only execution guard missing");
  }
  if (source.includes('req.method !== "POST" && req.method !== "GET"')) {
    throw new Error("GET execution remains enabled");
  }
});

Deno.test("GitHub fetches have bounded timeouts", () => {
  if (!source.includes("AbortSignal.timeout(10_000)")) {
    throw new Error("GitHub request timeout missing");
  }
  if (!source.includes("attempt < 3")) {
    throw new Error("Bounded retry condition missing");
  }
});