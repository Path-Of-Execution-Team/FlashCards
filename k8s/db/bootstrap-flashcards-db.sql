-- Creates the dedicated database and role for FlashCards on the shared
-- PostgreSQL instance in the `database` namespace.
--
-- INFRASTRUCTURE.md section 4 requires a separate role and database per
-- production application and forbids using the `postgres` superuser from
-- application code. This script is the one place the superuser is used.
--
-- Run it as `postgres`, passing the password that you stored in Vault under
-- secret/projects/moomento/production/backend -> SPRING_DATASOURCE_PASSWORD:
--
--   kubectl exec -i -n database postgresql-0 -- \
--     psql -U postgres -d postgres \
--          -v flashcards_password="$FLASHCARDS_DB_PASSWORD" \
--     < k8s/db/bootstrap-flashcards-db.sql
--
-- Note: a value passed with -v is visible in the process list of the machine
-- running kubectl. On a shared workstation, set it interactively instead.
--
-- Safe to re-run: it is idempotent and also rotates the password.

\set ON_ERROR_STOP on

-- --------------------------------------------------------------------------
-- Role
-- --------------------------------------------------------------------------
SELECT 'CREATE ROLE flashcards_user LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flashcards_user')
\gexec

-- Kept outside a DO block on purpose: psql does not interpolate :variables
-- inside dollar-quoted strings.
ALTER ROLE flashcards_user WITH LOGIN PASSWORD :'flashcards_password';

-- No superuser, no CREATEDB, no CREATEROLE, no replication.
ALTER ROLE flashcards_user
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

-- --------------------------------------------------------------------------
-- Database
-- --------------------------------------------------------------------------
SELECT 'CREATE DATABASE flashcards OWNER flashcards_user '
       'ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'flashcards')
\gexec

-- Nobody but the owner connects to it.
REVOKE ALL ON DATABASE flashcards FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE flashcards TO flashcards_user;

-- --------------------------------------------------------------------------
-- Schema ownership inside the new database
-- --------------------------------------------------------------------------
\connect flashcards

ALTER SCHEMA public OWNER TO flashcards_user;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO flashcards_user;

SELECT current_database() AS database,
       (SELECT rolname FROM pg_roles WHERE rolname = 'flashcards_user') AS role_present;
