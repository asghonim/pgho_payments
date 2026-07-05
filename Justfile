# Start the local Supabase stack (applies migrations: pg_tle, pgtap, pgho_payments itself).
start:
    supabase start

# Run the pgTAP test suite against the local Supabase database.
test:
    supabase test db

# Regenerate supabase/migrations/*_pgho_payments.sql after editing pgho_payments--0.0.1.sql,
# then reset the local Supabase database to pick it up.
regenerate:
    dbdev add --output-path supabase/migrations --schema pgho_payments path --directory .
    supabase db reset
