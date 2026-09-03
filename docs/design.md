# WA Parcel Reconciliation — Target Schema & Model Design

*Draft. Every field list, count, and CRS below was read from the live services on
2026-08-16; nothing here is assumed. Items still unresolved are marked **OPEN**.*

---

## 1. What this pipeline does

Ingests parcel data from Washington counties that each publish independently — different
field names, projections, geometry quality, and update cadence — and conforms them to a
common schema.

Washington State publishes a [statewide Current Parcels
layer](https://geo.wa.gov/datasets/current-parcels) whose attributes are already normalized
across all 39 counties. That makes it an **answer key**: we build our own conformance layer
and diff against theirs. Where we differ, we explain why — and where *they* are wrong, we
say so (see §9).

Scope for v1: **King, Pierce, Snohomish, Spokane** — 1.51M parcels, 45% of the state.

---

## 2. Sources

| Source | Layer | Parcels | Native CRS | Fields | Page size |
|---|---|---|---|---|---|
| WA State | `Current_Parcels/FeatureServer/0` | 3,321,859 | 2927 | 17 | 2000 |
| King | `PARCEL_ADDRESS_PUB_AREA_3069/0` | 636,323 | **2926** | 69 | **1000** |
| Pierce | `Tax_Parcels/0` | 339,910 | 2927 | 35 | 2000 |
| Snohomish | `Parcels/0` | 319,265 | **3857** | 54 | 2000 |
| Spokane | `Parcels/0` | 214,375 | **3857** | 43 | 2000 |

All five support `Query,Extract`, pagination, and GeoJSON/JSON/PBF. One extraction code
path covers all of them; only the parameters differ.

**Two companion tables on the state service, both load-bearing:**

- `File_Date` (39 rows) — per-county vintage of the state's copy. Counties are **not** the
  same vintage; sampled rows spanned 2026-01-09 to 2026-02-18. Every published comparison
  must state the vintage gap.
- `County_Unique_Land_Use_Codes` (1,931 rows) — per-county land use code → description.

**King publishes two parcel layers that disagree.** `PARCEL_AREA_439` (geometry only, 6
fields) has 638,886 parcels; `PARCEL_ADDRESS_PUB_AREA_3069` (69 fields) has 636,323. We use
the latter. The 2,563-parcel difference is a reconciliation finding, not a bug to hide.

---

## 3. Canonical target schema

Design rule that recurs throughout: **when a field's meaning varies by source, carry a
second column recording which meaning applies.** `value_basis`, `landuse_cd_method`,
`source_crs`, and `source_file_date` all exist for that reason. Without them the schema
looks uniform and quietly isn't.

```sql
-- marts.dim_parcel
parcel_uid            text        not null,  -- '033-9906000100'; matches state PARCEL_ID_NR
county_fips           char(3)     not null,
county_name           text        not null,  -- a real name, unlike the state's COUNTY_NM
parcel_id             text        not null,  -- normalized; TEXT always
parcel_id_raw         text,                  -- exactly as published
is_active             boolean     not null,
is_stacked            boolean     not null,  -- vertical component; see 5.8

situs_address         text,
sub_address           text,                  -- unit / condo designator
situs_city            text,
situs_zip5            text,                  -- TEXT, never numeric
situs_zip4            text,                  -- King only at present

landuse_code_source   text,                  -- county's own code, always retained
landuse_desc_source   text,
landuse_cd            smallint,              -- state taxonomy (89 values, 0-99); NULLABLE
landuse_cd_method     text        not null,  -- 'derived' | 'unmapped'

value_land_appraised  bigint,
value_bldg_appraised  bigint,                -- null for Spokane (not published)
value_basis           text        not null,  -- 'appraised' | 'market'
acres_reported        numeric,               -- county's own figure, for area validation

geom                  geometry(MultiPolygon, 2927) not null,

source_layer_url      text        not null,
source_crs            integer     not null,  -- 2926 | 2927 | 3857, as published
source_file_date      date,                  -- from the state File_Date table
ingested_at           timestamptz not null,
geometry_valid        boolean     not null,
geometry_repaired     boolean     not null
```

### Key decisions

**`parcel_uid` is the state's format, not a surrogate.** Zero-padded FIPS + `-` + county
parcel ID. Globally unique across all 39 counties, stable across runs, and joins directly
to the answer key. A `row_number()` surrogate would change on every run and break
quarantine references and run-over-run diffs. If a single opaque column is ever needed, use
a deterministic hash of `(county_fips, parcel_id)` — never a row number.

**Parcel IDs are TEXT, permanently.** Spokane's contain a period (`01013.9002`). Any numeric
cast silently destroys leading zeros.

**Geometry is `MultiPolygon`.** Pierce publishes `TaxParcelMultiPartCount`; a `Polygon`
column will reject multipart parcels.

**Stored in 2927 to match the state.** 2927 is the *South* zone and only Pierce is genuinely
in it — King, Snohomish and Spokane are North-zone counties — so this was expected to cost
some area accuracy. Measured against all 1.5M parcels, it does not: the ratio of
geometry-derived acreage to county-reported acreage has a median of 1.0001–1.0007 per county
with p25–p75 inside ±1.7%, including the three northern counties. Area computed in 2927 is
trustworthy here, and the `area_mismatch` flags are genuine outliers rather than projection
artefacts.

**`(county_fips, parcel_id)` uniqueness is expected to fail on first run** — multipart
parcels (Pierce), stacked condos (Snohomish `STACKED`/`FLATTEN`), and retired records all
threaten it. Write the test, let it fail, investigate. The failure is a deliverable.

**Owner and taxpayer fields are never ingested.** Three of the four counties publish them:

| County | Fields | Populated | Distinct |
|---|---|---|---|
| King | `KCTP_ADDR` (taxpayer mailing address) | 625,745 | 503,395 |
| King | `KCTP_ATTN` + `KCTP_CITY/STATE/ZIP/CTYST` | 524,786 | 11,558 |
| Snohomish | `OWNERNAME`, `TAXPRNAME` | 314,439 each | ~263,000 |
| Snohomish | `OWNERLINE1-3`, `TAXPRLINE1-3` + city/state/zip | 314,434 | 247,145 |
| Pierce | `Delivery_Address`, `City_State`, `Zipcode` | 339,910 | — |

Roughly 1.28M mailing addresses and 578,000 personal names. King is the largest by volume,
and **Pierce was the easiest to miss** — its mailing fields carry no `OWNER`/`TAXPR` prefix
to signal what they are, and were initially mapped as situs city and ZIP. Only the
`zip_implausible` flag catching 17,208 out-of-state ZIPs revealed it. A field name that does
not announce itself as PII is still PII.

All lawfully published public record. But bulk-republishing it to a public GitHub repo and a
public Tableau dashboard is a different act than the county making it individually queryable,
and no mapping references an owner field.

Excluded via an `exclude:` list in the manifest, enforced at the **request** level: never
requested, never transmitted, never written to bronze, never reaching the GeoPackage cache.
Dropping the columns after landing would be weaker.

The field *snapshot* still records their names and types from the layer metadata. Names are
not personal data, and keeping them means drift detection continues to see the full published
schema — so a county adding a new owner field remains visible.

Deliberately retained: Pierce's `Business_Name` (commercial premises, materially useful for
land use) and Spokane's `appraiser_id` (a county staff role identifier, 22 distinct values).

