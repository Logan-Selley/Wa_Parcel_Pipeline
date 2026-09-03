{#  Per-county balance: the fact's presence counts reconcile to the
    underlying relations.

      ours-present rows  = distinct parcel_uids in dim_parcel
      theirs-present rows = distinct parcel_uids in stg_state_parcels

    The full outer join cannot create or destroy rows on either side, so any
    mismatch means the join grain drifted (e.g. a key expression changed on
    one side only). The third assertion is the join's own guard: a row absent
    from BOTH sides cannot exist in a full outer join -- its presence would
    mean the join key collapsed (nulls matching nulls). #}

with dim_u as (
    select county_fips, count(distinct parcel_uid) as dim_uids
    from {{ ref('dim_parcel') }}
    where parcel_uid is not null
    group by 1
),
stg_u as (
    select county_fips, count(distinct parcel_uid) as stg_uids
    from {{ ref('stg_state_parcels') }}
    where parcel_uid is not null
    group by 1
),
fct as (
    select county_fips,
        count(*) filter (where not ours_absent)  as ours_side,
        count(*) filter (where not theirs_absent) as theirs_side,
        count(*) filter (where ours_absent and theirs_absent) as impossible
    from {{ ref('fct_parcel_reconciliation') }}
    group by 1
)

select 'ours_side does not match dim distinct parcel_uids' as violation,
       coalesce(d.county_fips, f.county_fips) as county_fips,
       d.dim_uids as expected, f.ours_side as actual
from dim_u d
full outer join fct f on f.county_fips = d.county_fips
where coalesce(d.dim_uids, 0) <> coalesce(f.ours_side, 0)

union all

select 'theirs_side does not match stg_state distinct parcel_uids',
       coalesce(s.county_fips, f.county_fips),
       s.stg_uids, f.theirs_side
from stg_u s
full outer join fct f on f.county_fips = s.county_fips
where coalesce(s.stg_uids, 0) <> coalesce(f.theirs_side, 0)

union all

select 'row absent from both sides (full outer join guard)',
       county_fips, impossible, impossible
from fct
where impossible > 0
