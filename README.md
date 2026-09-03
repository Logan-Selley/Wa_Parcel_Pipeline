# WA Parcel Reconciliation

Ingests parcel data from four Washington counties that each publish
independently — different field names, projections, geometry quality, record
grain and update cadence — conforms them to a common schema, and **reconciles
the result against the state's own normalized statewide layer.**

That last part is the point. Washington State publishes a [statewide Current
Parcels layer](https://geo.wa.gov/datasets/current-parcels) covering all 39
counties with normalized attributes, which makes it an **answer key**: build a
conformance layer independently, then diff against theirs and explain every
difference in both directions.

**1,509,907 source rows → 1,504,693 published records → 95–99% agreement with
the answer key**, with every remaining difference classified and eight documented
defects found in the answer key itself.

---

## Results

| County | Records | Agreement | Unexplained differences | Answer key stale by | Encroachments | Geometry repaired |
|---|---|---|---|---|---|---|
| King | 636,323 | **96.38%** | 20,606 | 188 days | 2,331 | 100 |
| Pierce | 339,330 | **99.13%** | 1,481 | 196 days | 3,653 | 60 |
| Snohomish | 314,670 | **97.30%** | 7,460 | 216 days | 398 | 77 |
| Spokane | 214,370 | **99.38%** | 231 | 166 days | 18 | 31 |

"Unexplained" is doing real work in that column. Raw disagreement was
**1,204,678**. Two corrections took it to 42,790 — and neither was a bug fix,
both were the discovery that a comparison was meaningless:

- **Case normalization.** King publishes `Bellevue`, the state publishes
  `BELLEVUE`. 489,880 city "disagreements" → 8,175 real ones.
- **Expected drift.** The answer key is 166–216 days behind the counties, and
  WA counties revalue annually, so assessed values *must* differ. Value fields
  are declared `drift: true`: they still get a per-field status and a
  `value_drift` count, they just don't count as disagreement.

Then a third, found by reading values instead of counts: Pierce's
`sub_address` holds the unit designator (`39 A`) while the state's holds the
**condominium complex name** (`WEST MEEKER CONDO`). 13,142 of Pierce's 14,493
differences were an artifact of comparing two different fields. Pierce went
95.19% → 99.13%.

---

## What we found in the answer key

Eight defects, each measured rather than asserted. The full list is in
[docs/design.md §9](docs/design.md); the ones worth reading:

- **`FIPS_NR` is null for 100% of one county.** All 13,629 null-FIPS rows are
  Asotin — every one carries a `003-` prefixed parcel id and a populated
  `COUNTY_NM`, and the layer holds zero rows with `FIPS_NR = '003'`. Recoverable
  from two columns they do populate.
- **`File_Date.COUNTY_NM` mixes codes and names, diagnosably.** 35 of 39 rows
  hold a FIPS code; four hold a name — `GraysHarbor`, `PendOreille`, `SanJuan`,
  `Walla Walla`. Those are Washington's only four multi-word county names, all
  of them. A name→FIPS lookup that fails on spaces, letting the raw name fall
  through.
- **8 of the 89 land use codes in use are absent from the layer's own coded
  value domain** — `[0, 9, 10, 20, 60, 70, 80, 90]`, mostly SLUCM group headers.
- **King publishes two parcel layers that disagree by 2,563 parcels.**
- **The state preserves Pierce's duplicate rows but discards the fields that
  made them resolvable** — across 6,769 duplicate groups, zero are
  distinguished by `sub_address` or `situs_address`. Ours are fully explained
  by a declared record key; theirs are unresolvable in principle.

**And one we retracted.** The state's situs city and ZIP are null for all of
Pierce, which looked like their largest gap and our largest win — until a
plausibility flag caught 17,208 non-Washington ZIPs in *our* output. Pierce's
`City_State` and `Zipcode` belong to the **taxpayer mailing address**: PO boxes
and out-of-state values on parcels physically in Pierce County, differing from
the situs address on 39% of rows. The state was right to leave those null; we
had mapped the wrong fields, and it was also a PII leak. Corrected, and the
retraction is documented rather than quietly deleted.

---

## Decisions and trade-offs

**Overlaps are detected and classified, never repaired.** Resolving one means
deciding which parcel is authoritative and clipping the other — a cadastral
judgment made from deeds, not inferable from published attributes. The state
carries the identical overlaps (356,489 vs our 356,470 in a sampled box), so
"fixing" them would manufacture a difference we couldn't defend. The line
against geometry repair, which the pipeline *does* perform: `ST_MakeValid` fixes
a malformed **representation of a known intent**; an overlap is a **semantic
disagreement between two individually valid records**. Repair representation
errors, report semantic conflicts.

**Classify overlaps by geometry ratio, not by the stacking flag.** Measured
across 352,281 both-stacked pairs, stacking always implies coincidence — but
588 fully-contained pairs had *neither* record flagged. Gating on the flag would
have reported those as errors and hidden the stacked ones; classifying on ratio
puts both in the right bucket and keeps a stacked parcel comparable to its
neighbours.

**Decline to fabricate.** The state normalized land use for all 39 counties but
discarded the original codes for 27, so no crosswalk is derivable for Spokane.
`landuse_cd` stays null with `landuse_cd_method = 'unmapped'` for 214k parcels
rather than inventing a mapping. Spokane's `coverage_theirs_only` of 429,064 is
almost entirely this and the building values Spokane doesn't publish — documented
refusals showing up honestly as measured deficits.

**Owner and taxpayer data is never ingested.** Roughly 1.28M mailing addresses
and 578,000 names across three counties, excluded at the **request** level so
they never cross the wire, never reach bronze, and never reach the map extract.
Field *names* are still snapshotted so drift detection sees the full published
schema.

**Quarantine, don't drop.** 4,598 source rows fail validation and are kept with
a reason. A canary asserts `staged = Σ source_record_count over published +
quarantined` — relational, so it survives source drift that would rot a
hardcoded count.

---

## A name is not a semantic

The single most transferable thing here. Four times, two columns shared a name
and did not share a definition — and every one was invisible in a disagreement
*count*, visible only in the values:

| Field | Ours | Theirs |
|---|---|---|
| `value_land` | appraised (King) / market (Snohomish) | a third basis |
| Pierce `City_State` | *(mapped as situs — wrong)* | taxpayer mailing |
| `sub_address` | unit designator | condominium complex name |
| `situs_city` | incorporated jurisdiction | USPS postal city |

The last one nearly caused a bad fix. 83,867 parcels where the state has a city
and we don't looked like a coverage gap worth closing — but they're
**unincorporated** parcels with Redmond/Woodinville/Vashon postal addresses.
Vashon isn't a city. Our null is correct, and deriving a city would have traded
a documented gap for a correctness problem: it would then disagree with the
jurisdiction values on the 8,175 where the two genuinely differ.

The pipeline's answer is to declare semantics in the manifest — `value_basis`
already does this — rather than to compare on name and hope.

---

## Architecture

```
ArcGIS REST ──▶ raw ──▶ staging ──▶ intermediate ──▶ marts ──▶ exports ──▶ Tableau
  (ingest/)   (bronze)  (conform)   (repair, merge,   (dim,     (parquet     + static
                                     validate)         fct,      csv, json,     site
                                                       scorecards) fgb)
                            └─▶ quarantine
```

**Config-driven, not county-specific.** One manifest under `vars:` in
`dbt_project.yml` is read by *both* the Python extractor (`yaml.safe_load`) and
dbt (`var()`) — one file, no codegen, no drift. It declares per county: the
endpoint, native CRS, field mappings as **SQL expressions** (so
`split_part(City_State, ',', 1)` is as ordinary as a column name), the record
key, PII exclusions, and the semantics that make comparison meaningful. Adding a
county is a manifest block plus a one-line model.

**One registry per concern, multiple consumers.** `rejection_rules()` feeds the
validation CASE, a vocabulary test, and the quarantine summary.
`comparable_fields()` feeds the reconciliation fact and the scorecard. Definitions
live once.

**Bronze keeps everything.** Narrowing at extract time would destroy the ability
to answer "why does the state say X" without re-downloading.

**Ingestion is keyset-paged.** `resultOffset` costs more with depth — measured
32.51s at offset 2.98M against **1.13s** for the equivalent `OBJECTID` range.
Two full statewide loads failed at 2.6M and 3.0M rows before the switch; after
it, 3.3M rows load without a single transient failure. Ranges also can't be
silently truncated, which offset windows can.

**Publish dates, not run times.** Staleness is measured between the county's
`editingInfo.lastEditDate` and the state's `File_Date` — both publisher
statements — so the gap is a property of the data. Measuring against our ingest
timestamp would grow it by a day every day with nothing having changed.

---

## Orchestration

Airflow runs ingest → dbt → export on a daily schedule, in **its own containers
and its own metadata database**. It never shares a Python environment with dbt:
tasks run the pipeline image as sibling containers via `DockerOperator`, so
Airflow decides *what* runs and *when*, and the image owns *how*. Swapping it
for Dagster or cron would touch no pipeline code — which is the property that
makes orchestration worth adding rather than a place for logic to accumulate.
Every step is still runnable from a shell.

**The DAG does nothing on days when nothing published.** The sources republish
every few weeks, so a daily schedule would otherwise re-fetch 1.5M unchanged
parcels to regenerate yesterday's bytes — and put that load on public services
we don't own. Each ingest is gated by a check comparing the publisher's
`editingInfo.lastEditDate` against the last one recorded in
`raw.source_field_snapshot`. Both values already existed; the gate is one HTTP
call and an indexed `max()`, with no new state to maintain.

The skip composes out of two ordinary Airflow behaviours rather than a branching
operator: `skip_on_exit_code` turns the gate's exit 99 into a *skipped* task,
skips propagate to its ingest, and `dbt_build` uses
`none_failed_min_one_success` so **one** county publishing rebuilds everything —
correct, because the reconciliation is cross-county and the scorecard is
comparative. All five unchanged → zero successful ingests → the whole run costs
five metadata calls.

The gate **skips only on proof**. No snapshot, no recorded value, a publisher
that doesn't populate `editingInfo`, an unreachable service — all mean "cannot
prove unchanged", and all do the work (an unreachable service *fails*, since
that and "no new data" look alike from a distance and are opposite conditions).
Redundant work is visible and cheap; a pipeline that skips because it cannot
see, reports success, and publishes last month's numbers is neither.

