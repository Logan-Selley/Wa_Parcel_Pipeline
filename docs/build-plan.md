# Build Plan — Silver Completion + Gold Layer

*Consolidated working reference, 2026-08-31. Supersedes the scattered specs from
the duplicate-handling, overlap-verification, and gold-scope discussions. Every
expected number below is a measured prediction, not a hope — verify against the
checklists as each piece lands.*

---

## Part A — Silver fixes (in build order)

### A1. Normalization fix: remove `upper()` from parcel_id

**Where**: `macros/conform_parcels.sql` (the `parcel_id_norm` expression).

**Change**:

```sql
-- before
nullif(upper(trim({{ map['parcel_id'] }}::text)), '') as parcel_id_norm
-- after
nullif(trim({{ map['parcel_id'] }}::text), '') as parcel_id_norm
```

**Why**: `upper()` collapsed 6 pairs of case-distinct King tracts (`Tr-A` vs
`TR-A` — distinct MINOR values in King's own MAJOR/MINOR identifier structure,
verified against the PARCEL_AREA_439 layer via REST), and would break up to 3
Spokane reconciliation joins. The state's casing mirrors each county's source
casing: King upper, Spokane lower, Pierce/Snohomish numeric — so
source-case-preserving uids join correctly everywhere. `upper()` is a provable
no-op for Pierce/Snohomish (zero lettered IDs — measured).

**Verify after rebuild**: King duplicates gone; uniqueness failures confined
to Pierce.

### A2. Spokane `UNKNOWN` sentinel → quarantine

**Where**: `dbt_project.yml` `"063"` map, `parcel_id` expression.

**Change**:

```yaml
parcel_id: "nullif(trim(PID_NUM), 'UNKNOWN')"
```

**Critical companion fix**: `parcel_id_raw` is emitted from the *same*
manifest expression — applying the sentinel there too would erase the raw
value for exactly the rows where preserving it matters. The raw column must
map the un-sentineled expression:

```yaml
parcel_id_raw: "trim(PID_NUM)::text"   # raw value preserved, 'UNKNOWN' included
```

(If the macro derives `parcel_id_raw` from the `parcel_id` map entry, split
the two: add a `parcel_id_raw` key or emit raw before the sentinel.) Add a
manifest note documenting the sentinel.

**Why**: the 3 UNKNOWN rows have no address, no use code, and geometries that
partially overlap 3–6 real parcels — unidentified fragments, not parcels.
Sentinel→null routes them into `missing_parcel_uid` quarantine with zero new
machinery; the vocabulary test and scorecard cover them automatically.

**Verify**: rejected count 4,595 → 4,598.

### A3. Record-integration step — declared record keys, not row hashes

**New model**: `models/intermediate/int_parcels_records.sql`, materialized
table. Pipeline becomes:

```
stg_parcels → repaired → records → validated → split
```

**Identity design — two ids, each with one job:**

1. **`record_key_uid`** — the county-schema record identity, constructed per
   the source's own structure: `parcel_uid` + the source's distinguishing
   fields, legibly encoded (e.g. Pierce `053-123456|A|2` = parcel + unit +
   level). Declared per county in the manifest:

   ```yaml
   record_key:
     fields: [taxparcelunit, taxparcelunittype, taxparcellevel]   # Pierce
   ```

   (Spokane: `[site_apartment]`; King: none — `pin` alone is unique after A1.)
   Legible, stable under unrelated attribute edits, faithful to the source's
   schema. This is the dim grain's primary identity. Pierce's record hierarchy
   is parcel → unit → unit_type → level — components like a Residence plus its
   Parking Space and Storage (each with own geometry; values live on the
   Residence, components carry zeros so nothing double-counts).

2. **`parcel_uid`** — unchanged, the state-format join key to the answer key.
   A secondary id by this design: the state has no unit/level fields, so
   record-level joins to the state are impossible anyway; the fact joins at
   `parcel_uid` and the fan-out is part of the finding.

