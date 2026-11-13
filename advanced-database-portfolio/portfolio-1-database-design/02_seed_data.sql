-- =====================================================================
-- MIT 8103 - Portfolio 1 : VoltGrid Power synthetic data (reproducible: setseed)
-- 8 business units in Lagos, Ogun and Oyo; 120 feeders; 1,200 transformers;
-- 40,000 customers; 42,000 meters; ~0.8 million token vends;
-- ~2.6 million daily readings from postpaid meters; 12 months of bills; ~40,000 outages.
-- Period: 1 Nov 2025 - 12 Nov 2026 (reference "now" = 12 Nov 2026, 23:59 Lagos time).
-- Run after 01_schema.sql:  psql -h localhost -d voltgrid -f 02_seed_data.sql   (about 2 minutes)
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path TO voltgrid, public;
SELECT setseed(0.2026);
\timing on

INSERT INTO business_unit (bu_code, bu_name, state) VALUES
 ('IKJ', 'Ikeja', 'Lagos'), ('IKD', 'Ikorodu', 'Lagos'), ('OTA', 'Ota', 'Ogun'), ('ABK', 'Abeokuta', 'Ogun'),
 ('IBN', 'Ibadan North', 'Oyo'), ('IBS', 'Ibadan South', 'Oyo'), ('OGB', 'Ogbomoso', 'Oyo'), ('OYO', 'Oyo Town', 'Oyo');

-- 15 feeders per business unit: 3 band A, 4 B, 5 C, 2 D, 1 E;  feeder_id = (bu_id - 1) * 15 + f
INSERT INTO feeder (bu_id, feeder_code, voltage_kv, band)
SELECT b.bu_id, b.bu_code || '-F' || lpad(f::text, 2, '0'), CASE WHEN f <= 2 THEN 33 ELSE 11 END,
       (ARRAY['A','A','A','B','B','B','B','C','C','C','C','C','D','D','E'])[f]
FROM business_unit b CROSS JOIN generate_series(1, 15) f ORDER BY b.bu_id, f;

-- 10 distribution transformers per feeder;  dt_id = (feeder_id - 1) * 10 + t
INSERT INTO transformer (feeder_id, dt_code, capacity_kva)
SELECT fd.feeder_id, fd.feeder_code || '-T' || lpad(t::text, 2, '0'), (ARRAY[100, 200, 300, 500])[1 + t % 4]
FROM feeder fd CROSS JOIN generate_series(1, 10) t ORDER BY fd.feeder_id, t;

-- Tariff review on 1 July 2026: band A up 7.4%, band B up 5%, bands C-E unchanged (new version anyway)
INSERT INTO tariff (band, customer_class, rate_per_kwh, valid_during)
SELECT bd.band, cl.cls, round(bd.rate * cl.factor * v.factor, 2), v.valid
FROM (VALUES ('A', 209.50, 1.074), ('B', 63.30, 1.05), ('C', 50.00, 1.0), ('D', 43.27, 1.0), ('E', 32.44, 1.0)) bd(band, rate, rise)
CROSS JOIN (VALUES ('R2', 1.00), ('C1', 1.05), ('C2', 1.10), ('D1', 1.15)) cl(cls, factor)
CROSS JOIN LATERAL (VALUES (1.0, daterange('2025-01-01', '2026-07-01')), (bd.rise, daterange('2026-07-01', NULL))) v(factor, valid)
ORDER BY bd.band, cl.cls, lower(v.valid);

-- ---------------------------------------------------------------- customers
INSERT INTO customer (account_no, full_name, phone, customer_class, bu_id, address, created_at)
WITH g AS (
  SELECT i, random() r_cls, random() r_bu, random() r_fn, random() r_sn, random() r_ph, random() r_pp,
         random() r_no, random() r_st, random() r_cr
  FROM generate_series(1, 40000) i)
SELECT 'VG' || (2011000000 + i * 13)::text,
       (ARRAY['Adebayo','Olumide','Folake','Bukola','Tunde','Kemi','Segun','Funmilayo','Yetunde','Damilola','Ayodele','Precious',
              'Ibrahim','Chinedu','Ngozi','Kehinde','Taiwo','Babatunde','Omolara','Adewale','Temitope','Oluwaseun','Gbenga','Ronke',
              'Musa','Aisha','Emeka','Blessing','Abiodun','Morenike'])[1 + floor(r_fn * 30)::int] || ' ' ||
       (ARRAY['Adeyemi','Ogunleye','Olaniyan','Adeleke','Afolabi','Ojo','Akinola','Oladipo','Bakare','Salami','Adegoke','Ogundipe',
              'Okafor','Lawal','Oyelaran','Ajayi','Babalola','Fashola','Odunsi','Alabi','Ayinde','Oyewole','Ishola','Onifade',
              'Sanni','Adekunle','Oyebanji','Olatunji','Amusan','Akande'])[1 + floor(r_sn * 30)::int],
       CASE WHEN r_ph < 0.92 THEN '+234' || (ARRAY['70','80','81','90','91'])[1 + floor(r_pp * 5)::int]
                                  || lpad(floor(r_ph * 1e8)::bigint::text, 8, '0') END,
       CASE WHEN r_cls < 0.82 THEN 'R2' WHEN r_cls < 0.92 THEN 'C1' WHEN r_cls < 0.97 THEN 'C2' ELSE 'D1' END,
       (ARRAY[1,1,1,2,2,3,3,4,4,5,5,6,6,7,8])[1 + floor(r_bu * 15)::int],
       (1 + floor(r_no * 120))::int || ', ' ||
       (ARRAY['Allen Avenue','Bodija Road','Ring Road','Oke-Ado Street','Lagos Road','Station Road','Market Street','Church Street',
              'Oba Adeyemi Road','Old Ife Road','Idi-Ape Street','Isale-Oko Road'])[1 + floor(r_st * 12)::int],
       timestamptz '2014-01-01 00:00+01' + r_cr * interval '4300 days'
