/** Count only rows actually returned by INSERT ... ON CONFLICT DO NOTHING. */
export function insertedEventCount(rows: readonly { id: number }[] | null | undefined): number {
  return rows?.length ?? 0;
}
