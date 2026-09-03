{#  The parcel-partition checks must each sum to the county’s total: their
    outcomes partition conformed rows exhaustively. If a future edit adds an
    unhandled outcome to any block (or drops rows from one), the sums stop
    closing and this fails -- the scorecard’s equivalent of the A4 canary.

    Two checks with a different universe are deliberately absent here:
      * rejection rows -- universe is parcels_rejected, not conformed (their
        county counts reconcile through source_record_count in
        agg_quarantine_summary itself)
      * geometry_overlap rows -- universe is PAIRS, not parcels (documented
        in the model; pair counts cannot sum to a parcel total) #}

{%- set partition_checks = [
    'geometry_valid',
    'area_check_coverage',
    'landuse_coverage',
    'attribute_completeness',
    'merge_provenance',
    'stacked_components'
] -%}

with outcome_sums as (

    select county_fips, check_name, sum(parcels) as outcome_sum
    from {{ ref('agg_quality_scorecard') }}
    where check_name in (
        {%- for c in partition_checks -%}
        '{{ c }}'{{ ", " if not loop.last }}
        {%- endfor -%}
    )
    group by 1, 2

),

totals as (

    select county_fips, max(total_parcels) as total_parcels
    from {{ ref('agg_quality_scorecard') }}
    group by 1

)

select
    o.county_fips,
    o.check_name,
    o.outcome_sum,
    t.total_parcels
from outcome_sums o
join totals t using (county_fips)
where o.outcome_sum <> t.total_parcels

union all

{#  State-side: the scorecard’s state_duplicate_groups count must equal the
    collision groups recomputed from stg_state_parcels. #}
select
    'state_duplicate_groups does not match recomputation' as violation,
    coalesce(s.county_fips, sc.county_fips) as county_fips,
    s.groups as recomputed, sc.parcels as scored
from (
    {#  Inner: one row per colliding parcel_uid, carrying its county.
        Outer: group those rows BY county. The county column must be a plain
        grouping key here, not an aggregate. #}
    select d.county_fips, count(*) as groups
    from (
        select parcel_uid, min(county_fips) as county_fips
        from {{ ref('stg_state_parcels') }}
        where parcel_uid is not null
        group by 1
        having count(*) > 1
    ) d
    group by 1
) s
full outer join (
    select county_fips, parcels
    from {{ ref('agg_quality_scorecard') }}
    where check_name = 'state_duplicate_groups'
) sc on sc.county_fips = s.county_fips
where coalesce(s.groups, 0) <> coalesce(sc.parcels, 0)

union all

{#  State-side: the scorecard’s state_unidentified count must equal the
    null-uid rows recomputed per county. #}
select
    'state_unidentified does not match recomputation' as violation,
    coalesce(u.county_fips, sc.county_fips) as county_fips,
    u.rows as recomputed, sc.parcels as scored
from (
    select county_fips as county_fips, count(*) as rows
    from {{ ref('stg_state_parcels') }}
    where parcel_uid is null
    group by 1
) u
full outer join (
    select county_fips, parcels
    from {{ ref('agg_quality_scorecard') }}
    where check_name = 'state_unidentified'
) sc on sc.county_fips = u.county_fips
where coalesce(u.rows, 0) <> coalesce(sc.parcels, 0)