FROM g ORDER BY i;
UPDATE customer c SET address = c.address || ', ' || b.bu_name FROM business_unit b WHERE b.bu_id = c.bu_id;

-- ---------------------------------------------------------------- meters (every 20th customer has a second meter)
-- D1 and C2 customers (maximum demand) are postpaid; 10% of R2/C1 meters are legacy postpaid meters.
INSERT INTO meter (meter_no, customer_id, dt_id, meter_type, installed_on)
WITH m AS (
  SELECT c.customer_id, c.customer_class, c.bu_id, c.created_at, k, random() r_f, random() r_t, random() r_type, random() r_inst
  FROM customer c CROSS JOIN generate_series(1, 2) k
  WHERE k = 1 OR c.customer_id % 20 = 0)
SELECT (45100000000 + (row_number() OVER (ORDER BY customer_id, k)) * 97)::text, customer_id,
       ((bu_id - 1) * 15 + floor(r_f * 15)::int) * 10 + 1 + floor(r_t * 10)::int,
       CASE WHEN customer_class IN ('C2', 'D1') OR r_type < 0.10 THEN 'POSTPAID' ELSE 'PREPAID' END,
       LEAST(created_at::date + floor(r_inst * 400)::int, DATE '2025-10-31')
FROM m ORDER BY customer_id, k;

-- ---------------------------------------------------------------- token vends (through the pricing trigger)
-- every prepaid meter buys 4-43 times in the year; amounts depend on the customer class
INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh, vended_at)
WITH pm AS (
  SELECT me.meter_no, c.customer_class, 4 + abs(hashtext(me.meter_no)) % 40 AS n_vends
  FROM meter me JOIN customer c USING (customer_id) WHERE me.meter_type = 'PREPAID'),
v AS (
  SELECT pm.meter_no, pm.customer_class, random() r_amt, random() r_ch,
         timestamptz '2025-11-01 00:00+01' + floor(random() * 377) * interval '1 day' + (6 + random() * 17.9) * interval '1 hour' AS at
  FROM pm CROSS JOIN LATERAL generate_series(1, pm.n_vends) s)
SELECT meter_no,
       'VGP-' || to_char(at AT TIME ZONE 'Africa/Lagos', 'YYMMDD') || '-' || substr(md5(random()::text || meter_no), 1, 16),
       (ARRAY['APP','APP','APP','APP','APP','APP','APP','BANK','BANK','BANK','BANK','POS','POS','POS','USSD','USSD','USSD','USSD','AGENT','AGENT'])
         [1 + floor(r_ch * 20)::int],
       (ARRAY[1000, 2000, 3000, 5000, 5000, 10000, 10000, 15000, 20000, 50000])[1 + floor(r_amt * 10)::int]
         * CASE customer_class WHEN 'R2' THEN 1 ELSE 3 END,
       0, 1, 1, at                                         -- vat, tariff_id and kwh are recomputed by trg_vend_price
FROM v ORDER BY at;

-- meters suspended (e.g. tampering found) or removed AFTER their purchases
UPDATE meter SET status = 'SUSPENDED' WHERE abs(hashtext(meter_no || 's')) % 40 = 0;
UPDATE meter SET status = 'REMOVED'   WHERE status = 'ACTIVE' AND abs(hashtext(meter_no || 'r')) % 200 = 0;

-- ---------------------------------------------------------------- daily readings of postpaid meters (cumulative kWh)
-- total(day) = base + day * rate + noise, with noise < rate/2, so the register never goes backwards;
-- about 1% of daily readings are missing (communication failure)
INSERT INTO meter_reading (meter_no, read_at, kwh_total)
WITH pm AS (
  SELECT me.meter_no, 1000 + abs(hashtext(me.meter_no)) % 50000 AS base,
         (CASE c.customer_class WHEN 'R2' THEN 9 WHEN 'C1' THEN 35 WHEN 'C2' THEN 140 ELSE 420 END)
           * (0.6 + (abs(hashtext(me.meter_no || 'k')) % 80) / 100.0) AS rate
  FROM meter me JOIN customer c USING (customer_id) WHERE me.meter_type = 'POSTPAID')
