-- models/intermediate/int_parcel_overlaps__pierce.sql
{{ config(materialized='table', tags=['expensive','overlaps']) }}
{{ parcel_overlaps('053') }}
