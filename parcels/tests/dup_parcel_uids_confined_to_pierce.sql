{#  The confined uniqueness test (A7 formulation): parcel_uid is
    intentionally non-unique where the county publishes multiple records
    under one tax parcel -- Pierce’s condo components. The duplication must
    stay CONFINED to Pierce: another county developing duplicate parcel_uids
    is a real regression, because that county’s record hierarchy would be
    lying about its own grain.

    The Pierce duplication itself is fully classified (docs/design-history.md
    A3b) and measured in agg_scorecard_wide; this test is the tripwire for
    everyone else. #}

with dups as (
    select county_fips, count(*) as dup_uids
    from (
        select parcel_uid, county_fips
        from {{ ref('int_parcels_conformed') }}
        group by 1, 2
        having count(*) > 1
    ) d
    group by 1
)

select county_fips, dup_uids
from dups
where county_fips <> '053'