---

## 4. Field mappings

Mappings are **expressions, not column names** — that is what lets a uniform manifest absorb
non-uniform sources.

| Target | King (033) | Pierce (053) | Snohomish (061) | Spokane (063) |
|---|---|---|---|---|
| `parcel_id` | `PIN` | `TaxParcelNumber` | `PARCEL_ID` | `PID_NUM` |
| `situs_address` | `ADDR_FULL` | `Site_Address` | `SITUSLINE1` | `site_address` |
| `sub_address` | `UNIT_NUM` | `TaxParcelUnit` | `SITUSUNIT` | `site_apartment` |
| `situs_city` | `CTYNAME` | **null** — not published; `City_State` is the mailing address | `SITUSCITY` | `site_city` |
| `situs_zip5` | `ZIP5` | **null** — `Zipcode` is the mailing ZIP | regex, §5.4 | regex, §5.4 |
| `situs_zip4` | `PLUS4` | **null** | regex, §5.4 | regex, §5.4 |
| `landuse_code_source` | `PREUSE_CODE` | `Use_Code` | `USECODE` | `prop_use_code` |
| `landuse_desc_source` | `PREUSE_DESC` | `Landuse_Description` | `null` | `prop_use_desc` |
| `value_land_appraised` | `APPRLNDVAL` | `Land_Value` | `MKLND` | `land_value` |
| `value_bldg_appraised` | `APPR_IMPR` | `Improvement_Value` | `MKIMP` | `null` |
| `value_basis` | `'appraised'` | `'appraised'` | `'market'` | `'appraised'` |
| `acres_reported` | `KCA_ACRES` | `Land_Acres` | `TAB_ACRES` | `acreage` |
| `is_active` | `"true"` | `"RetiredDate is null"` | `"coalesce(STATUS = 'A', false)"` | `"true"` |
| `source_crs` | `2926` | `2927` | `3857` | `3857` |

### Identifier resolution (verified, not assumed)

Spokane and Snohomish each publish several identifier-shaped columns. Both were resolved by
taking a state `PARCEL_ID_NR`, stripping the FIPS prefix, and matching against each candidate:

- **Spokane** — state `063-01013.9002`. `PID_NUM` and `parcel` both match exactly (count=1)
  and are identical across the sample. `PIDMAP` is a truncated map label (`3.9002`) and
  `ACO_NUM` is blank or unrelated. Use `PID_NUM`; add a test asserting `PID_NUM = parcel`,
  so divergence surfaces as a finding rather than a silent choice.
- **Snohomish** — state `061-32030100401200`. `PARCEL_ID` matches (count=1). `PAR_OID` is an
  internal integer OID; `REVOBJID` was null across the sample.

---

## 5. Derivations that aren't 1:1

### 5.1 `is_active` — Snohomish has a trap

**`RETIREDATE` is populated on all 319,265 Snohomish rows** and is therefore useless as an
active flag. The correct field is `STATUS`, whose distinct values are `A`, `H`, and null.

Use **`coalesce(STATUS = 'A', false)`**, not a bare `STATUS = 'A'`. Under SQL's three-valued
logic `null = 'A'` evaluates to NULL rather than false, so rows with a null status would
produce a NULL `is_active` — violating the `NOT NULL` column, and falling out of *both*
`where is_active` and `where not is_active` since NULL is neither. Every equality-based
`is_active` expression needs the same guard; only `IS NULL` forms are safe bare, because
`IS NULL` is total and never returns NULL.

The obviously-named field is the wrong one. This is exactly the kind of thing that silently
inflates counts and then can't be explained when totals disagree with the state.

- **Pierce** — `RetiredDate` is populated on 223 of 339,910 rows. `RetiredDate is null` works.
- **Spokane** — `eff_to_date` is null on all rows and `seg_status` has one distinct value
  (`Active-Complete`). The layer is pre-filtered to active. `is_active = true`.
