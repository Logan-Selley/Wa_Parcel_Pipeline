-- The quarantine gate: fail a county rejecting max_reject_pct or more of its
-- staged rows. Quarantine keeps and counts, but a rate that high would mean
-- validation is excluding a real share of a county, not flagging edge cases.
with rejected as (
    select county_fips, count(*) as reject_count
    from {{ ref('parcels_rejected') }}
    where rejection_reason is not null
    group by county_fips
), totals as (
    select county_fips, count(*) as total_count
    from {{ ref('stg_parcels') }}
    group by county_fips
)
select t.county_fips, (reject_count/total_count)*100 as reject_rate
from rejected r join totals t
on t.county_fips = r.county_fips
where (reject_count::numeric/total_count::numeric)*100 >= {{ var('max_reject_pct', 5) }}