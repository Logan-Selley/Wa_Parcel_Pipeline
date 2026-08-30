WITH validated as (
    SELECT county_fips, COUNT(*) as total_count
    FROM {{ ref('int_parcels_validated') }}
    GROUP BY county_fips
), classified as (
    SELECT county_fips, COUNT(*) as classified_count
    FROM (SELECT county_fips
          FROM {{ ref('int_parcels_conformed') }}
          UNION ALL
          SELECT county_fips
          FROM {{ ref('parcels_rejected') }})
    GROUP BY county_fips
)
SELECT v.county_fips,total_count,classified_count
FROM validated v JOIN classified c
ON v.county_fips = c.county_fips
WHERE total_count != classified_count