{# A4 canary: staged = SUM(source_record_count) over conformed + rejected.

   source_record_count is how many staged rows each published record variant
   absorbed, so summing it over BOTH split sides reconstructs the staged
   universe exactly -- including rows merged away by the record-integration
   step, and including any merge that happened to rejected rows. The old
   staged = conformed + rejected form stopped being true the moment the
   integration step could collapse rows. #}
WITH staged as (
    SELECT county_fips, COUNT(*) as staged_count
    FROM {{ ref('stg_parcels') }}
    GROUP BY county_fips
), published as (
    SELECT county_fips, SUM(source_record_count) as published_count
    FROM {{ ref('int_parcels_conformed') }}
    GROUP BY county_fips
), rejected as (
    SELECT county_fips, SUM(source_record_count) as rejected_count
    FROM {{ ref('parcels_rejected') }}
    GROUP BY county_fips
)
SELECT t.county_fips, t.staged_count,
       coalesce(p.published_count, 0) + coalesce(r.rejected_count, 0) as accounted_for
FROM staged t
LEFT JOIN published p ON p.county_fips = t.county_fips
LEFT JOIN rejected r ON r.county_fips = t.county_fips
WHERE coalesce(p.published_count, 0) + coalesce(r.rejected_count, 0) <> t.staged_count