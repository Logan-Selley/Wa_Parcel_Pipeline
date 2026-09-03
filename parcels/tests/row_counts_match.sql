{# A4 canary: staged = SUM(source_record_count) over conformed + rejected.

   source_record_count is how many staged rows each published record variant
   absorbed, so summing it over BOTH split sides reconstructs the staged
   universe exactly -- including rows merged away by the record-integration
   step, and including any merge that happened to rejected rows. The old
   staged = conformed + rejected form stopped being true the moment the
   integration step could collapse rows. #}
with staged as (
    select county_fips, count(*) as staged_count
    from {{ ref('stg_parcels') }}
    group by county_fips
), published as (
    select county_fips, sum(source_record_count) as published_count
    from {{ ref('int_parcels_conformed') }}
    group by county_fips
), rejected as (
    select county_fips, sum(source_record_count) as rejected_count
    from {{ ref('parcels_rejected') }}
    group by county_fips
)
select t.county_fips, t.staged_count,
       coalesce(p.published_count, 0) + coalesce(r.rejected_count, 0) as accounted_for
from staged t
left join published p on p.county_fips = t.county_fips
left join rejected r on r.county_fips = t.county_fips
where coalesce(p.published_count, 0) + coalesce(r.rejected_count, 0) <> t.staged_count