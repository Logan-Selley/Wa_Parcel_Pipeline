-- models/intermediate/int_parcel_overlaps__snohomish.sql
-- All per-county logic lives in macros/parcel_overlaps.sql; fips is the only argument.
{{ config(materialized='table', tags=['overlaps']) }}
{{ parcel_overlaps('061') }}
