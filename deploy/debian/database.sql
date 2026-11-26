-- psql, connected to the maintenance database as the cluster administrator.
SELECT 'CREATE ROLE "kr-debian" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kr-debian') \gexec

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'kr-debian' AND
               (NOT rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
        RAISE EXCEPTION 'Existing kr-debian role has incompatible privileges';
    END IF;
    IF EXISTS (SELECT FROM pg_database WHERE datname = 'kr_debian'
               AND datdba <> '"kr-debian"'::regrole) THEN
        RAISE EXCEPTION 'Existing kr_debian database belongs to a different role';
    END IF;
END $$;

SELECT 'CREATE DATABASE kr_debian OWNER "kr-debian"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kr_debian') \gexec
REVOKE ALL ON DATABASE kr_debian FROM PUBLIC;
ALTER ROLE "kr-debian" IN DATABASE kr_debian SET timezone = 'UTC';
