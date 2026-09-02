-- models/intermediate/int_parcel_overlaps__spokane.sql
{{ config(materialized='table', tags=['expensive','overlaps']) }}
{{ parcel_overlaps('063') }}
