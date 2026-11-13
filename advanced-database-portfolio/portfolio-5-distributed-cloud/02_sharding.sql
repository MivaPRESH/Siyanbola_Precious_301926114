-- =====================================================================
-- MIT 8103 - Portfolio 5 : VoltGrid meter readings HASH-sharded by meter number
-- Coordinator (5432, postgres_fdw) + shard_a (5434) + shard_b (5435).
-- A meter's whole history lives on ONE shard; meters are spread evenly whatever their area.
-- bu_code and band are copied into the shard rows so that reports per business unit can be
-- aggregated ON the shards (a foreign table cannot be joined to local tables on the shard side).
-- Run on the coordinator: psql -h localhost -p 5432 -d voltgrid -f 02_sharding.sql
-- =====================================================================
\set ON_ERROR_STOP on

\connect voltgrid_shard postgres localhost 5434
DROP TABLE IF EXISTS reading_shard;
CREATE TABLE reading_shard (
    meter_no  CHAR(11)      NOT NULL,
    read_at   TIMESTAMPTZ   NOT NULL,
    kwh_total NUMERIC(11,1) NOT NULL CHECK (kwh_total >= 0),
    bu_code   CHAR(3)       NOT NULL,
    band      CHAR(1)       NOT NULL,
    PRIMARY KEY (meter_no, read_at)
);
\connect voltgrid_shard postgres localhost 5435
DROP TABLE IF EXISTS reading_shard;
CREATE TABLE reading_shard (
    meter_no  CHAR(11)      NOT NULL,
    read_at   TIMESTAMPTZ   NOT NULL,
    kwh_total NUMERIC(11,1) NOT NULL CHECK (kwh_total >= 0),
    bu_code   CHAR(3)       NOT NULL,
    band      CHAR(1)       NOT NULL,
    PRIMARY KEY (meter_no, read_at)
);

\connect voltgrid postgres localhost 5432
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SCHEMA IF EXISTS voltgrid_dist CASCADE;
DROP SERVER IF EXISTS srv_shard_a CASCADE;
DROP SERVER IF EXISTS srv_shard_b CASCADE;
CREATE SCHEMA voltgrid_dist;
CREATE SERVER srv_shard_a FOREIGN DATA WRAPPER postgres_fdw
       OPTIONS (host 'localhost', port '5434', dbname 'voltgrid_shard', async_capable 'true', fetch_size '10000', batch_size '2000');
CREATE SERVER srv_shard_b FOREIGN DATA WRAPPER postgres_fdw
       OPTIONS (host 'localhost', port '5435', dbname 'voltgrid_shard', async_capable 'true', fetch_size '10000', batch_size '2000');
CREATE USER MAPPING FOR postgres SERVER srv_shard_a OPTIONS (user 'postgres');
CREATE USER MAPPING FOR postgres SERVER srv_shard_b OPTIONS (user 'postgres');

CREATE TABLE voltgrid_dist.readings (
    meter_no CHAR(11) NOT NULL, read_at TIMESTAMPTZ NOT NULL, kwh_total NUMERIC(11,1) NOT NULL,
    bu_code CHAR(3) NOT NULL, band CHAR(1) NOT NULL
) PARTITION BY HASH (meter_no);
CREATE FOREIGN TABLE voltgrid_dist.readings_a PARTITION OF voltgrid_dist.readings
       FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER srv_shard_a OPTIONS (schema_name 'public', table_name 'reading_shard');
CREATE FOREIGN TABLE voltgrid_dist.readings_b PARTITION OF voltgrid_dist.readings
       FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER srv_shard_b OPTIONS (schema_name 'public', table_name 'reading_shard');

\timing on
INSERT INTO voltgrid_dist.readings
SELECT r.meter_no, r.read_at, r.kwh_total, vm.bu_code, vm.band
FROM voltgrid.meter_reading r JOIN voltgrid.v_meter vm USING (meter_no);
\timing off
ANALYZE voltgrid_dist.readings_a; ANALYZE voltgrid_dist.readings_b;
SELECT tableoid::regclass AS shard, count(*) AS readings, count(DISTINCT meter_no) AS meters FROM voltgrid_dist.readings GROUP BY 1 ORDER BY 1;
