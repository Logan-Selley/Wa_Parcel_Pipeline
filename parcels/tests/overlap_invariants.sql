{#  Structural invariants for int_parcel_overlaps. Every one fails only if the
    CODE is wrong -- none depends on how much overlap the counties happen to
    publish this month.

    Deliberately NOT a count band. The A6 draft proposed asserting pair counts
    stay within a measured band, but a magnitude assertion rots the same way
    the A-verification checklist constants did: Pierce moved 34 rows in a day,
    and a band tight enough to catch a regression fails on normal
    republication. Worse, it cannot distinguish "our code broke" from "the
    county republished" -- only the first is a test failure.

    Magnitudes belong in agg_quality_scorecard, where drift is visible as
    history rather than as a red build. The row_counts_match canary is the
    model followed here: assert relationships, not numbers.
#}

with o as (select * from {{ ref('int_parcel_overlaps') }})

select 'both_stacked pair present -- shortcut contract broken' as violation, count(*) as n
from o where a_stacked and b_stacked
having count(*) > 0

union all
select 'pair not canonically ordered -- duplicate pairs possible', count(*)
from o where record_key_a >= record_key_b
having count(*) > 0

union all
select 'intra-parcel pair -- exclusion failed', count(*)
from o where parcel_uid_a = parcel_uid_b
having count(*) > 0

union all
select 'overlap_ratio outside (0,1]', count(*)
from o where overlap_ratio is null or overlap_ratio <= 0 or overlap_ratio > 1.0000001
having count(*) > 0

union all
select 'overlap_sqft at or below the min floor', count(*)
from o where overlap_sqft <= {{ var('min_overlap_sqft', 1) }}
having count(*) > 0

union all
select 'unflagged_coincident set on a non-coincident or stacked pair', count(*)
from o where unflagged_coincident
  and (overlap_class <> 'coincident' or a_stacked or b_stacked)
having count(*) > 0

union all
select 'overlap_class outside accepted values', count(*)
from o where overlap_class not in ('coincident','encroachment')
having count(*) > 0

union all
select 'overlap_class disagrees with overlap_ratio threshold', count(*)
from o where (overlap_ratio >= {{ var('coincident_ratio', 0.8) }}) <> (overlap_class = 'coincident')
having count(*) > 0
