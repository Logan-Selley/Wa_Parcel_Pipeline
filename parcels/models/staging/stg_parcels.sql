-- models/staging/stg_parcels.sql
-- The union of every county in the manifest. Everything downstream reads this
-- model rather than the per-county files, so adding a county needs no edits
-- below staging.
{% set counties = var('counties').keys() | list %}

{% for fips in counties %}
select * from {{ ref('stg_parcels__' ~ var('counties')[fips]['name'] | lower) }}
{% if not loop.last %}union all{% endif %}
{% endfor %}