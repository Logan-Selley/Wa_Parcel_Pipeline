WITH rejected as (
    SELECT county_fips, COUNT(*) as reject_count
    FROM {{ ref('parcels_rejected') }}
    WHERE rejection_reason IS NOT NULL
    GROUP BY county_fips
), totals as (
    SELECT county_fips, COUNT(*) as total_count
    FROM {{ ref('stg_parcels') }}
    GROUP BY county_fips
)
SELECT t.county_fips,(reject_count/total_count)*100 as reject_rate
FROM rejected r JOIN totals t
ON t.county_fips = r.county_fips
WHERE (reject_count::numeric/total_count::numeric)*100 >= {{ var('max_reject_pct', 5) }}