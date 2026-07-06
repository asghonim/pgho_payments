These instructions apply unless the user explicitly requests otherwise.

---

# Design Principles

Follow these principles in order of priority:

1. Data integrity over convenience.
2. Database-enforced security over application logic.
3. Immutable (append-only) data over mutable rows.
4. Least privilege.
5. SQL-first business logic.
6. Performance by default.
7. Explicit over implicit.

---

# Migration Order

Unless a migration requires a different order, follow this sequence:

1. CREATE TABLE
2. ALTER TABLE ... ENABLE ROW LEVEL SECURITY
3. CREATE INDEX
4. CREATE FUNCTIONS
5. REVOKE EXECUTE
6. GRANT EXECUTE
7. GRANT (SELECT or INSERT) and CREATE POLICIES
8. CREATE TRIGGERS
9. Seed data

---

# Table Standards

## Required

Every table must:

- Use `bigint GENERATED ALWAYS AS IDENTITY` as the primary key.
- Include a globally unique UUID immediately after the primary key.
- Include:

```sql
created_at timestamptz NOT NULL DEFAULT now()
```

- Explicitly specify every `ON DELETE` action.
- Enable Row Level Security immediately after creation.
- Define indexes immediately after creation.
- Prefix every referenced object with `@extschema@`.
- Use explicit constraint names.
- Use explicit column lists in every statement.

## Preferred

- Use UUID v7 where available.
- Normalize data instead of storing JSON.
- Use immutable append-only tables.
- Use generated columns instead of duplicated data.

## Never

- Never create an `updated_at` column.
- Never rely on application validation for integrity.
- Never use `SELECT *` inside views or functions.
- Never omit `ON DELETE`.
- Never use `ON DELETE CASCADE` unless explicitly justified.

---

# Immutable Data Model

Assume every table is append-only unless instructed otherwise.

Rows should never be updated or deleted.

Changes should create new rows.

Examples:

```
account_names
account_emails
account_avatars
conversation_titles
content_versions
organization_addresses
```

Mutable tables are allowed only for operational metadata.

Examples:

```
published_at
deleted_at
expires_at
retry_count
last_processed_at
```

When mutation is required:

- Prefer dedicated SQL functions.
- Validate permissions inside the function.
- Never expose direct UPDATE permissions.

---

# Index Standards

Always index:

- Foreign keys
- Permission lookup columns
- Columns used by RLS
- Frequently filtered columns
- Frequently joined columns

Use:

- Composite indexes for historical tables

```
(parent_id, created_at DESC)
```

- Composite indexes for event streams

```
(entity_id, created_at DESC)
```

- Partial indexes

```
WHERE deleted_at IS NULL

WHERE revoked_at IS NULL

WHERE processed_at IS NULL
```

- GIN + pg_trgm indexes for searchable text

Consider:

- BRIN indexes
- Covering indexes
- Partitioning for very large tables

Index names:

```
idx_<table>_<columns>
```

Examples:

```
idx_accounts_email

idx_messages_conversation_created

idx_api_keys_active
```

Create one index per statement.

---

# Constraints

Always use:

- CHECK constraints for text length

```sql
CHECK (char_length(name) BETWEEN 1 AND 255)
```

- UNIQUE constraints on natural keys

Examples:

- email
- slug
- external_id
- key_hash

Constraint names:

```
fk_<table>_<parent>

unique_<column>

check_<column>
```

---

# Row Level Security

Enable RLS immediately after every table is created.

Policies should follow this naming format

```
SELECT Accounts

INSERT Wallet

UPDATE Content

DELETE Organization
```

Do not create policies unless explicitly required. The application code is responsible for enforcing permissions and exposing API.

---

# Functions

## Required

Every function must:

- Specify its language.
- Explicitly set `search_path`.
- Use schema-qualified object names.
- Revoke EXECUTE from @extschema@.
- Grant EXECUTE only to the minimum required roles.

Example:

```sql
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = @extschema@, pg_temp
```

## Security

Prefer:

```
SECURITY INVOKER
```

Use:

```
SECURITY DEFINER
```

