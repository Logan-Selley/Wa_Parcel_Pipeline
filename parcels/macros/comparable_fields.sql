{% macro comparable_fields() %}
    {#  Fields compared between our conformed parcels and the state's answer
        key. One registry, read by fct_parcel_reconciliation and by
        agg_quality_scorecard -- the fourth consumer of the pattern already
        used by rejection_rules(), flag_rules() and the manifest.

        Per entry:
          field   canonical name, used for the output column prefix
          ours    column in the parcel-grain aggregate of int_parcels_conformed
          theirs  column in the parcel-grain aggregate of stg_state_parcels
          agg     how to collapse a multi-row parcel:
                    'sum'  additive measures. Both sides carry one value per
                           record, so a parcel total is the sum -- verified for
                           our side by A3b (single value-holder per record
                           group) and for theirs by their duplicates differing
                           in value_land on 6,740 of 6,769 Pierce groups.
                    'mode' identity-ish attributes. min() picks a representative
                           and a companion count(distinct) reports whether the
                           parcel was multi-valued, so "we have one address,
                           they have three" stays visible rather than being
                           silently collapsed.
          kind    text | integer. text comparisons are CASE-INSENSITIVE:
                  King publishes CTYNAME in title case and the state
                  upper-cases it, so 489,880 of King's situs_city values
                  "disagreed" on Bellevue vs BELLEVUE alone. Normalising drops
                  that to 8,175 real differences. Raw values are still carried
                  in the fact -- normalise for the COMPARISON, preserve for the
                  EVIDENCE, as with label/label_short on int_landuse_labels.
          drift   true when a disagreement is EXPECTED rather than a finding.
                  The answer key is 166-216 days behind the counties (measured
                  publisher-to-publisher, see int_source_vintage), and WA
                  counties revalue annually, so assessed values must differ.
                  Measured ratio of ours/theirs on disagreeing parcels: Pierce
                  median 0.977, Snohomish 1.098, Spokane 1.083 -- tight and
                  directional, consistent with appreciation over ~200 days
                  rather than a basis mismatch. Drift fields still get a
                  per-field status; they just do not force both_differ.

                  NOT settled for King, whose median ratio is 0.193 on the 1.1%
                  of parcels that disagree. That is not drift and is tracked
                  separately -- see docs/build-plan.md B3.
    #}
    {% set fields = [
        {'field': 'situs_address',        'ours': 'situs_address',        'theirs': 'situs_address',   'agg': 'mode', 'kind': 'text'},
        {'field': 'sub_address',          'ours': 'sub_address',          'theirs': 'sub_address',     'agg': 'mode', 'kind': 'text'},
        {'field': 'situs_city',           'ours': 'situs_city',           'theirs': 'situs_city',      'agg': 'mode', 'kind': 'text'},
        {'field': 'situs_zip5',           'ours': 'situs_zip5',           'theirs': 'situs_zip5',      'agg': 'mode', 'kind': 'text'},
        {'field': 'situs_zip4',           'ours': 'situs_zip4',           'theirs': 'situs_zip4',      'agg': 'mode', 'kind': 'text'},
        {'field': 'landuse_cd',           'ours': 'landuse_cd',           'theirs': 'landuse_cd',      'agg': 'mode', 'kind': 'integer'},
        {'field': 'value_land',           'ours': 'value_land_appraised', 'theirs': 'value_land',      'agg': 'sum',  'kind': 'integer', 'drift': true},
        {'field': 'value_bldg',           'ours': 'value_bldg_appraised', 'theirs': 'value_bldg',      'agg': 'sum',  'kind': 'integer', 'drift': true}
    ] %}
    {% do return(fields) %}
{% endmacro %}


{% macro field_status(f, ours_alias='o', theirs_alias='t') %}
    {#  Four-way per-field status, NOT a boolean.

        A boolean 'matched' would be useless here: most real findings are
        COVERAGE differences, not value disagreements. Pierce's situs city and
        ZIP are null on the state side (correctly -- the county publishes no
        situs city, see design.md 9) and King's situs_city is null on OUR side
        for 42,659 parcels the state does populate. Those are opposite
        findings; a boolean collapses both to "mismatch".

        'both_null' is deliberately distinct from 'agree'. Spokane's landuse_cd
        is null on our side by design (no derivable crosswalk) -- absence
        matching absence is NOT APPLICABLE, not agreement, and counting it as
        agreement would inflate the headline number with non-comparisons.
    #}
    case
        when {{ ours_alias }}.{{ f.field }} is null and {{ theirs_alias }}.{{ f.field }} is null
            then 'both_null'
        when {{ ours_alias }}.{{ f.field }} is null
            then 'ours_absent'
        when {{ theirs_alias }}.{{ f.field }} is null
            then 'theirs_absent'
        when {{ compare_expr(f, ours_alias) }} = {{ compare_expr(f, theirs_alias) }}
            then 'agree'
        else 'disagree'
    end
{% endmacro %}


{% macro field_agg(f, side) %}
    {#  Collapse a multi-row parcel to one comparable value. `side` is the
        column name on that side (f.ours or f.theirs). #}
    {%- if f.agg == 'sum' -%}
        sum({{ side }})
    {%- else -%}
        min({{ side }})
    {%- endif -%}
{% endmacro %}


{% macro compare_expr(f, alias) %}
    {#- Normalised form used for equality only. Text is upper-cased and trimmed
        so publisher casing conventions do not read as data differences; the
        raw value is what the fact stores and displays. -#}
    {%- if f.kind == 'text' -%}
        upper(trim({{ alias }}.{{ f.field }}))
    {%- else -%}
        {{ alias }}.{{ f.field }}
    {%- endif -%}
{% endmacro %}


{% macro classifying_fields() %}
    {#- Fields whose disagreement means something. Drift fields are excluded:
        a stale answer key must disagree on assessed values, so letting them
        drive reconciliation_class would mark nearly every parcel both_differ
        and bury the differences that are actually findings. -#}
    {%- set out = [] -%}
    {%- for f in comparable_fields() if not f.get('drift', false) -%}
        {%- do out.append(f) -%}
    {%- endfor -%}
    {%- do return(out) -%}
{% endmacro %}
