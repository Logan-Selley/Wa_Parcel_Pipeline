SELECT v.*,landuse_cd,
CASE WHEN c.landuse_cd is not NULL THEN 'derived' ELSE 'unmapped' END as landuse_cd_method
FROM {{ ref('int_parcels_validated') }} v
LEFT JOIN {{ ref('int_landuse_crosswalk') }} c
{# fips_nr in state_parcels is zero-padded ('061'), but the prefix inside orig_landuse_cd is not ('61-111') #}
ON SUBSTR(v.county_fips,2) || '-' || landuse_code_source = orig_landuse_cd
WHERE rejection_reason IS NULL