- **King** — no status or retirement field exists in this layer. `is_active = true` is an
  **assumption**, and must be labelled as one in the README rather than presented as a fact.

### 5.2 Land use — derivable for three of four counties

Where the state preserved `ORIG_LANDUSE_CD`, the county→state mapping is a clean function:
across 572 distinct county codes (King 128, Pierce 181, Snohomish 263) **zero map to more
than one state code**. So the crosswalk is derived, not authored:

```sql
select distinct fips_nr, orig_landuse_cd, landuse_cd
from {{ ref('stg_state_parcels') }}
where orig_landuse_cd is not null
```

Coverage is thin statewide — only **5 of 39** counties have full `ORIG_LANDUSE_CD` coverage,
6 partial, and **27 have none at all**. Our four span the range:

| County | Rows with original code | `landuse_cd_method` |
|---|---|---|
| King | 635,192 / 635,192 | `derived` |
| Pierce | 339,589 / 339,590 | `derived` (1 row unmapped) |
| Snohomish | 313,997 / 318,594 | `derived` (4,597 unmapped) |
| **Spokane** | **0 / 214,022** | **`unmapped`** |

**Spokane's `landuse_cd` stays null.** No crosswalk is derivable, and inventing one for
214k parcels is worse than a documented null. `landuse_code_source` and
`landuse_desc_source` still carry everything the county published, so nothing is lost about
what the parcel *is* — only the state-taxonomy claim is withheld.

**The description lookup covers only 10 of 39 counties**, and not the ten you would guess.
`County_Unique_Land_Use_Codes` holds 1,931 rows across FIPS 011, 015, 031, 033, 035, 051,
053, 055, 057 and 073 — that is every county which retained `ORIG_LANDUSE_CD`, *except*
Snohomish. The state publishes the lookup only where it kept the original codes, which is
self-consistent apart from that one omission.

For our four counties this inverts awkwardly:

| County | Crosswalk derivable | Description available |
|---|---|---|
| King | yes | yes — lookup, 120 codes |
| Pierce | yes | yes — lookup, 179 codes |
| Snohomish | yes | **no** — absent from lookup, and `USECODE` has no description field in source |
| Spokane | **no** | yes — its own `prop_use_desc` |

Snohomish is the worse case: crosswalkable but unlabellable, with no human-readable land use
meaning available from any published source.

**The labels are published — as coded-value domains in the layer metadata, not as tables.**
The statewide layer carries three, arriving in the same `?f=json` payload as the field list:

| Domain | Field | Values | Supersedes |
|---|---|---|---|
| `DOR_Land_Use_Codes` | `LANDUSE_CD` | 83 | nothing — the only source of labels for the normalized taxonomy |
| `County_Name` | `COUNTY_NM` | 39 | a hand-authored FIPS→name seed; repairs defects 3 and 7 |
| `County_Unique_Land_Use_Codes` | `ORIG_LANDUSE_CD` | 2,193 across **11** counties | `state_landuse_lookup` (1,931 across 10, omitting Snohomish) |

Captured per run into `raw.source_domains`. The county layers publish no domains at all
today; capture is generic so that changes if one starts.

Two consequences worth stating plainly. The domain is a **strict superset of the published
table** — so Snohomish *is* labellable, contrary to what the table alone implies. And the
`County_Name` domain resolves all four multi-word counties correctly spaced, so the
`File_Date` join is repaired by matching space-stripped names against it.

**These are Washington DOR codes, not SLUCM.** They share the 2-digit shape, but the meanings
are WA-statutory in at least part of the range: code 83 is *"Agriculture classified under
current use chapter 84.34 RCW"*, not SLUCM's forestry category. That same RCW 84.34
current-use provision is what produces Snohomish's `CULND`/`CUIMP` fields — the land use code
and the `value_basis` split in §5.3 are one tax mechanism seen from two directions.

**Eight codes in use have no published label.** `LANDUSE_CD` takes 89 distinct values in the
data but the domain defines 83, and `[0, 9, 10, 20, 60, 70, 80, 90]` appear without
definitions — six are round decades, i.e. SLUCM group headers rather than specific uses,
presumably assigned where a county reported only at the coarse level. Conversely `38` and
`87` are defined but unused. See defect 8.

Resolved by `int_landuse_labels`, which unions the captured domain with a small seed
(`landuse_code_fallback_labels`) supplying SLUCM group names for the eight:

| Column | Meaning |
|---|---|
| `label` | as published, for fidelity against the source |
| `label_short` | leading `'NN - '` stripped, so DOR and fallback labels format alike |
| `label_source` | `dor_domain` (83) or `slucm_fallback` (8) |

**Published labels always win.** The fallback applies only where the domain is silent, so if
DOR later defines code 80 the source flips automatically and the seed steps aside.

`label_source` is not decoration. Applying SLUCM group names here is an **inference, not a
lookup** — DOR codes are not pure SLUCM, as code 83 demonstrates. Anything built on a
`slucm_fallback` label inherits that caveat, and the column is what makes it visible. This is
also a legitimate `ours_better` entry: we label codes the authoritative source leaves
undefined, and we say which labels are inferred.

*v2 stretch:* propose a Spokane crosswalk by fuzzy-matching `prop_use_desc` against the
lookup's descriptions using `pg_trgm` / `fuzzystrmatch` — both already installed in
`01_init.sql` and currently unused. Note the chain is one hop longer than it first appears,
since Spokane is not itself in the lookup: match Spokane's descriptions against *other*
counties' descriptions, then follow those counties' codes through the derived crosswalk to
the state code. Store the result as a **reviewed seed with a confidence column**, never as a
runtime join.

### 5.3 Values — four concepts, one column name

