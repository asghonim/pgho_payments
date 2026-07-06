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
-- SaaS billing extensions (features, entitlements, addons, seats, change requests, invoices,
-- credit notes, contracts, usage) build on top of the existing catalog/subscriptions/orders
-- rather than duplicating them: a "plan" is a product, a "plan version" is a price, and an
-- "addon" is just a product flagged products.is_addon -- so entitlements attach to prices
-- once (price_feature_entitlements) and apply to both. tenant_id/customer_id stay plain text
-- everywhere, so this extension never needs to know about an app's own organizations/accounts
-- tables; the calling application owns its own authorization model. Unlike the tables above,
-- these newer tables enable RLS with no default policies (AGENTS.md), so a consuming app must
-- add its own policies (or grant to a role with BYPASSRLS) before it can read/write them.
--
-- Out of scope for this version (candidates for a later extension): coupons, tax calculation,
-- gift cards, payouts, revenue-share/marketplace splits, disputes, and automatic proration
-- math -- proration_behavior/payment_behavior on subscription_change_requests only record the
-- caller's intent; computing the actual amount and posting it as an invoice line item is left
-- to the application.

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

-- Extended (from the original 5-value set) to add 'incomplete_expired' (payment never
-- completed before expiry), 'paused' (pause_subscription/resume_subscription), and
-- 'expired' (a fixed-term contract or trial that ended without renewing).
CREATE TYPE subscription_status AS ENUM (
    'incomplete',
    'incomplete_expired',
    'trialing',
    'active',
    'past_due',
    'paused',
    'cancelled',
    'expired'
);

-- ---- SaaS billing extensions ----

CREATE TYPE proration_behavior AS ENUM (
    'create_prorations',
    'none',
    'always_invoice'
);

CREATE TYPE payment_behavior AS ENUM (
    'default_incomplete',
    'error_if_incomplete',
    'allow_incomplete'
);

CREATE TYPE change_request_type AS ENUM (
    'create',
    'upgrade',
    'downgrade',
    'cancel',
    'pause',
    'resume',
    'renew',
    'add_seats',
    'remove_seats',
    'add_addon',
    'remove_addon'
);

CREATE TYPE change_request_status AS ENUM (
    'pending',
    'processing',
    'awaiting_payment',
    'completed',
    'failed',
    'cancelled',
    'expired'
);

CREATE TYPE invoice_status AS ENUM (
    'draft',
    'open',
    'paid',
    'void',
    'uncollectible'
);

CREATE TYPE billing_reason AS ENUM (
    'subscription_create',
    'subscription_cycle',
    'subscription_update',
    'manual',
    'usage_threshold'
);

CREATE TYPE feature_type AS ENUM (
    'boolean',
    'limit',
    'metered'
);

CREATE TYPE feature_reset_period AS ENUM (
    'daily',
    'weekly',
    'monthly',
    'yearly',
    'never'
);

CREATE TYPE entitlement_source AS ENUM (
    'plan',
    'addon',
    'override',
    'promotion'
);

CREATE TYPE contract_status AS ENUM (
    'draft',
    'active',
    'expired',
    'terminated'
);

CREATE TYPE credit_note_status AS ENUM (
    'issued',
    'void'
);

