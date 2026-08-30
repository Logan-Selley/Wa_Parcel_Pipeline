SELECT
    *,
    CASE
        {% for r in rejection_rules() %}
        when {{ r.predicate }} then '{{ r.code }}'
        {% endfor %}
    END AS rejection_reason
FROM {{ ref('int_parcels_repaired') }}