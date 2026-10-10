import { insertedEventCount } from "./event-count.ts";

Deno.test("duplicate insert returns no rows and counts zero", () => {
  if (insertedEventCount([]) !== 0) throw new Error("Duplicate was counted");
});

Deno.test("successful insert counts one returned row", () => {
  if (insertedEventCount([{ id: 42 }]) !== 1) throw new Error("Insert was not counted");
});

Deno.test("missing returned rows never count as an insertion", () => {
  if (insertedEventCount(null) !== 0 || insertedEventCount(undefined) !== 0) {
    throw new Error("Missing data counted as insertion");
  }
});
