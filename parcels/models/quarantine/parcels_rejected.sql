SELECT *
FROM {{ ref('int_parcels_validated') }}
WHERE rejection_reason IS NOT NULL