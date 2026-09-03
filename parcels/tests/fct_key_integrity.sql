{#  The fact must carry no null parcel_uid and no null class. A null uid in
    the fact means a null key leaked through the join (the state’s 4,587
    unidentified rows are filtered upstream; ours are quarantined); a null
    class means the CASE lost its ELSE -- both silent-corruption shapes, not
    data findings. #}

select 'null parcel_uid in fact' as violation, count(*) as rows
from {{ ref('fct_parcel_reconciliation') }}
where parcel_uid is null
having count(*) > 0

union all

select 'null reconciliation_class in fact', count(*)
from {{ ref('fct_parcel_reconciliation') }}
where reconciliation_class is null
having count(*) > 0

union all

select 'null ours_absent/theirs_absent flag', count(*)
from {{ ref('fct_parcel_reconciliation') }}
where ours_absent is null or theirs_absent is null
having count(*) > 0
