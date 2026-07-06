BEGIN;

SET search_path TO pgho_payments, public;

SELECT plan(117);

-- ==============================
-- EXTENSION METADATA
-- ==============================

SELECT is(
    (SELECT extrelocatable FROM pg_extension WHERE extname = 'pgho_payments'),
    false,
    'pgho_payments is not relocatable, since @extschema@ is baked into function search_paths'
);

-- ==============================
-- LEDGER: post_transaction
-- ==============================

SELECT create_ledger_account('test', 'acct-a', 'asset') AS acct_a_id \gset
SELECT create_ledger_account('test', 'acct-b', 'asset') AS acct_b_id \gset

SELECT throws_ok(
    format($fmt$ SELECT post_transaction('single_leg', jsonb_build_array(jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', 100))) $fmt$, :'acct_a_id'),
    '22023',
    NULL,
    'post_transaction rejects fewer than two entries'
);

SELECT throws_ok(
    format($fmt$ SELECT post_transaction('zero_leg', jsonb_build_array(
        jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', 0),
        jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', 0)
    )) $fmt$, :'acct_a_id', :'acct_b_id'),
    '22023',
    NULL,
    'post_transaction rejects a zero-amount entry'
);

SELECT throws_ok(
    format($fmt$ SELECT post_transaction('unbalanced', jsonb_build_array(
        jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', 100),
        jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', -50)
    )) $fmt$, :'acct_a_id', :'acct_b_id'),
    '22023',
    NULL,
    'post_transaction rejects entries that do not sum to zero'
);

SELECT throws_ok(
    format($fmt$ SELECT post_transaction('cross_currency', jsonb_build_array(
        jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', 100),
        jsonb_build_object('account_id', %s, 'currency', 'EGP', 'amount', -100)
    )) $fmt$, :'acct_a_id', :'acct_b_id'),
    '22023',
    NULL,
    'post_transaction requires entries to balance per currency, not overall'
);

SELECT lives_ok(
    format($fmt$ SELECT post_transaction('seed', jsonb_build_array(
        jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', 1000),
        jsonb_build_object('account_id', %s, 'currency', 'USD', 'amount', -1000)
    )) $fmt$, :'acct_a_id', :'acct_b_id'),
    'post_transaction accepts a balanced pair of entries'
);

SELECT is(get_account_balance(:'acct_a_id'::bigint, 'USD'), 1000::bigint, 'balance reflects a posted credit');
SELECT is(get_account_balance(:'acct_b_id'::bigint, 'USD'), -1000::bigint, 'balance reflects a posted debit');

SELECT post_transaction('idem', jsonb_build_array(
    jsonb_build_object('account_id', :'acct_a_id'::bigint, 'currency', 'USD', 'amount', 500),
    jsonb_build_object('account_id', :'acct_b_id'::bigint, 'currency', 'USD', 'amount', -500)
), p_idempotency_key := 'ledger-idem-1') AS idem_tx_1 \gset

SELECT post_transaction('idem', jsonb_build_array(
    jsonb_build_object('account_id', :'acct_a_id'::bigint, 'currency', 'USD', 'amount', 500),
    jsonb_build_object('account_id', :'acct_b_id'::bigint, 'currency', 'USD', 'amount', -500)
), p_idempotency_key := 'ledger-idem-1') AS idem_tx_2 \gset

SELECT is(:'idem_tx_1'::bigint, :'idem_tx_2'::bigint, 'post_transaction with a repeated idempotency_key returns the original transaction id');
SELECT is(get_account_balance(:'acct_a_id'::bigint, 'USD'), 1500::bigint, 'a repeated idempotency_key does not double-post');

SELECT throws_ok(
    $$ UPDATE ledger_entries SET amount = 1 WHERE true $$,
    '0A000',
    NULL,
    'ledger_entries is append-only'
);

SELECT throws_ok(
    $$ UPDATE ledger_accounts SET owner_id = 'changed' WHERE owner_id = 'acct-a' $$,
    '0A000',
    NULL,
    'ledger_accounts identity is immutable once created'
);

SELECT get_or_create_system_account('fees', 'test') AS sys_acct_1 \gset
SELECT get_or_create_system_account('fees', 'test') AS sys_acct_2 \gset

SELECT is(
    :'sys_acct_1'::bigint,
    :'sys_acct_2'::bigint,
    'get_or_create_system_account is idempotent per (tenant_id, account_type) and never creates a duplicate'
);

-- ==============================
-- WALLET API
-- ==============================

SELECT create_wallet('user', 'wallet-user-1') AS wallet_1_id \gset
SELECT create_wallet('user', 'wallet-user-2') AS wallet_2_id \gset

SELECT lives_ok(
    format($fmt$ SELECT wallet_topup('%s'::uuid, 2000, 'USD') $fmt$, :'wallet_1_id'),
    'wallet_topup accepts a positive amount'
);

SELECT is(get_wallet_balance(:'wallet_1_id'::uuid, 'USD'), 2000::bigint, 'wallet_topup increases the wallet balance');

SELECT lives_ok(
    format($fmt$ SELECT wallet_withdraw('%s'::uuid, 500, 'USD') $fmt$, :'wallet_1_id'),
    'wallet_withdraw accepts a valid amount'
);

SELECT is(get_wallet_balance(:'wallet_1_id'::uuid, 'USD'), 1500::bigint, 'wallet_withdraw decreases the wallet balance');

SELECT throws_ok(
    format($fmt$ SELECT wallet_withdraw('%s'::uuid, 999999, 'USD') $fmt$, :'wallet_1_id'),
    '23514',
    NULL,
    'wallet_withdraw rejects an amount exceeding the balance'
);

SELECT lives_ok(
    format($fmt$ SELECT wallet_transfer('%s'::uuid, '%s'::uuid, 1000, 'USD') $fmt$, :'wallet_1_id', :'wallet_2_id'),
    'wallet_transfer moves funds between two active wallets'
);

SELECT is(get_wallet_balance(:'wallet_1_id'::uuid, 'USD'), 500::bigint, 'wallet_transfer debits the source wallet');
SELECT is(get_wallet_balance(:'wallet_2_id'::uuid, 'USD'), 1000::bigint, 'wallet_transfer credits the destination wallet');

UPDATE wallets SET status = 'frozen' WHERE id = :'wallet_1_id'::uuid;

SELECT throws_ok(
    format($fmt$ SELECT wallet_topup('%s'::uuid, 100, 'USD') $fmt$, :'wallet_1_id'),
    '55000',
    NULL,
    'wallet_topup rejects a wallet that is not active'
);

-- ==============================
-- CATALOG API
-- ==============================

SELECT create_product('Widget Pro') AS product_id \gset

SELECT lives_ok(
    format($fmt$ SELECT create_price('%s'::uuid, 'USD', 1000) $fmt$, :'product_id'),
    'create_price accepts a one_time price with no billing_interval'
);

SELECT throws_ok(
    format($fmt$ SELECT create_price('%s'::uuid, 'USD', 1000, 'recurring') $fmt$, :'product_id'),
    '22023',
    NULL,
    'create_price rejects a recurring price with no billing_interval'
);

SELECT create_price(:'product_id'::uuid, 'USD', 1500) AS onetime_price_id \gset
SELECT create_price(:'product_id'::uuid, 'USD', 2500, 'recurring', 'month') AS monthly_price_id \gset

SELECT lives_ok(
    format($fmt$ SELECT deactivate_price('%s'::uuid) $fmt$, :'onetime_price_id'),
    'deactivate_price runs without error'
);

SELECT is(
    (SELECT active FROM prices WHERE id = :'onetime_price_id'::uuid),
    false,
    'deactivate_price marks the price inactive'
);

SELECT throws_ok(
    format($fmt$ UPDATE prices SET unit_amount = 1 WHERE id = '%s'::uuid $fmt$, :'monthly_price_id'),
    '0A000',
    NULL,
    'prices content is immutable once created'
);

-- ==============================
-- ORDERS API
-- ==============================

SELECT create_order(
    'customer-1', 'USD',
    jsonb_build_array(
        jsonb_build_object('price_id', :'monthly_price_id'::uuid, 'quantity', 1),
        jsonb_build_object('unit_amount', 300, 'description', 'ad hoc fee', 'quantity', 2)
    )
) AS order_id \gset

SELECT is(
    (SELECT total_amount FROM orders WHERE id = :'order_id'::uuid),
    3100::bigint,
    'create_order computes totals from a mix of priced and ad hoc items'
);

SELECT is(
    (SELECT status::text FROM orders WHERE id = :'order_id'::uuid),
    'pending',
    'a freshly created order starts pending'
);

SELECT is(
    (SELECT count(*)::int FROM order_items WHERE order_id = :'order_id'::uuid),
    2,
    'one order_item row per item passed to create_order'
);

SELECT throws_ok(
    format($fmt$ UPDATE orders SET total_amount = 1 WHERE id = '%s'::uuid $fmt$, :'order_id'),
    '0A000',
    NULL,
    'orders content is immutable once placed'
);

SELECT lives_ok(
    format($fmt$ UPDATE orders SET metadata = '{"note":"post-placement"}'::jsonb WHERE id = '%s'::uuid $fmt$, :'order_id'),
    'orders metadata remains mutable after placement, unlike the other content fields'
);

SELECT throws_ok(
    $$ SELECT create_order('customer-1', 'USD', jsonb_build_array(jsonb_build_object('unit_amount', -100, 'quantity', 1))) $$,
    '22023',
    NULL,
    'create_order rejects a negative unit_amount on an ad hoc item'
);

SELECT create_order(
    'customer-2', 'USD',
    jsonb_build_array(jsonb_build_object('unit_amount', 500, 'quantity', 1)),
    p_idempotency_key := 'order-idem-1'
) AS idem_order_1 \gset

SELECT create_order(
    'customer-2', 'USD',
    jsonb_build_array(jsonb_build_object('unit_amount', 500, 'quantity', 1)),
    p_idempotency_key := 'order-idem-1'
) AS idem_order_2 \gset

SELECT is(:'idem_order_1'::uuid, :'idem_order_2'::uuid, 'create_order with a repeated idempotency_key returns the original order id');

SELECT lives_ok(
    format($fmt$ SELECT cancel_order('%s'::uuid) $fmt$, :'idem_order_1'),
    'cancel_order succeeds on a pending order'
);

SELECT throws_ok(
    format($fmt$ SELECT cancel_order('%s'::uuid) $fmt$, :'idem_order_1'),
    '55000',
    NULL,
    'cancel_order rejects an order that is not pending'
);

-- ==============================
-- PAYMENT INTENTS + REFUNDS API
-- ==============================

SELECT create_payment_intent('stripe', 'USD', 3100, :'order_id'::uuid) AS intent_id \gset

SELECT create_payment_intent('stripe', 'USD', 500, p_idempotency_key := 'intent-idem-1') AS idem_intent_1 \gset
SELECT create_payment_intent('stripe', 'USD', 500, p_idempotency_key := 'intent-idem-1') AS idem_intent_2 \gset

SELECT is(:'idem_intent_1'::uuid, :'idem_intent_2'::uuid, 'create_payment_intent with a repeated idempotency_key returns the original intent id');

SELECT throws_ok(
    format($fmt$ UPDATE payment_intents SET amount = 1 WHERE id = '%s'::uuid $fmt$, :'intent_id'),
    '0A000',
    NULL,
    'payment_intents core fields are immutable once created'
);

SELECT lives_ok(
    format($fmt$ SELECT mark_payment_intent_succeeded('%s'::uuid) $fmt$, :'intent_id'),
    'mark_payment_intent_succeeded runs without error'
);

SELECT is(
    (SELECT status::text FROM orders WHERE id = :'order_id'::uuid),
    'paid',
    'a succeeded payment_intent rolls the linked order up to paid'
);

SELECT create_refund(:'intent_id'::uuid) AS refund_id \gset

SELECT throws_ok(
    format($fmt$ SELECT create_refund('%s'::uuid, 1) $fmt$, :'intent_id'),
    '23514',
    NULL,
    'create_refund rejects a further refund once the intent is fully refunded'
);

SELECT mark_payment_intent_succeeded(:'idem_intent_1'::uuid);

SELECT create_refund(:'idem_intent_1'::uuid, 100, p_idempotency_key := 'refund-idem-1') AS idem_refund_1 \gset
SELECT create_refund(:'idem_intent_1'::uuid, 100, p_idempotency_key := 'refund-idem-1') AS idem_refund_2 \gset

SELECT is(:'idem_refund_1'::uuid, :'idem_refund_2'::uuid, 'create_refund with a repeated idempotency_key returns the original refund id');

SELECT is(
    (SELECT coalesce(sum(amount), 0)::bigint FROM refunds WHERE payment_intent_id = :'idem_intent_1'::uuid),
    100::bigint,
    'a repeated idempotency_key does not double-refund'
);

SELECT lives_ok(
    format($fmt$ SELECT mark_refund_succeeded('%s'::uuid) $fmt$, :'refund_id'),
    'mark_refund_succeeded runs without error'
);

SELECT is(
    (SELECT status::text FROM orders WHERE id = :'order_id'::uuid),
    'refunded',
    'a fully refunded payment_intent rolls the linked order up to refunded'
);

-- ==============================
-- WEBHOOKS: WORKER API
-- ==============================

SELECT throws_ok(
    $$ SELECT record_webhook_event('stripe', NULL, 'evt_missing_type', '{}'::jsonb) $$,
    '22023',
    NULL,
    'record_webhook_event rejects a null event_type instead of surfacing a raw not_null_violation'
);

SELECT throws_ok(
    $$ SELECT record_webhook_event('stripe', '', 'evt_missing_type', '{}'::jsonb) $$,
    '22023',
    NULL,
    'record_webhook_event rejects an empty event_type'
);

SELECT record_webhook_event('stripe', 'payment_intent.succeeded', 'evt_1', '{"foo":"bar"}'::jsonb) AS webhook_id_1 \gset
SELECT record_webhook_event('stripe', 'payment_intent.succeeded', 'evt_1', '{"foo":"bar"}'::jsonb) AS webhook_id_2 \gset

SELECT is(:'webhook_id_1'::uuid, :'webhook_id_2'::uuid, 'record_webhook_event absorbs a replayed (provider, provider_event_id) pair');

SELECT is(
    (SELECT count(*)::int FROM claim_webhook_events(10, 'stripe')),
    1,
    'claim_webhook_events claims the pending webhook event'
);

SELECT is(
    (SELECT status::text FROM webhook_events WHERE id = :'webhook_id_1'::uuid),
    'processing',
    'a claimed webhook event is marked processing'
);

SELECT lives_ok(
    format($fmt$ SELECT mark_webhook_event_processed('%s'::uuid) $fmt$, :'webhook_id_1'),
    'mark_webhook_event_processed runs without error'
);

SELECT record_webhook_event('stripe', 'charge.failed', 'evt_2', '{}'::jsonb) AS webhook_id_3 \gset

SELECT is(
    (SELECT count(*)::int FROM claim_webhook_events(10, 'stripe')),
    1,
    'claim_webhook_events claims the second pending webhook event'
);

SELECT lives_ok(
    format($fmt$ SELECT mark_webhook_event_failed('%s'::uuid, 'boom', false) $fmt$, :'webhook_id_3'),
    'mark_webhook_event_failed runs without error'
);

SELECT is(
    (SELECT status::text FROM webhook_events WHERE id = :'webhook_id_3'::uuid),
    'pending',
    'mark_webhook_event_failed requeues a non-permanent failure back to pending'
);

-- Finalize webhook_id_3 so it doesn't linger as 'pending' and get swept up by the
-- claim_webhook_events assertions further down.
SELECT mark_webhook_event_failed(:'webhook_id_3'::uuid, 'giving up', true);

SELECT record_webhook_event('stripe', 'charge.failed', 'evt_permanent', '{}'::jsonb) AS webhook_id_4 \gset
SELECT lives_ok(
    format($fmt$ SELECT mark_webhook_event_failed('%s'::uuid, 'boom', true) $fmt$, :'webhook_id_4'),
    'mark_webhook_event_failed(permanent := true) runs without error'
);

SELECT is(
    (SELECT status::text FROM webhook_events WHERE id = :'webhook_id_4'::uuid),
    'failed',
    'mark_webhook_event_failed(permanent := true) marks the event failed'
);

SELECT is(
    (SELECT failed_at IS NOT NULL FROM webhook_events WHERE id = :'webhook_id_4'::uuid),
    true,
    'mark_webhook_event_failed(permanent := true) records failed_at for observability'
);

SELECT record_webhook_event('stripe', 'charge.failed', 'evt_stuck', '{}'::jsonb) AS webhook_id_5 \gset

SELECT is(
    (SELECT count(*)::int FROM claim_webhook_events(10, 'stripe')),
    1,
    'claim_webhook_events claims the stuck-test webhook event'
);

SELECT is(
    (SELECT count(*)::int FROM claim_webhook_events(10, 'stripe')),
    0,
    'claim_webhook_events does not reclaim a processing event that was claimed moments ago'
);

UPDATE webhook_events SET claimed_at = now() - interval '1 hour' WHERE id = :'webhook_id_5'::uuid;

SELECT is(
    (SELECT count(*)::int FROM claim_webhook_events(10, 'stripe')),
    1,
    'claim_webhook_events reclaims a webhook event stuck in processing past the stuck-after threshold, so a crashed worker cannot strand it forever'
);

-- ==============================
-- SUBSCRIPTIONS API
-- ==============================

SELECT create_price(:'product_id'::uuid, 'USD', 900) AS active_onetime_price_id \gset

SELECT throws_ok(
    format($fmt$ SELECT create_subscription('customer-3', '%s'::uuid) $fmt$, :'active_onetime_price_id'),
    '22023',
    NULL,
    'create_subscription rejects a non-recurring price'
);

SELECT create_price(:'product_id'::uuid, 'USD', 2000, 'recurring', 'month') AS inactive_monthly_price_id \gset
SELECT deactivate_price(:'inactive_monthly_price_id'::uuid);

SELECT throws_ok(
    format($fmt$ SELECT create_subscription('customer-3', '%s'::uuid) $fmt$, :'inactive_monthly_price_id'),
    '55000',
    NULL,
    'create_subscription rejects an inactive price'
);

SELECT create_subscription('customer-3', :'monthly_price_id'::uuid, p_idempotency_key := 'sub-idem-1') AS idem_sub_1 \gset
SELECT create_subscription('customer-3', :'monthly_price_id'::uuid, p_idempotency_key := 'sub-idem-1') AS idem_sub_2 \gset

SELECT is(:'idem_sub_1'::uuid, :'idem_sub_2'::uuid, 'create_subscription with a repeated idempotency_key returns the original subscription id');

SELECT throws_ok(
    format($fmt$ SELECT change_subscription_price('%s'::uuid, '%s'::uuid) $fmt$, :'idem_sub_1', :'inactive_monthly_price_id'),
    '55000',
    NULL,
    'change_subscription_price rejects switching to an inactive price'
);

SELECT create_subscription('customer-3', :'monthly_price_id'::uuid) AS subscription_id \gset

SELECT is(
    (SELECT status::text FROM subscriptions WHERE id = :'subscription_id'::uuid),
    'active',
    'a subscription created with no trial starts active'
);

SELECT renew_subscription(:'subscription_id'::uuid) AS renewal_order_id \gset

SELECT is(
    (SELECT latest_order_id FROM subscriptions WHERE id = :'subscription_id'::uuid),
    :'renewal_order_id'::uuid,
    'renew_subscription records the new cycle order on the subscription'
);

SELECT cmp_ok(
    (SELECT current_period_start FROM subscriptions WHERE id = :'subscription_id'::uuid),
    '>',
    (SELECT created_at FROM subscriptions WHERE id = :'subscription_id'::uuid),
    'renew_subscription advances current_period_start'
);

SELECT lives_ok(
    format($fmt$ SELECT cancel_subscription('%s'::uuid, true) $fmt$, :'subscription_id'),
    'cancel_subscription(at_period_end := true) runs without error'
);

SELECT is(
    (SELECT cancel_at_period_end FROM subscriptions WHERE id = :'subscription_id'::uuid),
    true,
    'cancel_subscription(at_period_end := true) flags the subscription rather than cancelling immediately'
);

SELECT is(
    renew_subscription(:'subscription_id'::uuid),
    NULL::uuid,
    'renew_subscription returns no order once cancel_at_period_end takes effect'
);

SELECT is(
    (SELECT status::text FROM subscriptions WHERE id = :'subscription_id'::uuid),
    'cancelled',
    'renew_subscription finalizes the cancellation instead of billing another cycle'
);

-- ==============================
-- FEATURES & ENTITLEMENTS
-- ==============================

SELECT is(
    (SELECT is_addon FROM products WHERE id = :'product_id'::uuid),
    false,
    'create_product defaults is_addon to false'
);

SELECT create_feature('api_calls', 'API Calls', 'limit', p_unit := 'calls') AS api_calls_feature \gset
SELECT create_feature('sso', 'SSO', 'boolean') AS sso_feature \gset

SELECT set_price_entitlement(:'monthly_price_id'::uuid, 'api_calls', p_value_limit := 1000);
SELECT set_price_entitlement(:'monthly_price_id'::uuid, 'sso', p_value_boolean := false);

SELECT create_subscription('customer-4', :'monthly_price_id'::uuid) AS feature_sub_id \gset

SELECT is(
    (SELECT value_limit FROM check_feature_entitlement(:'feature_sub_id'::uuid, 'api_calls')),
    1000::bigint,
    'create_subscription recomputes entitlements from the plan price'
);

SELECT is(
    (SELECT allowed FROM check_feature_entitlement(:'feature_sub_id'::uuid, 'sso')),
    false,
    'a boolean feature the plan sets false is not allowed'
);

INSERT INTO products (name, is_addon) VALUES ('Extra API Calls', true) RETURNING id AS addon_product_id \gset
SELECT create_price(:'addon_product_id'::uuid, 'USD', 500, 'recurring', 'month') AS addon_price_id \gset
SELECT set_price_entitlement(:'addon_price_id'::uuid, 'api_calls', p_value_limit := 5000);
SELECT set_price_entitlement(:'addon_price_id'::uuid, 'sso', p_value_boolean := true);

SELECT throws_ok(
    format($fmt$ SELECT add_subscription_addon('%s'::uuid, '%s'::uuid) $fmt$, :'feature_sub_id', :'monthly_price_id'),
    'P0002',
    NULL,
    'add_subscription_addon rejects a price whose product is not flagged is_addon'
);

SELECT add_subscription_addon(:'feature_sub_id'::uuid, :'addon_price_id'::uuid) AS feature_addon_id \gset

SELECT is(
    (SELECT value_limit FROM check_feature_entitlement(:'feature_sub_id'::uuid, 'api_calls')),
    5000::bigint,
    'an active addon entitlement merges with the plan entitlement, taking the larger limit'
);

SELECT is(
    (SELECT allowed FROM check_feature_entitlement(:'feature_sub_id'::uuid, 'sso')),
    true,
    'a boolean feature is OR-merged across plan and addon, so the addon can turn it on'
);

SELECT remove_subscription_addon(:'feature_addon_id'::uuid);

SELECT is(
    (SELECT value_limit FROM check_feature_entitlement(:'feature_sub_id'::uuid, 'api_calls')),
    1000::bigint,
    'removing the addon recomputes entitlements back down to the plan-only value'
);

SELECT is(
    (SELECT allowed FROM check_feature_entitlement(:'feature_sub_id'::uuid, 'sso')),
    false,
    'removing the addon also drops the boolean feature it had turned on'
);

-- ==============================
-- SEATS, PAUSE/RESUME
-- ==============================

SELECT throws_ok(
    format($fmt$ SELECT set_subscription_quantity('%s'::uuid, 0) $fmt$, :'feature_sub_id'),
    '22023',
    NULL,
    'set_subscription_quantity rejects a non-positive quantity'
);

SELECT lives_ok(
    format($fmt$ SELECT set_subscription_quantity('%s'::uuid, 5) $fmt$, :'feature_sub_id'),
    'set_subscription_quantity accepts a positive quantity'
);

SELECT is(
    (SELECT quantity FROM subscriptions WHERE id = :'feature_sub_id'::uuid),
    5,
    'set_subscription_quantity updates the subscription seat count'
);

SELECT lives_ok(
    format($fmt$ SELECT pause_subscription('%s'::uuid) $fmt$, :'feature_sub_id'),
    'pause_subscription runs without error on an active subscription'
);

SELECT is(
    (SELECT status::text FROM subscriptions WHERE id = :'feature_sub_id'::uuid),
    'paused',
    'pause_subscription transitions the subscription to paused'
);

SELECT throws_ok(
    format($fmt$ SELECT pause_subscription('%s'::uuid) $fmt$, :'feature_sub_id'),
    '55000',
    NULL,
    'pause_subscription rejects a subscription that is already paused'
);

SELECT lives_ok(
    format($fmt$ SELECT resume_subscription('%s'::uuid) $fmt$, :'feature_sub_id'),
    'resume_subscription runs without error on a paused subscription'
);

SELECT is(
    (SELECT status::text FROM subscriptions WHERE id = :'feature_sub_id'::uuid),
    'active',
    'resume_subscription transitions the subscription back to active'
);

SELECT throws_ok(
    format($fmt$ SELECT resume_subscription('%s'::uuid) $fmt$, :'feature_sub_id'),
    '55000',
    NULL,
    'resume_subscription rejects a subscription that is not paused'
);

-- ==============================
-- SUBSCRIPTION CHANGE REQUESTS
-- ==============================

SELECT create_price(:'product_id'::uuid, 'USD', 3000, 'recurring', 'month') AS plan_price_v2 \gset

SELECT create_subscription_change_request(
    'customer-4', 'upgrade', :'feature_sub_id'::uuid, :'plan_price_v2'::uuid,
    p_idempotency_key := 'change-req-idem-1'
) AS change_request_1 \gset

SELECT create_subscription_change_request(
    'customer-4', 'upgrade', :'feature_sub_id'::uuid, :'plan_price_v2'::uuid,
    p_idempotency_key := 'change-req-idem-1'
) AS change_request_2 \gset

SELECT is(
    :'change_request_1'::uuid, :'change_request_2'::uuid,
    'create_subscription_change_request with a repeated idempotency_key returns the original request id'
);

SELECT lives_ok(
    format($fmt$ SELECT apply_subscription_change_request('%s'::uuid) $fmt$, :'change_request_1'),
    'apply_subscription_change_request runs without error for a pending upgrade request'
);

SELECT is(
    (SELECT price_id FROM subscriptions WHERE id = :'feature_sub_id'::uuid),
    :'plan_price_v2'::uuid,
    'apply_subscription_change_request dispatches an upgrade to change_subscription_price'
);

SELECT is(
    (SELECT status::text FROM subscription_change_requests WHERE uid = :'change_request_1'::uuid),
    'completed',
    'apply_subscription_change_request marks the request completed on success'
);

SELECT throws_ok(
    format($fmt$ SELECT apply_subscription_change_request('%s'::uuid) $fmt$, :'change_request_1'),
    '55000',
    NULL,
    'apply_subscription_change_request rejects a request that is not pending/awaiting_payment'
);

SELECT create_subscription_change_request('customer-4', 'cancel', :'feature_sub_id'::uuid) AS change_request_3 \gset

UPDATE subscription_change_requests SET expires_at = now() - interval '1 minute' WHERE uid = :'change_request_3'::uuid;

SELECT is(
    expire_subscription_change_requests(),
    1,
    'expire_subscription_change_requests expires exactly the one request past its expires_at'
);

SELECT is(
    (SELECT status::text FROM subscription_change_requests WHERE uid = :'change_request_3'::uuid),
    'expired',
    'expire_subscription_change_requests marks the stale request expired'
);

SELECT throws_ok(
    format($fmt$ SELECT apply_subscription_change_request('%s'::uuid) $fmt$, :'change_request_3'),
    '55000',
    NULL,
    'apply_subscription_change_request rejects an expired request'
);

-- ==============================
-- USAGE TRACKING
-- ==============================

SELECT create_feature('emails_sent', 'Emails Sent', 'metered', p_unit := 'emails') AS emails_feature \gset

SELECT record_usage(
    'customer-4', 'emails_sent', '2026-07-01'::timestamptz, '2026-08-01'::timestamptz,
    p_quantity := 10, p_subscription_id := :'feature_sub_id'::uuid, p_idempotency_key := 'usage-idem-1'
) AS usage_1 \gset

SELECT record_usage(
    'customer-4', 'emails_sent', '2026-07-01'::timestamptz, '2026-08-01'::timestamptz,
    p_quantity := 10, p_subscription_id := :'feature_sub_id'::uuid, p_idempotency_key := 'usage-idem-1'
) AS usage_2 \gset

SELECT is(:'usage_1'::uuid, :'usage_2'::uuid, 'record_usage with a repeated idempotency_key returns the original usage record id');

SELECT record_usage(
    'customer-4', 'emails_sent', '2026-07-01'::timestamptz, '2026-08-01'::timestamptz,
    p_quantity := 5, p_subscription_id := :'feature_sub_id'::uuid
) AS usage_3 \gset

SELECT is(
    (SELECT total_quantity FROM usage_summaries WHERE subscription_id = :'feature_sub_id'::uuid AND feature_key = 'emails_sent'),
    15::bigint,
    'usage_summaries sums distinct usage_records for the same period, but a repeated idempotency_key does not double-count'
);

-- ==============================
-- INVOICING & CREDIT NOTES
-- ==============================

SELECT create_order(
    'customer-4', 'USD',
    jsonb_build_array(jsonb_build_object('price_id', :'plan_price_v2'::uuid, 'quantity', 1))
) AS invoice_order_id \gset

SELECT create_invoice(
    'customer-4', 'USD', :'feature_sub_id'::uuid, :'invoice_order_id'::uuid, 'subscription_cycle',
    p_idempotency_key := 'invoice-idem-1'
) AS invoice_1 \gset

SELECT create_invoice(
    'customer-4', 'USD', :'feature_sub_id'::uuid, :'invoice_order_id'::uuid, 'subscription_cycle',
    p_idempotency_key := 'invoice-idem-1'
) AS invoice_2 \gset

SELECT is(:'invoice_1'::uuid, :'invoice_2'::uuid, 'create_invoice with a repeated idempotency_key returns the original invoice id');

SELECT is(
    (SELECT subtotal_amount FROM invoices WHERE uid = :'invoice_1'::uuid),
    3000::bigint,
    'create_invoice seeds subtotal_amount from the linked order'
);

SELECT add_invoice_line_item(:'invoice_1'::uuid, 'tax', 'VAT 5%', 150) AS tax_line_item_id \gset

SELECT is(
    (SELECT total_amount FROM invoices WHERE uid = :'invoice_1'::uuid),
    3150::bigint,
    'add_invoice_line_item recomputes total_amount from the order subtotal plus line items'
);

SELECT throws_ok(
    format($fmt$ SELECT add_invoice_line_item('%s'::uuid, 'bogus', 'x', 100) $fmt$, :'invoice_1'),
    '23514',
    NULL,
    'add_invoice_line_item rejects a type outside the allowed set'
);

SELECT lives_ok(
    format($fmt$ SELECT finalize_invoice('%s'::uuid) $fmt$, :'invoice_1'),
    'finalize_invoice runs without error on a draft invoice'
);

SELECT is(
    (SELECT status::text FROM invoices WHERE uid = :'invoice_1'::uuid),
    'open',
    'finalize_invoice transitions the invoice from draft to open'
);

SELECT throws_ok(
    format($fmt$ SELECT add_invoice_line_item('%s'::uuid, 'tax', 'late fee', 10) $fmt$, :'invoice_1'),
    '55000',
    NULL,
    'add_invoice_line_item rejects a non-draft invoice'
);

SELECT lives_ok(
    format($fmt$ SELECT mark_invoice_paid('%s'::uuid) $fmt$, :'invoice_1'),
    'mark_invoice_paid runs without error on an open invoice'
);

SELECT is(
    (SELECT status::text FROM invoices WHERE uid = :'invoice_1'::uuid),
    'paid',
    'mark_invoice_paid with no explicit amount pays the invoice in full'
);

SELECT is(
    (SELECT amount_due FROM invoices WHERE uid = :'invoice_1'::uuid),
    0::bigint,
    'a fully paid invoice has no amount due'
);

SELECT throws_ok(
    format($fmt$ SELECT void_invoice('%s'::uuid) $fmt$, :'invoice_1'),
    '55000',
    NULL,
    'void_invoice rejects a paid invoice -- it must be adjusted with a credit note instead'
);

SELECT issue_credit_note(:'invoice_1'::uuid, 'order_change', 500) AS credit_note_1 \gset

SELECT is(
    (SELECT total_amount FROM credit_notes WHERE uid = :'credit_note_1'::uuid),
    500::bigint,
    'issue_credit_note records the requested amount'
);

SELECT throws_ok(
    format($fmt$ SELECT issue_credit_note('%s'::uuid, 'order_change', 5000) $fmt$, :'invoice_1'),
    '23514',
    NULL,
    'issue_credit_note rejects an amount that would exceed the invoice total once already-issued credits are included'
);

SELECT lives_ok(
    format($fmt$ SELECT void_credit_note('%s'::uuid) $fmt$, :'credit_note_1'),
    'void_credit_note runs without error on an issued credit note'
);

SELECT is(
    (SELECT status::text FROM credit_notes WHERE uid = :'credit_note_1'::uuid),
    'void',
    'void_credit_note transitions the credit note to void'
);

SELECT throws_ok(
    format($fmt$ SELECT void_credit_note('%s'::uuid) $fmt$, :'credit_note_1'),
    '55000',
    NULL,
    'void_credit_note rejects a credit note that is not issued'
);

-- ==============================
-- ENTERPRISE CONTRACTS
-- ==============================

SELECT throws_ok(
    format(
        $fmt$ INSERT INTO subscription_contracts (customer_id, subscription_id, start_date, end_date)
              VALUES ('customer-4', '%s'::uuid, '2026-06-01', '2026-01-01') $fmt$,
        :'feature_sub_id'
    ),
    '23514',
    NULL,
    'subscription_contracts rejects an end_date before start_date'
);

SELECT lives_ok(
    format(
        $fmt$ INSERT INTO subscription_contracts (customer_id, subscription_id, start_date, sla_tier, signed_by)
              VALUES ('customer-4', '%s'::uuid, '2026-06-01', 'gold', 'jane@example.com') $fmt$,
        :'feature_sub_id'
    ),
    'subscription_contracts accepts a decoupled, plain-text signed_by identifier'
);

SELECT is(
    (SELECT status::text FROM subscription_contracts WHERE customer_id = 'customer-4'),
    'draft',
    'a freshly inserted contract defaults to draft status'
);

SELECT * FROM finish();
ROLLBACK;
