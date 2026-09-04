{{ config(materialized='table') }}

{#  The WIDE scorecard: one row per county, headline rates as columns.

    A pure PROJECTION of agg_quality_scorecard -- every number here is
    computed FROM the long-format table, not recomputed from base relations.
    The long table stays the single source of truth; if a check’s definition
    changes, this view follows it without a second implementation to keep
    honest.

    The pivot uses max(case when outcome = X then parcels end) because the
    long table holds several outcomes per (county, check) -- this shape picks
    the outcome each headline wants. Any check NOT named here simply doesn’t
    appear in the wide view; adding one means adding its columns here, which
    is the deliberate cost of a fixed contract for BI.

    One wrinkle: merge_provenance’s merged_source_rows needs the source rows
    summed per merge class, which the long table does not carry -- so it is
    pulled from the conformed relation directly (the only number in this
    model that does not come from the long table, and it is the A4 canary’s
    own arithmetic: conformed expansion = staged - rejected expansion).
#}

with pivoted as (

    select
        county_fips,
        county_name,

        -- geometry validity
        max(case when check_name = 'geometry_valid' and outcome = 'invalid'
                 then parcels end)                      as geometry_invalid,
        {#  Bare max(), NOT keyed to a check_name. total_parcels is joined onto
            EVERY row of the long table, so keying it to one check made the
            denominator of every percentage here vanish if that check were
            renamed or removed. #}
        max(total_parcels)                              as total_parcels,

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
        {#  Disjoint from coincident_unflagged below -- the long table
            partitions them, it does not nest them. King reads 0 here while
            having 330 coincident pairs, because all 330 are unflagged. #}
        max(case when check_name = 'geometry_overlap' and outcome = 'coincident'
                 then parcels end)                      as overlap_pairs_coincident_flagged,
        max(case when check_name = 'geometry_overlap' and outcome = 'coincident_unflagged'
                 then parcels end)                      as overlap_pairs_unflagged,
        max(case when check_name = 'geometry_overlap' and outcome = 'encroachment'
                 then parcels end)                      as overlap_pairs_encroachment,

        -- rejections
        max(case when check_name = 'rejection' then parcels end) as rejected_records,
        max(case when check_name = 'reconciliation' and outcome = 'both_match'
                 then parcels end)                      as parcels_matched,
        max(case when check_name = 'reconciliation' and outcome = 'both_differ'
                 then parcels end)                      as parcels_differ,
        max(case when check_name = 'reconciliation' and outcome = 'ours_only'
                 then parcels end)                      as parcels_ours_only,
        max(case when check_name = 'reconciliation' and outcome = 'theirs_only'
                 then parcels end)                      as parcels_theirs_only,
        max(case when check_name = 'value_drift' then parcels end) as parcels_value_drift,

        {#  Quality ledger: what we improved on the answer key, and where it
            improves on us. Summed across fields, so a parcel differing on two
            fields counts twice -- these are field-level coverage counts, not
            parcel counts. #}
        sum(case when check_name = 'field_coverage'
                  and outcome like '%:theirs_absent'
                 then parcels else 0 end)               as coverage_ours_only,
        sum(case when check_name = 'field_coverage'
                  and outcome like '%:ours_absent'
                 then parcels else 0 end)               as coverage_theirs_only,
        max(case when check_name = 'geometry_repaired' then parcels end)
                                                        as geometry_repaired,
        max(case when check_name = 'county_source_vintage'
                 then outcome::date end)                as county_published_at,

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

rejected_rows as (

    {#  Quarantine in SOURCE rows, not quarantine rows. A rejected row is a
        merged record and can stand for several published rows -- Spokane’s 2
        rejected rows represent 3 UNKNOWN source records -- so a row count
        under-reports the failures and does not tie to the A4 canary. #}
    select county_fips, sum(rejected_source_rows) as rejected_source_rows
    from {{ ref('agg_quarantine_summary') }}
    group by 1

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
    coalesce(p.overlap_pairs_coincident_flagged, 0)     as coincident_flagged_pairs,
    coalesce(p.overlap_pairs_coincident_flagged, 0)
      + coalesce(p.overlap_pairs_unflagged, 0)          as coincident_pairs_total,

    coalesce(p.rejected_records, 0)                     as rejected_records,
    coalesce(r.rejected_source_rows, 0)                 as rejected_source_rows,
    round(100.0 * coalesce(r.rejected_source_rows, 0)
          / nullif(p.total_parcels + coalesce(r.rejected_source_rows, 0), 0), 2)
                                                        as pct_rejected,

    coalesce(p.state_duplicate_groups, 0)               as state_duplicate_groups,
    coalesce(p.state_unidentified, 0)                   as state_unidentified_parcels,

    {# ---------------------------------------------- answer-key comparison #
        The project’s headline, and the reason this table exists. parcels_differ
        is the UNEXPLAINED delta: what survives case normalisation (design.md
        5.6) and the exclusion of fields a 167-216 day stale answer key is
        expected to disagree on (5.5). Reporting raw disagreement instead would
        be true and useless -- it was 1,204,678 before those two corrections. #}
    coalesce(p.parcels_matched, 0)                      as parcels_matched,
    coalesce(p.parcels_differ, 0)                       as parcels_differ,
    coalesce(p.parcels_ours_only, 0)                    as parcels_ours_only,
    coalesce(p.parcels_theirs_only, 0)                  as parcels_theirs_only,
    round(100.0 * coalesce(p.parcels_matched, 0)
          / nullif(coalesce(p.parcels_matched,0) + coalesce(p.parcels_differ,0)
                 + coalesce(p.parcels_ours_only,0) + coalesce(p.parcels_theirs_only,0), 0), 2)
                                                        as pct_agreement,
    coalesce(p.parcels_value_drift, 0)                  as parcels_value_drift,

    {# ------------------------------------------------------ quality ledger #
        What we corrected or supply beyond the answer key, and where it
        supplies more than us. Field-level counts: a parcel contributing two
        fields counts twice. #}
    coalesce(p.geometry_repaired, 0)                    as geometry_repaired,
    coalesce(p.coverage_ours_only, 0)                   as coverage_fields_ours_only,
    coalesce(p.coverage_theirs_only, 0)                 as coverage_fields_theirs_only,

    {#  Both dates are publisher statements -- the county’s
        editingInfo.lastEditDate against the state’s File_Date -- so the gap is
        a property of the two SOURCES and does not move when we re-run.
        Measuring against our ingest time instead would grow it by a day every
        day with nothing about the data having changed. #}
    p.county_published_at,
    p.state_copy_vintage                                as state_published_at,
    (p.county_published_at - p.state_copy_vintage)      as vintage_gap_days

from pivoted p
left join merged_rows m   on m.county_fips = p.county_fips
left join rejected_rows r on r.county_fips = p.county_fips
order by p.county_fips