A column called `land_value` would silently average four different things:

- **King** publishes appraised *and* taxable (`APPRLNDVAL`/`TAX_LNDVAL`)
- **Pierce** publishes appraised, with `Taxable_Value` separate
- **Snohomish** publishes market *vs.* current-use (`MKLND`/`CULND`) — current-use applies to
  ag and forest land under WA's current-use taxation
- **Spokane** publishes `land_value` and `assessed_amt`, but **no building value**

We take the appraised/market figure and record which in `value_basis`. Spokane's building
value is *derivable* as `assessed_amt - land_value`, but that is our inference, not their
published number — so it stays null rather than being silently computed.

### 5.4 ZIP codes — three counties publish a mixed field

Only King splits the ZIP properly, into clean `ZIP5` and `PLUS4` columns. The other
three pack both into one field, inconsistently:

| County | Field | Dominant form | Also observed |
|---|---|---|---|
| Pierce | `Zipcode` | `98108-2743` (1,740 / 2,000 sampled distinct) | bare `98402` |
| Snohomish | `SITUSZIP` | `98036-8437` (1,984 / 2,000) | bare `98036`; malformed `982037-870` |
| Spokane | `site_zip` | `99001-9006` | `00000`, `99000-`, `99003--`, `599223`, `0000` |

A naive `left(field, 5)` gets ZIP5 mostly right but silently discards every ZIP+4 —
which is real data for the large majority of rows in two of the three counties.

Anchored regex extraction, applied identically to all three:

```sql
substring(trim(<field>) from '^([0-9]{5})')             as situs_zip5
substring(trim(<field>) from '^[0-9]{5}-([0-9]{4})$')   as situs_zip4
```

`[0-9]` rather than `\d` deliberately: it keeps the expressions backslash-free so
they survive YAML parsing as ordinary double-quoted strings, with no escaping.

The `$` anchor on the ZIP+4 pattern is what makes this safe — a suffix is taken
only when the *whole* value is well-formed, so partial and corrupt forms become
null instead of propagating garbage. Verified against the real values:

| Input | `situs_zip5` | `situs_zip4` |
|---|---|---|
| `98108-2743` | `98108` | `2743` |
| `98402` | `98402` | null |
| `982037-870` | `98203` | null — corruption not propagated |
| `99000-` / `99003--` | `99000` / `99003` | null |
| `0000` | **null** — too short to be a ZIP5 | null |
| `00000` | `00000` | null |
| `599223` | `59922` | null |

**Conformance extracts structurally; it does not judge plausibility.** `00000`
survives as a literal ZIP5, and `599223` becomes `59922` — a Montana prefix.
Situs addresses are physical Washington locations, so anything outside
980xx–994xx is definitionally wrong, but that assertion belongs in the quality
layer and the quarantine report, not in the mapping. Keeping the two separate is
what lets the scorecard *count* bad ZIPs per county instead of silently erasing
them.

### 5.5 Value comparison — drift, and the King condominium grain split

`value_land` / `value_bldg` disagree with the answer key on a large share of
parcels. Two distinct causes, separated by measurement, and only one is a
finding.

**Expected drift (Pierce, Snohomish, Spokane).** The answer key is 166–216 days
behind the counties (measured publisher-to-publisher, `int_source_vintage` vs
`int_county_vintage`), and WA counties revalue annually, so assessed values
*must* differ. The ratio of ours/theirs on disagreeing parcels is tight and
directional — Pierce median 0.977, Snohomish 1.098, Spokane 1.083 — which is
what ~200 days of appreciation looks like, not a basis mismatch. These fields
carry `drift: true` in `comparable_fields()`, so they receive a per-field status
but do not force `both_differ`. Letting them classify would mark nearly every
parcel as differing and bury the real findings: 1,204,678 `both_differ` before,
42,790 after (the rest of that drop is city casing, below).

**A real finding (King).** King's ratio does not fit drift at all — median
**0.193** on the 1.1% of parcels that disagree. Broken out by `PROPTYPE`:

| proptype | disagree | total | % | median ratio |
|---|---|---|---|---|
| **K** | **5,095** | 5,242 | **97.2%** | **0.143** |
| R | 1,088 | 572,891 | 0.19% | 0.572 |
| C | 822 | 43,043 | 1.91% | 0.601 |

**73% of King's value disagreements are one property class.** `PROPTYPE = 'K'`
is condominium — 4,681 `Condominium(Residential)`, 332 `Condominium(Mixed Use)`,
plus apartments. The 5,746 K parcels carry 5,746 *distinct* MAJORs, average 1.24
acres and $612,818 land value: these are **complex-level** records, not units.

So this is an **aggregation-grain** difference, not a valuation-basis one. King
publishes the whole condominium's land value; the state carries something
unit-scaled, and 0.143 ≈ 1/7 is a plausible average units-per-complex divisor.
That matters for how the B3 gate is framed: for King the question is not "which
basis is `VALUE_LAND`" but "at what grain". Snohomish's and Spokane's systematic
+8–10% remains a separate, open question.

Residential agreeing 99.81% of the time is the control that makes the K class
legible as an anomaly rather than as general noise.

### 5.6 Text comparison is case-insensitive

`situs_city` "disagreed" on 489,880 King parcels — `Bellevue` vs `BELLEVUE`.
King publishes `CTYNAME` in title case and the state upper-cases it. Normalising
drops that to **8,175** real differences.

`compare_expr()` upper-cases and trims text fields for the equality test only;
the fact stores and displays the raw values from both sides. Normalise for the
comparison, preserve for the evidence — the same split as `label` /
`label_short` on `int_landuse_labels`.

### 5.6b Two fields that are not the same field

