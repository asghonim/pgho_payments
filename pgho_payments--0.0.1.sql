-- pgho_payments: ledger-first payments, wallets, catalog, orders, and subscriptions
--
-- Money is represented by an immutable double-entry ledger (ledger_accounts /
-- ledger_transactions / ledger_entries); every other module -- wallets, orders, payment
-- intents, refunds, subscriptions -- keeps its own state and correlates to the ledger only
-- loosely, via ledger_transactions.reference_type/reference_id. The ledger module has no
-- FKs pointing at commerce tables, so it can be used entirely on its own.
--
-- post_transaction() is the only sanctioned way to write ledger_entries: it enforces that
-- every transaction's entries sum to zero per currency before anything is inserted.
--
-- Providers (stripe, paypal, paymob, wallet, ...) are plain text throughout, not enums, so
-- integrating a new provider never requires a schema change -- only a worker that claims
-- webhook_events for it via claim_webhook_events().
--
-- Out of scope for this version (candidates for a later extension): invoices, coupons, tax,
-- credit notes, gift cards, payouts, revenue-share/marketplace splits, disputes, proration.

-- ==============================
-- TYPES
-- ==============================

-- Wallet lifecycle is a closed set; frozen wallets can be read but not moved.
CREATE TYPE wallet_status AS ENUM (
    'active',
    'frozen',
    'closed'
);

CREATE TYPE price_type AS ENUM (
    'one_time',
    'recurring'
);

CREATE TYPE billing_interval AS ENUM (
    'day',
    'week',
    'month',
    'year'
);

CREATE TYPE order_status AS ENUM (
    'pending',
    'paid',
    'failed',
    'cancelled',
    'refunded',
    'partially_refunded'
);

CREATE TYPE payment_intent_status AS ENUM (
    'requires_payment_method',
    'processing',
    'requires_action',
    'succeeded',
    'failed',
    'cancelled'
);

CREATE TYPE refund_status AS ENUM (
    'pending',
    'succeeded',
    'failed',
    'cancelled'
);

CREATE TYPE webhook_event_status AS ENUM (
    'pending',
    'processing',
    'processed',
    'failed'
);

CREATE TYPE subscription_status AS ENUM (
    'trialing',
    'active',
    'past_due',
    'cancelled',
    'incomplete'
);

-- ==============================
-- TABLES
-- ==============================

-- ---- Ledger ----

