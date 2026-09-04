{#  The bi extract’s geometry contract: no nulls, no empties, WGS84 only.
    All three are hard failures -- this is the table the map binds to, and a
    null or misprojected geometry renders as a missing or misplaced parcel
    with no error anywhere else.

    Validity is deliberately NOT here: simplification measured 1
    self-intersecting result in 1,504,693, which is a known-benign rendering
    artifact -- see bi_geom_validity.sql (warn severity) for that assertion. #}

select
    case
        when geom is null then 'null geom'
        when st_isempty(geom) then 'empty geom'
        else 'srid ' || st_srid(geom)::text
    end as violation,
    count(*) as rows
from {{ ref('bi_findings_extract') }}
where geom is null
   or st_isempty(geom)
   or st_srid(geom) <> 4326
group by 1
