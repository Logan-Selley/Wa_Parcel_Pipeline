# Design history: Silver + Gold

*How the silver and gold layers got their shape: the
decisions, the measurements behind them, and the ideas that were tested and
rejected. Everything here is landed. Current numbers live in the README and the
scorecard, not here, absolute figures rot (Pierce moved 34 rows in a day),
while the relational contracts below do not.*

Model comments anchor to sections of this file (A1, A3, A3b, A4, A6, A7, B3).
If you add an anchor, add the section first.

---

## A1. Parcel IDs keep the source's casing

`upper()` in the `parcel_id_norm` expression collapsed six pairs of
case-distinct King tracts (`Tr-A` vs `TR-A`, distinct MINOR values in King's
own MAJOR/MINOR identifier structure, verified against the PARCEL_AREA_439
layer via REST) and would have broken up to three Spokane joins. The state
mirrors each county's source casing, King upper, Spokane lower,
Pierce/Snohomish numeric, so source-case-preserving uids join correctly
everywhere. Removed; verified a no-op for the two numeric counties.

## A2. Spokane's `UNKNOWN` sentinel

Three Spokane rows publish `PID_NUM = 'UNKNOWN'`, genuine empty placeholders:
no address, no use code, geometry partially overlapping three to six real
parcels. `nullif(trim(PID_NUM), 'UNKNOWN')` routes them into
`missing_parcel_uid` quarantine with no new machinery. The companion decision
matters more than the sentinel itself: `parcel_id_raw` maps a separate
expression (`trim(PID_NUM)::text`), so the raw value survives on exactly the
rows where preserving it matters. Rejected count moved 4,595 → 4,598.

## A3. Record identity: declared record keys, not row hashes

Counties publish records, not parcels, and each encodes its own record
hierarchy. Two ids, each with one job:

1. **`record_key_uid`**, parcel_uid plus the county's declared record_key
   fields, legibly encoded (`053-123456|A|2` = parcel + unit + unit_type +
   level). Declared per county in the manifest (Pierce:
   unit/unit_type/level; Spokane: site_apartment; King and Snohomish: none,
   their published ids are already unique).
2. **`record_signature`**, md5 over every raw column not in the county's
   identity_exclude (system row ids, volatile timestamps, geometry-derived
   metadata). Demoted to variant discriminator: it separates records the
   declared key doesn't, without putting volatile data in the key, values in
   a key would churn identity on every assessment update.

Measured: declaring Pierce's three fields took key collisions from 6,763
groups to 460, and the county's schema resolves its own duplicates one
declared field at a time (unit → unit_type → level walked 6,763 → 4,253 →
460). The remaining attr-differing groups are documented residual, not forced
unique, forcing uniqueness there would repeat the state's own sin of
collapsing records its source distinguishes.

Integration (`int_parcels_records`): group by record_key_uid, union geometry
within a group, carry `source_record_count` as the provenance for every merge.
The signature is computed in staging, conform_parcels is the only model with
raw columns in scope, and carried explicitly through every downstream column
list; joining back to raw below staging was considered and rejected.

Two schema decisions folded in here, both user-driven and verified:

- `unit_type` joins the conformed schema. Values live on the Residence
  component while Parking/Storage/Garage components carry zeros, without the
  column, the zero-value components look like broken records instead of what
  they are.
- Pierce's level folds into `sub_address` (`2518 / L1`). The county's −1
  sentinel is real below-grade data: 975 rows, 517 sharing their unit with a
  level-1 record, 236 of those geometrically contained in it. Basement
  components stacked in plan view, legitimate, not duplicates.

## A3b. The residual: merge, measured lossless

After A3, 234 key-groups still carried two or more distinct signatures.
Measured properties, which turned the disposition into an arithmetic question
rather than a judgment call:

- exactly one value-holder per group, 229 of 234 carry values, zero carry
  more than one, the remaining five carry none;
- `acres_reported` is a parcel-level measure stated once on the valued record,
  while component geometry covers only the built footprint, the ~4.5×
  acres-vs-area ratio on merged records is a grain difference, not a defect;
- address, city, ZIP and land use never diverge within a group.

Disposition: merge per record_key_uid. Sum the values (a single holder makes
it lossless, the zero-valued shells contribute nothing), `st_union` the
geometry, `count(*)` as `source_record_count`. Conformed 1,504,927 →
1,504,693. `record_signature` is kept as provenance but is out of the grain.

The King tracts decision landed here too: attribute-less records stay in the
dimension (a parcel registry includes what exists) and their share is
published in the scorecard rather than filtered out. The same reasoning puts
every record in the map extract, a public map silently omitting 9,231 King
records would be making an editorial choice for its readers.

## A4. The canary

`staged = rejected + Σ(source_record_count)` over conformed. The older
`staged = conformed + rejected` became mathematically wrong the moment the
integration step could collapse rows, merged-away rows must stay reconciled.
`source_record_count` is what makes the sum work on both sides; it is also why
the scorecard counts quarantine in source rows, not quarantine rows (one
rejected merged record can stand for several published rows).

## A5. GiST index on int_parcels_conformed

Builds in ~6s, and the overlap models are only tractable with it. See A6 for
why its existence is asserted by a test rather than assumed.

## A6. Overlaps: what was measured, tested, and rejected

Cost tracks parcel size, not row count: Snohomish averages 13.75 acres against
King's 2.20, so its bounding boxes yield ~9.0M candidate pairs from half the
rows.

