{{ config(materialized='table') }}

{#  The WIDE scorecard: one row per county, headline rates as columns.

    A pure PROJECTION of agg_quality_scorecard — every number here is
    computed FROM the long-format table, not recomputed from base relations.
    The long table stays the single source of truth; if a check's definition
    changes, this view follows it without a second implementation to keep
    honest.

    The pivot uses max(case when outcome = X then parcels end) because the
    long table holds several outcomes per (county, check) — this shape picks
    the outcome each headline wants. Any check NOT named here simply doesn't
    appear in the wide view; adding one means adding its columns here, which
    is the deliberate cost of a fixed contract for BI.

    One wrinkle: merge_provenance's merged_source_rows needs the source rows
    summed per merge class, which the long table does not carry — so it is
    pulled from the conformed relation directly (the only number in this
    model that does not come from the long table, and it is the A4 canary's
    own arithmetic: conformed expansion = staged - rejected expansion).
#}

with pivoted as (

    select
        county_fips,
        county_name,

        -- geometry validity
        max(case when check_name = 'geometry_valid' and outcome = 'invalid'
                 then parcels end)                      as geometry_invalid,
        max(case when check_name = 'geometry_valid'
                 then total_parcels end)                as total_parcels,

        -- area check coverage
        max(case when check_name = 'area_check_coverage' and outcome = 'no_roll_figure'
                 then parcels end)                      as no_roll_figure,
        max(case when check_name = 'area_check_coverage' and outcome = 'measurable'
                 then parcels end)                      as area_measurable,

        -- landuse coverage
        max(case when check_name = 'landuse_coverage' and outcome = 'unmapped'
                 then parcels end)                      as landuse_unmapped,

        -- attribute completeness
        max(case when check_name = 'attribute_completeness' and outcome = 'attribute_sparse'
                 then parcels end)                      as attribute_sparse,

        -- merge provenance
        max(case when check_name = 'merge_provenance' and outcome = 'merged'
                 then parcels end)                      as merged_records,

        -- stacked components
        max(case when check_name = 'stacked_components' and outcome = 'stacked'
                 then parcels end)                      as stacked_components,

        -- geometry overlaps (pair counts, not parcel counts)
        max(case when check_name = 'geometry_overlap' and outcome = 'coincident'
                 then parcels end)                      as overlap_pairs_coincident,
        max(case when check_name = 'geometry_overlap' and outcome = 'coincident_unflagged'
                 then parcels end)                      as overlap_pairs_unflagged,
        max(case when check_name = 'geometry_overlap' and outcome = 'encroachment'
                 then parcels end)                      as overlap_pairs_encroachment,

        -- rejections
        max(case when check_name = 'rejection' then parcels end) as rejected_records,

        -- state-side comparison
        max(case when check_name = 'state_duplicate_groups'
                 then parcels end)                      as state_duplicate_groups,
        max(case when check_name = 'state_unidentified'
                 then parcels end)                      as state_unidentified,

        -- vintage (county-level; one row per county)
        max(case when check_name = 'state_copy_vintage'
                 then outcome::date end)                as state_copy_vintage

    from {{ ref('agg_quality_scorecard') }}
    group by 1, 2

),

merged_rows as (

    -- Merged-source provenance: how many published rows the merged records
    -- absorbed. Not available in the long scorecard (it carries parcel
    -- counts), so taken from conformed — the same figure the A4 canary
    -- reconciles through.
    select
        county_fips,
        sum(source_record_count) as merged_source_rows
    from {{ ref('int_parcels_conformed') }}
    where source_record_count > 1
    group by 1

)

select
    p.county_fips,
    p.county_name,

    coalesce(p.total_parcels, 0)                        as total_records,
    coalesce(p.geometry_invalid, 0)                     as geometry_invalid,

    coalesce(p.no_roll_figure, 0)                       as no_roll_figure,
    round(100.0 * coalesce(p.no_roll_figure, 0)
          / nullif(coalesce(p.no_roll_figure, 0) + coalesce(p.area_measurable, 0), 0), 2)
                                                        as pct_no_roll_figure,

    round(100.0 * coalesce(p.landuse_unmapped, 0)
          / nullif(p.total_parcels, 0), 2)              as pct_landuse_unmapped,

    coalesce(p.attribute_sparse, 0)                     as attribute_sparse_records,
    round(100.0 * coalesce(p.attribute_sparse, 0)
          / nullif(p.total_parcels, 0), 2)              as pct_attribute_sparse,

    coalesce(p.merged_records, 0)                       as merged_records,
    coalesce(m.merged_source_rows, 0)                   as merged_source_rows,
    round(100.0 * coalesce(p.merged_records, 0)
          / nullif(p.total_parcels, 0), 2)              as pct_records_merged,

    coalesce(p.stacked_components, 0)                   as stacked_components,

    coalesce(p.overlap_pairs_encroachment, 0)           as encroachment_pairs,
    coalesce(p.overlap_pairs_unflagged, 0)              as unflagged_coincident_pairs,
    coalesce(p.overlap_pairs_coincident, 0)             as coincident_pairs,

    coalesce(p.rejected_records, 0)                     as rejected_records,
    round(100.0 * coalesce(p.rejected_records, 0)
          / nullif(p.total_parcels + coalesce(p.rejected_records, 0), 0), 2)
                                                        as pct_rejected,

    coalesce(p.state_duplicate_groups, 0)               as state_duplicate_groups,
    coalesce(p.state_unidentified, 0)                   as state_unidentified_parcels,
    p.state_copy_vintage

from pivoted p
left join merged_rows m on m.county_fips = p.county_fips
order by p.county_fips
