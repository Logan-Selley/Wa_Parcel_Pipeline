{#  The fact’s class distribution must be internally consistent with the
    statuses it was computed from. Two invariants:

      1. A both_match row cannot carry any ’disagree’ status on a
         classifying field (that is what both_differ means).
      2. A both_differ row must carry at least one ’disagree’ on a
         classifying field (otherwise it should have been both_match).

    Drift fields are excluded from both checks by design -- value disagreement
    is expected against a stale answer key and surfaces as value_drift, not
    as class. This is the CASE-tree’s invariant restated as data: if the
    class logic and the statuses ever diverge (a field added to one but not
    the other), this fails. #}

{%- set classifying = classifying_fields() -%}

with f as (
    select * from {{ ref('fct_parcel_reconciliation') }}
)

select 'both_match row with a disagreeing classifying field' as violation, count(*) as rows
from f
where reconciliation_class = 'both_match'
  and ({% for f2 in classifying %}
       {{ f2.field }}_status = 'disagree'{{ " or " if not loop.last }}
       {%- endfor %})
having count(*) > 0

union all

select 'both_differ row with no disagreeing classifying field', count(*)
from f
where reconciliation_class = 'both_differ'
  and not ({% for f2 in classifying %}
           {{ f2.field }}_status = 'disagree'{{ " or " if not loop.last }}
           {%- endfor %})
having count(*) > 0