Its known gap is stated rather than papered over: the gate keys on the *source*,
not on whether our own run succeeded, so an ingest that lands before a dbt
failure leaves the next scheduled run skipping. The remedies are ordinary — clear
the failed task, or trigger with `force` — and closing it properly would mean
recording pipeline outcomes in the orchestrator and reading them back here,
which is exactly the coupling the container boundary exists to prevent.

---

## Outputs

The warehouse is a build tool, not a service. Everything downstream is a static
artifact, so nothing needs hosting for the outputs to exist.

| Artifact | Contents | Consumer |
|---|---|---|
| `exports/parquet/` | fct, dim, three scorecards (zstd) | analysis |
| `exports/csv/` | same tables | **Tableau Public** workbook input |
| `exports/json/` | three scorecard tables (68 kB) | static site, committed |
| `exports/fgb/` | 1,504,693 records as FlatGeobuf | tippecanoe → PMTiles |
| `site/index.html` | MapLibre + PMTiles, KPI cards, scorecard | zero-build static page |

Export reads the gold tables through **duckdb's postgres extension** — no
intermediate service, no ORM. `bi_parcel_extract` is already WGS84 from dbt, so
geometry crosses as WKB and is rehydrated with shapely; the export deliberately
avoids duckdb's spatial extension.

