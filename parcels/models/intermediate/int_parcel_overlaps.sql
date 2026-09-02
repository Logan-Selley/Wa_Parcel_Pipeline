{{ config(materialized='view', tags=['expensive','overlaps']) }}

{#  Union of the per-county overlap models -- the single relation dim_parcel
    and the scorecard read. A view, not a table: the county models are already
    materialized, so this is a cheap façade over them.

    Tagged expensive because its refs are: excluding tag:expensive from a
    routine build must exclude this too, or it would reference tables that
    were never built. #}

{% set counties = ['king', 'pierce', 'snohomish', 'spokane'] %}

{% for c in counties %}
select * from {{ ref('int_parcel_overlaps__' ~ c) }}
{% if not loop.last %}union all{% endif %}
{% endfor %}
