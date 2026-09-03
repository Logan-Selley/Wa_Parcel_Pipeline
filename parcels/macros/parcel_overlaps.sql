{% macro parcel_overlaps(fips) %}

{#  Per-county overlap detection. One model per county (the stg_parcels__*
    pattern) so a slow county cannot hide a fast one's result and each gets
    its own timing in dbt output -- Snohomish costs ~5x King and bundling
    them meant no partial progress.

    THE BOTH-STACKED SHORTCUT

    Pairs where BOTH records are stacked are excluded from the expensive
    computation entirely. This is licensed by measurement, not convenience:
    across 352,281 both-stacked pairs in a 5-mile sample box, ZERO fell below
    a 0.8 overlap ratio -- stacking always implies coincidence. They are
    vertical components of one building sharing a plan-view footprint, so
    computing st_intersection to rediscover that is 98.8% of the work for
    none of the signal.

    Nor are they enumerated as pairs: stack-internal pair counts are O(n^2)
    in stack size, so a 40-unit building contributes 780 pairs and swamps any
    scorecard. The useful metric is the STACKED RECORD count, which
    dim_parcel already carries from is_stacked.

    What survives is what matters: a stacked record overlapping a
    non-stacked NEIGHBOUR still appears (563 such encroachments in the sample
    box), because only both-stacked pairs are skipped.

    EXECUTION SHAPE -- see docs/design.md 5.8. Direct table references, never
    a CTE over conformed: a CTE referenced twice will not inline, materializes,
    and the GiST index becomes unreachable (verified: Nested Loop + Index Scan
    becomes Hash Join with the spatial predicates demoted to a filter). The
    `candidates as materialized` barrier is what stops the outer select
    re-evaluating st_intersection per reference.
#}

with candidates as materialized (

    select
        a.record_key_uid                            as record_key_a,
        b.record_key_uid                            as record_key_b,
        a.parcel_uid                                as parcel_uid_a,
        b.parcel_uid                                as parcel_uid_b,
        a.is_stacked                                as a_stacked,
        b.is_stacked                                as b_stacked,
        st_area(st_intersection(a.geom, b.geom))    as overlap_sqft,
        least(st_area(a.geom), st_area(b.geom))     as smaller_sqft
    from {{ ref('int_parcels_conformed') }} a
    join {{ ref('int_parcels_conformed') }} b
        {#  County EQUALITY between the two sides, with the constant applied
            once in the WHERE below. Putting the constant on BOTH sides of the
            ON clause makes the planner filter b by county via Seq Scan and
            demote the && to a join filter -- verified with EXPLAIN, and it
            turns a seconds-long county join into an all-pairs nested loop. #}
        on  a.county_fips = b.county_fips
        and a.record_key_uid < b.record_key_uid
        {#  Cheap boolean, before any geometry work. #}
        and not (a.is_stacked and b.is_stacked)
        and a.geom && b.geom
        {#  Interior-interior intersection: a shared lot line does not qualify.
            Removes ~40% of candidates before the far costlier st_intersection.
            `not st_touches(a,b)` is equivalent and may short-circuit sooner --
            unbenchmarked. #}
        and st_relate(a.geom, b.geom, 'T********')
    where a.county_fips = '{{ fips }}'
      and a.parcel_uid <> b.parcel_uid
      and st_area(st_intersection(a.geom, b.geom)) > {{ var('min_overlap_sqft', 1) }}

)

select
    '{{ fips }}'::char(3)                           as county_fips,
    record_key_a,
    record_key_b,
    parcel_uid_a,
    parcel_uid_b,
    a_stacked,
    b_stacked,
    overlap_sqft,
    overlap_sqft / nullif(smaller_sqft, 0)          as overlap_ratio,
    case
        when overlap_sqft / nullif(smaller_sqft, 0) >= {{ var('coincident_ratio', 0.8) }}
            then 'coincident'
        else 'encroachment'
    end                                             as overlap_class,
    {#  Coincident with neither record flagged: an incomplete stacking
        indicator, or genuinely duplicated geometry across distinct parcels.
        588 in the sample box. Named so the scorecard counts them rather than
        burying them. #}
    (overlap_sqft / nullif(smaller_sqft, 0) >= {{ var('coincident_ratio', 0.8) }}
     and not a_stacked and not b_stacked)           as unflagged_coincident
from candidates

{% endmacro %}
