-- -----------------------------------------------------------------------------
-- 09: New price-item basis "scaffoldArea" (Gerüstfläche, app engine 1.2.0).
-- Scaffold area = every wall length × (wall height + 1 m). Quantities are
-- computed on the device; the server only needs to accept the new basis when a
-- price-book version is published. Quote verification is unaffected (it checks
-- unit prices, line totals, VAT and sums, not quantities).
-- -----------------------------------------------------------------------------

create or replace function app.valid_price_items(p_items jsonb) returns boolean
language sql immutable set search_path = '' as $$
    select jsonb_typeof(p_items) = 'array'
       and jsonb_array_length(p_items) between 1 and 2000
       and not exists (
            select 1 from jsonb_array_elements(p_items) as e(item)
            where not (
                jsonb_typeof(item) = 'object'
                and coalesce(item ->> 'id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                and length(coalesce(item ->> 'code', '')) between 1 and 50
                and length(coalesce(item ->> 'name', '')) between 1 and 300
                and coalesce(item ->> 'basis', '') in ('wallArea', 'floorArea', 'ceilingArea', 'skirtingLength',
                                                       'revealLength', 'doorCount', 'windowCount', 'fixedPiece',
                                                       'scaffoldArea')
                and jsonb_typeof(item -> 'unitPriceCents') = 'number'
                and (item ->> 'unitPriceCents')::numeric between 0 and 100000000
                and (item ->> 'unitPriceCents')::numeric = trunc((item ->> 'unitPriceCents')::numeric)
                and jsonb_typeof(item -> 'defaultWastePercent') = 'number'
                and (item ->> 'defaultWastePercent')::numeric between 0 and 100
                and jsonb_typeof(item -> 'openingRule') = 'object'
                and coalesce(item -> 'openingRule' ->> 'mode', '') in ('none', 'all', 'aboveThreshold')
                and jsonb_typeof(item -> 'openingRule' -> 'thresholdM2') = 'number'
                and jsonb_typeof(item -> 'openingRule' -> 'addReveals') = 'boolean'
                and jsonb_typeof(item -> 'openingRule' -> 'revealDepthM') = 'number'
            )
       )
       and (select count(distinct lower(item ->> 'id')) from jsonb_array_elements(p_items) as e(item))
           = jsonb_array_length(p_items)
$$;