only when elevated privileges are necessary.

Never create a SECURITY DEFINER function without an explicit `search_path`.

## Design

Prefer functions that are:

- Deterministic
- Idempotent
- Small
- Focused
- Set-based

Avoid:

- Dynamic SQL
- Hidden side effects
- Exception swallowing
- Row-by-row loops when set operations are possible

---

# Triggers

Use triggers only when they enforce database integrity.

Trigger rules:

- Place the trigger immediately after its function.
- Keep trigger functions small.
- Delegate business logic into helper functions.
- Prefer AFTER triggers unless BEFORE is required.

Example:

```sql
CREATE OR REPLACE FUNCTION @extschema@.on_account_inserted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_temp
AS $$
BEGIN
    INSERT INTO @extschema@.principals (...)
    VALUES (...);

    RETURN NEW;
END;
$$;

CREATE TRIGGER on_account_inserted
AFTER INSERT ON @extschema@.accounts
FOR EACH ROW
EXECUTE FUNCTION @extschema@.on_account_inserted();
```

---

# Permissions

Follow the Principle of Least Privilege.

Never grant:

- UPDATE
- DELETE
- ALL

unless explicitly required.

Prefer SQL functions over table permissions.

INSERT grants:

- Must specify explicit columns.
- Must exclude:

```
id
uuid
created_at
deleted_at
account_id
organization_id
```

User identity columns should default from helper functions.

Example:

```sql
account_id bigint NOT NULL DEFAULT my_account_id()
```

---

# Views

Prefer SECURITY INVOKER views.

Always:

- Explicitly list columns.
- Use schema-qualified names.

Never:

- SELECT *
- Depend on implicit column ordering.

Materialized views should include a refresh strategy.

---

# JSON

Prefer normalized tables.

Use `jsonb` only when:

- The schema is dynamic.
- Third-party payloads are stored.
- Arbitrary metadata is required.

When using JSON:

- Validate structure.
- Add CHECK constraints where possible.
- Index queried paths.

---

# Large Tables

Consider partitioning when tables are expected to grow significantly.

Preferred strategies:

- Monthly partitions
- Organization partitions
- Tenant partitions

---

# Transactions

Keep migrations transactional.

Avoid operations that require long table locks.

Only create indexes CONCURRENTLY outside transaction-based migrations.

---

# Naming Conventions

## Tables

```
accounts

organizations

organization_members

account_names
```

## Indexes

```
idx_accounts_email

idx_messages_created

idx_api_keys_active
```

## Constraints

```
fk_messages_conversation

unique_slug

check_name_length
```

## Functions

```
@extschema@.check_membership()

@extschema@.publish_content()

@extschema@.delete_content()
```

## Triggers

```
on_account_inserted

on_message_created
```

## Policies

```
SELECT Accounts

INSERT Wallet

UPDATE Content
```

---

# SQL Style

- Always schema-qualify object names.
- Place the closing parenthesis of CREATE TABLE on its own line.
- Create one index per statement.
- Use tabs for function bodies and seed data.
- Keep statements vertically aligned for readability.

---

# Assumed Extensions

Assume these extensions already exist unless instructed otherwise.

- pgcrypto
- pg_trgm
- btree_gin
- uuidv7 (or equivalent)
- citext

Do not create extensions unless explicitly instructed.

---

# Pre-Flight Checklist

Before completing any migration, verify:

- [ ] Uses bigint identity primary keys.
- [ ] UUID column exists.
- [ ] created_at exists.
- [ ] No updated_at column.
- [ ] Explicit ON DELETE actions.
- [ ] Constraint names are explicit.
- [ ] Indexes created.
- [ ] RLS enabled.
- [ ] Policies created.
- [ ] search_path explicitly set.
- [ ] EXECUTE revoked from @extschema@.
- [ ] Minimum EXECUTE grants applied.
- [ ] SECURITY INVOKER used unless necessary.
- [ ] Schema-qualified object names used.
- [ ] Immutable design considered.
- [ ] Trigger placed immediately after its function.
- [ ] SQL formatted consistently.