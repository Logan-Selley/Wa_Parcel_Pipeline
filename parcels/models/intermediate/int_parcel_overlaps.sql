{{ config(materialized='view', tags=['overlaps']) }}

{#  Union of the per-county overlap models -- the single relation dim_parcel
    and the scorecard read. A view, not a table: the county models are already
    materialized, so this is a cheap façade over them.

    NOT tagged expensive -- nothing here is any more. The four county models
    cost 32.55s together (Snohomish 32.0, King 26.8, Pierce 15.0, Spokane 14.9,
    four threads), against 119s for int_parcels_repaired alone. The tag was
    added when a routine build was over an hour, which turned out to be the
    missing GiST index on int_parcels_conformed rather than anything about this
    model; the index fix landed and the tag outlived its reason. Excluding
    these from a build never excluded agg_quality_scorecard, which refs the
    county tables directly -- so the exclusion did not save the work, it just
    published overlap counts computed against an older parcel set. #}

{% set counties = ['king', 'pierce', 'snohomish', 'spokane'] %}

{% for c in counties %}
select * from {{ ref('int_parcel_overlaps__' ~ c) }}
{% if not loop.last %}union all{% endif %}
{% endfor %}