Two of the largest apparent disagreement classes turned out to be comparisons
between columns that never measured the same thing. Both were found by looking
at the values rather than the counts.

**`sub_address` — unit designator vs complex name.** Ours holds the unit
(`39 A`, `3`); the state's holds the **condominium complex name**
(`WEST MEEKER CONDO`, `MAYFAIR PLACE CONDO`). Measured on Pierce: 98.4% of the
state's values begin with a letter against 75.6% of ours beginning with a digit.
This accounted for **13,142 of Pierce's 14,493 differences — 91%**, every one an
artifact. Marked `incomp: true` in `comparable_fields()`; both values are still
carried, only the classification excludes it. Pierce agreement moved 95.19% →
**99.13%**.

**`situs_city` — postal city vs incorporated jurisdiction.** King's `CTYNAME` is
the jurisdiction; the state's `SITUS_CITY_NM` is the USPS postal city:

| ours | theirs | parcels |
|---|---|---|
| Burien | SEATTLE | 4,347 |
| Covington | KENT | 663 |
| Tukwila | SEATTLE | 435 |
| Newcastle | RENTON | 280 |

Burien, Tukwila and Newcastle are their own cities carrying Seattle/Renton
postal addresses. The 42,659 parcels where we are null and they are populated
are **unincorporated** King County with postal cities of Redmond, Woodinville
and Vashon — Vashon is not a city at all.

**This is why the 83,867-parcel `situs_city` coverage deficit must NOT be
closed.** Our null is correct: an unincorporated parcel has no jurisdiction
city. Deriving one would mean adopting postal semantics, which would then
disagree with the jurisdiction values on the 8,175 where the two genuinely
differ — trading a documented gap for a correctness problem.

Unlike `sub_address` the field is not wholly incomparable: where a parcel IS
incorporated the two usually coincide, and they agree on ~98.5% of King parcels
carrying both. So it stays classifying, and the postal-vs-jurisdiction split is
a **declared deviation** rather than an unexplained delta.

**The scalable lesson.** A county-specific fix — parsing King's `ADDR_FULL` for
a city — would close 42,659 gaps and be worthless at county #5. The
metadata-driven question is not "how do we populate city" but "**which concept
does each source publish**", which belongs in the manifest as a per-field
semantic declaration, exactly as `value_basis` already declares
appraised-vs-market. Comparing two fields that share a name but not a definition
is the failure mode; a name is not a semantic.

### 5.7 Area validation

All four counties publish their own acreage, which gives a free geometry check: reproject,
compute area, compare to `acres_reported`.

Two subtleties. Spokane and Snohomish publish in Web Mercator, so their `Shape__Area` is a
Web Mercator area — inflated roughly 2× at Washington's latitude and unusable. And for
Snohomish use **`TAB_ACRES`**, not `GIS_ACRES`: `GIS_ACRES` is computed from the geometry, so
comparing it to geometry-derived area is circular. `TAB_ACRES` comes off the tax roll and is
independent.


### 5.8 Parcel overlap — detected and classified, never repaired

**The decision: overlaps are reported, not fixed.** This is a deliberate scope
boundary, and worth stating explicitly because declining is the defensible call.

Three reasons:

1. **Repairing would invent boundaries.** Resolving an overlap means deciding
   which parcel is authoritative and clipping the other. That is a cadastral
   judgment made from deeds and surveys by the county assessor. Nothing in the
   published attributes says which edge is correct, so any automated fix
   fabricates a boundary no source asserts.
2. **It would manufacture a false `ours_better`.** The state carries the
   identical overlaps — 356,489 against our 356,470 in a sampled 5-mile box of
   Snohomish, a 0.005% difference attributable to vintage. Clipping them would
   create a systematic divergence from the answer key that we would then have to
   defend as an improvement, when it is invention. Same failure mode as the
   Pierce `City_State` retraction (§9).
3. **Some overlaps are correct.** Easements, air rights, tidelands, PLSS
   discrepancies and vertical stacks are all legitimate. Distinguishing those
   from errors requires the deed.

**The line this draws against geometry repair**, which the pipeline *does*
perform: `ST_MakeValid` fixes a malformed **representation of a known intent** —
a self-intersecting ring has one obviously-intended shape and repair recovers it
deterministically. An overlap is a **semantic disagreement between two records**,
each individually valid. There is no intent to recover, only a conflict to
report. The pipeline repairs representation errors and reports semantic
conflicts.

#### Classification is by geometry ratio, not by the stacking flag

`is_stacked` normalizes a concept the counties encode incompatibly: Pierce marks
vertical components with `taxparcellevel <> 0` on a **shared** parcel number
(25,642 records), Snohomish with a `STACKED` flag on records that each carry
their **own** `PARCEL_ID` (42,204 records). King and Spokane publish no indicator
and are blanket false.

That same physical structure therefore surfaces two different ways, and the state
inherits both without reconciling: Pierce's stacking is visible in **duplicate
keys** (6,769 groups, which the state also carries), Snohomish's only in
**overlapping geometry**. A schema normalized on field names does not normalize
this.

Measured in a 5-mile sample box, ratio = intersection ÷ smaller area:

| pair kind | partial (<0.8) | 0.8–1.0 | contained (1.0) |
|---|---|---|---|
| both stacked | **0** | 138,341 | 213,940 |
| one stacked | 563 | 732 | 1,674 |
| neither | 355 | 277 | **588** |

Stacking implies coincidence with **zero exceptions** across 352,281 pairs — but
coincidence does not imply a stacking flag, as the 588 unflagged fully-contained
pairs show. So the classifier keys on ratio and `is_stacked` explains rather than
gates:

