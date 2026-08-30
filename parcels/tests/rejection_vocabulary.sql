SELECT DISTINCT rejection_reason
FROM {{ ref('parcels_rejected') }}
WHERE rejection_reason IS NOT NULL
AND rejection_reason NOT IN (
    {% for r in rejection_rules() %}'{{ r.rule_id }}'{{ "," if not loop.last }}{% endfor %}
)