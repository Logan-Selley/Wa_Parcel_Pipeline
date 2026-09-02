{{ config(materialized='table') }}

{#
    One row per PUBLISHED RECORD: record_key_uid (A3b grain).

    Grouping by the pair does exactly two things, nothing else:

      1. collapses rows the county published more than once with identical
         attributes (true duplicates), and
      2. unions the geometry of rows published as multiple pieces of one
         record (multipart parcels -- King's own 439 layer ships 012605TR-A
         as three features).

    A3b: the grain is record_key_uid ALONE -- the county's own record
    hierarchy (parcel, unit, unit_type, level). record_signature is retained
    as provenance but is out of the grain, so the 234 residual key-groups
    that differ only by signature now merge.

    Measured, and the reason summing is lossless rather than lucky:
      * 229 of 234 groups carry exactly ONE value-holder; 0 carry more than
        one; the remaining 5 carry no values and no acres. So sum() over
        land/bldg/acres returns the single holders figure -- the zero-valued
        shells contribute nothing.
      * Across every other conformed column -- address, sub_address, city,
        zip5, landuse code and description, is_active, value_basis -- ZERO
        groups diverge. min() is therefore not choosing a winner; there is
        nothing to choose between.
      * Only geometry diverges (202 groups), which is exactly what
        st_union is here for.

    source_record_count is the provenance for every merge, and the A4 canary
    reconciles staged = SUM(source_record_count) over conformed + rejected
    through it.

    Why min() is still sound after A3b widened the groups: measured across
    all 234 residual key-groups, zero diverge on any non-value column, so
    min() returns the single common value rather than picking a winner. The
    columns that DO diverge are handled deliberately -- values by sum()
    (single holder), geometry by st_union(). A future column that is neither
    invariant within a key-group nor explicitly aggregated would be silently
    arbitrary; the record_key_uid unique test and the count-based canary are
    what catch that.
#}

with repaired as (

    select * from {{ ref('int_parcels_repaired') }}

),

unioned as (

    select
        record_key_uid,
        min(parcel_uid)            as parcel_uid,
        min(county_fips)           as county_fips,
        min(county_name)           as county_name,
        min(parcel_id)             as parcel_id,
        min(parcel_id_raw)         as parcel_id_raw,
        bool_or(is_active)         as is_active,
        {#  bool_or: a merged record is stacked if any component it absorbed
            was. Invariant within a key-group in practice, but bool_or states
            the intent rather than relying on that. #}
        bool_or(is_stacked)        as is_stacked,
        min(situs_address)         as situs_address,
        min(sub_address)           as sub_address,
        min(situs_city)            as situs_city,
        min(situs_zip5)            as situs_zip5,
        min(situs_zip4)            as situs_zip4,
        min(landuse_code_source)   as landuse_code_source,
        min(landuse_desc_source)   as landuse_desc_source,

        {#  sum(), not min(): exactly one record per group holds values and the
            rest are zero-valued shells (measured, zero exceptions), so the sum
            IS the holders figure. sum() of all-nulls stays null, which is the
            correct answer for the 5 value-less groups. #}
        sum(value_land_appraised)  as value_land_appraised,
        sum(value_bldg_appraised)  as value_bldg_appraised,
        min(value_basis)           as value_basis,

        {#  acres_reported is a PARCEL-level measure stated once on the valued
            record, while the unioned geometry covers only the built components.
            Summing recovers the parcel figure; the resulting acres-vs-area
            mismatch on merged records is a grain difference, not a defect --
            see docs/build-plan.md A3b. #}
        sum(acres_reported)        as acres_reported,
        min(source_layer_url)      as source_layer_url,
        min(source_crs)            as source_crs,
        min(ingested_at)           as ingested_at,
        st_multi(st_union(geom))   as geom,
        bool_or(geometry_repaired) as geometry_repaired,
        count(*)                   as source_record_count,

        {#  Out of the grain as of A3b, kept for provenance. min() over a group
            that merged two variants is an arbitrary pick of one -- use
            source_record_count, not this, to detect a merge. #}
        min(record_signature)      as record_signature
    from repaired
    group by
        record_key_uid,

        {#  The null-key guard. record_key_uid is null exactly on the quarantine
            path (no parcel id), and SQL GROUP BY puts every NULL in ONE group --
            so grouping by the key alone would collapse all 4,598 rejected rows
            into a single row and destroy the quarantine. This expression is a
            constant NULL for real keys (so they group by key alone, which is
            A3b) and falls back to the signature for null keys (preserving the
            pre-A3b quarantine behaviour exactly). #}
        case when record_key_uid is null then record_signature end

)

select
    record_key_uid,
    record_signature,
    parcel_uid,
    county_fips,
    county_name,
    parcel_id,
    parcel_id_raw,
    is_active,
    is_stacked,
    situs_address,
    sub_address,
    situs_city,
    situs_zip5,
    situs_zip4,
    landuse_code_source,
    landuse_desc_source,
    value_land_appraised,
    value_bldg_appraised,
    value_basis,
    acres_reported,
    source_layer_url,
    source_crs,
    ingested_at,
    geom,

    -- Post-union validity: reprojection taught us that source validity is not
    -- stored validity, and unioning is one more transformation with the same
    -- property. A merged parcel is valid iff its unioned geometry is.
    coalesce(st_isvalid(geom), false) as geometry_valid,

    -- Post-union "no geometry": st_union skips nulls, so a null result means
    -- every merged record lacked geometry. A group whose union came out EMPTY
    -- (ST_MakeValid yielding no polygons) is not "missing" -- it had geometry
    -- that repair destroyed -- and the geometry_unrepairable rejection rule
    -- catches it instead, preserving the distinction the two reasons exist for.
    (geom is null) as source_geom_missing,

    geometry_repaired,
    source_record_count

from unioned
