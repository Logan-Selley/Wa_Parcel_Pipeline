-- models/intermediate/int_parcel_overlaps__king.sql
{{ config(materialized='table', tags=['expensive','overlaps']) }}
{{ parcel_overlaps('033') }}
