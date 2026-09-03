{{ config(
    materialized='table',
    post_hook="create index if not exists idx_bi_geom on {{ this }} using gist (geom)"
) }}

{#
    The map-facing extract: dim_parcel reprojected to WGS84 and simplified
    for browser-side rendering. One row per published record -- the same grain
    as dim, deliberately. This is a PRESENTATION projection of the dimension,
    not a second contract: every column here is reproducible from dim, and
    this model can be dropped and rebuilt at any time without losing anything.

    PRESENTATION-FILTER DECISION: everything is included -- attribute-less
    components, stacked units, zero-value allocation records. The King tracts
    decision (docs/design-history.md A3b) was to keep a parcel registry complete
    and let consumers filter; a public map that silently omitted 9,231
    King records would be the map’s editorial choice, not the pipeline’s.
    Dashboards filter on is_active / value presence as their story needs.

    SIMPLIFICATION: ST_SimplifyPreserveTopology with
    var(’simplify_tolerance’, 0.00001) degrees (~1 m at this latitude).
    Deliberately conservative -- the smallest published components (Pierce’s
    167 sqft parking stalls) are ~4 m across, so an aggressive tolerance
    would erase exactly the records the duplicate investigation found
    meaningful. Vertices drop where it matters (large rural parcels);
    small lots pass through essentially untouched.

    NOTE: plain st_simplify here would be a bug -- Douglas-Peucker collapses
    polygons whose vertices all fall within the tolerance, and returns NULL
    for the ring (measured: 1,060 tiny parcels -- 6-261 sqft, 4-6 vertices --
    silently vanished from the extract on the first build). PreserveTopology
    returns the original geometry instead. If a null geom ever reappears in
    this table, a simplification function changed underneath us.

    PRIVACY: safe by construction, not by filtering -- owner and taxpayer
    fields were never ingested (design.md §4), so there is nothing here to
    redact. The extract is regenerable from dim at any time.
#}

select
    record_key_uid,
    parcel_uid,
    county_fips,
    county_name,
    is_active,
    is_stacked,
    situs_address,
    sub_address,
    situs_city,
    situs_zip5,
    landuse_cd,
    landuse_cd_method,
    landuse_desc_source,
    value_land_appraised,
    value_bldg_appraised,
    value_basis,
    acres_reported,
    source_record_count,

    st_simplifypreservetopology(
        st_transform(geom, 4326),
        {{ var('simplify_tolerance', 0.00001) }}
    ) as geom

from {{ ref('dim_parcel') }}
