# pgho_payments

A [pg_tle](https://github.com/aws/pg_tle) Postgres extension that gives an application a
ledger-first financial core: double-entry accounting, wallets, a product catalog, orders,
payment-provider integration (intents, webhooks, refunds), and SaaS subscription billing
(seats, addons, feature entitlements, usage-based metering, change requests, invoices,
credit notes, and enterprise contracts).

## Introduction

The guiding principle: **money is represented by an immutable double-entry ledger; every
other module is built around that ledger, not the other way around.**

```
Catalog (products, prices) ------> Feature entitlements ------> Subscription entitlements
        |                                                              ^
        v                                                              |
    Orders  ---------->  Payment Intents  ---->  Refunds        Subscriptions -----> Addons
        ^                       |                                     ^    \
        |                       v                                     |     `--> Change requests
  Invoices ----> Credit notes   Ledger (accounts, transactions, entries)     `--> Usage records/summaries
        ^                              ^                                          `--> Contracts
        |                              |
     (orders)                       Wallets
```

- **Ledger** (`ledger_accounts`, `ledger_transactions`, `ledger_entries`,
  `ledger_account_balances`): an append-only journal. `post_transaction()` is the only
  sanctioned way to write entries -- it enforces that every transaction's legs sum to zero
  *per currency* before anything is inserted. This module has no foreign keys into any
  commerce table, so it can be used entirely on its own.
- **Wallets** (`wallets`): a named balance for a user, organization, or system account,
  backed by a `ledger_account`. Top-ups, withdrawals, and transfers are thin wrappers around
  `post_transaction()`.
- **Catalog** (`products`, `prices`): sellable things and their (immutable, versioned)
  price points. A "plan" is a product, a "plan version" is a price; an "addon" is just a
  product flagged `is_addon`, so it shares the same pricing/entitlement machinery instead of
  a parallel one.
- **Orders** (`orders`, `order_items`): immutable purchase snapshots. Line items snapshot
  `unit_amount` from the price at order time, so later price changes never retroactively
  change a placed order.
- **Payments** (`payment_intents`, `refunds`, `webhook_events`): intent-to-collect tracking,
  refunds, and a claim-based worker queue for provider webhooks. `provider` is plain text
  everywhere (`stripe`, `paypal`, `paymob`, ...), not an enum, so a new provider never
  requires a schema change.
- **Subscriptions** (`subscriptions`, `subscription_events`, `subscription_addons`):
  recurring billing built on the catalog + orders + payment intents modules, plus seats
  (`quantity`), addons, pause/resume, and an append-only event log.
- **Change requests** (`subscription_change_requests`): an optional async/idempotent state
  machine (`create`/`upgrade`/`downgrade`/`cancel`/`pause`/`resume`/`renew`/seats/addons) for
  callers that need queuing, expiry, and payment-gating semantics around a mutation.
  `apply_subscription_change_request()` just dispatches to the functions above -- calling
  those directly remains valid for synchronous use.
- **Features & entitlements** (`features`, `price_feature_entitlements`,
  `subscription_entitlements`): what a price (plan or addon) grants, and a per-subscription
  cache recomputed by `recompute_subscription_entitlements()` -- never hand-edited, except
  `override`/`promotion`-sourced rows, which recompute deliberately leaves alone.
- **Usage** (`usage_records`, `usage_summaries`): append-only metered-feature events and a
  rollup cache, for features billed or capped by consumption rather than a flat limit.
- **Invoices & credit notes** (`invoices`, `invoice_line_items`, `credit_notes`): a billing
  document wrapping an order's line items plus billing-only adjustments (proration, tax,
  discount, credit, usage), and a paper-trail record for reducing what's owed on a paid
  invoice.
- **Enterprise contracts** (`subscription_contracts`): custom pricing/terms/SLA tracking for
  negotiated deals, decoupled from any app-specific accounts table (`signed_by` is plain
  text).

Everything that changes money -- a wallet top-up, a captured payment, a refund -- ultimately
posts a balanced `ledger_transaction`. Balances are never stored or updated directly; they're
always a rollup recomputed from the entries. Credit notes are the one exception in this
version -- see "Out of scope" below.

Like the rest of this extension, all of the above stays decoupled from any application's own
organizations/accounts tables: `tenant_id`/`customer_id` are plain text throughout, and the
newer tables enable row-level security with no default policy (per this repo's `AGENTS.md`),
so a consuming application adds its own policies rather than this extension assuming one.

### Out of scope (for now)

Coupons, tax calculation, gift cards, payouts, revenue-share/marketplace splits, disputes,
and automatic proration math are not implemented. `proration_behavior`/`payment_behavior` on
a change request only record the caller's intent -- computing the actual amount and posting
it as an invoice line item is left to the application. Posting a credit note's ledger
reversal (mirroring `mark_refund_succeeded`) is also left to the application for this
version.

## Installation

### Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started)
- [dbdev CLI](https://github.com/supabase/dbdev) (only needed to regenerate the migration
  after editing the extension source)
- Docker, to run the local Supabase/Postgres stack

`.devcontainer/init.sh` installs both CLIs if you're using the provided devcontainer.

### Local development

```sh
just start   # supabase start -- applies the pg_tle, pgtap, and pgho_payments migrations
just test    # supabase test db -- runs the pgTAP suite in supabase/tests/database/
```

### Installing into a database

`pgho_payments--0.0.1.sql` + `pgho_payments.control` are the actual pg_tle extension
source. In this repo they're wrapped into a `pgtle.install_extension(...)` call inside
`supabase/migrations/*_pgho_payments.sql`, generated by:

```sh
just add   # dbdev add ... then supabase db reset
```

Outside of this repo's Supabase stack, install it like any other pg_tle extension:

```sql
select pgtle.install_extension(
    'pgho_payments',
    '0.0.1',
    'Ledger-first payments: double-entry ledger, wallets, catalog, orders, subscriptions',
    pg_read_file('pgho_payments--0.0.1.sql')
);

create extension pgho_payments schema pgho_payments;
```

### Granting access

The extension revokes all privileges from `PUBLIC` on install (its tables, functions, and
sequences). Grant your application's own role only what it needs, for example:

```sql
grant usage on schema pgho_payments to app_role;
grant execute on all functions in schema pgho_payments to app_role;
grant select on all tables in schema pgho_payments to app_role;
```

Prefer granting `EXECUTE` on the functions API over raw table `INSERT`/`UPDATE` -- the
immutability triggers and idempotency logic live in the functions, not in table-level
constraints alone.

The `grant select`/`grant execute` pair above is enough to use the ledger-first core, but
not the SaaS-billing tables (`features` and everything added alongside it) -- those enable
RLS with no default policy, so `app_role` also needs its own policies before it can see or
write rows there. See "Row-level security" below.

### A note on relocating the extension

`pgho_payments.control` sets `relocatable = false`, because every function pins
`SET search_path = @extschema@, pg_catalog`, substituted once at install time. If the
extension were relocated via `ALTER EXTENSION pgho_payments SET SCHEMA ...`, the tables
would move but each function's pinned search_path would still point at the old schema
name, so functions would stop finding their own tables. Postgres rejects that command
outright for a non-relocatable extension; to move an installed instance, drop and recreate
it in the new schema instead.

## Usage

All examples assume `search_path` includes the schema the extension was installed into
(e.g. `set search_path to pgho_payments, public;`).

### Ledger and wallets

```sql
-- Chart-of-accounts entries are created lazily by the wallet/system helpers below, but you
-- can also create one directly for a custom account type (e.g. a merchant's revenue ledger):
select create_ledger_account('org', 'org-123', 'revenue');

-- Wallets are a named balance backed by a ledger account:
select create_wallet('user', 'user-42') as wallet_id \gset

select wallet_topup(:'wallet_id', 5000, 'USD');            -- +50.00
select wallet_withdraw(:'wallet_id', 1000, 'USD');         -- -10.00
select wallet_transfer(:'wallet_id', :'other_wallet_id', 500, 'USD');

select get_wallet_balance(:'wallet_id', 'USD');

-- Anything else that needs to move money posts directly through the ledger. Entries must
-- sum to zero *per currency*:
select post_transaction(
    'manual_adjustment',
    jsonb_build_array(
        jsonb_build_object('account_id', 1, 'currency', 'USD', 'amount',  1000),
        jsonb_build_object('account_id', 2, 'currency', 'USD', 'amount', -1000)
    ),
    p_description := 'correcting a misapplied fee'
);
```

### Catalog

```sql
select create_product('Pro Plan') as product_id \gset

select create_price(:'product_id', 'USD', 1000) as price_one_time \gset
select create_price(:'product_id', 'USD', 2500, 'recurring', 'month') as price_monthly \gset

select deactivate_price(:'price_one_time');
```

### Orders

```sql
select create_order(
    'customer-1', 'USD',
    jsonb_build_array(
        jsonb_build_object('price_id', :'price_monthly', 'quantity', 1),
        jsonb_build_object('unit_amount', 300, 'description', 'setup fee', 'quantity', 1)
    ),
    p_idempotency_key := 'checkout-session-abc'
) as order_id \gset

select cancel_order(:'order_id');  -- only while status = 'pending'
```

### Payment intents and refunds

```sql
select create_payment_intent('stripe', 'USD', 1300, :'order_id') as intent_id \gset

-- Called from your provider integration once the charge is confirmed:
select mark_payment_intent_succeeded(:'intent_id', p_provider_intent_id := 'pi_123');
-- -> posts the ledger transaction and rolls the linked order up to 'paid'

select create_refund(:'intent_id') as refund_id \gset  -- full refund; pass p_amount for partial
select mark_refund_succeeded(:'refund_id');
-- -> posts the reversing ledger transaction and rolls the order to 'refunded'/'partially_refunded'
```

### Webhooks

```sql
-- Called from your webhook receiver, before verifying/acting on the payload:
select record_webhook_event('stripe', 'payment_intent.succeeded', 'evt_123', payload_jsonb);

-- Called from a background worker:
select * from claim_webhook_events(p_limit := 10, p_provider := 'stripe');
select mark_webhook_event_processed(:'webhook_event_id');
select mark_webhook_event_failed(:'webhook_event_id', 'timeout calling downstream API', p_permanent := false);
```

### Subscriptions

```sql
select create_subscription('customer-1', :'price_monthly') as subscription_id \gset

-- Called by your billing scheduler once a period elapses (see the
-- subscriptions_renewal_due_idx index for finding subscriptions due to renew):
select renew_subscription(:'subscription_id');

select change_subscription_price(:'subscription_id', :'new_price_id');
select cancel_subscription(:'subscription_id', p_at_period_end := true);

select set_subscription_quantity(:'subscription_id', 5);  -- seats
select pause_subscription(:'subscription_id');
select resume_subscription(:'subscription_id');
```

### Features, entitlements, and addons

```sql
select create_feature('api_calls', 'API Calls', 'limit', p_unit := 'calls') as api_calls_feature \gset
select create_feature('sso', 'SSO', 'boolean') as sso_feature \gset

select set_price_entitlement(:'price_monthly', 'api_calls', p_value_limit := 1000);
select set_price_entitlement(:'price_monthly', 'sso', p_value_boolean := false);

-- Entitlements are cached on the subscription and recomputed automatically by
-- create_subscription/change_subscription_price/add_subscription_addon/remove_subscription_addon:
select * from check_feature_entitlement(:'subscription_id', 'api_calls');

-- An addon is just a product flagged is_addon, priced/entitled like any other price:
insert into products (name, is_addon) values ('Extra API Calls') returning id as addon_product_id \gset
select create_price(:'addon_product_id', 'USD', 500, 'recurring', 'month') as addon_price_id \gset
select set_price_entitlement(:'addon_price_id', 'api_calls', p_value_limit := 5000);

select add_subscription_addon(:'subscription_id', :'addon_price_id') as subscription_addon_id \gset
-- -> api_calls entitlement is now the merge of plan + addon (larger limit wins; -1 = unlimited)
select remove_subscription_addon(:'subscription_addon_id');
```

### Usage tracking (metered features)

```sql
select create_feature('emails_sent', 'Emails Sent', 'metered', p_unit := 'emails') as emails_feature \gset

-- Resolves subscription_id from the customer's active subscription when not supplied, and
-- rolls the quantity into usage_summaries in the same call:
select record_usage('customer-1', 'emails_sent', '2026-07-01', '2026-08-01', p_quantity := 10);

select total_quantity from usage_summaries
where subscription_id = :'subscription_id' and feature_key = 'emails_sent';
```

### Change requests (optional queue/state machine)

```sql
select create_subscription_change_request(
    'customer-1', 'upgrade', :'subscription_id', :'new_price_id',
    p_idempotency_key := 'change-req-abc'
) as change_request_id \gset

-- Called synchronously, or by a worker once payment is confirmed:
select apply_subscription_change_request(:'change_request_id');

-- Called periodically by a worker to close out requests nobody ever completed:
select expire_subscription_change_requests();
```

### Invoicing and credit notes

```sql
select create_invoice('customer-1', 'USD', :'subscription_id', :'order_id', 'subscription_cycle') as invoice_id \gset
select add_invoice_line_item(:'invoice_id', 'tax', 'VAT 5%', 150);

select finalize_invoice(:'invoice_id');       -- draft -> open
select mark_invoice_paid(:'invoice_id');      -- open -> paid once amount_paid >= total_amount

select issue_credit_note(:'invoice_id', 'order_change', p_amount := 500) as credit_note_id \gset
select void_credit_note(:'credit_note_id');
```

### Enterprise contracts

```sql
insert into subscription_contracts (customer_id, subscription_id, start_date, sla_tier, signed_by)
values ('customer-1', :'subscription_id', current_date, 'gold', 'jane@example.com');
```

## Idempotency

Every write path that touches money or creates a billable record accepts an
`p_idempotency_key`; a repeated key returns the original row's id instead of creating a
duplicate. This includes the SaaS-billing additions: `create_subscription_change_request()`,
`create_invoice()`, and `record_usage()`. Provider-originated events (`webhook_events`)
instead use the natural key `(provider, provider_event_id)`.

## Immutability

Ledger rows (`ledger_transactions`, `ledger_entries`), audit logs (`subscription_events`),
and metered usage events (`usage_records`) are fully append-only -- corrections are made by
posting a reversing transaction (or a new usage record), never by editing history. Commerce
rows (`prices`, `orders`, `payment_intents`, `refunds`, `subscriptions`, `ledger_accounts`)
are immutable on their core fields once created; only status/lifecycle fields may change
afterward. Every case is enforced by a `BEFORE UPDATE` trigger raising `ERRCODE = '0A000'`.
Invoices follow the same spirit without a dedicated trigger: `add_invoice_line_item()`
refuses to touch anything but a `draft` invoice, and a `paid` invoice can only be adjusted by
issuing a `credit_note`, never edited directly.

## Row-level security

Unlike the ledger-first core above (which has no RLS and relies entirely on the calling
application's own `GRANT`s), the SaaS-billing tables (`features` and everything added
alongside it) enable RLS with no default policy, per this repo's `AGENTS.md`. That means a
role only sees rows there once the consuming application adds its own policies -- there is
no built-in notion of who's allowed to see which `tenant_id`/`customer_id`'s data.

## Testing

```sh
just start
just test
```

The suite lives in `supabase/tests/database/pgho_payments.test.sql` and is organized by the
same section headers as `pgho_payments--0.0.1.sql`.

## Contributing

After editing `pgho_payments--0.0.1.sql`, run `just add` to regenerate the dbdev
migration and reset your local database, then `just test`.