The map extract keeps **everything** — attribute-less components, stacked units,
zero-value allocation records. A public map that silently omitted 9,231 King
records would be making an editorial choice the pipeline shouldn't make for it.
Simplification uses `ST_SimplifyPreserveTopology`: plain `ST_Simplify` silently
erased 1,060 tiny parcels (6–261 sqft) whose vertices all fell inside the
tolerance.

---

## Running it

```bash
make check       # verify env before blaming a query: index, disk, active queries
make freshness   # has any source republished since the last ingest?
make ingest-all  # all four counties
make ingest-state
make build       # every model and test
make export      # gold tables -> parquet/csv/json/fgb
make pmtiles     # fgb -> map tiles
make site        # assemble site/data/
```

Or `make airflow-up` and let the DAG run all of it in order.

`make check` exists because a routine rebuild once silently dropped a GiST
index, and the next 90 minutes of performance conclusions were drawn against an
unindexed table — including two that were confidently wrong in opposite
directions. Verifying the environment before attributing a performance change to
a query change is now a build step, not a habit.

**There is no longer a fast build and a slow one.** `build` used to pass
`--exclude tag:expensive` to skip the overlap models; the tag is gone. It was
added while an hour-long build was blamed on those models rather than on the
missing index above, and it never saved the work anyway —
`agg_quality_scorecard` refs the per-county overlap tables directly, so
excluding them only meant publishing encroachment counts older than the parcels
beside them. Measured now: 32.55s for all four counties, against 119s for
`int_parcels_repaired` alone.

**Do not invoke a bare `dbt`.** On this machine it resolves to dbt Fusion, which
has no Postgres adapter. Every target pins `.venv/bin/dbt`.

---

## Testing

37 dbt tests, all structural — they fail when the *code* is wrong, not when the
source data changes.

The pipeline had one permanently-red test (`parcel_uid` uniqueness) and one
proposed count-band test. Both were replaced: magnitudes rot — Pierce moved 34
rows in a day — and a band tight enough to catch a regression fails on ordinary
republication, while telling you nothing about *which* side changed. What
replaced them asserts relationships:

- the canary: `staged = Σ source_record_count over published + quarantined`
- `record_key_uid` unique — the drift guard A3b earns
- the full outer join can neither create nor destroy rows
- eight overlap invariants, including "no both-stacked pair present", which
  guards the 98.8% computation skip
- geometry index existence, because its silent absence already cost 90 minutes