3. **`record_signature`** (md5 over all raw columns minus
   `identity_exclude`: system/volatile `objectid`/`globalid`/`editdate`;
   geometry-derived `shape__area`/`shape__length`/x/y/long/lat/`maplegend`) —
   **demoted to variant discriminator**, not identity. It separates records
   the declared key doesn't, without polluting the key with volatile data
   (values in a key would churn identity on every assessment update).

   **Carry-forward requirement**: the signature must be computed **in
   staging** (`conform_parcels` is the only model with raw columns in scope)
   and then **explicitly listed in every downstream fixed column list** —
   `int_parcels_repaired` enumerates its SELECT, so an omitted
   `record_signature` silently drops out of the grain. (The alternative —
   joining `records` back to `raw.parcels_*` — reintroduces a raw dependency
   below staging; don't.)

**Integration logic**: `group by record_key_uid, record_signature` — union
geometry within (`st_multi(st_union(geom))`), recompute validity post-union,
`bool_or(geometry_repaired)`, `source_record_count`. This merges exactly one
thing: the same published record appearing as multiple geometry pieces
(King's 439 layer proves counties do this — `012605TR-A` ships as 3 features).
`dim` grain = `(record_key_uid, record_signature)`: one row per published
record variant.

**Measured classification under this design:**

| County | Record key | Key collisions in conformed | Unions |
|---|---|---|---|
| Spokane | `pid_num` (+ apartment) | **0** after A2 — the attr-differing trio *is* the UNKNOWN group and quarantines out | 2 groups (sig-identical pairs) |
| King | `pin` | **0** after A1 (case fix) | 0 |
| Pierce | `unit` + `unit_type` + `level` | **460 groups / 1,073 rows** — 227 sig-identical (562 rows collapse, 193 as unions), 233 attr-differing variants kept distinct by the signature | 193 unions + 34 identical-geometry collapses |

**Measured build results (2026-08-31, post-A3):** staged 1,509,907; rejected
4,597 rows expanding to 4,598 (the UNKNOWN trio contained **two
signature-identical rows that merged** — its third row stands alone);
conformed 1,504,927 rows expanding to 1,505,309; canary
1,505,309 + 4,598 = 1,509,907 ✓. Merged variants: Pierce 235 (380 staged rows
absorbed), Spokane 2, King/Snohomish 0.

**The iterating hierarchy**: Pierce's schema resolves its own duplicates one
declared field at a time (unit → unit_type → level took collisions from 6,763
→ 4,253 → 460 groups). The remaining 233 attr-differing groups are the honest
residual — records sharing the full declared key but differing in some
unmapped attribute — and they are *documented, not forced unique*: the
`(record_key_uid, record_signature)` grain keeps every variant distinct, the
scorecard publishes key-collision counts, and the union never fires where the
source distinguishes. Forcing uniqueness there would repeat the state's own
sin — collapsing records its source distinguishes.

**Schema decisions (user-driven, verified):**

1. **`unit_type` joins the conformed schema** (new column; Pierce =
   `taxparcelunittype`, null elsewhere). It is semantically load-bearing:
   values live on the Residence component while Parking/Storage/Garage
   components carry zeros — without the column, the zero-value components
   look like broken records instead of what they are.
2. **`level` folds into `sub_address`** (no other county has an equivalent,
   so no sibling column): Pierce's mapping becomes unit + level, e.g.
   `sub_address = '2518 / L1'`, with the county's `-1` sentinel handled.
   Measured: `taxparcellevel = -1` is real county data (975 rows, zero
   nulls) and reads as **below-grade**: of 975 −1 records, 517 share their
   unit with a level-1 record, and 236 of those are **fully contained** in
   the level-1 geometry (verified on objectid 146838: the −1 Residence, 184
   sqft, nested inside objectid 146839, the level-1 Residence, 1,502 sqft,
   $303,900 valued). Basement components stacked in plan view — legitimate,
   not duplicates. 73 partial overlaps and 128 disjoint −1 records are a
   scorecard look, not a quarantine.
3. **`parcel_type` joins the conformed schema** — the general classification
   the counties publish and we excluded: Pierce `taxparceltype` (Base Parcel
   312,482 / Condominium 22,491 / Airspace Condominium 3,402 / Tax Purpose
   Only 879 / Lease Hold 405 / Undivided Interest 233 / Building Only 52) and
   King `proptype` (R / C / K / T / U / X / M, with 9,043 nulls matching the
   value-less class exactly). Spokane publishes no equivalent (its `parcel`
   column is a near-copy of `pid_num`, 214,366 distinct of 214,368 rows) and
   Snohomish has no type column. This column is the county's own answer to
   "what kind of sectioning is this record" — and it validates the
   topological test: level-0 rows ≈ Base Parcel count almost exactly, and the
   Condominium / Airspace classes are precisely the records whose geometry is
   not a land section.
4. **Overlap convention confirmed intact**: the nested-component case is
   *intra-uid* (same `parcel_uid`), which A6 excludes by design — plan-view
   nesting of vertically stacked components is exactly what the exclusion
   exists for. The overlap test remains different-parcels-only.


**Verify**: conformed rows **1,504,938** (−2 Spokane unions, −335 Pierce
collapses); `sum(source_record_count)` = 1,505,275; canary 4,598 + 1,505,275 =
1,509,873 ✓; uniqueness failures confined to Pierce's documented residual.

### A3b. Residual disposition — measured, then simplified (user design adopted)

After A3, the residual duplicates in conformed are key-groups with ≥2
distinct signatures (234 groups / 468 rows). Measured properties:

- **Exactly one value-holder per group** (all 229 acre-bearing groups): one
  record carries land/improvement/taxable values; every other record is a
  zero-valued shell. Zero groups carry >1 value-holder; zero groups carry
  none at all.
- **`land_acres` is a parcel-level measure stated once** (on the valued
  record), while component geometries cover only the built footprint —
  which is why per-row acres/geometry ratios run ~4.56× and sum(acres) vs
  union area ~4.47× on these groups. **Not inaccurate — mis-grained**: acres
  describes the tax parcel; the geometry describes the components.
- Divergence profile: the value quadruple varies in every group; geometry in
  ~196; address/use/legal/exemptions in none.

**Disposition — MERGE per record_key_uid (user's design, measured lossless):**

Summing the values is lossless because each group has exactly one
value-holder (measured, zero exceptions): the zero-valued shells contribute
nothing to any sum, and the unioned geometry carries every component's
extent. `int_parcels_records` therefore groups by **`record_key_uid` alone**:

```sql
group by record_key_uid
-- sum(land_value), sum(improvement_value), sum(taxable_value)   -- lossless: single holder
-- sum(land_acres)                                               -- = the parcel's acres (zeros add nothing)
-- st_multi(st_union(geom))                                      -- full component extent
-- count(*) as source_record_count
```

**Semantic notes on the merged records:**

1. `acres_reported` (single holder) is the **tax parcel's** acreage; the
   unioned geometry is the **built components'** footprint. The area_ratio
   flag will fire on these records (~0.2 building/parcel coverage) — that is
   now an *explained* class, not a defect: acres = parcel land incl. common
   area, geometry = components. Scorecard annotates; do not "fix" by
   geometry-deriving.
2. `record_signature` is retained as a provenance/debug column (min over the
   group) but is **out of the grain**.
3. No new quarantine classes: the A3b superseded_duplicate / absorbed_nested
   ideas are **retired** — everything merges; quarantine is unchanged; the
   canary reconciles through `source_record_count` as before.

**This buys the truly clean test**: `unique record_key_uid` on conformed —
one row per (tax parcel, unit, unit_type, level) — the county's own record
hierarchy, unique by construction. Expected after A3b: conformed
1,504,927 → **1,504,693** (−234); expansion unchanged (1,505,309); canary
green. `parcel_uid` remains the state join, intentionally non-unique, with
the scorecard publishing merges-vs-collisions (ours 469 rows → 235+2+234
explained merges vs the state's 49,409 unexplained).

**Correction record**: the earlier sum-refutation ("median 4.28× overshoot —
overlapping re-statements") compared the parcel-level acres measure against
component-extent area — a grain mismatch, read as double-counting. The
per-row and value-holder measurements above supersede it.

### A4. Canary arithmetic update

**Where**: `tests/row_counts_match.sql`.

**New contract**: `staged = rejected + Σ(source_record_count)` over conformed.
The old `staged = conformed + rejected` is now mathematically wrong by design —
merged-away rows must stay reconciled.

### A5. GiST index prerequisite

**Where**: `int_parcels_conformed` config (already a table):

```jinja
{{ config(
    materialized='table',
    post_hook="create index if not exists idx_conformed_geom on {{ this }} using gist (geom)"
) }}
```

No GiST indexes exist anywhere today (verified). Recreated each build via the
post-hook; `IF NOT EXISTS` keeps it cheap.

### A6. `int_parcel_overlaps` model — reworked after real measurement

**Baseline correction**: the "0 in 2,000 sampled" figure was a sampling
artifact — against a ~0.06% pair rate the sample expected ~0.001 hits.
Full-county measurement (reviewer-run, with GiST): **Spokane 133 pairs,
King 2,661**. Real overlaps exist and the test must be designed around
measured counts, not near-zero.

**Cost model**: cost tracks **parcel size, not row count** — Snohomish's
parcels average 13.75 acres vs King's 2.20, so its bounding boxes yield
9.0M candidate pairs (5.2× King's) from half the rows. Reviewer timings:
Spokane 12.7s, King ~5 min, Snohomish >450s (timeout).

**Implementation requirements**:

1. **Compute `st_intersection` once** — CTE `AS MATERIALIZED` (or LATERAL):
   the naive form evaluates it in both WHERE and SELECT, tripling the
   expensive call. Necessary but not sufficient for Snohomish.
2. **Partition by county** — four independent jobs; Snohomish must not block
   the others, and per-county progress is observable.
3. ~~**`ST_Subdivide` the large geometries before the join**~~ — **TESTED AND
   REJECTED.** ST_Subdivide splits on VERTEX COUNT, and Snohomish is large,
   not complex: 28 avg vertices with only 2% of rows over 256, but a 394ft
   avg bbox side vs King's 169ft. A default `ST_Subdivide(geom, 256)` would
   touch 2% of rows and change nothing.

   Forcing it with `ST_Subdivide(geom, 8)` does cut the average bbox side to
   105ft — but expands 314,670 records into 3,031,020 pieces, and the join
   got *worse*: the overlap query still timed out at 480s, and even the
   bbox-only candidate count timed out at 340s (the same count on
   un-subdivided geometry takes 20s for all four counties). The 9.6x row
   expansion swamps the 3.75x box reduction.

   **Spatial TILING also TESTED AND REJECTED -- it is 26x WORSE.** A 1-mile
   ST_SquareGrid over Snohomish gives 2,003 cells and 372,356 assignments
   (1.18 cells per record, so straddle duplication is negligible) and builds
   in 5s. But joining on `a.cell_id = b.cell_id` short-circuits the GiST
   index and degenerates to all-pairs within each cell: **237,892,264
   intra-cell pairs versus the 9,001,941 candidates the index produces
   untiled.** The plain GiST index is already a better spatial partition than
   a 1-mile grid. The run died first on disk exhaustion, then on timeout with
   the filter pushed below the aggregation.

   **The premise is what is actually wrong.** A6 assumed overlaps are
   "rare-and-meaningful signal". Measured in a single 5-mile box of
   Snohomish: 716,602 bbox candidates, 598,527 touching, and **356,470 with
   genuine INTERIOR overlap** (`ST_Relate 'T********'`) -- 60% of touches are
   real overlaps, not shared boundaries. Snohomish parcels systematically
   overlap.

   Cause: **42,220 Snohomish records carry `STACKED = Y`** -- vertically
   stacked units sharing one plan-view footprint. Each is its own tax parcel,
   so they carry DIFFERENT parcel_uids and the `a.parcel_uid <> b.parcel_uid`
   exclusion never sees them. This is the same phenomenon A3b already
   documents for Pierce's level -1 basements nested inside level 1; in
   Snohomish it simply crosses the parcel_uid boundary.

   **A6 therefore needs a SEMANTIC exclusion before it needs a performance
   fix**: stacked/condo records must be excluded, or classified separately,
   the way intra-parcel components already are. Without it the model is not
   slow -- it is correctly reporting tens of millions of legitimate vertical
   stacks, which is not a data-quality exception list. Re-measure cost only
   after the exclusion; the candidate set may drop far enough that none of
   the performance work is needed.

   **Infrastructure note**: the Postgres volume sits on a 97%-full disk (12G
   free) while /mnt/F has 2.8TB. The first tiling attempt failed with "no
   space left on device" on temp spill, not on query cost.
4. GiST index per A5 (verified: builds in ~6s; none existed before).

**Model shape**:

```sql
-- per county (partitioned), geometry pre-subdivided where large
with pairs as materialized (
    select a.parcel_uid as uid_a, b.parcel_uid as uid_b,
           st_area(st_intersection(a.geom, b.geom)) as overlap_sqft
    from {{ ref('int_parcels_conformed') }} a
    join {{ ref('int_parcels_conformed') }} b
      {#  record_key_uid, not parcel_uid, for the pair key: after A3b
          parcel_uid is intentionally non-unique (6,763 Pierce groups), so
          `a.parcel_uid < b.parcel_uid` emits one row per RECORD pair while
          labelling them all with the same uid pair -- duplicate output rows.
          record_key_uid is unique by construction; the separate <> on
          parcel_uid is what excludes intra-parcel stacking. #}
      on  a.record_key_uid < b.record_key_uid
      and a.parcel_uid <> b.parcel_uid
      and st_intersects(a.geom, b.geom)
)
select uid_a, uid_b, overlap_sqft
from pairs
where overlap_sqft > {{ var('min_overlap_sqft', 1) }}
```

**Test design — count bands REJECTED in favour of structural invariants.**

The draft proposed asserting per-county pair counts stay within a measured
band. That repeats a mistake this project has already corrected twice: a
magnitude assertion rots. Pierce moved 34 rows in a day; a band tight enough
to catch a regression fails on ordinary republication, and one loose enough
to survive republication catches little. Worse, when it fires it cannot
distinguish "our code broke" from "the county republished" — only the first
is a test failure. The A-verification checklist constants were deleted for
exactly this reason, and `parcel_uid_is_unique` was retired for it.

`tests/overlap_invariants.sql` asserts eight structural properties instead,
each of which fails only if the CODE is wrong (all verified passing across
78,593 pairs):

  1. no both-stacked pair present — the shortcut's contract
  2. record_key_a < record_key_b — canonical ordering, no duplicate pairs
  3. no intra-parcel pair — the parcel_uid exclusion holds
  4. overlap_ratio within (0, 1]
  5. overlap_sqft above the min_overlap floor
  6. unflagged_coincident implies coincident AND neither record stacked
  7. overlap_class within accepted values
  8. overlap_class agrees with the ratio threshold

The model here is `row_counts_match`: assert RELATIONSHIPS, not numbers.
Magnitudes belong in agg_quality_scorecard, where drift reads as history
rather than as a red build.

**Measured baselines** (for the scorecard, not for assertions) — all four
counties build in ~81s total:

| County | Build | Coincident | Encroachment | Unflagged coincident |
|---|---|---|---|---|
| King | 26s | 330 | 2,331 | 330 |
| Pierce | 15s | 27,492 | 3,653 | 990 |
| Snohomish | 28s | 44,256 | 398 | 4,121 |
| Spokane | 12s | 115 | 18 | 115 |

Note Snohomish's 398 encroachments against the ~7,000 the sample-box
extrapolation predicted: the sample had no minimum-overlap floor, so most
partial neighbour overlaps are sub-square-foot survey slivers. The 1 sqft
floor is doing real work.

### A6 resolution — measured, root-caused, closed

The performance mystery was never the query. Two compounding environmental
faults produced every catastrophic timing:

1. **The GiST index silently vanished on rebuild.** The post-hook's
   `CREATE INDEX IF NOT EXISTS` no-ops after dbt's tmp-table rename drops the
   old index with the old table. Every "slow" measurement (King 9 min, Spokane
   12.7s → 300s, the 45-minute hang that motivated the lateral rewrite) ran
   against an unindexed table. Fixed: DROP + CREATE + ANALYZE in the post-hook,
   asserted by `tests/conformed_geom_index_exists.sql`.
2. **Post-cancellation I/O churn.** The 400s Spokane timeout ran minutes after
   cancelling a 78-minute runaway build on a 97%-full volume; the system was
   flushing/cleaning gigabytes from the aborted CTAS. Identical SQL, identical
   plan, saturated disk.

With both fixed, measured via dbt end-to-end: **Spokane 12s (133 pairs),
Pierce 15s (31,145), King 26s (2,661)** — plan verified as Gather → Nested
Loop → Index Scan, identical for bare SELECT and CTAS, parallelism intact
inside the materialized CTE.

Also corrected: the "st_intersection evaluated 4x" analysis counted plan
occurrences, not cost × cardinality — select-list expressions evaluate only
for surviving rows (~133), so re-evaluation was always negligible. The
materialized barrier is harmless (verified) but was never the fix.

Predicate benchmark with index present: st_relate 'T********' 7s,
not st_touches 8s, st_intersects 13s — keep st_relate.

**Standing rule, earned twice now**: before attributing a performance change
to a query change, verify (a) the indexes exist — pg_indexes, not memory,
(b) statistics are fresh, and (c) nothing else is saturating the volume —
pg_stat_activity plus disk headroom. Plan-shape conclusions drawn without
those checks were all wrong, in both directions.

### A7. Test rescope

- **Retire** `parcel_uid_is_unique` as expected-fail; replace with the
  *confined* formulation:

```sql
select distinct county_fips
from (select parcel_uid from {{ ref('int_parcels_conformed') }}
      group by 1 having count(*) > 1) d
join {{ ref('int_parcels_conformed') }} c using (parcel_uid)
where c.county_fips != '053'
```

  Passes when non-Pierce counties are uid-clean — which holds after A2 (the
  Spokane attr-differing trio *is* the UNKNOWN group and quarantines out);
  Pierce's unit-record non-uniqueness stays documented, and
  dup-groups-per-county becomes a scorecard metric.
- Keep: canary (A4 form), reject rate (numeric cast), vocabulary,
  schema-location, geometry validity, drift, vintage.

### A-verification checklist (after A1–A7 rebuild)

*All absolute numbers below were measured 2026-08-31. Pierce re-ingested at
339,944 rows (+34) after these were taken, and we have now watched the source
drift twice in two days — treat these as re-measurement baselines, not
assertions. The A4 relational contract (`staged = rejected +
Σ source_record_count`) is the durable form; re-derive the absolutes from it
at build time.*

| Metric | Measured 2026-08-31 (post-A3 build) |
|---|---|
| Staged rows | 1,509,907 (Pierce 339,944 after re-ingest) |
| Rejected rows / expansion | 4,597 / **4,598** (4,595 Snohomish voids + UNKNOWN trio, two of which merged) |
| `sum(source_record_count)` over conformed | **1,505,309** |
| Conformed row count | **1,504,927** (−380 Pierce, −2 Spokane) |
| Canary | 1,505,309 + 4,598 = 1,509,907 ✓ (green) |
| Uniqueness failures | Pierce only — the documented 460 residual key-collision groups (6,763 duplicated uids) |
| Overlap pairs (per county) | Spokane ~133, King ~2,661 (reviewer-measured); Pierce + Snohomish pending full runs |
| GiST index | present (created manually post-build; the post-hook's non-execution on a racing double-build is an open wrinkle -- rerun with `--no-partial-parse` if it recurs) |

---

## Part B — Gold layer

**Config**: `models/marts/` directory; in `dbt_project.yml` nest under
`parcels:` (package-path config lesson):

```yaml
models:
  parcels:
    +materialized: view
    marts:
      +schema: marts
      +materialized: table
```

Dashboards should not recompute the silver chain — gold is tables.

### B1. `stg_state_parcels` (staging — build first)

Thin view over `raw.state_parcels`:

- **`parcel_uid = trim(parcel_id_nr)`** — NOT `fips_nr || '-' || parcel_id_nr`.
  The state's `PARCEL_ID_NR` **already contains its own FIPS prefix**,
  verified on all 3,278,890 non-null rows with zero exceptions (e.g.
  `033-…` on fips 033 rows). Concatenating would double-prefix
  (`033-033-…`) and break every reconciliation join.
- **The 13,629 null-FIPS rows are recoverable, not unidentified**: all of
  them are Asotin County (prefix `003`) with well-formed prefixed ids — the
  state's `fips_nr` is systematically null for the entire county while the
  ids are intact. Recover `fips = substring(parcel_id_nr, 1, 3)` (or a
  county-domain join) and Asotin reconciles instead of landing in a junk
  bucket. New §9 defect: "Asotin's 13,629 parcels lack `FIPS_NR`
  entirely — recoverable from the id prefix; the state's own county lookup
  failed for one whole county."
- **Split `SITUS_ZIP_NR` with the existing anchored regex** — measured 691,059
  state rows carry ZIP+4 (design §10 open question resolved; the regex becomes
  bidirectional)
- Keep `orig_landuse_cd` + `landuse_cd` so the fact distinguishes "state
  unmapped" from "state mapped differently"
- State-side casing verified per-county (King upper, others lower) — no case
  normalization, same rule as ours

### B2. `dim_parcel`

Grain = **one row per published spatial record** from `int_parcels_conformed`.
Dedup/union is already done upstream; Pierce unit records remain, with the
ambiguity flag carried. Columns per design §3. This model is nearly boring —
everything it needs is test-enforced upstream.

### B3. `fct_parcel_reconciliation` — the flagship

Full outer join `dim_parcel` ↔ `stg_state_parcels` on `parcel_uid`:

- `reconciliation_class`: `both_match` / `both_differ` / `ours_only` /
  `theirs_only` / `theirs_unidentified` (the 42,969 null-FIPS/null-PID state
  rows land there explicitly)
- Per-field agreement columns (address, city, zip5/zip4, landuse, values),
  **null-aware**: unmapped landuse is *not applicable*, not a disagreement;
  null-vs-null handling decided per field and documented in the model header
- `vintage_gap_days` from both sides' `source_file_date`
  (`int_county_vintage` already handles the state side statewide, including
  the four multi-word county names)
- State-side collisions: per-row grain + `state_side_dup_count` — their
  49,409 vs our fully-explained ledger is the comparison
- **Gate**: before treating value deltas as findings, measure what basis the
  state's `VALUE_LAND` is (King appraised? Snohomish market?) by comparing
  distributions on matched rows; write the answer into the model header

### B4. `agg_quarantine_summary`

Reason × county × count + human labels. Labels come from the registry: loop
`rejection_rules()` into a `VALUES` CTE, join on code. The registry now feeds
the CASE, the vocabulary test, and the summary — one source of truth, three
consumers.

### B5. `agg_quality_scorecard`

County × check × outcome. Unpivot the flags by looping `flag_rules()` into
`UNION ALL` blocks (true/false/null counts each), plus hand-written blocks:

- geometry validity rate
- **area-check coverage** (share of parcels with an independent roll figure:
  King ~98.5%, Pierce ~95.6%, Snohomish ~83%, Spokane ~99.8%)
- landuse coverage (derived % + unmapped counts per county)
- reject rate
- **dup groups per county** (ours, every one explained, vs the state's 49,409)
- **attribute completeness** (the King tracts decision, published as a number)
- overlap pairs from `int_parcel_overlaps`

### B6. `bi_parcel_extract`

`ST_Transform` → 4326, `ST_SimplifyPreserveTopology` with
`var('simplify_tolerance')` (start ~1m, eyeball in QGIS). The presentation
filter decision lives here (e.g., attribute-less tracts in or out — visible
in the model header either way). Materialized table.

### B7. Gold tests

- Reconciliation balance (class counts sum per side)
- `accepted_values` on `reconciliation_class`
- dim grain — confined-to-Pierce formulation
- scorecard self-consistency (summed outcomes = underlying counts)
- bi SRID + validity

### B8. Build order & reconciliation expectations

```
A1→A7 (rebuild, checklist above)
→ stg_state_parcels
→ dim_parcel
→ fct_parcel_reconciliation   ← measure VALUE_LAND basis first
→ agg_quarantine_summary
→ agg_quality_scorecard
→ bi_parcel_extract
```

State rows per county (measured): 033: 635,192 / 053: 339,590 / 061: 318,594 /
063: 214,022 — so `ours_only` is small (King ~1,131 net) and the interesting
mass is in `both_differ` and `theirs_unidentified`.

### B9. Design-doc updates to fold in as you go

- §10 ZIP+4 question **resolved** (691,059 state rows carry it)
- §9 additions: 29,340 null state parcel IDs; 49,409 state duplicate keys;
  state King missing ~53 lettered PINs; Pierce duplicate taxonomy (geometry
  disambiguates 98.2%, unit/level/comment 43%, 87 byte-identical dedupes, 35
  zero-twin allocation pairs); King case-variant tracts (the `upper()`
  artifact); area ratio measured trustworthy (median 1.0001–1.0007)
- New section: the duplicate-handling decision tree (union / dedupe / keep /
  quarantine) with measured counts per branch