CREATE TABLE ledger_accounts (
    id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    text,
    owner_type   text        NOT NULL,
    owner_id     text        NOT NULL,
    account_type text        NOT NULL,
    name         text,
    metadata     jsonb       NOT NULL DEFAULT '{}',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE @extschema@.ledger_accounts IS 'One node in the chart of accounts; owner_type/owner_id/account_type are open text (wallet, revenue, fees, processor_clearing, ...) so new account kinds never require a schema change';

CREATE TABLE ledger_transactions (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       text,
    type            text        NOT NULL,
    reference_type  text,
    reference_id    text,
    description     text,
    metadata        jsonb       NOT NULL DEFAULT '{}',
    idempotency_key text,
    created_by      text,
    created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE @extschema@.ledger_transactions IS 'Append-only header grouping a balanced set of ledger_entries; reference_type/reference_id optionally correlate to a commerce row (order, payment_intent, refund, ...) without an FK, keeping the ledger usable standalone';

CREATE TABLE ledger_entries (
    id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id bigint      NOT NULL REFERENCES ledger_transactions(id) ON DELETE RESTRICT,
    account_id     bigint      NOT NULL REFERENCES ledger_accounts(id)     ON DELETE RESTRICT,
    currency       text        NOT NULL,
    amount         bigint      NOT NULL CHECK (amount <> 0),
    created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE @extschema@.ledger_entries IS 'Append-only journal lines in minor currency units; signed (credit > 0, debit < 0). Entries for a transaction_id must sum to zero per currency -- enforced by post_transaction(), the only sanctioned write path';

CREATE TABLE ledger_account_balances (
    account_id bigint      NOT NULL REFERENCES ledger_accounts(id) ON DELETE CASCADE,
    currency   text        NOT NULL,
    balance    bigint      NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, currency)
);

COMMENT ON TABLE @extschema@.ledger_account_balances IS 'Rollup cache recomputed from ledger_entries by sync_account_balance(); never written to directly';

CREATE TABLE wallets (
    id                uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id         text,
    owner_type        text          NOT NULL,
    owner_id          text          NOT NULL,
    wallet_type       text          NOT NULL DEFAULT 'main',
    ledger_account_id bigint        NOT NULL REFERENCES ledger_accounts(id) ON DELETE RESTRICT,
    status            wallet_status NOT NULL DEFAULT 'active',
    default_currency  text,
    metadata          jsonb         NOT NULL DEFAULT '{}',
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, owner_type, owner_id, wallet_type)
);

COMMENT ON TABLE @extschema@.wallets IS 'A named balance for an owner (user, organization, system); the actual balance lives in the backing ledger_account, never stored here directly';

-- ---- Catalog ----

CREATE TABLE products (
    id          uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id   text,
    name        text        NOT NULL,
    description text,
    active      boolean     NOT NULL DEFAULT true,
    metadata    jsonb       NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE prices (
    id               uuid             NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    product_id       uuid             NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    currency         text             NOT NULL,
    unit_amount      bigint           NOT NULL CHECK (unit_amount >= 0),
    type             price_type       NOT NULL DEFAULT 'one_time',
    billing_interval billing_interval,
    interval_count   integer          NOT NULL DEFAULT 1 CHECK (interval_count > 0),
    active           boolean          NOT NULL DEFAULT true,
    metadata         jsonb            NOT NULL DEFAULT '{}',
    created_at       timestamptz      NOT NULL DEFAULT now(),
    CHECK ( (type = 'recurring') = (billing_interval IS NOT NULL) )
);

COMMENT ON TABLE @extschema@.prices IS 'Immutable price points for a product; superseding a price means creating a new row and deactivating the old one, so historical orders/subscriptions keep referencing stable amounts';

-- ---- Orders ----

CREATE TABLE orders (
    id              uuid         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id       text,
    customer_id     text,
    status          order_status NOT NULL DEFAULT 'pending',
    currency        text         NOT NULL,
    subtotal_amount bigint       NOT NULL DEFAULT 0,
    total_amount    bigint       NOT NULL DEFAULT 0,
    metadata        jsonb        NOT NULL DEFAULT '{}',
    idempotency_key text,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE @extschema@.orders IS 'Immutable snapshot of a purchase once created; only status/updated_at may change afterward (see prevent_order_content_mutation)';

CREATE TABLE order_items (
    id           uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id     uuid        NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id   uuid        REFERENCES products(id) ON DELETE SET NULL,
    price_id     uuid        REFERENCES prices(id)   ON DELETE SET NULL,
    description  text,
    unit_amount  bigint      NOT NULL,
    quantity     integer     NOT NULL DEFAULT 1 CHECK (quantity > 0),
    amount_total bigint      NOT NULL,
    currency     text        NOT NULL,
    metadata     jsonb       NOT NULL DEFAULT '{}',
    created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE @extschema@.order_items IS 'unit_amount/amount_total are snapshotted from the price at order time; later price changes never retroactively affect a placed order';

-- ---- Payments ----

CREATE TABLE payment_intents (
    id                  uuid                  NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id           text,
    order_id            uuid                  REFERENCES orders(id) ON DELETE SET NULL,
    provider            text                  NOT NULL,
    provider_intent_id  text,
    status              payment_intent_status NOT NULL DEFAULT 'requires_payment_method',
    currency            text                  NOT NULL,
    amount              bigint                NOT NULL CHECK (amount > 0),
    client_secret       text,
    payment_method_type text,
    last_error          text,
    metadata            jsonb                 NOT NULL DEFAULT '{}',
    idempotency_key     text,
    created_at          timestamptz           NOT NULL DEFAULT now(),
    updated_at          timestamptz           NOT NULL DEFAULT now(),
    succeeded_at        timestamptz,
    failed_at           timestamptz,
    cancelled_at        timestamptz
);

COMMENT ON TABLE @extschema@.payment_intents IS 'Represents intent to collect a payment before contacting a provider; provider is open text (stripe, paypal, paymob, wallet, ...) like outbox channels';

CREATE TABLE refunds (
    id                 uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id          text,
    payment_intent_id  uuid          NOT NULL REFERENCES payment_intents(id) ON DELETE RESTRICT,
    provider           text,
    provider_refund_id text,
    status             refund_status NOT NULL DEFAULT 'pending',
    currency           text          NOT NULL,
    amount             bigint        NOT NULL CHECK (amount > 0),
    reason             text,
    metadata           jsonb         NOT NULL DEFAULT '{}',
    idempotency_key    text,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    succeeded_at       timestamptz,
    failed_at          timestamptz
);

CREATE TABLE webhook_events (
    id                 uuid                 NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    provider           text                 NOT NULL,
    event_type         text                 NOT NULL,
    provider_event_id  text                 NOT NULL,
    status             webhook_event_status NOT NULL DEFAULT 'pending',
    payload            jsonb                NOT NULL,
    attempts           integer              NOT NULL DEFAULT 0,
    last_error         text,
    received_at        timestamptz          NOT NULL DEFAULT now(),
    claimed_at         timestamptz,
    processed_at       timestamptz,
    failed_at          timestamptz,
    UNIQUE (provider, provider_event_id)
);

COMMENT ON TABLE @extschema@.webhook_events IS 'Raw provider webhook payloads; (provider, provider_event_id) is the natural idempotency key so replayed webhooks are absorbed by record_webhook_event()''s ON CONFLICT';

-- ---- Subscriptions ----

CREATE TABLE subscriptions (
    id                    uuid                NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id             text,
    customer_id           text,
    price_id              uuid                NOT NULL REFERENCES prices(id) ON DELETE RESTRICT,
    status                subscription_status NOT NULL DEFAULT 'incomplete',
    current_period_start  timestamptz         NOT NULL DEFAULT now(),
    current_period_end    timestamptz         NOT NULL,
    cancel_at_period_end  boolean             NOT NULL DEFAULT false,
    cancelled_at          timestamptz,
    trial_end             timestamptz,
    latest_order_id       uuid                REFERENCES orders(id) ON DELETE SET NULL,
    metadata              jsonb               NOT NULL DEFAULT '{}',
    idempotency_key       text,
    created_at            timestamptz         NOT NULL DEFAULT now(),
    updated_at            timestamptz         NOT NULL DEFAULT now()
);

CREATE TABLE subscription_events (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id uuid        NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    type            text        NOT NULL,
    payload         jsonb       NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE @extschema@.subscription_events IS 'Append-only audit trail: created, renewed, price_changed, cancelled, past_due, ...';

-- ==============================
-- INDEXES
-- ==============================

CREATE INDEX ledger_accounts_tenant_idx ON ledger_accounts (tenant_id) WHERE tenant_id IS NOT NULL;
CREATE INDEX ledger_accounts_owner_idx  ON ledger_accounts (owner_type, owner_id);

CREATE INDEX ledger_transactions_reference_idx ON ledger_transactions (reference_type, reference_id) WHERE reference_type IS NOT NULL;
CREATE INDEX ledger_transactions_tenant_idx    ON ledger_transactions (tenant_id) WHERE tenant_id IS NOT NULL;
CREATE INDEX ledger_transactions_type_idx      ON ledger_transactions (type);
CREATE INDEX ledger_transactions_created_idx   ON ledger_transactions (created_at DESC);
CREATE UNIQUE INDEX ledger_transactions_idempotency_key_idx ON ledger_transactions (idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE INDEX ledger_entries_transaction_idx ON ledger_entries (transaction_id);
CREATE INDEX ledger_entries_account_idx     ON ledger_entries (account_id, currency);

CREATE INDEX wallets_tenant_idx         ON wallets (tenant_id) WHERE tenant_id IS NOT NULL;
CREATE INDEX wallets_owner_idx          ON wallets (owner_type, owner_id);
CREATE INDEX wallets_ledger_account_idx ON wallets (ledger_account_id);

CREATE INDEX products_active_idx ON products (active) WHERE active = true;
CREATE INDEX products_tenant_idx ON products (tenant_id) WHERE tenant_id IS NOT NULL;

CREATE INDEX prices_product_idx ON prices (product_id);
CREATE INDEX prices_active_idx  ON prices (active) WHERE active = true;

CREATE INDEX orders_status_idx   ON orders (status);
CREATE INDEX orders_customer_idx ON orders (customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX orders_tenant_idx   ON orders (tenant_id) WHERE tenant_id IS NOT NULL;
CREATE UNIQUE INDEX orders_idempotency_key_idx ON orders (idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE INDEX order_items_order_idx   ON order_items (order_id);
CREATE INDEX order_items_product_idx ON order_items (product_id) WHERE product_id IS NOT NULL;
CREATE INDEX order_items_price_idx   ON order_items (price_id) WHERE price_id IS NOT NULL;

CREATE INDEX payment_intents_status_idx ON payment_intents (status);
CREATE INDEX payment_intents_order_idx  ON payment_intents (order_id) WHERE order_id IS NOT NULL;
CREATE INDEX payment_intents_tenant_idx ON payment_intents (tenant_id) WHERE tenant_id IS NOT NULL;
CREATE UNIQUE INDEX payment_intents_provider_idx ON payment_intents (provider, provider_intent_id) WHERE provider_intent_id IS NOT NULL;
CREATE UNIQUE INDEX payment_intents_idempotency_key_idx ON payment_intents (idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE INDEX refunds_payment_intent_idx ON refunds (payment_intent_id);
CREATE INDEX refunds_status_idx         ON refunds (status);
CREATE UNIQUE INDEX refunds_provider_idx ON refunds (provider, provider_refund_id) WHERE provider_refund_id IS NOT NULL;
CREATE UNIQUE INDEX refunds_idempotency_key_idx ON refunds (idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE INDEX webhook_events_claim_idx      ON webhook_events (provider, status, received_at) WHERE status = 'pending';
CREATE INDEX webhook_events_processing_idx ON webhook_events (claimed_at) WHERE status = 'processing';

CREATE INDEX subscriptions_status_idx   ON subscriptions (status);
CREATE INDEX subscriptions_price_idx    ON subscriptions (price_id);
CREATE INDEX subscriptions_customer_idx ON subscriptions (customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX subscriptions_tenant_idx   ON subscriptions (tenant_id) WHERE tenant_id IS NOT NULL;
CREATE UNIQUE INDEX subscriptions_idempotency_key_idx ON subscriptions (idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX subscriptions_renewal_due_idx ON subscriptions (current_period_end) WHERE status IN ('active', 'trialing');

CREATE INDEX subscription_events_subscription_idx ON subscription_events (subscription_id);

-- ==============================
-- IMMUTABILITY
-- ==============================

-- ledger_transactions and ledger_entries are the audit spine: once posted, never touched.
-- A correction is made by posting a reversing transaction, never by editing history.
CREATE OR REPLACE FUNCTION prevent_ledger_transaction_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'ledger_transactions is append-only; % is not permitted', TG_OP
        USING ERRCODE = '0A000';
END;
$$;

CREATE TRIGGER ledger_transactions_no_update
    BEFORE UPDATE OR DELETE ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION prevent_ledger_transaction_mutation();

CREATE OR REPLACE FUNCTION prevent_ledger_entry_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'ledger_entries is append-only; % is not permitted', TG_OP
        USING ERRCODE = '0A000';
END;
$$;

CREATE TRIGGER ledger_entries_no_update
    BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION prevent_ledger_entry_mutation();

CREATE OR REPLACE FUNCTION prevent_ledger_account_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.tenant_id    IS DISTINCT FROM OLD.tenant_id
       OR NEW.owner_type   IS DISTINCT FROM OLD.owner_type
       OR NEW.owner_id     IS DISTINCT FROM OLD.owner_id
       OR NEW.account_type IS DISTINCT FROM OLD.account_type
       OR NEW.created_at   IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'ledger_accounts identity is immutable once created; only name/metadata may change'
            USING ERRCODE = '0A000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER ledger_accounts_immutable_content
    BEFORE UPDATE ON ledger_accounts
    FOR EACH ROW EXECUTE FUNCTION prevent_ledger_account_content_mutation();

-- Prices are immutable once created: only active/metadata may change. Changing the price
-- of a product means creating a new price row and deactivating the old one (see prices
-- table comment), so historical orders/subscriptions keep referencing stable amounts.
CREATE OR REPLACE FUNCTION prevent_price_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.product_id       IS DISTINCT FROM OLD.product_id
       OR NEW.currency         IS DISTINCT FROM OLD.currency
       OR NEW.unit_amount      IS DISTINCT FROM OLD.unit_amount
       OR NEW.type             IS DISTINCT FROM OLD.type
       OR NEW.billing_interval IS DISTINCT FROM OLD.billing_interval
       OR NEW.interval_count   IS DISTINCT FROM OLD.interval_count
       OR NEW.created_at       IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'prices content is immutable once created; only active/metadata may change'
            USING ERRCODE = '0A000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER prices_immutable_content
    BEFORE UPDATE ON prices
    FOR EACH ROW EXECUTE FUNCTION prevent_price_content_mutation();

-- Orders are immutable snapshots: once placed, only status/updated_at may change, so an
-- order always reflects exactly the totals/items agreed at purchase time.
CREATE OR REPLACE FUNCTION prevent_order_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.tenant_id       IS DISTINCT FROM OLD.tenant_id
       OR NEW.customer_id     IS DISTINCT FROM OLD.customer_id
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.subtotal_amount IS DISTINCT FROM OLD.subtotal_amount
       OR NEW.total_amount    IS DISTINCT FROM OLD.total_amount
       OR NEW.metadata        IS DISTINCT FROM OLD.metadata
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'orders content is immutable once placed; only status may change'
            USING ERRCODE = '0A000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER orders_immutable_content
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION prevent_order_content_mutation();

CREATE OR REPLACE FUNCTION prevent_payment_intent_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.tenant_id       IS DISTINCT FROM OLD.tenant_id
       OR NEW.order_id        IS DISTINCT FROM OLD.order_id
       OR NEW.provider        IS DISTINCT FROM OLD.provider
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.amount          IS DISTINCT FROM OLD.amount
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'payment_intents core fields are immutable once created; only status/provider detail may change'
            USING ERRCODE = '0A000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER payment_intents_immutable_content
    BEFORE UPDATE ON payment_intents
    FOR EACH ROW EXECUTE FUNCTION prevent_payment_intent_content_mutation();

CREATE OR REPLACE FUNCTION prevent_refund_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.tenant_id          IS DISTINCT FROM OLD.tenant_id
       OR NEW.payment_intent_id IS DISTINCT FROM OLD.payment_intent_id
       OR NEW.currency          IS DISTINCT FROM OLD.currency
       OR NEW.amount            IS DISTINCT FROM OLD.amount
       OR NEW.idempotency_key   IS DISTINCT FROM OLD.idempotency_key
       OR NEW.created_at        IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'refunds core fields are immutable once created; only status/provider detail may change'
            USING ERRCODE = '0A000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER refunds_immutable_content
    BEFORE UPDATE ON refunds
    FOR EACH ROW EXECUTE FUNCTION prevent_refund_content_mutation();

CREATE OR REPLACE FUNCTION prevent_subscription_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.tenant_id       IS DISTINCT FROM OLD.tenant_id
       OR NEW.customer_id     IS DISTINCT FROM OLD.customer_id
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'subscriptions identity is immutable once created; only plan/period/status fields may change'
            USING ERRCODE = '0A000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER subscriptions_immutable_content
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION prevent_subscription_content_mutation();

CREATE OR REPLACE FUNCTION prevent_subscription_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'subscription_events is append-only; % is not permitted', TG_OP
        USING ERRCODE = '0A000';
END;
$$;

CREATE TRIGGER subscription_events_no_update
    BEFORE UPDATE OR DELETE ON subscription_events
    FOR EACH ROW EXECUTE FUNCTION prevent_subscription_event_mutation();

-- ==============================
-- LEDGER: CORE API
-- ==============================

CREATE OR REPLACE FUNCTION create_ledger_account(
    p_owner_type   text,
    p_owner_id     text,
    p_account_type text,
    p_tenant_id    text  DEFAULT NULL,
    p_name         text  DEFAULT NULL,
    p_metadata     jsonb DEFAULT '{}'
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_account_id bigint;
BEGIN
    IF p_owner_type IS NULL OR trim(p_owner_type) = '' THEN
        RAISE EXCEPTION 'owner_type is required' USING ERRCODE = '22023';
    END IF;
    IF p_owner_id IS NULL OR trim(p_owner_id) = '' THEN
        RAISE EXCEPTION 'owner_id is required' USING ERRCODE = '22023';
    END IF;
    IF p_account_type IS NULL OR trim(p_account_type) = '' THEN
        RAISE EXCEPTION 'account_type is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, account_type, name, metadata)
    VALUES (p_tenant_id, p_owner_type, p_owner_id, p_account_type, p_name, coalesce(p_metadata, '{}'))
    RETURNING id INTO v_account_id;

    RETURN v_account_id;
END;
$$;

-- Rollup cache recompute: always derives balance from ledger_entries, never accepts a
-- balance value directly, so ledger_account_balances can never drift from the journal.
CREATE OR REPLACE FUNCTION sync_account_balance(
    p_account_id bigint,
    p_currency   text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
BEGIN
    INSERT INTO ledger_account_balances (account_id, currency, balance, updated_at)
    VALUES (
        p_account_id,
        p_currency,
        (SELECT coalesce(sum(amount), 0) FROM ledger_entries WHERE account_id = p_account_id AND currency = p_currency),
        now()
    )
    ON CONFLICT (account_id, currency)
    DO UPDATE SET balance = EXCLUDED.balance, updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION get_account_balance(
    p_account_id bigint,
    p_currency   text
)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path = @extschema@, pg_catalog
AS $$
    SELECT coalesce((SELECT balance FROM ledger_account_balances WHERE account_id = p_account_id AND currency = p_currency), 0);
$$;

CREATE OR REPLACE FUNCTION get_account_balances(
    p_account_id bigint
)
RETURNS SETOF ledger_account_balances
LANGUAGE sql
STABLE
SET search_path = @extschema@, pg_catalog
AS $$
    SELECT * FROM ledger_account_balances WHERE account_id = p_account_id ORDER BY currency;
$$;

-- The only sanctioned way to write ledger_entries. p_entries is a jsonb array of
-- {"account_id": bigint, "currency": text, "amount": bigint} legs; amounts are signed
-- (credit > 0, debit < 0) and must sum to zero *per currency* -- a transaction can't net
-- USD against EGP in one journal, since that would silently hide an FX conversion.
CREATE OR REPLACE FUNCTION post_transaction(
    p_type            text,
    p_entries         jsonb,
    p_reference_type  text  DEFAULT NULL,
    p_reference_id    text  DEFAULT NULL,
    p_description     text  DEFAULT NULL,
    p_metadata        jsonb DEFAULT '{}',
    p_idempotency_key text  DEFAULT NULL,
    p_tenant_id       text  DEFAULT NULL,
    p_created_by      text  DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_transaction_id bigint;
    v_row            RECORD;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id INTO v_transaction_id FROM ledger_transactions WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_transaction_id;
        END IF;
    END IF;

    IF p_type IS NULL OR trim(p_type) = '' THEN
        RAISE EXCEPTION 'transaction type is required' USING ERRCODE = '22023';
    END IF;

    IF p_entries IS NULL OR jsonb_typeof(p_entries) <> 'array' OR jsonb_array_length(p_entries) < 2 THEN
        RAISE EXCEPTION 'post_transaction requires at least two entries' USING ERRCODE = '22023';
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(p_entries) AS e
    LOOP
        IF NOT (v_row.e ? 'account_id') OR NOT (v_row.e ? 'currency') OR NOT (v_row.e ? 'amount') THEN
            RAISE EXCEPTION 'each entry requires account_id, currency, and amount' USING ERRCODE = '22023';
        END IF;
        IF (v_row.e->>'amount')::bigint = 0 THEN
            RAISE EXCEPTION 'entry amount must not be zero' USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ledger_accounts WHERE id = (v_row.e->>'account_id')::bigint) THEN
            RAISE EXCEPTION 'ledger account % not found', v_row.e->>'account_id' USING ERRCODE = 'P0002';
        END IF;
    END LOOP;

    SELECT e->>'currency' AS currency, sum((e->>'amount')::bigint) AS total
    INTO v_row
    FROM jsonb_array_elements(p_entries) AS e
    GROUP BY e->>'currency'
    HAVING sum((e->>'amount')::bigint) <> 0
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'entries do not balance for currency %: sum is %', v_row.currency, v_row.total
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO ledger_transactions (tenant_id, type, reference_type, reference_id, description, metadata, idempotency_key, created_by)
    VALUES (p_tenant_id, p_type, p_reference_type, p_reference_id, p_description, coalesce(p_metadata, '{}'), p_idempotency_key, p_created_by)
    RETURNING id INTO v_transaction_id;

    INSERT INTO ledger_entries (transaction_id, account_id, currency, amount)
    SELECT v_transaction_id, (e->>'account_id')::bigint, e->>'currency', (e->>'amount')::bigint
    FROM jsonb_array_elements(p_entries) AS e;

    FOR v_row IN
        SELECT DISTINCT (e->>'account_id')::bigint AS account_id, e->>'currency' AS currency
        FROM jsonb_array_elements(p_entries) AS e
    LOOP
        PERFORM sync_account_balance(v_row.account_id, v_row.currency);
    END LOOP;

    RETURN v_transaction_id;
END;
$$;

-- ==============================
-- WALLET API
-- ==============================

-- Money crossing the system boundary (top-ups, withdrawals) needs a counterpart ledger
-- account on the other side of the entry; this lazily creates one system account per
-- (tenant, account_type) rather than requiring callers to provision it up front.
CREATE OR REPLACE FUNCTION get_or_create_system_account(
    p_account_type text,
    p_tenant_id    text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_account_id bigint;
BEGIN
    SELECT id INTO v_account_id
    FROM ledger_accounts
    WHERE owner_type = 'system'
      AND owner_id = p_account_type
      AND account_type = p_account_type
      AND tenant_id IS NOT DISTINCT FROM p_tenant_id;

    IF v_account_id IS NULL THEN
        v_account_id := create_ledger_account('system', p_account_type, p_account_type, p_tenant_id, p_account_type);
    END IF;

    RETURN v_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION create_wallet(
    p_owner_type       text,
    p_owner_id         text,
    p_tenant_id        text  DEFAULT NULL,
    p_wallet_type      text  DEFAULT 'main',
    p_default_currency text  DEFAULT NULL,
    p_metadata         jsonb DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_wallet_id         uuid;
    v_ledger_account_id bigint;
BEGIN
    v_ledger_account_id := create_ledger_account(p_owner_type, p_owner_id, 'wallet', p_tenant_id, p_wallet_type);

    INSERT INTO wallets (tenant_id, owner_type, owner_id, wallet_type, ledger_account_id, default_currency, metadata)
    VALUES (p_tenant_id, p_owner_type, p_owner_id, coalesce(p_wallet_type, 'main'), v_ledger_account_id, p_default_currency, coalesce(p_metadata, '{}'))
    RETURNING id INTO v_wallet_id;

    RETURN v_wallet_id;
END;
$$;

CREATE OR REPLACE FUNCTION wallet_topup(
    p_wallet_id       uuid,
    p_amount          bigint,
    p_currency        text,
    p_reference_type  text DEFAULT NULL,
    p_reference_id    text DEFAULT NULL,
    p_description     text DEFAULT NULL,
    p_idempotency_key text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_wallet           wallets;
    v_external_account bigint;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'topup amount must be positive' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_wallet FROM wallets WHERE id = p_wallet_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'wallet % not found', p_wallet_id USING ERRCODE = 'P0002';
    END IF;
    IF v_wallet.status <> 'active' THEN
        RAISE EXCEPTION 'wallet % is %, not active', p_wallet_id, v_wallet.status USING ERRCODE = '55000';
    END IF;

    v_external_account := get_or_create_system_account('external', v_wallet.tenant_id);

    RETURN post_transaction(
        p_type            := 'wallet_topup',
        p_entries         := jsonb_build_array(
            jsonb_build_object('account_id', v_wallet.ledger_account_id, 'currency', p_currency, 'amount', p_amount),
            jsonb_build_object('account_id', v_external_account,         'currency', p_currency, 'amount', -p_amount)
        ),
        p_reference_type  := p_reference_type,
        p_reference_id    := p_reference_id,
        p_description     := p_description,
        p_idempotency_key := p_idempotency_key,
        p_tenant_id       := v_wallet.tenant_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION wallet_withdraw(
    p_wallet_id       uuid,
    p_amount          bigint,
    p_currency        text,
    p_reference_type  text DEFAULT NULL,
    p_reference_id    text DEFAULT NULL,
    p_description     text DEFAULT NULL,
    p_idempotency_key text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_wallet           wallets;
    v_external_account bigint;
    v_balance          bigint;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'withdrawal amount must be positive' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_wallet FROM wallets WHERE id = p_wallet_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'wallet % not found', p_wallet_id USING ERRCODE = 'P0002';
    END IF;
    IF v_wallet.status <> 'active' THEN
        RAISE EXCEPTION 'wallet % is %, not active', p_wallet_id, v_wallet.status USING ERRCODE = '55000';
    END IF;

    v_balance := get_account_balance(v_wallet.ledger_account_id, p_currency);
    IF v_balance < p_amount THEN
        RAISE EXCEPTION 'insufficient balance: wallet % has % %, requested %', p_wallet_id, v_balance, p_currency, p_amount
            USING ERRCODE = '23514';
    END IF;

    v_external_account := get_or_create_system_account('external', v_wallet.tenant_id);

    RETURN post_transaction(
        p_type            := 'wallet_withdrawal',
        p_entries         := jsonb_build_array(
            jsonb_build_object('account_id', v_wallet.ledger_account_id, 'currency', p_currency, 'amount', -p_amount),
            jsonb_build_object('account_id', v_external_account,         'currency', p_currency, 'amount', p_amount)
        ),
        p_reference_type  := p_reference_type,
        p_reference_id    := p_reference_id,
        p_description     := p_description,
        p_idempotency_key := p_idempotency_key,
        p_tenant_id       := v_wallet.tenant_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION wallet_transfer(
    p_from_wallet_id  uuid,
    p_to_wallet_id    uuid,
    p_amount          bigint,
    p_currency        text,
    p_reference_type  text DEFAULT NULL,
    p_reference_id    text DEFAULT NULL,
    p_description     text DEFAULT NULL,
    p_idempotency_key text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_from    wallets;
    v_to      wallets;
    v_balance bigint;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'transfer amount must be positive' USING ERRCODE = '22023';
    END IF;
    IF p_from_wallet_id = p_to_wallet_id THEN
        RAISE EXCEPTION 'cannot transfer a wallet to itself' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_from FROM wallets WHERE id = p_from_wallet_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'wallet % not found', p_from_wallet_id USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO v_to FROM wallets WHERE id = p_to_wallet_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'wallet % not found', p_to_wallet_id USING ERRCODE = 'P0002';
    END IF;
    IF v_from.status <> 'active' OR v_to.status <> 'active' THEN
        RAISE EXCEPTION 'both wallets must be active to transfer' USING ERRCODE = '55000';
    END IF;

    v_balance := get_account_balance(v_from.ledger_account_id, p_currency);
    IF v_balance < p_amount THEN
        RAISE EXCEPTION 'insufficient balance: wallet % has % %, requested %', p_from_wallet_id, v_balance, p_currency, p_amount
            USING ERRCODE = '23514';
    END IF;

    RETURN post_transaction(
        p_type            := 'wallet_transfer',
        p_entries         := jsonb_build_array(
            jsonb_build_object('account_id', v_from.ledger_account_id, 'currency', p_currency, 'amount', -p_amount),
            jsonb_build_object('account_id', v_to.ledger_account_id,   'currency', p_currency, 'amount', p_amount)
        ),
        p_reference_type  := p_reference_type,
        p_reference_id    := p_reference_id,
        p_description     := p_description,
        p_idempotency_key := p_idempotency_key,
        p_tenant_id       := v_from.tenant_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_wallet_balance(
    p_wallet_id uuid,
    p_currency  text
)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path = @extschema@, pg_catalog
AS $$
    SELECT get_account_balance(w.ledger_account_id, p_currency)
    FROM wallets w
    WHERE w.id = p_wallet_id;
$$;

-- ==============================
-- CATALOG API
-- ==============================

CREATE OR REPLACE FUNCTION create_product(
    p_name        text,
    p_tenant_id   text  DEFAULT NULL,
    p_description text  DEFAULT NULL,
    p_metadata    jsonb DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_product_id uuid;
BEGIN
    IF p_name IS NULL OR trim(p_name) = '' THEN
        RAISE EXCEPTION 'product name is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO products (tenant_id, name, description, metadata)
    VALUES (p_tenant_id, p_name, p_description, coalesce(p_metadata, '{}'))
    RETURNING id INTO v_product_id;

    RETURN v_product_id;
END;
$$;

CREATE OR REPLACE FUNCTION create_price(
    p_product_id       uuid,
    p_currency         text,
    p_unit_amount      bigint,
    p_type             text    DEFAULT 'one_time',
    p_billing_interval text    DEFAULT NULL,
    p_interval_count   integer DEFAULT 1,
    p_metadata         jsonb   DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_price_id uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = p_product_id) THEN
        RAISE EXCEPTION 'product % not found', p_product_id USING ERRCODE = 'P0002';
    END IF;
    IF p_unit_amount < 0 THEN
        RAISE EXCEPTION 'unit_amount must not be negative' USING ERRCODE = '22023';
    END IF;
    IF p_type = 'recurring' AND p_billing_interval IS NULL THEN
        RAISE EXCEPTION 'billing_interval is required for a recurring price' USING ERRCODE = '22023';
    END IF;

    INSERT INTO prices (product_id, currency, unit_amount, type, billing_interval, interval_count, metadata)
    VALUES (
        p_product_id, p_currency, p_unit_amount, p_type::price_type,
        p_billing_interval::billing_interval, coalesce(p_interval_count, 1), coalesce(p_metadata, '{}')
    )
    RETURNING id INTO v_price_id;

    RETURN v_price_id;
END;
$$;

CREATE OR REPLACE FUNCTION deactivate_price(
    p_price_id uuid
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE prices SET active = false WHERE id = p_price_id;
$$;

-- ==============================
-- ORDERS API
-- ==============================

-- Resolves each item against its price (snapshotting unit_amount/product_id so later price
-- changes never retroactively affect this order) or accepts an ad hoc unit_amount, then
-- inserts the order with its final totals already computed -- never via a follow-up UPDATE,
-- since subtotal_amount/total_amount are immutable-after-insert (see prevent_order_content_mutation).
CREATE OR REPLACE FUNCTION create_order(
    p_customer_id     text,
    p_currency        text,
    p_items           jsonb,
    p_tenant_id       text  DEFAULT NULL,
    p_metadata        jsonb DEFAULT '{}',
    p_idempotency_key text  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_order_id uuid;
    v_item     RECORD;
    v_price    prices;
    v_quantity integer;
    v_unit     bigint;
    v_desc     text;
    v_product  uuid;
    v_price_id uuid;
    v_subtotal bigint := 0;
    v_resolved jsonb  := '[]'::jsonb;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id INTO v_order_id FROM orders WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_order_id;
        END IF;
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'create_order requires at least one item' USING ERRCODE = '22023';
    END IF;

    FOR v_item IN SELECT value AS item FROM jsonb_array_elements(p_items)
    LOOP
        v_price    := NULL;
        v_product  := NULL;
        v_price_id := NULL;

        IF v_item.item ? 'price_id' THEN
            SELECT * INTO v_price FROM prices WHERE id = (v_item.item->>'price_id')::uuid;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'price % not found', v_item.item->>'price_id' USING ERRCODE = 'P0002';
            END IF;
            IF NOT v_price.active THEN
                RAISE EXCEPTION 'price % is not active', v_price.id USING ERRCODE = '55000';
            END IF;
            IF v_price.currency <> p_currency THEN
                RAISE EXCEPTION 'price % currency % does not match order currency %', v_price.id, v_price.currency, p_currency
                    USING ERRCODE = '22023';
            END IF;
            v_unit     := v_price.unit_amount;
            v_product  := v_price.product_id;
            v_price_id := v_price.id;
            v_desc     := v_item.item->>'description';
        ELSE
            IF NOT (v_item.item ? 'unit_amount') THEN
                RAISE EXCEPTION 'item requires either price_id or unit_amount' USING ERRCODE = '22023';
            END IF;
            v_unit := (v_item.item->>'unit_amount')::bigint;
            v_desc := v_item.item->>'description';
        END IF;

        v_quantity := coalesce((v_item.item->>'quantity')::integer, 1);
        IF v_quantity <= 0 THEN
            RAISE EXCEPTION 'item quantity must be positive' USING ERRCODE = '22023';
        END IF;

        v_subtotal := v_subtotal + (v_unit * v_quantity);

        v_resolved := v_resolved || jsonb_build_array(jsonb_build_object(
            'product_id',   v_product,
            'price_id',     v_price_id,
            'description',  v_desc,
            'unit_amount',  v_unit,
            'quantity',     v_quantity,
            'amount_total', v_unit * v_quantity
        ));
    END LOOP;

    INSERT INTO orders (tenant_id, customer_id, currency, subtotal_amount, total_amount, metadata, idempotency_key)
    VALUES (p_tenant_id, p_customer_id, p_currency, v_subtotal, v_subtotal, coalesce(p_metadata, '{}'), p_idempotency_key)
    RETURNING id INTO v_order_id;

    INSERT INTO order_items (order_id, product_id, price_id, description, unit_amount, quantity, amount_total, currency)
    SELECT
        v_order_id,
        (r->>'product_id')::uuid,
        (r->>'price_id')::uuid,
        r->>'description',
        (r->>'unit_amount')::bigint,
        (r->>'quantity')::integer,
        (r->>'amount_total')::bigint,
        p_currency
    FROM jsonb_array_elements(v_resolved) AS r;

    RETURN v_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION cancel_order(
    p_order_id uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_order orders;
BEGIN
    SELECT * INTO v_order FROM orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order % not found', p_order_id USING ERRCODE = 'P0002';
    END IF;
    IF v_order.status <> 'pending' THEN
        RAISE EXCEPTION 'order % is %, only a pending order can be cancelled', p_order_id, v_order.status
            USING ERRCODE = '55000';
    END IF;

    UPDATE orders SET status = 'cancelled', updated_at = now() WHERE id = p_order_id;
END;
$$;

-- ==============================
-- PAYMENT INTENTS API
-- ==============================

CREATE OR REPLACE FUNCTION create_payment_intent(
    p_provider        text,
    p_currency        text,
    p_amount          bigint,
    p_order_id        uuid  DEFAULT NULL,
    p_tenant_id       text  DEFAULT NULL,
    p_metadata        jsonb DEFAULT '{}',
    p_idempotency_key text  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_payment_intent_id uuid;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id INTO v_payment_intent_id FROM payment_intents WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_payment_intent_id;
        END IF;
    END IF;

    IF p_provider IS NULL OR trim(p_provider) = '' THEN
        RAISE EXCEPTION 'provider is required' USING ERRCODE = '22023';
    END IF;
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'amount must be positive' USING ERRCODE = '22023';
    END IF;
    IF p_order_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM orders WHERE id = p_order_id) THEN
        RAISE EXCEPTION 'order % not found', p_order_id USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO payment_intents (tenant_id, order_id, provider, currency, amount, metadata, idempotency_key)
    VALUES (p_tenant_id, p_order_id, p_provider, p_currency, p_amount, coalesce(p_metadata, '{}'), p_idempotency_key)
    RETURNING id INTO v_payment_intent_id;

    RETURN v_payment_intent_id;
END;
$$;

CREATE OR REPLACE FUNCTION mark_payment_intent_processing(
    p_payment_intent_id  uuid,
    p_provider_intent_id text DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE payment_intents
    SET status = 'processing', provider_intent_id = coalesce(p_provider_intent_id, provider_intent_id), updated_at = now()
    WHERE id = p_payment_intent_id;
$$;

CREATE OR REPLACE FUNCTION mark_payment_intent_requires_action(
    p_payment_intent_id uuid,
    p_client_secret     text DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE payment_intents
    SET status = 'requires_action', client_secret = coalesce(p_client_secret, client_secret), updated_at = now()
    WHERE id = p_payment_intent_id;
$$;

-- Marking a payment intent succeeded posts the corresponding ledger transaction (crediting
-- the system 'revenue' account against the 'external' clearing account) and rolls up the
-- linked order's status. The ledger post is idempotent on the intent's own id, so retried
-- webhook deliveries never double-post.
CREATE OR REPLACE FUNCTION mark_payment_intent_succeeded(
    p_payment_intent_id  uuid,
    p_provider_intent_id text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_intent           payment_intents;
    v_revenue_account  bigint;
    v_external_account bigint;
BEGIN
    SELECT * INTO v_intent FROM payment_intents WHERE id = p_payment_intent_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment_intent % not found', p_payment_intent_id USING ERRCODE = 'P0002';
    END IF;

    UPDATE payment_intents
    SET status = 'succeeded',
        provider_intent_id = coalesce(p_provider_intent_id, provider_intent_id),
        succeeded_at = now(),
        updated_at = now()
    WHERE id = p_payment_intent_id;

    v_revenue_account  := get_or_create_system_account('revenue', v_intent.tenant_id);
    v_external_account := get_or_create_system_account('external', v_intent.tenant_id);

    PERFORM post_transaction(
        p_type            := 'payment_intent_succeeded',
        p_entries         := jsonb_build_array(
            jsonb_build_object('account_id', v_revenue_account,  'currency', v_intent.currency, 'amount', v_intent.amount),
            jsonb_build_object('account_id', v_external_account, 'currency', v_intent.currency, 'amount', -v_intent.amount)
        ),
        p_reference_type  := 'payment_intent',
        p_reference_id    := p_payment_intent_id::text,
        p_idempotency_key := 'payment_intent_succeeded:' || p_payment_intent_id::text,
        p_tenant_id       := v_intent.tenant_id
    );

    IF v_intent.order_id IS NOT NULL THEN
        PERFORM sync_order_status(v_intent.order_id);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION mark_payment_intent_failed(
    p_payment_intent_id uuid,
    p_error             text DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE payment_intents
    SET status = 'failed', last_error = p_error, failed_at = now(), updated_at = now()
    WHERE id = p_payment_intent_id;
$$;

CREATE OR REPLACE FUNCTION mark_payment_intent_cancelled(
    p_payment_intent_id uuid,
    p_reason            text DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE payment_intents
    SET status = 'cancelled', last_error = p_reason, cancelled_at = now(), updated_at = now()
    WHERE id = p_payment_intent_id;
$$;

-- ==============================
-- REFUNDS API
-- ==============================

CREATE OR REPLACE FUNCTION create_refund(
    p_payment_intent_id uuid,
    p_amount            bigint DEFAULT NULL,
    p_reason            text   DEFAULT NULL,
    p_idempotency_key   text   DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_refund_id        uuid;
    v_intent           payment_intents;
    v_already_refunded bigint;
    v_amount           bigint;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id INTO v_refund_id FROM refunds WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_refund_id;
        END IF;
    END IF;

    SELECT * INTO v_intent FROM payment_intents WHERE id = p_payment_intent_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment_intent % not found', p_payment_intent_id USING ERRCODE = 'P0002';
    END IF;
    IF v_intent.status <> 'succeeded' THEN
        RAISE EXCEPTION 'payment_intent % is %, only a succeeded intent can be refunded', p_payment_intent_id, v_intent.status
            USING ERRCODE = '55000';
    END IF;

    SELECT coalesce(sum(amount), 0) INTO v_already_refunded
    FROM refunds
    WHERE payment_intent_id = p_payment_intent_id AND status IN ('pending', 'succeeded');

    v_amount := coalesce(p_amount, v_intent.amount - v_already_refunded);
    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'refund amount must be positive' USING ERRCODE = '22023';
    END IF;
    IF v_already_refunded + v_amount > v_intent.amount THEN
        RAISE EXCEPTION 'refund of % would exceed payment_intent % amount of % (already refunded %)',
            v_amount, p_payment_intent_id, v_intent.amount, v_already_refunded USING ERRCODE = '23514';
    END IF;

    INSERT INTO refunds (tenant_id, payment_intent_id, provider, currency, amount, reason, idempotency_key)
    VALUES (v_intent.tenant_id, p_payment_intent_id, v_intent.provider, v_intent.currency, v_amount, p_reason, p_idempotency_key)
    RETURNING id INTO v_refund_id;

    RETURN v_refund_id;
END;
$$;

CREATE OR REPLACE FUNCTION mark_refund_succeeded(
    p_refund_id          uuid,
    p_provider_refund_id text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_refund           refunds;
    v_intent           payment_intents;
    v_revenue_account  bigint;
    v_external_account bigint;
BEGIN
    SELECT * INTO v_refund FROM refunds WHERE id = p_refund_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'refund % not found', p_refund_id USING ERRCODE = 'P0002';
    END IF;

    SELECT * INTO v_intent FROM payment_intents WHERE id = v_refund.payment_intent_id;

    UPDATE refunds
    SET status = 'succeeded',
        provider_refund_id = coalesce(p_provider_refund_id, provider_refund_id),
        succeeded_at = now(),
        updated_at = now()
    WHERE id = p_refund_id;

    v_revenue_account  := get_or_create_system_account('revenue', v_refund.tenant_id);
    v_external_account := get_or_create_system_account('external', v_refund.tenant_id);

    PERFORM post_transaction(
        p_type            := 'refund_succeeded',
        p_entries         := jsonb_build_array(
            jsonb_build_object('account_id', v_revenue_account,  'currency', v_refund.currency, 'amount', -v_refund.amount),
            jsonb_build_object('account_id', v_external_account, 'currency', v_refund.currency, 'amount', v_refund.amount)
        ),
        p_reference_type  := 'refund',
        p_reference_id    := p_refund_id::text,
        p_idempotency_key := 'refund_succeeded:' || p_refund_id::text,
        p_tenant_id       := v_refund.tenant_id
    );

    IF v_intent.order_id IS NOT NULL THEN
        PERFORM sync_order_status(v_intent.order_id);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION mark_refund_failed(
    p_refund_id uuid,
    p_error     text DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE refunds
    SET status     = 'failed',
        failed_at  = now(),
        updated_at = now(),
        metadata   = CASE WHEN p_error IS NOT NULL THEN metadata || jsonb_build_object('failure_reason', p_error) ELSE metadata END
    WHERE id = p_refund_id;
$$;

-- ==============================
-- STATUS ROLLUP
-- ==============================

-- Recomputes an order's status from its payment_intents/refunds rather than being told what
-- to transition to, mirroring pgho_outbox's sync_message_status(): the source of truth is
-- always the child rows, never the caller's assertion.
CREATE OR REPLACE FUNCTION sync_order_status(
    p_order_id uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_order           orders;
    v_paid_amount     bigint;
    v_refunded_amount bigint;
    v_new_status      order_status;
BEGIN
    SELECT * INTO v_order FROM orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT coalesce(sum(amount), 0) INTO v_paid_amount
    FROM payment_intents
    WHERE order_id = p_order_id AND status = 'succeeded';

    SELECT coalesce(sum(r.amount), 0) INTO v_refunded_amount
    FROM refunds r
    JOIN payment_intents pi ON pi.id = r.payment_intent_id
    WHERE pi.order_id = p_order_id AND r.status = 'succeeded';

    IF v_paid_amount = 0 THEN
        RETURN;
    ELSIF v_refunded_amount >= v_paid_amount THEN
        v_new_status := 'refunded';
    ELSIF v_refunded_amount > 0 THEN
        v_new_status := 'partially_refunded';
    ELSE
        v_new_status := 'paid';
    END IF;

    IF v_new_status IS DISTINCT FROM v_order.status THEN
        UPDATE orders SET status = v_new_status, updated_at = now() WHERE id = p_order_id;
    END IF;
END;
$$;

-- ==============================
-- WEBHOOKS: WORKER API
-- ==============================

CREATE OR REPLACE FUNCTION record_webhook_event(
    p_provider          text,
    p_event_type        text,
    p_provider_event_id text,
    p_payload           jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_id uuid;
BEGIN
    IF p_provider IS NULL OR trim(p_provider) = '' THEN
        RAISE EXCEPTION 'provider is required' USING ERRCODE = '22023';
    END IF;
    IF p_provider_event_id IS NULL OR trim(p_provider_event_id) = '' THEN
        RAISE EXCEPTION 'provider_event_id is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO webhook_events (provider, event_type, provider_event_id, payload)
    VALUES (p_provider, p_event_type, p_provider_event_id, coalesce(p_payload, '{}'))
    ON CONFLICT (provider, provider_event_id) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
        SELECT id INTO v_id FROM webhook_events WHERE provider = p_provider AND provider_event_id = p_provider_event_id;
    END IF;

    RETURN v_id;
END;
$$;

-- FOR UPDATE SKIP LOCKED lets multiple workers claim disjoint batches concurrently; mirrors
-- pgho_outbox's claim_deliveries().
CREATE OR REPLACE FUNCTION claim_webhook_events(
    p_limit    integer DEFAULT 10,
    p_provider text    DEFAULT NULL
)
RETURNS SETOF webhook_events
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
BEGIN
    RETURN QUERY
    UPDATE webhook_events
    SET status = 'processing', claimed_at = now(), attempts = attempts + 1
    WHERE id IN (
        SELECT id FROM webhook_events
        WHERE status = 'pending'
          AND (p_provider IS NULL OR provider = p_provider)
        ORDER BY received_at
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    )
    RETURNING *;
END;
$$;

CREATE OR REPLACE FUNCTION mark_webhook_event_processed(
    p_webhook_event_id uuid
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE webhook_events SET status = 'processed', processed_at = now() WHERE id = p_webhook_event_id;
$$;

CREATE OR REPLACE FUNCTION mark_webhook_event_failed(
    p_webhook_event_id uuid,
    p_error            text    DEFAULT NULL,
    p_permanent        boolean DEFAULT false
)
RETURNS void
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    UPDATE webhook_events
    SET status     = CASE WHEN p_permanent THEN 'failed'::webhook_event_status ELSE 'pending'::webhook_event_status END,
        last_error = p_error,
        claimed_at = NULL
    WHERE id = p_webhook_event_id;
$$;

-- ==============================
-- SUBSCRIPTIONS API
-- ==============================

CREATE OR REPLACE FUNCTION compute_period_end(
    p_start            timestamptz,
    p_billing_interval billing_interval,
    p_interval_count   integer
)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
SET search_path = @extschema@, pg_catalog
AS $$
    SELECT p_start + (p_interval_count || ' ' || p_billing_interval::text)::interval;
$$;

CREATE OR REPLACE FUNCTION create_subscription(
    p_customer_id     text,
    p_price_id        uuid,
    p_tenant_id       text        DEFAULT NULL,
    p_trial_end       timestamptz DEFAULT NULL,
    p_metadata        jsonb       DEFAULT '{}',
    p_idempotency_key text        DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_subscription_id uuid;
    v_price           prices;
    v_now             timestamptz := now();
    v_period_end      timestamptz;
    v_status          subscription_status;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id INTO v_subscription_id FROM subscriptions WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_subscription_id;
        END IF;
    END IF;

    SELECT * INTO v_price FROM prices WHERE id = p_price_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'price % not found', p_price_id USING ERRCODE = 'P0002';
    END IF;
    IF v_price.type <> 'recurring' THEN
        RAISE EXCEPTION 'price % is not recurring; subscriptions require a recurring price', p_price_id USING ERRCODE = '22023';
    END IF;

    IF p_trial_end IS NOT NULL AND p_trial_end > v_now THEN
        v_status     := 'trialing';
        v_period_end := p_trial_end;
    ELSE
        v_status     := 'active';
        v_period_end := compute_period_end(v_now, v_price.billing_interval, v_price.interval_count);
    END IF;

    INSERT INTO subscriptions (
        tenant_id, customer_id, price_id, status,
        current_period_start, current_period_end, trial_end, metadata, idempotency_key
    )
    VALUES (
        p_tenant_id, p_customer_id, p_price_id, v_status,
        v_now, v_period_end, p_trial_end, coalesce(p_metadata, '{}'), p_idempotency_key
    )
    RETURNING id INTO v_subscription_id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (v_subscription_id, 'created', jsonb_build_object('price_id', p_price_id, 'status', v_status));

    RETURN v_subscription_id;
END;
$$;

CREATE OR REPLACE FUNCTION cancel_subscription(
    p_subscription_id uuid,
    p_at_period_end   boolean DEFAULT true,
    p_reason          text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_subscription subscriptions;
BEGIN
    SELECT * INTO v_subscription FROM subscriptions WHERE id = p_subscription_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'subscription % not found', p_subscription_id USING ERRCODE = 'P0002';
    END IF;

    IF p_at_period_end THEN
        UPDATE subscriptions SET cancel_at_period_end = true, updated_at = now() WHERE id = p_subscription_id;
    ELSE
        UPDATE subscriptions
        SET status = 'cancelled', cancelled_at = now(), updated_at = now()
        WHERE id = p_subscription_id;
    END IF;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'cancelled', jsonb_build_object('at_period_end', p_at_period_end, 'reason', p_reason));
END;
$$;

-- Advances a subscription to its next billing cycle: creates the cycle's order (a single
-- item snapshotting the subscription's current price) and payment_intent, then moves
-- current_period_start/end forward. Substitutes for the out-of-scope "invoice" concept --
-- proration on plan changes is explicitly not handled here.
CREATE OR REPLACE FUNCTION renew_subscription(
    p_subscription_id uuid,
    p_provider        text DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_subscription subscriptions;
    v_price        prices;
    v_order_id     uuid;
    v_new_start    timestamptz;
    v_new_end      timestamptz;
BEGIN
    SELECT * INTO v_subscription FROM subscriptions WHERE id = p_subscription_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'subscription % not found', p_subscription_id USING ERRCODE = 'P0002';
    END IF;
    IF v_subscription.status NOT IN ('active', 'trialing', 'past_due') THEN
        RAISE EXCEPTION 'subscription % is %, cannot renew', p_subscription_id, v_subscription.status
            USING ERRCODE = '55000';
    END IF;

    IF v_subscription.cancel_at_period_end THEN
        UPDATE subscriptions SET status = 'cancelled', cancelled_at = now(), updated_at = now() WHERE id = p_subscription_id;
        INSERT INTO subscription_events (subscription_id, type, payload)
        VALUES (p_subscription_id, 'cancelled', '{"reason":"cancel_at_period_end"}');
        RETURN NULL;
    END IF;

    SELECT * INTO v_price FROM prices WHERE id = v_subscription.price_id;

    v_order_id := create_order(
        p_customer_id     := v_subscription.customer_id,
        p_currency        := v_price.currency,
        p_items           := jsonb_build_array(jsonb_build_object('price_id', v_price.id, 'quantity', 1)),
        p_tenant_id       := v_subscription.tenant_id,
        p_metadata        := jsonb_build_object('subscription_id', v_subscription.id)
    );

    PERFORM create_payment_intent(
        p_provider  := p_provider,
        p_currency  := v_price.currency,
        p_amount    := v_price.unit_amount,
        p_order_id  := v_order_id,
        p_tenant_id := v_subscription.tenant_id
    );

    v_new_start := v_subscription.current_period_end;
    v_new_end   := compute_period_end(v_new_start, v_price.billing_interval, v_price.interval_count);

    UPDATE subscriptions
    SET status               = 'active',
        current_period_start = v_new_start,
        current_period_end   = v_new_end,
        latest_order_id      = v_order_id,
        updated_at           = now()
    WHERE id = p_subscription_id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'renewed', jsonb_build_object('order_id', v_order_id, 'period_start', v_new_start, 'period_end', v_new_end));

    RETURN v_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION change_subscription_price(
    p_subscription_id uuid,
    p_new_price_id    uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_subscription subscriptions;
    v_new_price    prices;
BEGIN
    SELECT * INTO v_subscription FROM subscriptions WHERE id = p_subscription_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'subscription % not found', p_subscription_id USING ERRCODE = 'P0002';
    END IF;

    SELECT * INTO v_new_price FROM prices WHERE id = p_new_price_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'price % not found', p_new_price_id USING ERRCODE = 'P0002';
    END IF;
    IF v_new_price.type <> 'recurring' THEN
        RAISE EXCEPTION 'price % is not recurring; subscriptions require a recurring price', p_new_price_id USING ERRCODE = '22023';
    END IF;

    UPDATE subscriptions SET price_id = p_new_price_id, updated_at = now() WHERE id = p_subscription_id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'price_changed', jsonb_build_object('old_price_id', v_subscription.price_id, 'new_price_id', p_new_price_id));
END;
$$;

-- Lock down pgho_payments: no access by default.
-- The calling application is responsible for granting only the minimum
-- required privileges to its own database role(s) after installation.

REVOKE USAGE ON SCHEMA @extschema@ FROM PUBLIC;
REVOKE ALL   ON ALL TABLES    IN SCHEMA @extschema@ FROM PUBLIC;
REVOKE ALL   ON ALL FUNCTIONS IN SCHEMA @extschema@ FROM PUBLIC;
REVOKE ALL   ON ALL SEQUENCES IN SCHEMA @extschema@ FROM PUBLIC;
