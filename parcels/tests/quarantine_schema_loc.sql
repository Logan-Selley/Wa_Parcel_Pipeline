{# The config-nesting bug deployed parcels_rejected into staging. Fails unless
   the model’s schema is literally quarantine -- no string matching, no quoting
   games. #}
{% set rejected = ref('parcels_rejected') %}
select 1
where '{{ rejected.schema }}' != 'quarantine'