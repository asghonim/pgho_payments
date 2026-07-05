create schema if not exists "pgho_payments";
create extension if not exists "pgho_payments" schema "pgho_payments" version '0.0.1';
-- Setting default version to:0.0.1
select pgtle.set_default_version('pgho_payments', '0.0.1');
