import type { DerivedStoreContext, DerivedStoreDefinition, ManifestDatabaseMutation } from "./manifestDatabase";
import type { RegisteredManifestRecord } from "./manifestRegistry";

// Persisted month-count aggregate row keyed by YYYY-MM so the timeline sidebar
// can render without scanning the full item list.
export interface MonthCountRow {
  monthKey: string;
  count: number;
  firstTakenAt: string;
}

const ORIGINAL_IDENTITY = { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" } as const;

// One geotagged original, small enough that the map can load every
// coordinate without reading full manifests across the worker boundary.
export interface MapPointRow {
  key: string;
  latitude: number;
  longitude: number;
  takenAt: string;
}

const monthKeyOf = (record: RegisteredManifestRecord): string | null => {
  if (record.kind !== "Original") return null;
  const takenAt = (record.manifest as { spec?: { takenAt?: string } })?.spec?.takenAt;
  return typeof takenAt === "string" ? takenAt.slice(0, 7) : null;
};

const takenAtOf = (record: RegisteredManifestRecord): string | null => {
  if (record.kind !== "Original") return null;
  const takenAt = (record.manifest as { spec?: { takenAt?: string } })?.spec?.takenAt;
  return typeof takenAt === "string" ? takenAt : null;
};

// Keeps a per-month { count, firstTakenAt } aggregate in sync with Original manifests
// so the timeline month sidebar reads a small precomputed table instead of scanning all items.
export const timelineMonthCountsStore: DerivedStoreDefinition = {
  name: "timeline_month_counts",
  keyPath: "monthKey",

  async rebuild({ manifests, derived }: DerivedStoreContext): Promise<void> {
    const buckets = new Map<string, { count: number; firstTakenAt: string }>();
    for await (const { key } of manifests.openKeyCursor(ORIGINAL_IDENTITY, { indexName: "byTakenAt" })) {
      const takenAt = String(key);
      const monthKey = takenAt.slice(0, 7);
      const existing = buckets.get(monthKey);
      if (existing) {
        existing.count += 1;
        if (takenAt < existing.firstTakenAt) existing.firstTakenAt = takenAt;
      } else {
        buckets.set(monthKey, { count: 1, firstTakenAt: takenAt });
      }
    }
    for (const [monthKey, { count, firstTakenAt }] of buckets) {
      await derived.put({ monthKey, count, firstTakenAt } satisfies MonthCountRow);
    }
  },

  async applyMutation({ manifests, derived }: DerivedStoreContext, mutation: ManifestDatabaseMutation): Promise<void> {
    const adjust = async (monthKey: string, delta: number, takenAt: string | null) => {
      const existing = (await derived.get(monthKey)) as MonthCountRow | undefined;
      const nextCount = (existing?.count ?? 0) + delta;
      if (nextCount <= 0) {
        await derived.delete(monthKey);
        return;
      }

      let firstTakenAt = existing?.firstTakenAt ?? takenAt ?? "";
      if (delta > 0 && takenAt && takenAt < firstTakenAt) {
        firstTakenAt = takenAt;
      }
      if (delta < 0 && existing && takenAt === existing.firstTakenAt) {
        // The removed item was the earliest in this month -- re-scan to find the new first.
        const monthStart = `${monthKey}-01T00:00:00`;
        const monthEnd = `${monthKey}-99`;
        let newFirst: string | null = null;
        for await (const { key } of manifests.openKeyCursor(ORIGINAL_IDENTITY, {
          indexName: "byTakenAt",
          range: { lower: monthStart, upper: monthEnd, lowerOpen: false, upperOpen: true },
        })) {
          newFirst = String(key);
          break;
        }
        firstTakenAt = newFirst ?? firstTakenAt;
      }
      await derived.put({ monthKey, count: nextCount, firstTakenAt } satisfies MonthCountRow);
    };

    for (const record of mutation.removed) {
      const mk = monthKeyOf(record);
      if (mk) await adjust(mk, -1, takenAtOf(record));
    }
    for (const record of mutation.added) {
      const mk = monthKeyOf(record);
      if (mk) await adjust(mk, 1, takenAtOf(record));
    }
    for (const update of mutation.updated) {
      const prevMk = monthKeyOf(update.previous);
      const currMk = monthKeyOf(update.current);
      if (prevMk === currMk) {
        // Same month -- firstTakenAt may have changed if takenAt was edited.
        const prevTakenAt = takenAtOf(update.previous);
        const currTakenAt = takenAtOf(update.current);
        if (prevTakenAt !== currTakenAt && currMk) {
          await adjust(currMk, -1, prevTakenAt);
          await adjust(currMk, 1, currTakenAt);
        }
        continue;
      }
      if (prevMk) await adjust(prevMk, -1, takenAtOf(update.previous));
      if (currMk) await adjust(currMk, 1, takenAtOf(update.current));
    }
  },
};

// Reads a coordinate only when the original can appear on both the map
// and the timeline. Photos without a capture time are absent from the
// timeline, so counting them on a tile would disagree with the place grid.
const mapPointFrom = (record: RegisteredManifestRecord): MapPointRow | null => {
  if (record.kind !== "Original") return null;
  const spec = (record.manifest as {
    spec?: { takenAt?: unknown; location?: { latitude?: unknown; longitude?: unknown } };
  })?.spec;
  if (!spec || typeof spec.takenAt !== "string" || spec.takenAt.length === 0) return null;
  const latitude = spec.location?.latitude;
  const longitude = spec.location?.longitude;
  if (typeof latitude !== "number" || typeof longitude !== "number") return null;
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  return { key: record.key, latitude, longitude, takenAt: spec.takenAt };
};

// Writes or deletes the coordinate row so a location edit, including
// losing or gaining one, leaves the map matching the manifest.
const writeMapPoint = async (
  derived: DerivedStoreContext["derived"],
  record: RegisteredManifestRecord,
): Promise<void> => {
  if (record.kind !== "Original") return;
  const row = mapPointFrom(record);
  if (row) {
    await derived.put(row);
    return;
  }
  await derived.delete(record.key);
};

// Projects geotagged originals into map_points so opening the map does
// not decode every manifest. Counts stay aligned with the timeline
// because a row exists only when the original has a capture time.
export const mapPointsStore: DerivedStoreDefinition = {
  name: "map_points",
  keyPath: "key",

  async rebuild({ manifests, derived }: DerivedStoreContext): Promise<void> {
    for await (const { value } of manifests.openCursor(ORIGINAL_IDENTITY)) {
      const row = mapPointFrom(value);
      if (row) await derived.put(row);
    }
  },

  async applyMutation({ derived }: DerivedStoreContext, mutation: ManifestDatabaseMutation): Promise<void> {
    for (const record of mutation.removed) {
      if (record.kind === "Original") await derived.delete(record.key);
    }
    for (const record of mutation.added) {
      await writeMapPoint(derived, record);
    }
    for (const update of mutation.updated) {
      if (update.previous.key !== update.current.key && update.previous.kind === "Original") {
        await derived.delete(update.previous.key);
      }
      await writeMapPoint(derived, update.current);
    }
  },
};
