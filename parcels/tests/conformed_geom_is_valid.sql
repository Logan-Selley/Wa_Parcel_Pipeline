SELECT *
FROM {{ ref('int_parcels_conformed') }}
WHERE NOT st_IsValid(geom)