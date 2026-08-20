-- models/staging/stg_parcels__pierce.sql
-- All per-county logic lives in the manifest (dbt_project.yml vars).
{{ conform_parcels('053') }}