SELECT meter_no, (d::date)::timestamp AT TIME ZONE 'Africa/Lagos',
       round(base + (d::date - DATE '2025-11-01') * rate + rate * 0.5 * random()::numeric, 1)
FROM pm CROSS JOIN generate_series(DATE '2025-11-01', DATE '2026-11-12', interval '1 day') d
WHERE random() > 0.01;

-- ---------------------------------------------------------------- monthly bills Nov 2025 - Oct 2026
INSERT INTO bill (meter_no, period, kwh, tariff_id, energy, vat, paid, due_date)
WITH use AS (
  SELECT r.meter_no, p.period, max(r.kwh_total) - min(r.kwh_total) AS kwh
  FROM generate_series(DATE '2025-11-01', DATE '2026-10-01', interval '1 month') p0
  CROSS JOIN LATERAL (SELECT p0::date AS period) p
  JOIN meter_reading r ON r.read_at >= p.period::timestamp AT TIME ZONE 'Africa/Lagos'
                      AND r.read_at <= (p.period + interval '1 month')::timestamp AT TIME ZONE 'Africa/Lagos'
  GROUP BY r.meter_no, p.period),
priced AS (
  SELECT u.meter_no, u.period, u.kwh, t.tariff_id, round(u.kwh * t.rate_per_kwh, 2) AS energy, random() AS r_pay, random() AS r_part
  FROM use u JOIN v_meter vm USING (meter_no)
  JOIN tariff t ON t.band = vm.band AND t.customer_class = vm.customer_class AND t.valid_during @> u.period)
SELECT meter_no, period, kwh, tariff_id, energy, round(energy * 0.075, 2),
       CASE WHEN period < DATE '2026-10-01' THEN
              CASE WHEN r_pay < 0.85 THEN energy + round(energy * 0.075, 2)
                   WHEN r_pay < 0.95 THEN round((energy + round(energy * 0.075, 2)) * (0.4 + r_part::numeric * 0.5), 2) ELSE 0 END
            ELSE CASE WHEN r_pay < 0.30 THEN energy + round(energy * 0.075, 2) ELSE 0 END END,
       (period + interval '1 month 14 days')::date
FROM priced ORDER BY period, meter_no;

INSERT INTO payment (bill_id, payment_ref, amount, paid_at)
SELECT bill_id, 'BLP-' || lpad(bill_id::text, 9, '0'), paid,
       ((period + interval '1 month')::timestamp AT TIME ZONE 'Africa/Lagos') + random() * interval '24 days'
FROM bill WHERE paid > 0 ORDER BY bill_id;

-- ---------------------------------------------------------------- outages, 1 Nov 2025 - 11 Nov 2026
-- at most one outage per feeder per day, kept inside that day (so the exclusion constraint is met);
-- daily outage length depends on the band (A short, E long)
INSERT INTO outage (feeder_id, started_at, restored_at, cause)
WITH o AS (
  SELECT fd.feeder_id, d::date AS day,
         LEAST(23.5, (CASE fd.band WHEN 'A' THEN 2.5 WHEN 'B' THEN 6 WHEN 'C' THEN 10 WHEN 'D' THEN 14 ELSE 18 END) * (0.5 + random())) AS hrs,
         random() AS r_start, random() AS r_cause, random() AS r_day, fd.band
  FROM feeder fd CROSS JOIN generate_series(DATE '2025-11-01', DATE '2026-11-11', interval '1 day') d)
SELECT feeder_id, s, s + hrs * interval '1 hour',
       CASE WHEN r_cause < 0.60 THEN 'LOAD_SHEDDING' WHEN r_cause < 0.85 THEN 'FAULT' WHEN r_cause < 0.97 THEN 'MAINTENANCE' ELSE 'GRID_COLLAPSE' END
FROM o CROSS JOIN LATERAL (SELECT day::timestamp AT TIME ZONE 'Africa/Lagos' + r_start * (24 - hrs) * interval '1 hour' AS s) st
WHERE r_day < CASE band WHEN 'A' THEN 0.6 ELSE 0.95 END
ORDER BY s;
-- three feeders are out right now
INSERT INTO outage (feeder_id, started_at, restored_at, cause) VALUES
 (12, '2026-11-12 19:40+01', NULL, 'FAULT'), (47, '2026-11-12 21:05+01', NULL, 'LOAD_SHEDDING'), (101, '2026-11-12 22:30+01', NULL, 'FAULT');

\timing off
ANALYZE;
SELECT 'business_unit' AS tbl, count(*) FROM business_unit UNION ALL SELECT 'feeder', count(*) FROM feeder
UNION ALL SELECT 'transformer', count(*) FROM transformer UNION ALL SELECT 'tariff', count(*) FROM tariff
UNION ALL SELECT 'customer', count(*) FROM customer UNION ALL SELECT 'meter', count(*) FROM meter
UNION ALL SELECT 'vend', count(*) FROM vend UNION ALL SELECT 'meter_reading', count(*) FROM meter_reading
UNION ALL SELECT 'bill', count(*) FROM bill UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'outage', count(*) FROM outage;
