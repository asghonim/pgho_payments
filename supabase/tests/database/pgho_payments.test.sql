BEGIN;

SET search_path TO pgho_payments, public;

SELECT plan(71);

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

SELECT * FROM finish();
ROLLBACK;
