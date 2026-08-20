-- models/staging/stg_parcels__snohomish.sql
-- All per-county logic lives in the manifest (dbt_project.yml vars).
{{ conform_parcels('061') }}
