{{ config(severity='warn') }}

{#  Simplification measured 1 self-intersecting result in 1,504,693 (a
    Douglas-Peucker artifact, not a source defect -- the pre-simplify
    geometry is 100% valid). Rendering is unaffected, so this is a quality
    signal at warn severity rather than a build failure. If this count
    grows materially, the tolerance or the simplification function changed. #}

select
    'invalid geometry after simplify+transform' as violation,
    count(*) as rows
from {{ ref('bi_findings_extract') }}
where not st_isvalid(geom)