- `coincident` (ratio ≥ 0.8) — co-located records; not a boundary defect.
  `unflagged_coincident` isolates the 588-class as its own finding.
- `encroachment` (ratio < 0.8) — the quality signal; 918 pairs in the box.

**This is what keeps a stacked parcel comparable to its neighbours.** A blanket
`NOT (a.is_stacked OR b.is_stacked)` exclusion would have discarded all 563
one-stacked encroachments and reported the 588 unflagged pairs as errors. Same
principle as `value_basis` and `landuse_cd_method`: carry the provenance column,
do not filter on it.

#### Cost

`int_parcel_overlaps` is the project's expensive model, tagged `expensive` so
routine builds run `--exclude tag:expensive`. Snohomish dominates: 13.75 average
acres against King's 2.20 means larger bounding boxes and ~9.0M candidate pairs
from half the rows (King ~1.7M, completing in ~5 min). Two remedies were tested
and **rejected**, with measurements in build-plan A6: `ST_Subdivide` (splits on
vertex count, but Snohomish is large not complex — forcing it expanded 314,670
records into 3,031,020 pieces and made the join worse) and 1-mile spatial tiling
(**26× worse** — 237,892,264 intra-cell pairs against 9,001,941 from the GiST
index, because joining on cell equality short-circuits the spatial index).

The `ST_Relate 'T********'` predicate — interior-interior intersection, so a
shared lot line does not qualify — removes ~40% of candidates before the far more
expensive `ST_Intersection`.

---

## 6. dbt model shape

```
raw (bronze)          raw.parcels_king, raw.parcels_pierce, ...      ALL source fields
                      raw.state_parcels, raw.state_file_date,
                      raw.state_landuse_lookup, raw.source_field_snapshot
        │
staging (silver)      stg_parcels__king      ← one thin file per county
                      stg_parcels__pierce       (each is a single macro call)
                      stg_parcels__snohomish
                      stg_parcels__spokane
                      stg_parcels            ← union; everything below is county-agnostic
                      stg_state_parcels
        │
intermediate          int_landuse_crosswalk  ← derived from the answer key
                      int_parcels_conformed  ← crosswalk applied, validation flags set
        │
marts (gold)          dim_parcel                 one row per parcel
                      fct_parcel_reconciliation  parcel × source, ours vs theirs, delta
                      agg_quality_scorecard      county × rule × pass/fail  → Tableau
                      agg_quarantine_summary     reason × county × count
                      bi_parcel_extract          simplified 4326 geometry, denormalized
        │
quarantine            quarantine.parcels_rejected  rejected rows + reason + source metadata
```

**Bronze keeps every source field** — all 69 King, 54 Snohomish, 43 Spokane, 35 Pierce.
Narrowing to 13 at extract time destroys the ability to answer "why does the state say X
here" without re-downloading.

**Silver is the answer-key contract.** `stg_parcels` conforms field-for-field to the state's
schema so the diff is a join, not a mapping exercise. Postgres folds unquoted identifiers to
lowercase, so their `PARCEL_ID_NR` becomes `parcel_id_nr` naturally — 1:1 names, no quoting.

**Gold is the analysis of the conformance, not the parcels.** The conformed parcel table is
silver and stays silver even though it is publishable — being a deliverable doesn't promote a
table. Every gold model above either changes grain or serves a specific consumer.

### Per-county staging models are one line each

```sql
-- models/staging/stg_parcels__pierce.sql   (the entire file)
{{ conform_parcels('053') }}
```

`conform_parcels` reads the manifest and emits `select <expr> as <target>, ...` plus the
uniform work: `ST_Transform` to 2927, `ST_IsValid` flagging, trimming, metadata columns.

Adding a county = one manifest block + one one-line file. Collapsing this into a single
looping model would mean fewer files but would cost the three things that matter: each
county is its own DAG node (which is what the dbt docs screenshot shows a reviewer), each
can be tested and `--select`ed individually, and one county's failure is one red node rather
than a dead pipeline.

### The manifest

Lives under `vars:` in `dbt_project.yml` — dbt reads it at parse time, and the Python
extractor `yaml.safe_load`s the same file. One source of truth, no codegen, no drift between
what gets pulled and what dbt expects.

```yaml
vars:
  counties:
    "053":
      name: Pierce
      item_id:     81a83fb925654e92a544036d39a1f3f2
      service_url: https://services2.arcgis.com/1UvBaQ5y1ubjUPmd/arcgis/rest/services/Tax_Parcels/FeatureServer
      layer_id:    0
      portal_url:  https://gisdata-piercecowa.opendata.arcgis.com/datasets/81a83fb925654e92a544036d39a1f3f2_0
      source_crs:  2927
      map:
        parcel_id:   TaxParcelNumber
        situs_city:  "split_part(City_State, ',', 1)"
        value_land_appraised: Land_Value
        value_bldg_appraised: Improvement_Value
        situs_zip4:  null          # explicit: not published
        is_active:   "RetiredDate is null"
      allow_null:
        sub_address: "TaxParcelUnit is populated only for condo and multi-unit parcels"
```

The top half drives extraction; the bottom half drives dbt.

**`map` values are SQL; `allow_null` values are prose. Nothing infers this from content —
the key decides.** The macro interpolates `map` values into the query verbatim and reads only
the *keys* of `allow_null` to suppress tests; reason strings are documentation and never
reach SQL. Because interpolation is verbatim, `map` is effectively config-injected SQL — which
is what makes the drift test (§7) load-bearing rather than decorative: asserting every mapped
column exists in the source field snapshot catches a typo before it becomes a confusing
compile error.

**Two typing rules follow:**

