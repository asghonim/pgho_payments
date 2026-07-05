-- Delete existing extension if installed
drop extension if exists "pgho_payments";
drop schema if exists "pgho_payments" cascade;
create schema if not exists "pgho_payments";
-- Create the extension
create extension "pgho_payments" schema "pgho_payments" version '0.0.1';
-- Setting default version to:0.0.1
select pgtle.set_default_version('pgho_payments', '0.0.1');
