-- Every quarantine reason must come from the registry. A row appearing here
-- means some code path wrote a verdict rejection_rules() does not declare,
-- and the scorecard would label it as unregistered.
select distinct rejection_reason
from {{ ref('parcels_rejected') }}
where rejection_reason is not null
and rejection_reason not in (
    {% for r in rejection_rules() %}'{{ r.rule_id }}'{{ "," if not loop.last }}{% endfor %}
)