- **Unquoted YAML `null` means "not supplied"** — it parses to `None`, so the macro branches
  on `{% if expr is none %}`. Every other value is a **quoted string**, including `"true"`, so
  that `map` values are uniformly strings and YAML type coercion never surprises the macro.
- **The macro casts every expression to the canonical type** — `{{ expr }}::{{ type }} as
  {{ field }}` — not just the nulls. A bare `null` has unknown type and can fail resolution
  against a `text` branch of the union, and a value that is `integer` in one county and
  `bigint` in another resolves silently but inconsistently. Casting makes §3 the single
  authority on types, with every county conforming by construction.

**Endpoint fields are split three ways on purpose.** `service_url` + `layer_id` rather than
one concatenated URL, because the state service exposes three addressable objects off one
root (layer 0 = parcels, table 1 = `File_Date`, table 2 = `County_Unique_Land_Use_Codes`).
`item_id` is the resilient pointer — service URLs embed an org hash
(`services2.arcgis.com/1UvBaQ5y1ubjUPmd/`) that changes if a county migrates ArcGIS orgs,
whereas the item ID doesn't and resolves to the current service URL via
`arcgis.com/sharing/rest/content/items/<id>?f=json`. Hit `service_url` on the fast path; fall
back to re-resolving from `item_id` on failure. `portal_url` is the human-facing citation for
the README and is never fetched by code.

**Pagination is by OBJECTID range, not resultOffset.** `maxRecordCount` is still
discovered from the same `?f=json` response (King caps at 1000, the others at 2000) and used
as the window width, but windows are `OBJECTID >= a AND OBJECTID < b` rather than offset
slices.

This was not a preference. Offset paging makes the service skip N rows to reach the window,
so cost grows with depth: measured on the statewide layer at offset 2,980,000, an offset
query took **32.51s** against **1.13s** for the equivalent OBJECTID range — 29x. With four
workers issuing deep offset queries concurrently the service began returning generic
"Unable to perform query" errors, and full statewide loads failed twice at 2.6M and 3.0M
rows after 70+ minutes each. Switching to ranges cut the run to minutes and produced **zero**
transient failures.

Two correctness properties follow, both of which offset paging lacked:

* **A window cannot be silently truncated.** OBJECTIDs are unique, so a range of width
  `page_size` holds at most `page_size` rows and the server never has cause to trim it.
  Offset paging had the opposite hazard — request 2000 from a service capped at 1000 and you
  receive 1000 with no error, and an offset advanced by 2000 skips half the layer.
* **Coverage is total by construction.** Disjoint ranges tiling `[min, max]` account for
  every row whether or not OBJECTIDs are contiguous; gaps yield short pages, which is
  expected rather than a fault.

The total-count check after the final page remains the guard that both hold.

If 39 counties makes `dbt_project.yml` unwieldy, move to a standalone `manifest.yml` and pass
it with `dbt run --vars "$(cat manifest.yml)"`.

---

## 7. Tests

**Uniform, on `stg_parcels`:** `parcel_uid` unique + not_null; `county_fips` accepted values;
`landuse_cd` in the 89-value state domain; `geom` not null and `ST_IsValid`; `source_crs` in
`(2926, 2927, 3857)`.

**Coverage-aware, derived from the manifest — not from a parallel list.** A blanket
`not_null` on `situs_address` is wrong, since some counties don't publish one. But an
explicit `supplies:` list alongside `map:` would be redundant with it and a second thing to
keep in sync. Expectations are derived from the mapping itself:

| Manifest state | Meaning | Test generated |
|---|---|---|
| field absent from `map` | not supplied | none |
| mapped to literal `null` | not supplied, deliberately and visibly | none |
| mapped to a real expression | we are claiming this field is populated | `not_null` for that county's rows |
| listed in `allow_null` | mapped but genuinely sparse | none; **reason string is mandatory** |

Mapping a field is therefore an assertion that it works, and every exception has to be
written down. A county that never promised an address doesn't fail; one that promised and
delivered nulls does.

**Drift detection.** The extractor already reads `/FeatureServer/0?f=json` for CRS and page
size; that response includes the full field list. Snapshot it into
`raw.source_field_snapshot` and test that it still matches the manifest — mapped field
vanished, new field appeared, type changed, **CRS changed**. Roughly twenty lines, and it
converts "breaks silently three weeks later" into "CI goes red the morning the county
republished." Handling drift automatically is out of scope; detecting it loudly is the
whole job.

The `unique` test on `int_landuse_crosswalk (fips, orig_landuse_cd)` is drift detection too —
if it fails, the state changed their normalization.

**Known limitation:** dbt handles partial failure poorly. If `stg_parcels__spokane` errors,
everything downstream of the union is skipped — there's no clean native "union whatever
succeeded." Per-county models limit the blast radius to one node. This is a legitimate
motivation for orchestration in v2, rather than adding Airflow as résumé decoration.

---

## 8. Reconciliation against the answer key

`fct_parcel_reconciliation` joins `dim_parcel` to `stg_state_parcels` on `parcel_uid` and
classifies every parcel:

- present in both, all mapped fields agree
- present in both, ≥1 field disagrees (with per-field delta)
- ours only — the state is missing a parcel the county publishes
- theirs only — includes the 2,563-parcel King layer discrepancy and the 13,629 null-FIPS rows

Every row carries `source_file_date` for both sides, so vintage gaps are visible rather than
being mistaken for real disagreement.

---

## 9. Defects found in the answer key

Running list. This section will do more for the README than the architecture diagram.