Once tagged `expensive` so routine builds could skip it. **Tag removed**, the
four models now cost 32.55s together against 119s for `int_parcels_repaired`
alone, and the hour-plus build that motivated the tag was the missing GiST
index, not this join. Excluding them also never excluded `agg_quality_scorecard`,
which refs the county tables directly, so the exclusion bought no time and
published stale overlap counts. See design.md §5.8.

Tested and rejected, with measurements:

- **ST_Subdivide** splits on vertex count, and Snohomish is large, not complex
  (28 avg vertices, 2% of rows over 256). Forcing it to 8 expanded 314,670
  records into 3,031,020 pieces and made the join worse.
- **1-mile spatial tiling** was 26× worse: joining on cell equality
  short-circuits the GiST index and degenerates to all-pairs within each cell
  (237,892,264 intra-cell pairs against 9,001,941 from the index). The plain
  GiST index is already a better spatial partition than the grid.

The performance mystery was never the query. Two environmental faults produced
every catastrophic timing: the GiST index silently vanishing on rebuild (dbt's
tmp-table rename drops the old index, after which `CREATE INDEX IF NOT
EXISTS` no-ops, the post-hook now does DROP + CREATE + ANALYZE, and
`tests/conformed_geom_index_exists.sql` asserts it), and post-cancellation I/O
churn on a 97%-full volume. With both fixed, all four counties build in ~81s
total.

Two standing rules earned here, both the hard way:

- **Before attributing a performance change to a query change**, verify the
  indexes exist (pg_indexes, not memory), statistics are fresh, and nothing
  else is saturating the volume. Plan-shape conclusions drawn without those
  checks were all wrong, in both directions.
- **Assert relationships, not magnitudes.** Count bands rot: Pierce moved 34
  rows in a day, and a band tight enough to catch a regression fails on
  ordinary republication while telling you nothing about which side changed.
  `tests/overlap_invariants.sql` asserts eight structural properties instead;
  drift reads as history in the scorecard.

Also settled here, the both-stacked shortcut: across 352,281 both-stacked
pairs in a 5-mile sample box, zero fell below a 0.8 ratio, stacking always
implies coincidence, so both-stacked pairs skip the expensive computation
entirely, while a stacked record overlapping a non-stacked neighbour still
appears (563 such encroachments in the box).

## A7. parcel_uid uniqueness: retired, confined

`parcel_uid` unique was the project's one permanently-red test, Pierce
legitimately publishes multiple records per tax parcel, and the state carries
the same duplicates. A permanently-red assertion is worse than none, so it was
replaced by the confined formulation in
`tests/dup_parcel_uids_confined_to_pierce.sql`: duplication must stay confined
to Pierce, where another county developing duplicate uids is a real regression
(its record hierarchy would be lying about its own grain). Dup-group counts
per county are a scorecard metric, not a test.

---

## Part B: the gold layer

Shape decisions as built. Config: marts are tables under the `marts` schema;
dashboards never recompute the silver chain.

### B1. `stg_state_parcels`: the answer key, conformed to our vocabulary

The uid is `trim(parcel_id_nr)`: the state already embeds its own FIPS prefix,
verified on all 3,278,890 non-null rows with zero exceptions. The originally
planned concatenation would have double-prefixed (`033-033-…`) and broken
every reconciliation join. The 13,629 null-FIPS rows are recovered from the id
prefix (Asotin) rather than orphaned. `SITUS_ZIP_NR` splits with the same
anchored regex as the counties, 691,059 state rows carry ZIP+4, so splitting
only our side would have manufactured a coverage difference on every one.

### B3. `fct_parcel_reconciliation`: the flagship

Parcel-grain, full outer join on parcel_uid. The gate that mattered: measure
what basis the state's `VALUE_LAND` is before treating deltas as findings.
Measured answer, three counties show expected drift (median ours/theirs
ratios 0.977-1.098, consistent with ~200 days of appreciation against an
annually revalued source), so value fields carry `drift: true` and surface as
`value_drift` rather than as class. King is genuinely different: median 0.193
on the 1.1% that disagree, concentrated almost entirely in one property class
(`PROPTYPE = 'K'`, complex-level condominium records against unit-scaled
state values). An aggregation-grain difference, tracked separately, not
settled into the drift bucket.

### B4/B5. Registry-driven labels

`rejection_rules()` and `flag_rules()` feed the validation CASE, the
vocabulary tests, the quarantine summary and the scorecard, one definition
per rule, five consumers.

### B6. `bi_findings_extract`

Replaced the full-parcel map extract. A map of 1.5M polygons duplicated a
statewide map the state already publishes, could not be read, and produced a
tile archive over GitHub's 100 MB file limit. This extract carries only the
55,589 records the pipeline has a finding about, encroachments, unflagged
coincident pairs, coverage gaps in either direction, attribute disagreements,
repaired geometry, quarantined shapes, with geometry drawn from whichever
side has it and `geom_source` saying which. Simplification conservative:
`ST_SimplifyPreserveTopology`, plain `ST_Simplify` silently erased 1,060 tiny
parcels (6-261 sqft) on the first build, returning null for rings whose
vertices all fell inside the tolerance.

### B7. Gold tests

Assert relationships: reconciliation balance, class vocabulary, confined
uniqueness, scorecard self-consistency, bi geometry contract.
