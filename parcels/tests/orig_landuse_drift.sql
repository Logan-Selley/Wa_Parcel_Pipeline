SELECT county_fips,orig_landuse_cd
FROM {{ ref('int_landuse_crosswalk') }}
GROUP BY county_fips,orig_landuse_cd HAVING COUNT(*) > 1