-- =====================================================================
-- MIT 8103 - Portfolio 3 : transactions at VoltGrid Power - COMMIT, ROLLBACK, SAVEPOINT
-- Run: psql -h localhost -U postgres -d voltgrid -f 00_demo_setup.sql
--      psql -h localhost -U postgres -d voltgrid -e -f 01_commit_rollback_savepoint.sql
-- =====================================================================
SET search_path TO voltgrid, public;
\set ON_ERROR_STOP off

-- ---------------------------------------------------------------------
\echo '=== CASE 1: Folake buys 5,000 naira of units - the token sale and its SMS are ONE unit (transactional outbox) -> COMMIT ==='
BEGIN;
  INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh)
  VALUES ('99000000001', 'DEMO-APP-0001', 'APP', 5000, 0, 1, 1)
  RETURNING vend_id AS v1, token AS t1, kwh AS k1 \gset
  INSERT INTO sms_outbox (phone, message)
  VALUES ('+2349099900001', format('VoltGrid: token %s for meter 99000000001, %s kWh. Thank you.', :'t1', :'k1'));
COMMIT;
SELECT v.payment_ref, v.amount, v.vat, v.kwh, t.rate_per_kwh, (SELECT count(*) FROM sms_outbox o WHERE o.message LIKE '%' || v.token || '%') AS sms_queued
FROM vend v JOIN tariff t USING (tariff_id) WHERE v.vend_id = :v1;

-- ---------------------------------------------------------------------
\echo '=== CASE 2: the card payment is reversed by the bank before confirmation -> ROLLBACK (no token, no SMS) ==='
BEGIN;
  INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh)
  VALUES ('99000000001', 'DEMO-APP-0002', 'APP', 20000, 0, 1, 1) RETURNING token AS t2 \gset
  INSERT INTO sms_outbox (phone, message) VALUES ('+2349099900001', 'VoltGrid: token ' || :'t2');
  SELECT count(*) AS sales_seen_inside_tx FROM vend WHERE meter_no = '99000000001';
ROLLBACK;
SELECT count(*) AS sales_after_rollback, (SELECT count(*) FROM sms_outbox WHERE phone = '+2349099900001') AS sms_after_rollback
FROM vend WHERE meter_no = '99000000001';

-- ---------------------------------------------------------------------
\echo '=== CASE 3: the bakery pays 300,000 naira of its 638,550 bill - payment row + bill balance in one transaction -> COMMIT ==='
SELECT bill_id AS bakery_bill FROM bill WHERE meter_no = '99000000002' AND period = '2026-10-01' \gset
BEGIN;
  INSERT INTO payment (bill_id, payment_ref, amount) VALUES (:bakery_bill, 'DEMO-BLP-0001', 300000);
  UPDATE bill SET paid = paid + 300000 WHERE bill_id = :bakery_bill;
COMMIT;
SELECT energy + vat AS total, paid, energy + vat - paid AS outstanding,
       (SELECT sum(amount) FROM payment WHERE bill_id = :bakery_bill) AS sum_of_payments FROM bill WHERE bill_id = :bakery_bill;

\echo '=== CASE 4: a second transfer of 400,000 would OVERPAY the bill: CHECK fails, the payment row is undone too ==='
BEGIN;
  INSERT INTO payment (bill_id, payment_ref, amount) VALUES (:bakery_bill, 'DEMO-BLP-0002', 400000);
  UPDATE bill SET paid = paid + 400000 WHERE bill_id = :bakery_bill;
  SELECT 'this statement is not executed: the transaction is aborted' AS note;
COMMIT;
SELECT paid, (SELECT count(*) FROM payment WHERE bill_id = :bakery_bill) AS payments_recorded FROM bill WHERE bill_id = :bakery_bill;

-- ---------------------------------------------------------------------
\echo '=== CASE 5: a bank settlement file with 3 payments; line 2 is for a SUSPENDED meter -> SAVEPOINT per line ==='
BEGIN;
  SAVEPOINT line1;
  INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES ('99000000001', 'DEMO-BNK-0001', 'BANK', 3000, 0, 1, 1);
  RELEASE SAVEPOINT line1;
  SAVEPOINT line2;
  INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES ('99000000003', 'DEMO-BNK-0002', 'BANK', 10000, 0, 1, 1);
  ROLLBACK TO SAVEPOINT line2;          -- undo only line 2, keep line 1; record it for a refund
  INSERT INTO settlement_exception (payment_ref, meter_no, amount, reason)
  VALUES ('DEMO-BNK-0002', '99000000003', 10000, 'meter SUSPENDED - refund customer');
  SAVEPOINT line3;
  INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES ('99000000001', 'DEMO-BNK-0003', 'BANK', 2000, 0, 1, 1);
  RELEASE SAVEPOINT line3;
COMMIT;
SELECT payment_ref, meter_no, amount, kwh FROM vend WHERE payment_ref LIKE 'DEMO-BNK-%' ORDER BY 1;
SELECT payment_ref, meter_no, amount, reason FROM settlement_exception WHERE payment_ref LIKE 'DEMO-%';

-- ---------------------------------------------------------------------
\echo '=== CASE 6: tariff review - close the current band A / R2 version and open a new one from 1 Jan 2027 ==='
\echo '--- 6a wrong order: insert the new version first -> it overlaps the open-ended current one -> whole change rolled back'
BEGIN;
  INSERT INTO tariff (band, customer_class, rate_per_kwh, valid_during) VALUES ('A', 'R2', 240.00, daterange('2027-01-01', NULL));
  UPDATE tariff SET valid_during = daterange(lower(valid_during), '2027-01-01') WHERE band = 'A' AND customer_class = 'R2' AND upper_inf(valid_during);
ROLLBACK;
\echo '--- 6b right order inside one transaction: close the old version, then insert the new one'
BEGIN;
  UPDATE tariff SET valid_during = daterange(lower(valid_during), '2027-01-01') WHERE band = 'A' AND customer_class = 'R2' AND upper_inf(valid_during);
  INSERT INTO tariff (band, customer_class, rate_per_kwh, valid_during) VALUES ('A', 'R2', 240.00, daterange('2027-01-01', NULL));
  SELECT band, customer_class, rate_per_kwh, valid_during FROM tariff WHERE band = 'A' AND customer_class = 'R2' ORDER BY lower(valid_during);
ROLLBACK;   -- demonstration only: the real tariff table is left unchanged
SELECT band, customer_class, rate_per_kwh, valid_during FROM tariff WHERE band = 'A' AND customer_class = 'R2' ORDER BY lower(valid_during);
