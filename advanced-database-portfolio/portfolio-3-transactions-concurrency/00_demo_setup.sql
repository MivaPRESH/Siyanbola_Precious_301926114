-- =====================================================================
-- MIT 8103 - Portfolio 3 : demo customers, meters and bill (re-runnable)
-- plus two small tables used by the transaction cases:
--   sms_outbox           token SMS queued in the SAME transaction as the sale (transactional outbox)
--   settlement_exception lines of a bank settlement file that could not be vended
-- Run: psql -h localhost -U postgres -d voltgrid -f 00_demo_setup.sql
-- =====================================================================
SET search_path TO voltgrid, public;
CREATE TABLE IF NOT EXISTS sms_outbox (
    sms_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone      VARCHAR(14) NOT NULL,
    message    TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at    TIMESTAMPTZ
);
CREATE TABLE IF NOT EXISTS settlement_exception (
    payment_ref VARCHAR(30) PRIMARY KEY,
    meter_no    CHAR(11)    NOT NULL,
    amount      NUMERIC(10,2) NOT NULL,
    reason      TEXT        NOT NULL,
    logged_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- remove earlier demo runs
DELETE FROM sms_outbox WHERE phone LIKE '+23490999%';
DELETE FROM settlement_exception WHERE payment_ref LIKE 'DEMO-%';
DELETE FROM payment WHERE bill_id IN (SELECT bill_id FROM bill WHERE meter_no LIKE '990000000%');
DELETE FROM bill WHERE meter_no LIKE '990000000%';
DELETE FROM vend WHERE meter_no LIKE '990000000%';
DELETE FROM meter WHERE meter_no LIKE '990000000%';
DELETE FROM customer WHERE account_no LIKE 'VG99999999%';

-- feeder 16 = IKD-F01 (band A), transformer 151 is on it
INSERT INTO customer (account_no, full_name, phone, customer_class, bu_id, address) VALUES
 ('VG9999999901', 'Folake Adeyemi (demo)', '+2349099900001', 'R2', 2, '12 Lagos Road, Ikorodu'),
 ('VG9999999902', 'Oyelaran Bakery Ltd (demo)', '+2349099900002', 'C2', 2, '4 Market Street, Ikorodu'),
 ('VG9999999903', 'Tunde Ishola (demo)', '+2349099900003', 'R2', 2, '7 Church Street, Ikorodu');
INSERT INTO meter (meter_no, customer_id, dt_id, meter_type, status, installed_on)
SELECT v.meter_no, c.customer_id, 151, v.mtype, v.status, DATE '2024-02-01'
FROM (VALUES ('99000000001', 'VG9999999901', 'PREPAID',  'ACTIVE'),
             ('99000000002', 'VG9999999902', 'POSTPAID', 'ACTIVE'),
             ('99000000003', 'VG9999999903', 'PREPAID',  'SUSPENDED')) v(meter_no, acct, mtype, status)
JOIN customer c ON c.account_no = v.acct;

-- the bakery's October bill: 2,400 kWh x band A C2 tariff, nothing paid yet
INSERT INTO bill (meter_no, period, kwh, tariff_id, energy, vat, due_date)
SELECT '99000000002', DATE '2026-10-01', 2400, t.tariff_id, round(2400 * t.rate_per_kwh, 2), round(round(2400 * t.rate_per_kwh, 2) * 0.075, 2), DATE '2026-11-15'
FROM tariff t WHERE t.band = 'A' AND t.customer_class = 'C2' AND t.valid_during @> DATE '2026-10-01';

SELECT vm.meter_no, vm.meter_type, vm.status, vm.full_name, vm.band, vm.customer_class FROM v_meter vm WHERE meter_no LIKE '990000000%' ORDER BY 1;
SELECT meter_no, period, kwh, energy, vat, energy + vat AS total, paid FROM bill WHERE meter_no = '99000000002';
