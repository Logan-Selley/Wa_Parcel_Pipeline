{# Expected to fail, data has duplicates, needs investigation #}
SELECT parcel_uid as duplicate_uid
FROM {{ ref('int_parcels_conformed') }}
GROUP BY parcel_uid HAVING COUNT(*) > 1