SELECT *
FROM {{ ref('int_parcels_conformed') }}
WHERE source_file_date IS NULL