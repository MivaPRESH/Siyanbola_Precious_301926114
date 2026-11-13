-- =====================================================================
-- MIT 8103 - Portfolio 1 : constraint tests. Every T-test must be REJECTED; the control must be ACCEPTED.
-- Run: psql -h localhost -d voltgrid -f 03_constraint_tests.sql > evidence/constraint_tests_output.txt 2>&1
-- =====================================================================
SET search_path TO voltgrid, public;
\set VERBOSITY default
SELECT meter_no AS prepaid   FROM meter WHERE meter_type = 'PREPAID'  AND status = 'ACTIVE'    ORDER BY meter_no LIMIT 1 \gset
SELECT meter_no AS suspended FROM meter WHERE meter_type = 'PREPAID'  AND status = 'SUSPENDED' ORDER BY meter_no LIMIT 1 \gset
SELECT meter_no AS postpaid  FROM meter WHERE meter_type = 'POSTPAID' AND status = 'ACTIVE'    ORDER BY meter_no LIMIT 1 \gset
SELECT payment_ref AS used_ref FROM vend ORDER BY vend_id LIMIT 1 \gset
SELECT bill_id, meter_no AS billed_meter, energy + vat AS bill_total FROM bill WHERE paid = 0 ORDER BY bill_id LIMIT 1 \gset
SELECT feeder_id AS of, started_at + interval '30 minutes' AS mid FROM outage WHERE restored_at IS NOT NULL ORDER BY outage_id LIMIT 1 \gset

\echo '--- T1  a second band A / R2 tariff overlapping the current one (exclusion constraint on daterange)'
INSERT INTO tariff (band, customer_class, rate_per_kwh, valid_during) VALUES ('A', 'R2', 240.00, daterange('2026-12-01', NULL));

\echo '--- T2  token for a SUSPENDED meter (trigger)'
INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES (:'suspended', 'TEST-T2', 'APP', 5000, 0, 1, 1);

\echo '--- T3  token for a POSTPAID meter (trigger)'
INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES (:'postpaid', 'TEST-T3', 'APP', 5000, 0, 1, 1);

\echo '--- T4  the bank sends the same payment notification twice (UNIQUE payment_ref = idempotent vending)'
INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES (:'prepaid', :'used_ref', 'BANK', 5000, 0, 1, 1);

\echo '--- T5  vend below the minimum of 500 naira (CHECK)'
INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES (:'prepaid', 'TEST-T5', 'USSD', 200, 0, 1, 1);

\echo '--- T6  a reading dated 2024 - no partition covers it (partitioned table without a DEFAULT partition)'
INSERT INTO meter_reading VALUES (:'postpaid', '2024-03-01 00:00+01', 100);

\echo '--- T7  a second bill for the same meter and month (UNIQUE meter_no, period)'
INSERT INTO bill (meter_no, period, kwh, tariff_id, energy, vat, due_date)
SELECT meter_no, period, kwh, tariff_id, energy, vat, due_date FROM bill WHERE bill_id = :bill_id;

\echo '--- T8  bill period that is not the first day of a month (CHECK)'
INSERT INTO bill (meter_no, period, kwh, tariff_id, energy, vat, due_date) VALUES (:'billed_meter', '2026-12-15', 10, 1, 1000, 75, '2027-01-29');

\echo '--- T9  overpayment: bill marked as paid more than energy + VAT (CHECK bill_no_overpayment)'
UPDATE bill SET paid = :bill_total + 1 WHERE bill_id = :bill_id;

\echo '--- T10 a second outage on the same feeder overlapping an existing one (exclusion constraint on tstzrange)'
INSERT INTO outage (feeder_id, started_at, restored_at, cause) VALUES (:of, :'mid', timestamptz :'mid' + interval '1 hour', 'FAULT');

\echo '--- T11 outage restored before it started (CHECK)'
INSERT INTO outage (feeder_id, started_at, restored_at, cause) VALUES (1, '2026-11-20 10:00+01', '2026-11-20 09:00+01', 'FAULT');

\echo '--- T12 delete a customer who still has meters (FOREIGN KEY, ON DELETE RESTRICT by default)'
DELETE FROM customer WHERE customer_id = 1;

\echo '--- T13 badly formed account number (CHECK ^VG[0-9]{10}$)'
INSERT INTO customer (account_no, full_name, customer_class, bu_id, address) VALUES ('VG-123', 'Test Person', 'R2', 1, '1 Test Street');

\echo '--- CONTROL valid vend of 10,000 naira: the database computes VAT, kWh, tariff and token (then rolled back)'
BEGIN;
INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES (:'prepaid', 'TEST-CONTROL', 'APP', 10000, 0, 1, 1)
RETURNING meter_no, amount, vat, tariff_id, kwh, length(token) AS token_digits;
SELECT vm.band, vm.customer_class, t.rate_per_kwh, t.valid_during FROM v_meter vm JOIN tariff t ON t.band = vm.band
 AND t.customer_class = vm.customer_class AND t.valid_during @> current_date WHERE vm.meter_no = :'prepaid';
ROLLBACK;