CREATE TYPE credit_note_reason AS ENUM (
    'duplicate',
    'fraudulent',
    'order_change',
    'product_unsatisfactory'
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
    is_addon    boolean     NOT NULL DEFAULT false,
    active      boolean     NOT NULL DEFAULT true,
    metadata    jsonb       NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE @extschema@.products IS 'is_addon distinguishes an addon product from a plan product; both price the same way via prices, and both can carry feature entitlements via price_feature_entitlements, so subscriptions and subscription_addons share one catalog instead of two';

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
    quantity              integer             NOT NULL DEFAULT 1 CHECK (quantity > 0),
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

-- ---- SaaS billing: features & entitlements ----
--
-- Tables from here down follow AGENTS.md exactly (bigint identity PK + uid, RLS enabled with
-- no default policy) rather than the uuid-PK/no-RLS style above, and are additive: nothing
-- above this point changes behavior except products.is_addon and subscriptions.quantity.

CREATE TABLE features (
    id          bigint               GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid         uuid                 NOT NULL DEFAULT gen_random_uuid(),
    key         text                 NOT NULL CHECK (char_length(key) BETWEEN 1 AND 100),
    name        text                 NOT NULL CHECK (char_length(name) BETWEEN 1 AND 255),
    description text                 CHECK (char_length(description) <= 1000),
    type        feature_type         NOT NULL,
    unit        text                 CHECK (char_length(unit) <= 100),
    is_active   boolean              NOT NULL DEFAULT true,
    created_at  timestamptz          NOT NULL DEFAULT now(),
    CONSTRAINT unique_features_uid UNIQUE (uid),
    CONSTRAINT unique_features_key UNIQUE (key)
);
ALTER TABLE features ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.features IS 'Global catalog of entitlement-checkable capabilities; boolean/limit features are read from subscription_entitlements, metered features are additionally tracked in usage_records/usage_summaries';

CREATE TABLE price_feature_entitlements (
    id           bigint               GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid          uuid                 NOT NULL DEFAULT gen_random_uuid(),
    price_id     uuid                 NOT NULL REFERENCES prices(id)  ON DELETE CASCADE,
    feature_id   bigint               NOT NULL REFERENCES features(id) ON DELETE RESTRICT,
    value_boolean boolean,
    value_limit  bigint,
    reset_period feature_reset_period NOT NULL DEFAULT 'monthly',
    created_at   timestamptz          NOT NULL DEFAULT now(),
    CONSTRAINT unique_price_feature_entitlements_uid UNIQUE (uid),
    CONSTRAINT unique_price_feature_entitlements_price_feature UNIQUE (price_id, feature_id)
);
ALTER TABLE price_feature_entitlements ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.price_feature_entitlements IS 'What a price (plan price or addon price -- see products.is_addon) grants; value_limit = -1 means unlimited. One table serves both plans and addons since both are just prices';

-- ---- SaaS billing: addons ----

CREATE TABLE subscription_addons (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid             uuid        NOT NULL DEFAULT gen_random_uuid(),
    subscription_id uuid        NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    price_id        uuid        NOT NULL REFERENCES prices(id)        ON DELETE RESTRICT,
    quantity        integer     NOT NULL DEFAULT 1 CHECK (quantity > 0),
    status          text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
    started_at      timestamptz NOT NULL DEFAULT now(),
    ends_at         timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_subscription_addons_uid UNIQUE (uid)
);
ALTER TABLE subscription_addons ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.subscription_addons IS 'An addon attached to a subscription; price_id must belong to a product with is_addon = true (enforced in add_subscription_addon(), not a CHECK, since it requires a cross-table lookup)';

-- ---- SaaS billing: subscription change requests (state machine) ----

CREATE TABLE subscription_change_requests (
    id                  bigint                GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid                 uuid                  NOT NULL DEFAULT gen_random_uuid(),
    subscription_id     uuid                  REFERENCES subscriptions(id) ON DELETE SET NULL,
    tenant_id           text,
    customer_id         text                  NOT NULL,
    type                change_request_type   NOT NULL,
    status              change_request_status NOT NULL DEFAULT 'pending',
    current_price_id    uuid                  REFERENCES prices(id) ON DELETE RESTRICT,
    target_price_id     uuid                  REFERENCES prices(id) ON DELETE RESTRICT,
    effective_at        timestamptz,
    proration_behavior  proration_behavior    NOT NULL DEFAULT 'create_prorations',
    payment_behavior    payment_behavior      NOT NULL DEFAULT 'default_incomplete',
    idempotency_key     text,
    failure_reason      text,
    metadata            jsonb                 NOT NULL DEFAULT '{}',
    created_at          timestamptz           NOT NULL DEFAULT now(),
    processed_at        timestamptz,
    expires_at          timestamptz           NOT NULL DEFAULT (now() + interval '24 hours'),
    CONSTRAINT unique_subscription_change_requests_uid UNIQUE (uid),
    CONSTRAINT unique_subscription_change_requests_idempotency_key UNIQUE (idempotency_key)
);
ALTER TABLE subscription_change_requests ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.subscription_change_requests IS 'An async/idempotent request to mutate a subscription; apply_subscription_change_request() dispatches it to the existing direct-mutation functions (cancel_subscription, change_subscription_price, ...) and records the outcome. Direct calls to those functions remain valid for callers that do not need the queue/idempotency/payment-gating semantics';

-- ---- SaaS billing: invoices & credit notes ----

CREATE TABLE invoices (
    id               bigint         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid              uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id        text,
    customer_id      text           NOT NULL,
    subscription_id  uuid           REFERENCES subscriptions(id) ON DELETE SET NULL,
    order_id         uuid           REFERENCES orders(id)        ON DELETE SET NULL,
    status           invoice_status NOT NULL DEFAULT 'draft',
    number           text,
    currency         text           NOT NULL,
    subtotal_amount  bigint         NOT NULL DEFAULT 0,
    tax_amount       bigint         NOT NULL DEFAULT 0,
    discount_amount  bigint         NOT NULL DEFAULT 0,
    total_amount     bigint         NOT NULL DEFAULT 0,
    amount_due       bigint         NOT NULL DEFAULT 0,
    amount_paid      bigint         NOT NULL DEFAULT 0,
    billing_reason   billing_reason,
    period_start     timestamptz,
    period_end       timestamptz,
    due_date         timestamptz,
    paid_at          timestamptz,
    voided_at        timestamptz,
    provider         text,
    provider_invoice_id text,
    idempotency_key  text,
    metadata         jsonb          NOT NULL DEFAULT '{}',
    created_at       timestamptz    NOT NULL DEFAULT now(),
    CONSTRAINT unique_invoices_uid UNIQUE (uid),
    CONSTRAINT unique_invoices_number UNIQUE (number),
    CONSTRAINT unique_invoices_provider_invoice_id UNIQUE (provider_invoice_id),
    CONSTRAINT unique_invoices_idempotency_key UNIQUE (idempotency_key)
);
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.invoices IS 'A billing document wrapping an order (subtotal/line items already captured by orders/order_items) plus billing-only adjustments in invoice_line_items (proration/tax/discount/credit/usage). number is assigned explicitly by create_invoice() via next_invoice_number(), not a column default, so it stays out of the WHEN/THEN chain of any future bulk-copy tooling';

CREATE TABLE invoice_line_items (
    id            bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid           uuid          NOT NULL DEFAULT gen_random_uuid(),
    invoice_id    bigint        NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    type          text          NOT NULL CHECK (type IN ('proration', 'tax', 'discount', 'credit', 'usage')),
    description   text          NOT NULL,
    quantity      numeric(12,4) NOT NULL DEFAULT 1,
    unit_amount   bigint        NOT NULL DEFAULT 0,
    total_amount  bigint        NOT NULL DEFAULT 0,
    period_start  timestamptz,
    period_end    timestamptz,
    feature_key   text,
    metadata      jsonb         NOT NULL DEFAULT '{}',
    created_at    timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT unique_invoice_line_items_uid UNIQUE (uid)
);
ALTER TABLE invoice_line_items ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.invoice_line_items IS 'Billing-only adjustments on top of an invoice''s underlying order; ordinary subscription/one_time charges live in order_items, not here, so the two never duplicate the same line';

CREATE TABLE credit_notes (
    id                      bigint             GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid                     uuid               NOT NULL DEFAULT gen_random_uuid(),
    invoice_id              bigint             NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
    tenant_id               text,
    customer_id             text               NOT NULL,
    number                  text,
    status                  credit_note_status NOT NULL DEFAULT 'issued',
    reason                  credit_note_reason NOT NULL,
    currency                text               NOT NULL,
    total_amount            bigint             NOT NULL CHECK (total_amount > 0),
    provider_credit_note_id text,
    created_at              timestamptz        NOT NULL DEFAULT now(),
    voided_at               timestamptz,
    CONSTRAINT unique_credit_notes_uid UNIQUE (uid),
    CONSTRAINT unique_credit_notes_number UNIQUE (number),
    CONSTRAINT unique_credit_notes_provider_credit_note_id UNIQUE (provider_credit_note_id)
);
ALTER TABLE credit_notes ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.credit_notes IS 'A paper-trail record that an invoice''s amount owed was reduced; posting the corresponding ledger reversal (mirroring mark_refund_succeeded) is left to the application for this version';

-- ---- SaaS billing: enterprise contracts ----

CREATE TABLE subscription_contracts (
    id                  bigint          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid                 uuid            NOT NULL DEFAULT gen_random_uuid(),
    tenant_id           text,
    customer_id         text            NOT NULL,
    subscription_id     uuid            REFERENCES subscriptions(id) ON DELETE SET NULL,
    status              contract_status NOT NULL DEFAULT 'draft',
    start_date          date            NOT NULL,
    end_date            date,
    custom_pricing      jsonb           NOT NULL DEFAULT '{}',
    negotiated_features jsonb           NOT NULL DEFAULT '{}',
    sla_tier            text            CHECK (char_length(sla_tier) <= 100),
    document_url        text            CHECK (char_length(document_url) <= 2048),
    signed_at           timestamptz,
    signed_by           text,
    created_at          timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT unique_subscription_contracts_uid UNIQUE (uid),
    CONSTRAINT check_subscription_contracts_dates CHECK (end_date IS NULL OR end_date >= start_date)
);
ALTER TABLE subscription_contracts ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.subscription_contracts IS 'signed_by is plain text (an email or external identifier), not an FK, keeping this table decoupled from any app-specific accounts table';

-- ---- SaaS billing: entitlements (computed cache) & usage ----

CREATE TABLE subscription_entitlements (
    id            bigint             GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid           uuid               NOT NULL DEFAULT gen_random_uuid(),
    subscription_id uuid             NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    feature_id    bigint             NOT NULL REFERENCES features(id)      ON DELETE CASCADE,
    feature_key   text               NOT NULL,
    value_boolean boolean,
    value_limit   bigint,
    is_unlimited  boolean            NOT NULL DEFAULT false,
    source        entitlement_source NOT NULL DEFAULT 'plan',
    computed_at   timestamptz        NOT NULL DEFAULT now(),
    valid_until   timestamptz,
    created_at    timestamptz        NOT NULL DEFAULT now(),
    CONSTRAINT unique_subscription_entitlements_uid UNIQUE (uid),
    CONSTRAINT unique_subscription_entitlements_subscription_feature UNIQUE (subscription_id, feature_id)
);
ALTER TABLE subscription_entitlements ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.subscription_entitlements IS 'Computed/cached by recompute_subscription_entitlements(), never hand-edited except for source = override/promotion rows, which recompute deliberately leaves alone (see the ON CONFLICT guard there)';

CREATE TABLE usage_records (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid             uuid        NOT NULL DEFAULT gen_random_uuid(),
    subscription_id uuid        REFERENCES subscriptions(id) ON DELETE CASCADE,
    feature_id      bigint      NOT NULL REFERENCES features(id) ON DELETE RESTRICT,
    feature_key     text        NOT NULL,
    quantity        bigint      NOT NULL DEFAULT 1,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    period_start    timestamptz NOT NULL,
    period_end      timestamptz NOT NULL,
    idempotency_key text,
    metadata        jsonb       NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_usage_records_uid UNIQUE (uid),
    CONSTRAINT unique_usage_records_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT check_usage_records_period CHECK (period_end > period_start)
);
ALTER TABLE usage_records ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.usage_records IS 'Append-only raw usage events for metered features; record_usage() resolves subscription_id from the customer''s active subscription when not supplied and rolls the quantity into usage_summaries in the same call';

CREATE TABLE usage_summaries (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uid             uuid        NOT NULL DEFAULT gen_random_uuid(),
    subscription_id uuid        NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    feature_id      bigint      NOT NULL REFERENCES features(id)      ON DELETE RESTRICT,
    feature_key     text        NOT NULL,
    period_start    timestamptz NOT NULL,
    period_end      timestamptz NOT NULL,
    total_quantity  bigint      NOT NULL DEFAULT 0,
    last_updated_at timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_usage_summaries_uid UNIQUE (uid),
    CONSTRAINT unique_usage_summaries_subscription_feature_period UNIQUE (subscription_id, feature_id, period_start, period_end)
);
ALTER TABLE usage_summaries ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE @extschema@.usage_summaries IS 'Rollup cache maintained by record_usage(); never written to directly, mirroring ledger_account_balances/sync_account_balance()';

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

-- ---- SaaS billing extensions (idx_<table>_<columns> naming per AGENTS.md) ----

CREATE INDEX idx_features_type ON features (type) WHERE is_active = true;

CREATE INDEX idx_price_feature_entitlements_price ON price_feature_entitlements (price_id);
CREATE INDEX idx_price_feature_entitlements_feature ON price_feature_entitlements (feature_id);

CREATE INDEX idx_subscription_addons_subscription ON subscription_addons (subscription_id);
CREATE INDEX idx_subscription_addons_price ON subscription_addons (price_id);
CREATE INDEX idx_subscription_addons_active ON subscription_addons (subscription_id) WHERE status = 'active';

CREATE INDEX idx_change_requests_subscription ON subscription_change_requests (subscription_id);
CREATE INDEX idx_change_requests_customer ON subscription_change_requests (customer_id);
CREATE INDEX idx_change_requests_status ON subscription_change_requests (status);
CREATE INDEX idx_change_requests_expires ON subscription_change_requests (expires_at) WHERE status IN ('pending', 'processing', 'awaiting_payment');

CREATE INDEX idx_invoices_customer ON invoices (customer_id);
CREATE INDEX idx_invoices_subscription ON invoices (subscription_id) WHERE subscription_id IS NOT NULL;
CREATE INDEX idx_invoices_order ON invoices (order_id) WHERE order_id IS NOT NULL;
CREATE INDEX idx_invoices_status ON invoices (status);
CREATE INDEX idx_invoices_tenant ON invoices (tenant_id) WHERE tenant_id IS NOT NULL;
CREATE INDEX idx_invoices_period ON invoices (customer_id, period_start, period_end);

CREATE INDEX idx_invoice_line_items_invoice ON invoice_line_items (invoice_id);

CREATE INDEX idx_credit_notes_invoice ON credit_notes (invoice_id);
CREATE INDEX idx_credit_notes_customer ON credit_notes (customer_id);

CREATE INDEX idx_contracts_customer ON subscription_contracts (customer_id);
CREATE INDEX idx_contracts_subscription ON subscription_contracts (subscription_id) WHERE subscription_id IS NOT NULL;

CREATE INDEX idx_entitlements_subscription ON subscription_entitlements (subscription_id);
CREATE INDEX idx_entitlements_feature_key ON subscription_entitlements (feature_key);

CREATE INDEX idx_usage_records_subscription_period ON usage_records (subscription_id, period_start, period_end) WHERE subscription_id IS NOT NULL;
CREATE INDEX idx_usage_records_feature_key ON usage_records (feature_key);

CREATE INDEX idx_usage_summaries_subscription_period ON usage_summaries (subscription_id, period_start);
CREATE INDEX idx_usage_summaries_feature_key ON usage_summaries (feature_key);

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

-- Orders are immutable snapshots: once placed, only status/updated_at/metadata may change,
-- so an order always reflects exactly the totals/items agreed at purchase time, while still
-- allowing applications to attach post-creation context (tracking numbers, fulfillment
-- notes, external sync IDs) the same way prices/payment_intents/refunds/subscriptions do.
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
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'orders content is immutable once placed; only status/updated_at/metadata may change'
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
    -- Ensure the row exists, then lock it FOR UPDATE before computing the sum so
    -- concurrent callers serialize on this account instead of racing to overwrite
    -- each other's pre-lock sum with a stale value.
    INSERT INTO ledger_account_balances (account_id, currency, balance, updated_at)
    VALUES (p_account_id, p_currency, 0, now())
    ON CONFLICT (account_id, currency) DO NOTHING;

    PERFORM 1 FROM ledger_account_balances
    WHERE account_id = p_account_id AND currency = p_currency
    FOR UPDATE;

    UPDATE ledger_account_balances
    SET balance = (SELECT coalesce(sum(amount), 0) FROM ledger_entries WHERE account_id = p_account_id AND currency = p_currency),
        updated_at = now()
    WHERE account_id = p_account_id AND currency = p_currency;
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

    FOR v_row IN SELECT e AS e FROM jsonb_array_elements(p_entries) AS e
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

    -- A concurrent caller may insert the same idempotency_key between our pre-check above
    -- and this insert; catch the resulting unique_violation and return the winner's
    -- transaction id instead of raising, so the idempotency contract holds under a race.
    BEGIN
        INSERT INTO ledger_transactions (tenant_id, type, reference_type, reference_id, description, metadata, idempotency_key, created_by)
        VALUES (p_tenant_id, p_type, p_reference_type, p_reference_id, p_description, coalesce(p_metadata, '{}'), p_idempotency_key, p_created_by)
        RETURNING id INTO v_transaction_id;
    EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_transaction_id FROM ledger_transactions WHERE idempotency_key = p_idempotency_key;
        RETURN v_transaction_id;
    END;

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
    -- There is no unique constraint on (tenant_id, owner_type, account_type) for system
    -- accounts, so without serializing here two concurrent callers can both miss the
    -- SELECT below and each create their own account. Take a transaction-scoped advisory
    -- lock keyed on (tenant_id, account_type) so concurrent callers queue up and the
    -- second one observes the first's row instead of creating a duplicate.
    PERFORM pg_advisory_xact_lock(hashtextextended('get_or_create_system_account:' || coalesce(p_tenant_id, '') || ':' || p_account_type, 0));

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
    SELECT id INTO v_wallet_id
    FROM wallets
    WHERE tenant_id IS NOT DISTINCT FROM p_tenant_id
      AND owner_type = p_owner_type
      AND owner_id = p_owner_id
      AND wallet_type = coalesce(p_wallet_type, 'main');
    IF FOUND THEN
        RETURN v_wallet_id;
    END IF;

    v_ledger_account_id := create_ledger_account(p_owner_type, p_owner_id, 'wallet', p_tenant_id, p_wallet_type);

    -- A concurrent caller may insert the same (tenant_id, owner_type, owner_id, wallet_type)
    -- between our pre-check above and this insert; on unique_violation, delete the ledger
    -- account we just created so it doesn't leak as an orphan, and return the winner's
    -- wallet id instead of raising.
    BEGIN
        INSERT INTO wallets (tenant_id, owner_type, owner_id, wallet_type, ledger_account_id, default_currency, metadata)
        VALUES (p_tenant_id, p_owner_type, p_owner_id, coalesce(p_wallet_type, 'main'), v_ledger_account_id, p_default_currency, coalesce(p_metadata, '{}'))
        RETURNING id INTO v_wallet_id;
    EXCEPTION WHEN unique_violation THEN
        DELETE FROM ledger_accounts WHERE id = v_ledger_account_id;
        SELECT id INTO v_wallet_id
        FROM wallets
        WHERE tenant_id IS NOT DISTINCT FROM p_tenant_id
          AND owner_type = p_owner_type
          AND owner_id = p_owner_id
          AND wallet_type = coalesce(p_wallet_type, 'main');
        RETURN v_wallet_id;
    END;

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

    -- Lock the wallet row before checking the balance so concurrent withdrawals against
    -- the same wallet serialize: the second waiter re-reads the balance (post-lock) after
    -- the first has committed its debit, instead of both passing the check off a stale read.
    SELECT * INTO v_wallet FROM wallets WHERE id = p_wallet_id FOR UPDATE;
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

    -- Lock the source wallet before checking its balance, same as wallet_withdraw, so a
    -- concurrent transfer/withdrawal debiting the same source wallet can't both pass the
    -- balance check off a stale pre-lock read and overspend it.
    SELECT * INTO v_from FROM wallets WHERE id = p_from_wallet_id FOR UPDATE;
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
            IF v_unit < 0 THEN
                RAISE EXCEPTION 'item unit_amount must not be negative' USING ERRCODE = '22023';
            END IF;
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

    -- A concurrent caller may insert the same idempotency_key between our pre-check above
    -- and this insert; catch the resulting unique_violation and return the winner's order
    -- id instead of raising, so the idempotency contract holds under a race.
    BEGIN
        INSERT INTO orders (tenant_id, customer_id, currency, subtotal_amount, total_amount, metadata, idempotency_key)
        VALUES (p_tenant_id, p_customer_id, p_currency, v_subtotal, v_subtotal, coalesce(p_metadata, '{}'), p_idempotency_key)
        RETURNING id INTO v_order_id;
    EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_order_id FROM orders WHERE idempotency_key = p_idempotency_key;
        RETURN v_order_id;
    END;

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

    -- A concurrent caller may insert the same idempotency_key between our pre-check above
    -- and this insert; catch the resulting unique_violation and return the winner's
    -- payment_intent id instead of raising, so the idempotency contract holds under a race.
    BEGIN
        INSERT INTO payment_intents (tenant_id, order_id, provider, currency, amount, metadata, idempotency_key)
        VALUES (p_tenant_id, p_order_id, p_provider, p_currency, p_amount, coalesce(p_metadata, '{}'), p_idempotency_key)
        RETURNING id INTO v_payment_intent_id;
    EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_payment_intent_id FROM payment_intents WHERE idempotency_key = p_idempotency_key;
        RETURN v_payment_intent_id;
    END;

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

    -- Lock the payment_intent before checking the already-refunded total so concurrent
    -- refund requests against the same intent serialize: the second waiter re-reads the
    -- refunded total (post-lock) after the first has committed, instead of both passing
    -- the limit check off a stale read and together exceeding the intent's amount.
    SELECT * INTO v_intent FROM payment_intents WHERE id = p_payment_intent_id FOR UPDATE;
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

    -- A concurrent caller may insert the same idempotency_key between our pre-check above
    -- and this insert; catch the resulting unique_violation and return the winner's
    -- refund id instead of raising, so the idempotency contract holds under a race.
    BEGIN
        INSERT INTO refunds (tenant_id, payment_intent_id, provider, currency, amount, reason, idempotency_key)
        VALUES (v_intent.tenant_id, p_payment_intent_id, v_intent.provider, v_intent.currency, v_amount, p_reason, p_idempotency_key)
        RETURNING id INTO v_refund_id;
    EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_refund_id FROM refunds WHERE idempotency_key = p_idempotency_key;
        RETURN v_refund_id;
    END;

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
    IF p_event_type IS NULL OR trim(p_event_type) = '' THEN
        RAISE EXCEPTION 'event_type is required' USING ERRCODE = '22023';
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
-- pgho_outbox's claim_deliveries(). Also reclaims events stuck in 'processing' for too long
-- (worker crashed/restarted mid-processing without ever calling mark_webhook_event_processed
-- or mark_webhook_event_failed), so a dead worker can't strand events forever.
CREATE OR REPLACE FUNCTION claim_webhook_events(
    p_limit            integer DEFAULT 10,
    p_provider         text    DEFAULT NULL,
    p_stuck_after      interval DEFAULT interval '15 minutes'
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
        WHERE (p_provider IS NULL OR provider = p_provider)
          AND (
            status = 'pending'
            OR (status = 'processing' AND claimed_at < now() - p_stuck_after)
          )
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
    SET status       = CASE WHEN p_permanent THEN 'failed'::webhook_event_status ELSE 'pending'::webhook_event_status END,
        last_error   = p_error,
        claimed_at   = NULL,
        processed_at = NULL,
        failed_at    = CASE WHEN p_permanent THEN now() ELSE NULL END
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
    IF NOT v_price.active THEN
        RAISE EXCEPTION 'price % is not active', p_price_id USING ERRCODE = '55000';
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

    -- A concurrent caller may insert the same idempotency_key between our pre-check above
    -- and this insert; catch the resulting unique_violation and return the winner's
    -- subscription id instead of raising, so the idempotency contract holds under a race.
    BEGIN
        INSERT INTO subscriptions (
            tenant_id, customer_id, price_id, status,
            current_period_start, current_period_end, trial_end, metadata, idempotency_key
        )
        VALUES (
            p_tenant_id, p_customer_id, p_price_id, v_status,
            v_now, v_period_end, p_trial_end, coalesce(p_metadata, '{}'), p_idempotency_key
        )
        RETURNING id INTO v_subscription_id;
    EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_subscription_id FROM subscriptions WHERE idempotency_key = p_idempotency_key;
        RETURN v_subscription_id;
    END;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (v_subscription_id, 'created', jsonb_build_object('price_id', p_price_id, 'status', v_status));

    PERFORM recompute_subscription_entitlements(v_subscription_id);

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
    IF NOT v_new_price.active THEN
        RAISE EXCEPTION 'price % is not active', p_new_price_id USING ERRCODE = '55000';
    END IF;
    IF v_new_price.type <> 'recurring' THEN
        RAISE EXCEPTION 'price % is not recurring; subscriptions require a recurring price', p_new_price_id USING ERRCODE = '22023';
    END IF;

    UPDATE subscriptions SET price_id = p_new_price_id, updated_at = now() WHERE id = p_subscription_id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'price_changed', jsonb_build_object('old_price_id', v_subscription.price_id, 'new_price_id', p_new_price_id));

    PERFORM recompute_subscription_entitlements(p_subscription_id);
END;
$$;

-- ==============================
-- SAAS BILLING API
-- ==============================

-- ---- Numbering ----

CREATE SEQUENCE invoice_number_seq START 1;
CREATE SEQUENCE credit_note_number_seq START 1;

CREATE OR REPLACE FUNCTION next_invoice_number()
RETURNS text
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    SELECT 'INV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('invoice_number_seq')::text, 6, '0');
$$;

CREATE OR REPLACE FUNCTION next_credit_note_number()
RETURNS text
LANGUAGE sql
SET search_path = @extschema@, pg_catalog
AS $$
    SELECT 'CN-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('credit_note_number_seq')::text, 6, '0');
$$;

-- ---- Features & entitlements ----

CREATE OR REPLACE FUNCTION create_feature(
    p_key         text,
    p_name        text,
    p_type        text,
    p_description text  DEFAULT NULL,
    p_unit        text  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_uid uuid;
BEGIN
    IF p_key IS NULL OR trim(p_key) = '' THEN
        RAISE EXCEPTION 'feature key is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO features (key, name, description, type, unit)
    VALUES (p_key, p_name, p_description, p_type::feature_type, p_unit)
    RETURNING uid INTO v_uid;

    RETURN v_uid;
END;
$$;

-- Upserts by (price_id, feature_id) so re-declaring the same price/feature pair updates the
-- existing entitlement instead of erroring or duplicating it.
CREATE OR REPLACE FUNCTION set_price_entitlement(
    p_price_id      uuid,
    p_feature_key   text,
    p_value_boolean boolean DEFAULT NULL,
    p_value_limit   bigint  DEFAULT NULL,
    p_reset_period  text    DEFAULT 'monthly'
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_feature_id bigint;
    v_uid        uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM prices WHERE id = p_price_id) THEN
        RAISE EXCEPTION 'price % not found', p_price_id USING ERRCODE = 'P0002';
    END IF;

    SELECT id INTO v_feature_id FROM features WHERE key = p_feature_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'feature % not found', p_feature_key USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO price_feature_entitlements (price_id, feature_id, value_boolean, value_limit, reset_period)
    VALUES (p_price_id, v_feature_id, p_value_boolean, p_value_limit, p_reset_period::feature_reset_period)
    ON CONFLICT (price_id, feature_id) DO UPDATE
        SET value_boolean = EXCLUDED.value_boolean,
            value_limit   = EXCLUDED.value_limit,
            reset_period  = EXCLUDED.reset_period
    RETURNING uid INTO v_uid;

    RETURN v_uid;
END;
$$;

-- Recomputes a subscription's cached entitlements from its own price plus its active addons'
-- prices (both read from the same price_feature_entitlements table -- see products.is_addon).
-- A feature granted by both is merged permissively: booleans OR together, limits take the
-- larger value (or -1/unlimited if either grants unlimited). Rows with source = override or
-- promotion are deliberately left untouched by the ON CONFLICT guard below, so a manually
-- granted override always wins over whatever the plan/addons would otherwise compute.
CREATE OR REPLACE FUNCTION recompute_subscription_entitlements(
    p_subscription_id uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM subscriptions WHERE id = p_subscription_id) THEN
        RAISE EXCEPTION 'subscription % not found', p_subscription_id USING ERRCODE = 'P0002';
    END IF;

    DELETE FROM subscription_entitlements
    WHERE subscription_id = p_subscription_id
      AND source IN ('plan', 'addon');

    INSERT INTO subscription_entitlements (
        subscription_id, feature_id, feature_key,
        value_boolean, value_limit, is_unlimited, source, computed_at
    )
    SELECT
        p_subscription_id,
        combined.feature_id,
        combined.feature_key,
        bool_or(combined.value_boolean),
        CASE WHEN coalesce(bool_or(combined.value_limit = -1), false) THEN -1 ELSE max(combined.value_limit) END,
        coalesce(bool_or(combined.value_limit = -1), false),
        CASE WHEN bool_or(combined.is_addon) THEN 'addon' ELSE 'plan' END::entitlement_source,
        now()
    FROM (
        SELECT f.id AS feature_id, f.key AS feature_key,
               pfe.value_boolean, pfe.value_limit, false AS is_addon
        FROM subscriptions s
        JOIN price_feature_entitlements pfe ON pfe.price_id = s.price_id
        JOIN features f ON f.id = pfe.feature_id
        WHERE s.id = p_subscription_id

        UNION ALL

        SELECT f.id, f.key, afe.value_boolean, afe.value_limit, true
        FROM subscription_addons sa
        JOIN price_feature_entitlements afe ON afe.price_id = sa.price_id
        JOIN features f ON f.id = afe.feature_id
        WHERE sa.subscription_id = p_subscription_id
          AND sa.status = 'active'
    ) combined
    GROUP BY combined.feature_id, combined.feature_key
    ON CONFLICT (subscription_id, feature_id) DO UPDATE
        SET value_boolean = EXCLUDED.value_boolean,
            value_limit   = EXCLUDED.value_limit,
            is_unlimited  = EXCLUDED.is_unlimited,
            source        = EXCLUDED.source,
            computed_at   = EXCLUDED.computed_at
        WHERE subscription_entitlements.source NOT IN ('override', 'promotion');
END;
$$;

CREATE OR REPLACE FUNCTION check_feature_entitlement(
    p_subscription_id uuid,
    p_feature_key     text
)
RETURNS TABLE (allowed boolean, value_limit bigint, is_unlimited boolean)
LANGUAGE sql
STABLE
SET search_path = @extschema@, pg_catalog
AS $$
    SELECT coalesce(se.value_boolean, se.value_limit IS NULL OR se.value_limit <> 0, false),
           se.value_limit,
           coalesce(se.is_unlimited, false)
    FROM subscription_entitlements se
    WHERE se.subscription_id = p_subscription_id
      AND se.feature_key = p_feature_key;
$$;

-- ---- Addons ----

CREATE OR REPLACE FUNCTION add_subscription_addon(
    p_subscription_id uuid,
    p_price_id        uuid,
    p_quantity        integer DEFAULT 1
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_price prices;
    v_uid   uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM subscriptions WHERE id = p_subscription_id) THEN
        RAISE EXCEPTION 'subscription % not found', p_subscription_id USING ERRCODE = 'P0002';
    END IF;

    SELECT p.* INTO v_price
    FROM prices p
    JOIN products pr ON pr.id = p.product_id
    WHERE p.id = p_price_id AND pr.is_addon = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'price % is not an active addon price', p_price_id USING ERRCODE = 'P0002';
    END IF;
    IF NOT v_price.active THEN
        RAISE EXCEPTION 'price % is not active', p_price_id USING ERRCODE = '55000';
    END IF;
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'quantity must be positive' USING ERRCODE = '22023';
    END IF;

    INSERT INTO subscription_addons (subscription_id, price_id, quantity)
    VALUES (p_subscription_id, p_price_id, p_quantity)
    RETURNING uid INTO v_uid;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'addon_added', jsonb_build_object('price_id', p_price_id, 'quantity', p_quantity));

    PERFORM recompute_subscription_entitlements(p_subscription_id);

    RETURN v_uid;
END;
$$;

CREATE OR REPLACE FUNCTION remove_subscription_addon(
    p_subscription_addon_uid uuid,
    p_reason                 text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_addon subscription_addons;
BEGIN
    SELECT * INTO v_addon FROM subscription_addons WHERE uid = p_subscription_addon_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'subscription addon % not found', p_subscription_addon_uid USING ERRCODE = 'P0002';
    END IF;

    UPDATE subscription_addons
    SET status = 'cancelled', ends_at = now()
    WHERE id = v_addon.id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (v_addon.subscription_id, 'addon_removed', jsonb_build_object('price_id', v_addon.price_id, 'reason', p_reason));

    PERFORM recompute_subscription_entitlements(v_addon.subscription_id);
END;
$$;

-- ---- Seats, pause/resume ----

CREATE OR REPLACE FUNCTION set_subscription_quantity(
    p_subscription_id uuid,
    p_quantity        integer
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_subscription subscriptions;
BEGIN
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'quantity must be positive' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_subscription FROM subscriptions WHERE id = p_subscription_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'subscription % not found', p_subscription_id USING ERRCODE = 'P0002';
    END IF;

    UPDATE subscriptions SET quantity = p_quantity, updated_at = now() WHERE id = p_subscription_id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'quantity_changed', jsonb_build_object('old_quantity', v_subscription.quantity, 'new_quantity', p_quantity));
END;
$$;

CREATE OR REPLACE FUNCTION pause_subscription(
    p_subscription_id uuid
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
    IF v_subscription.status NOT IN ('active', 'trialing', 'past_due') THEN
        RAISE EXCEPTION 'subscription % is %, cannot pause', p_subscription_id, v_subscription.status
            USING ERRCODE = '55000';
    END IF;

    UPDATE subscriptions SET status = 'paused', updated_at = now() WHERE id = p_subscription_id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'paused', jsonb_build_object('previous_status', v_subscription.status));
END;
$$;

CREATE OR REPLACE FUNCTION resume_subscription(
    p_subscription_id uuid
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
    IF v_subscription.status <> 'paused' THEN
        RAISE EXCEPTION 'subscription % is %, cannot resume', p_subscription_id, v_subscription.status
            USING ERRCODE = '55000';
    END IF;

    UPDATE subscriptions SET status = 'active', updated_at = now() WHERE id = p_subscription_id;

    INSERT INTO subscription_events (subscription_id, type, payload)
    VALUES (p_subscription_id, 'resumed', '{}');
END;
$$;

-- ---- Subscription change requests (state machine) ----

CREATE OR REPLACE FUNCTION create_subscription_change_request(
    p_customer_id        text,
    p_type               text,
    p_subscription_id    uuid        DEFAULT NULL,
    p_target_price_id    uuid        DEFAULT NULL,
    p_tenant_id          text        DEFAULT NULL,
    p_proration_behavior text        DEFAULT 'create_prorations',
    p_payment_behavior   text        DEFAULT 'default_incomplete',
    p_effective_at       timestamptz DEFAULT NULL,
    p_metadata           jsonb       DEFAULT '{}',
    p_idempotency_key    text        DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_uid               uuid;
    v_current_price_id  uuid;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT uid INTO v_uid FROM subscription_change_requests WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_uid;
        END IF;
    END IF;

    IF p_subscription_id IS NOT NULL THEN
        SELECT price_id INTO v_current_price_id FROM subscriptions WHERE id = p_subscription_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'subscription % not found', p_subscription_id USING ERRCODE = 'P0002';
        END IF;
    END IF;

    -- A concurrent caller may insert the same idempotency_key between our pre-check above
    -- and this insert; catch the resulting unique_violation and return the winner's request
    -- id instead of raising, so the idempotency contract holds under a race.
    BEGIN
        INSERT INTO subscription_change_requests (
            subscription_id, tenant_id, customer_id, type,
            current_price_id, target_price_id, effective_at,
            proration_behavior, payment_behavior, idempotency_key, metadata
        )
        VALUES (
            p_subscription_id, p_tenant_id, p_customer_id, p_type::change_request_type,
            v_current_price_id, p_target_price_id, p_effective_at,
            p_proration_behavior::proration_behavior, p_payment_behavior::payment_behavior,
            p_idempotency_key, coalesce(p_metadata, '{}')
        )
        RETURNING uid INTO v_uid;
    EXCEPTION WHEN unique_violation THEN
        SELECT uid INTO v_uid FROM subscription_change_requests WHERE idempotency_key = p_idempotency_key;
        RETURN v_uid;
    END;

    RETURN v_uid;
END;
$$;

-- Dispatches a pending change request to the existing direct-mutation functions and records
-- the outcome; those functions remain independently callable for synchronous, non-queued use.
CREATE OR REPLACE FUNCTION apply_subscription_change_request(
    p_change_request_uid uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_request subscription_change_requests;
BEGIN
    SELECT * INTO v_request FROM subscription_change_requests WHERE uid = p_change_request_uid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'subscription change request % not found', p_change_request_uid USING ERRCODE = 'P0002';
    END IF;
    IF v_request.status NOT IN ('pending', 'awaiting_payment') THEN
        RAISE EXCEPTION 'change request % is %, cannot apply', p_change_request_uid, v_request.status
            USING ERRCODE = '55000';
    END IF;
    IF v_request.expires_at < now() THEN
        UPDATE subscription_change_requests SET status = 'expired' WHERE id = v_request.id;
        RAISE EXCEPTION 'change request % has expired', p_change_request_uid USING ERRCODE = '55000';
    END IF;

    UPDATE subscription_change_requests SET status = 'processing' WHERE id = v_request.id;

    BEGIN
        IF v_request.type = 'create' THEN
            UPDATE subscription_change_requests
            SET subscription_id = create_subscription(v_request.customer_id, v_request.target_price_id, v_request.tenant_id)
            WHERE id = v_request.id;
        ELSIF v_request.type IN ('upgrade', 'downgrade') THEN
            PERFORM change_subscription_price(v_request.subscription_id, v_request.target_price_id);
        ELSIF v_request.type = 'cancel' THEN
            PERFORM cancel_subscription(v_request.subscription_id, true);
        ELSIF v_request.type = 'pause' THEN
            PERFORM pause_subscription(v_request.subscription_id);
        ELSIF v_request.type = 'resume' THEN
            PERFORM resume_subscription(v_request.subscription_id);
        ELSIF v_request.type = 'renew' THEN
            PERFORM renew_subscription(v_request.subscription_id);
        ELSIF v_request.type = 'add_seats' THEN
            PERFORM set_subscription_quantity(
                v_request.subscription_id,
                (SELECT quantity FROM subscriptions WHERE id = v_request.subscription_id)
                    + coalesce((v_request.metadata->>'seats')::integer, 1)
            );
        ELSIF v_request.type = 'remove_seats' THEN
            PERFORM set_subscription_quantity(
                v_request.subscription_id,
                greatest(1, (SELECT quantity FROM subscriptions WHERE id = v_request.subscription_id)
                    - coalesce((v_request.metadata->>'seats')::integer, 1))
            );
        ELSIF v_request.type = 'add_addon' THEN
            PERFORM add_subscription_addon(
                v_request.subscription_id, v_request.target_price_id,
                coalesce((v_request.metadata->>'quantity')::integer, 1)
            );
        ELSIF v_request.type = 'remove_addon' THEN
            PERFORM remove_subscription_addon((v_request.metadata->>'subscription_addon_uid')::uuid);
        END IF;

        UPDATE subscription_change_requests
        SET status = 'completed', processed_at = now()
        WHERE id = v_request.id;
    EXCEPTION WHEN OTHERS THEN
        UPDATE subscription_change_requests
        SET status = 'failed', failure_reason = SQLERRM, processed_at = now()
        WHERE id = v_request.id;
        RAISE;
    END;
END;
$$;

-- Bulk-expires change requests that were never applied/paid before their expires_at; mirrors
-- claim_webhook_events' "reclaim stuck work" pattern but as a plain bulk UPDATE since nothing
-- needs to be claimed/locked for exclusive processing here.
CREATE OR REPLACE FUNCTION expire_subscription_change_requests(
    p_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_count integer;
BEGIN
    WITH expired AS (
        SELECT id FROM subscription_change_requests
        WHERE status IN ('pending', 'processing', 'awaiting_payment')
          AND expires_at < now()
        LIMIT p_limit
    )
    UPDATE subscription_change_requests
    SET status = 'expired'
    WHERE id IN (SELECT id FROM expired);

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- ---- Invoicing ----

CREATE OR REPLACE FUNCTION create_invoice(
    p_customer_id     text,
    p_currency        text,
    p_subscription_id uuid        DEFAULT NULL,
    p_order_id        uuid        DEFAULT NULL,
    p_billing_reason  text        DEFAULT NULL,
    p_period_start    timestamptz DEFAULT NULL,
    p_period_end      timestamptz DEFAULT NULL,
    p_tenant_id       text        DEFAULT NULL,
    p_metadata        jsonb       DEFAULT '{}',
    p_idempotency_key text        DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_uid      uuid;
    v_order    orders;
    v_subtotal bigint := 0;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT uid INTO v_uid FROM invoices WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_uid;
        END IF;
    END IF;

    IF p_order_id IS NOT NULL THEN
        SELECT * INTO v_order FROM orders WHERE id = p_order_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'order % not found', p_order_id USING ERRCODE = 'P0002';
        END IF;
        v_subtotal := v_order.subtotal_amount;
    END IF;

    BEGIN
        INSERT INTO invoices (
            tenant_id, customer_id, subscription_id, order_id, number,
            currency, subtotal_amount, total_amount, amount_due,
            billing_reason, period_start, period_end, metadata, idempotency_key
        )
        VALUES (
            p_tenant_id, p_customer_id, p_subscription_id, p_order_id, next_invoice_number(),
            p_currency, v_subtotal, v_subtotal, v_subtotal,
            p_billing_reason::billing_reason, p_period_start, p_period_end, coalesce(p_metadata, '{}'), p_idempotency_key
        )
        RETURNING uid INTO v_uid;
    EXCEPTION WHEN unique_violation THEN
        SELECT uid INTO v_uid FROM invoices WHERE idempotency_key = p_idempotency_key;
        RETURN v_uid;
    END;

    RETURN v_uid;
END;
$$;

-- The only sanctioned way to add a billing adjustment line (proration/tax/discount/credit/
-- usage) to an invoice; recomputes the invoice's totals from its order subtotal plus all of
-- its line items so amount_due can never drift from what the line items say it should be.
CREATE OR REPLACE FUNCTION add_invoice_line_item(
    p_invoice_uid  uuid,
    p_type         text,
    p_description  text,
    p_unit_amount  bigint,
    p_quantity     numeric     DEFAULT 1,
    p_period_start timestamptz DEFAULT NULL,
    p_period_end   timestamptz DEFAULT NULL,
    p_feature_key  text        DEFAULT NULL,
    p_metadata     jsonb       DEFAULT '{}'
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_invoice      invoices;
    v_line_item_id bigint;
    v_order        orders;
    v_totals       RECORD;
    v_subtotal     bigint;
BEGIN
    SELECT * INTO v_invoice FROM invoices WHERE uid = p_invoice_uid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % not found', p_invoice_uid USING ERRCODE = 'P0002';
    END IF;
    IF v_invoice.status <> 'draft' THEN
        RAISE EXCEPTION 'invoice % is %, only a draft invoice accepts line items', p_invoice_uid, v_invoice.status
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO invoice_line_items (invoice_id, type, description, quantity, unit_amount, total_amount, period_start, period_end, feature_key, metadata)
    VALUES (v_invoice.id, p_type, p_description, p_quantity, p_unit_amount, round(p_quantity * p_unit_amount), p_period_start, p_period_end, p_feature_key, coalesce(p_metadata, '{}'))
    RETURNING id INTO v_line_item_id;

    v_subtotal := 0;
    IF v_invoice.order_id IS NOT NULL THEN
        SELECT * INTO v_order FROM orders WHERE id = v_invoice.order_id;
        v_subtotal := v_order.subtotal_amount;
    END IF;

    SELECT
        coalesce(sum(total_amount) FILTER (WHERE type = 'tax'), 0)                                    AS tax,
        coalesce(sum(total_amount) FILTER (WHERE type = 'discount'), 0) + coalesce(sum(total_amount) FILTER (WHERE type = 'credit'), 0) AS discount,
        coalesce(sum(total_amount) FILTER (WHERE type IN ('proration', 'usage')), 0)                   AS additions
    INTO v_totals
    FROM invoice_line_items
    WHERE invoice_id = v_invoice.id;

    UPDATE invoices
    SET subtotal_amount = v_subtotal,
        tax_amount       = v_totals.tax,
        discount_amount  = v_totals.discount,
        total_amount     = v_subtotal + v_totals.tax + v_totals.additions - v_totals.discount,
        amount_due       = (v_subtotal + v_totals.tax + v_totals.additions - v_totals.discount) - amount_paid
    WHERE id = v_invoice.id;

    RETURN v_line_item_id;
END;
$$;

CREATE OR REPLACE FUNCTION finalize_invoice(
    p_invoice_uid uuid,
    p_due_date    timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_invoice invoices;
BEGIN
    SELECT * INTO v_invoice FROM invoices WHERE uid = p_invoice_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % not found', p_invoice_uid USING ERRCODE = 'P0002';
    END IF;
    IF v_invoice.status <> 'draft' THEN
        RAISE EXCEPTION 'invoice % is %, only a draft invoice can be finalized', p_invoice_uid, v_invoice.status
            USING ERRCODE = '55000';
    END IF;

    UPDATE invoices SET status = 'open', due_date = coalesce(p_due_date, due_date) WHERE id = v_invoice.id;
END;
$$;

CREATE OR REPLACE FUNCTION mark_invoice_paid(
    p_invoice_uid uuid,
    p_amount      bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_invoice invoices;
    v_amount  bigint;
    v_paid    bigint;
BEGIN
    SELECT * INTO v_invoice FROM invoices WHERE uid = p_invoice_uid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % not found', p_invoice_uid USING ERRCODE = 'P0002';
    END IF;
    IF v_invoice.status <> 'open' THEN
        RAISE EXCEPTION 'invoice % is %, only an open invoice can be paid', p_invoice_uid, v_invoice.status
            USING ERRCODE = '55000';
    END IF;

    v_amount := coalesce(p_amount, v_invoice.total_amount - v_invoice.amount_paid);
    v_paid   := v_invoice.amount_paid + v_amount;

    UPDATE invoices
    SET amount_paid = v_paid,
        amount_due  = v_invoice.total_amount - v_paid,
        status      = CASE WHEN v_paid >= v_invoice.total_amount THEN 'paid'::invoice_status ELSE status END,
        paid_at     = CASE WHEN v_paid >= v_invoice.total_amount THEN now() ELSE paid_at END
    WHERE id = v_invoice.id;
END;
$$;

CREATE OR REPLACE FUNCTION void_invoice(
    p_invoice_uid uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_invoice invoices;
BEGIN
    SELECT * INTO v_invoice FROM invoices WHERE uid = p_invoice_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % not found', p_invoice_uid USING ERRCODE = 'P0002';
    END IF;
    IF v_invoice.status NOT IN ('draft', 'open') THEN
        RAISE EXCEPTION 'invoice % is %; a paid invoice must be adjusted with a credit note instead', p_invoice_uid, v_invoice.status
            USING ERRCODE = '55000';
    END IF;

    UPDATE invoices SET status = 'void', voided_at = now() WHERE id = v_invoice.id;
END;
$$;

-- ---- Credit notes ----

CREATE OR REPLACE FUNCTION issue_credit_note(
    p_invoice_uid uuid,
    p_reason      text,
    p_amount      bigint DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_invoice          invoices;
    v_already_credited bigint;
    v_amount           bigint;
    v_uid              uuid;
BEGIN
    SELECT * INTO v_invoice FROM invoices WHERE uid = p_invoice_uid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % not found', p_invoice_uid USING ERRCODE = 'P0002';
    END IF;
    IF v_invoice.status <> 'paid' THEN
        RAISE EXCEPTION 'invoice % is %, only a paid invoice can receive a credit note', p_invoice_uid, v_invoice.status
            USING ERRCODE = '55000';
    END IF;

    SELECT coalesce(sum(total_amount), 0) INTO v_already_credited
    FROM credit_notes
    WHERE invoice_id = v_invoice.id AND status = 'issued';

    v_amount := coalesce(p_amount, v_invoice.total_amount - v_already_credited);
    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'credit note amount must be positive' USING ERRCODE = '22023';
    END IF;
    IF v_already_credited + v_amount > v_invoice.total_amount THEN
        RAISE EXCEPTION 'credit note of % would exceed invoice % total of % (already credited %)',
            v_amount, p_invoice_uid, v_invoice.total_amount, v_already_credited USING ERRCODE = '23514';
    END IF;

    INSERT INTO credit_notes (invoice_id, tenant_id, customer_id, number, status, reason, currency, total_amount)
    VALUES (v_invoice.id, v_invoice.tenant_id, v_invoice.customer_id, next_credit_note_number(), 'issued', p_reason::credit_note_reason, v_invoice.currency, v_amount)
    RETURNING uid INTO v_uid;

    RETURN v_uid;
END;
$$;

CREATE OR REPLACE FUNCTION void_credit_note(
    p_credit_note_uid uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_credit_note credit_notes;
BEGIN
    SELECT * INTO v_credit_note FROM credit_notes WHERE uid = p_credit_note_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'credit note % not found', p_credit_note_uid USING ERRCODE = 'P0002';
    END IF;
    IF v_credit_note.status <> 'issued' THEN
        RAISE EXCEPTION 'credit note % is not issued', p_credit_note_uid USING ERRCODE = '55000';
    END IF;

    UPDATE credit_notes SET status = 'void', voided_at = now() WHERE id = v_credit_note.id;
END;
$$;

-- ---- Usage tracking ----

-- Resolves subscription_id from the customer's active subscription when not supplied, then
-- records the raw event and rolls it into usage_summaries in the same call (an explicit call
-- here rather than an AFTER INSERT trigger, matching how sync_order_status/sync_account_balance
-- are invoked explicitly elsewhere in this file rather than via triggers).
CREATE OR REPLACE FUNCTION record_usage(
    p_customer_id     text,
    p_feature_key     text,
    p_period_start    timestamptz,
    p_period_end      timestamptz,
    p_quantity        bigint      DEFAULT 1,
    p_subscription_id uuid        DEFAULT NULL,
    p_tenant_id       text        DEFAULT NULL,
    p_idempotency_key text        DEFAULT NULL,
    p_metadata        jsonb       DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
DECLARE
    v_feature_id      bigint;
    v_subscription_id uuid;
    v_uid             uuid;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT uid INTO v_uid FROM usage_records WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_uid;
        END IF;
    END IF;

    SELECT id INTO v_feature_id FROM features WHERE key = p_feature_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'feature % not found', p_feature_key USING ERRCODE = 'P0002';
    END IF;

    v_subscription_id := p_subscription_id;
    IF v_subscription_id IS NULL THEN
        SELECT id INTO v_subscription_id
        FROM subscriptions
        WHERE customer_id = p_customer_id
          AND status IN ('active', 'trialing')
        ORDER BY created_at DESC
        LIMIT 1;
    END IF;

    BEGIN
        INSERT INTO usage_records (subscription_id, feature_id, feature_key, quantity, period_start, period_end, idempotency_key, metadata)
        VALUES (v_subscription_id, v_feature_id, p_feature_key, p_quantity, p_period_start, p_period_end, p_idempotency_key, coalesce(p_metadata, '{}'))
        RETURNING uid INTO v_uid;
    EXCEPTION WHEN unique_violation THEN
        SELECT uid INTO v_uid FROM usage_records WHERE idempotency_key = p_idempotency_key;
        RETURN v_uid;
    END;

    IF v_subscription_id IS NOT NULL THEN
        INSERT INTO usage_summaries (subscription_id, feature_id, feature_key, period_start, period_end, total_quantity, last_updated_at)
        VALUES (v_subscription_id, v_feature_id, p_feature_key, p_period_start, p_period_end, p_quantity, now())
        ON CONFLICT (subscription_id, feature_id, period_start, period_end) DO UPDATE
            SET total_quantity  = usage_summaries.total_quantity + EXCLUDED.total_quantity,
                last_updated_at = now();
    END IF;

    RETURN v_uid;
END;
$$;

-- Lock down pgho_payments: no access by default.
-- The calling application is responsible for granting only the minimum
-- required privileges to its own database role(s) after installation.

REVOKE USAGE ON SCHEMA @extschema@ FROM PUBLIC;
REVOKE ALL   ON ALL TABLES    IN SCHEMA @extschema@ FROM PUBLIC;
REVOKE ALL   ON ALL FUNCTIONS IN SCHEMA @extschema@ FROM PUBLIC;
REVOKE ALL   ON ALL SEQUENCES IN SCHEMA @extschema@ FROM PUBLIC;
