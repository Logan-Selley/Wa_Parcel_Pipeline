{{ config(materialized='table') }}

{#  When each SOURCE was last published, per county.

    Not when we ingested it. ingested_at is a property of our run schedule --
    re-running the extractor tomorrow would move it a day without anything
    about the data changing -- so any staleness metric built on it measures us,
    not the sources.

    editingInfo.lastEditDate is the county's own analogue of the state's
    File_Date: the publisher's statement of when the layer last changed.
    Captured from the same ?f=json payload the extractor already fetches for
    CRS, field list and maxRecordCount, and stored per run on the field
    snapshot (constant across that run's field rows, hence max()).

    Latest capture only -- the snapshot is append-only so drift stays visible
    as history.
#}

with latest as (
    select fips, max(captured_at) as captured_at
    from {{ source('raw', 'source_field_snapshot') }}
    where source_last_edit is not null
    group by fips
)

select
    s.fips                          as county_fips,
    max(s.source_last_edit)         as source_published_at,
    max(s.captured_at)              as observed_at
from {{ source('raw', 'source_field_snapshot') }} s
join latest l on l.fips = s.fips and l.captured_at = s.captured_at
group by s.fips
