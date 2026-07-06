# Start the local Supabase stack (applies migrations: pg_tle, pgtap, pgho_payments itself).
start:
    supabase start

# Run the pgTAP test suite against the local Supabase database.
test:
    supabase test db

install docker="":
    dbdev install --connection postgresql://postgres:postgres@{{ if docker != "" { "host.docker.internal" } else { "localhost" } }}:54322/postgres path --directory .

# Regenerate supabase/migrations/*_pgho_payments.sql after editing pgho_payments--0.0.1.sql
add docker="":
    dbdev add --output-path supabase/migrations --schema pgho_payments --connection postgresql://postgres:postgres@{{ if docker != "" { "host.docker.internal" } else { "localhost" } }}:54322/postgres path --directory .

reset:
    supabase db reset

migrate direction="up":
    supabase migration {{ direction }}