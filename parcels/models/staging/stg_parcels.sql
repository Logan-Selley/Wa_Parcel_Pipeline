-- models/staging/stg_parcels.sql
{% set counties = var('counties').keys() | list %}

{% for fips in counties %}
select * from {{ ref('stg_parcels__' ~ var('counties')[fips]['name'] | lower) }}
{% if not loop.last %}union all{% endif %}
{% endfor %}