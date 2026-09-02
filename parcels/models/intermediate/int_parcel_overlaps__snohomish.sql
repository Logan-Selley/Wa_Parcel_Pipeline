-- models/intermediate/int_parcel_overlaps__snohomish.sql
{{ config(materialized='table', tags=['expensive','overlaps']) }}
{{ parcel_overlaps('061') }}