1. **`FIPS_NR` is null for 100% of one county.** All 13,629 null-FIPS rows are Asotin:
   every one carries a populated `PARCEL_ID_NR` prefixed `003-` and `COUNTY_NM` `'3'`, and
   the layer holds **zero** rows with `FIPS_NR = '003'`. These are not parcels belonging to
   no county — they are one county whose FIPS column was never populated, recoverable from
   two other columns the state does fill. It is also why the layer reports 38 FIPS groups
   rather than 39.

   `stg_state_parcels` recovers the value before applying the manifest scope. Filtering on
   the raw column drops all 13,629 silently, since SQL `NULL` never matches `IN` — and the
   reconciliation's `theirs_unidentified` bucket would then hold only the null-`PARCEL_ID_NR`
   rows inside our counties (4,587), not the class the ledger accounts for.
2. **Null `PARCEL_ID_NR`** — found in a 3-row Pierce sample, so not rare. Our schema makes
   this column `NOT NULL` and routes violations to quarantine. Being stricter than the
   authoritative source is a finding, not a deviation to apologise for.
3. **`COUNTY_NM` is `String(12)` but contains FIPS codes**, not names (`'33'`, `'53'`).
4. **`ORIG_LANDUSE_CD` discarded for 27 of 39 counties**, making their own normalization
   unauditable for most of the state.
5. **King publishes two parcel layers that disagree by 2,563 parcels.**
6. **Counties are not the same vintage** — sampled `File_Date` values span six weeks.
7. **`File_Date.COUNTY_NM` mixes codes and names, and the failure is diagnosable.**
   35 of 39 rows hold an unpadded FIPS code (`'1'`, `'11'`); four hold a name:
   `GraysHarbor`, `PendOreille`, `SanJuan`, `Walla Walla`. The FIPS codes absent from
   the numeric rows are exactly 027, 051, 055 and 071 — which are Washington's only
   four multi-word county names, all of them.

   So the process populating this column resolves name → FIPS by lookup, and the
   lookup fails on multi-word names, letting the raw name fall through. The fallback
   is not even self-consistent: three have their spaces stripped while `Walla Walla`
   retains its own, implying two code paths.

   Practical impact: joining `File_Date` needs `lpad(county_nm, 3, '0')` *and* a
   name → FIPS mapping for those four. Our four counties are all numeric, so the
   vintage join works today and breaks at statewide scope. Repaired by matching
   space-stripped names against the published `County_Name` domain (§5.2) — no
   hand-authored seed required.
8. **8 of the 89 `LANDUSE_CD` values in use are absent from the layer's own
   `DOR_Land_Use_Codes` domain** — `[0, 9, 10, 20, 60, 70, 80, 90]`. Roughly 9% of the
   values in their normalized column fall outside their own declared vocabulary.
**Investigated and dismissed as a defect:** the state's `SITUS_CITY_NM` and `SITUS_ZIP_NR`
are null for all of Pierce. That looked like their largest single gap and our largest
`ours_better` entry — until the `zip_implausible` flag surfaced 17,208 non-Washington ZIPs in
our own Pierce output. Pierce's `City_State` and `Zipcode` belong to the `Delivery_Address`
group, which is the **taxpayer mailing address**: PO boxes and out-of-state values
(TIMNATH CO, GEARHART OR, KNOXVILLE TN) on parcels physically in Pierce County, differing
from `Site_Address` on 133,983 of 339,910 rows.

Pierce publishes a situs street address and nothing else locational. The state leaving city
and ZIP null is **correct**, and mapping the mailing fields into situs columns was our error.
Corrected in §4; the fields are now excluded as PII alongside King's `KCTP_*` and Snohomish's
`TAXPR_*`.

The lesson generalises: a field named for a place is not necessarily the *parcel's* place.
Check whether an address group is situs or mailing before mapping any part of it.

Also worth noting, in our sources rather than the state's: **Snohomish has 4,595 rows with a
null `PARCEL_ID`**. Measured against the full conformed load, these are not scattered bad
rows — they are a coherent class:

| `is_active` | null `parcel_uid` | rows |
|---|---|---|
| false | **true** | 4,595 |
| false | false | 231 |
| true | false | 314,439 |

**Every null-ID row is inactive, and no active parcel lacks an ID.** They also carry no owner
data — the 314,439 active rows match the `OWNERNAME` populated count exactly. So these are
void or placeholder records rather than parcels with missing identifiers, which makes the
quarantine rule narrower than feared: filtering on `is_active` removes all of them, and
quarantine only needs to *account* for them rather than repair them.

Still close enough to the 4,597 Snohomish rows missing `ORIG_LANDUSE_CD` in the state layer
(a difference of 2) to be the same underlying set propagating upstream.

---

## 10. Open questions

- **RESOLVED** — Snohomish's 4,595 null-`PARCEL_ID` rows are entirely contained within the
  inactive set, and carry no owner data. See §9. Whether they are the *same* rows as the
  4,597 missing `ORIG_LANDUSE_CD` in the state layer still needs a join to confirm.
- **OPEN** — Does `(county_fips, parcel_id)` hold as a unique key once multipart and stacked
  parcels are included? Expected to fail; the investigation is the deliverable.
- **OPEN** — King has no retirement field. Confirm whether `PARCEL_ADDRESS_PUB_AREA_3069` is
  pre-filtered to active parcels, or whether retired parcels are silently included.
- **OPEN** — Is `landuse_cd` genuinely a published standard (the value pattern and 0–99 range
  suggest a standard 2-digit land use classification), or state-specific? Affects how the
  taxonomy is described in the README.
- **OPEN** — Confirm the state's `SITUS_ZIP_NR` (`String(10)`) never carries ZIP+4; if it
  does, `situs_zip5`/`situs_zip4` need splitting on the state side too.
