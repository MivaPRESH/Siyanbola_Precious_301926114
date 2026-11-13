-- =====================================================================
-- MIT 8103 - Portfolio 1 : the generated data obeys the business rules (every count must be 0)
-- Run: psql -h localhost -d voltgrid -f 04_verify_seed_rules.sql
-- =====================================================================
SET search_path TO voltgrid, public;
\echo '=== Rule checks: violations (must all be 0) ==='
SELECT 'vends on a meter that is not prepaid' AS rule, count(*) AS violations
FROM vend v JOIN meter m USING (meter_no) WHERE m.meter_type <> 'PREPAID'
UNION ALL
SELECT 'vend tariff is not the band/class tariff valid that day', count(*)
FROM vend v JOIN v_meter vm USING (meter_no) JOIN tariff t ON t.tariff_id = v.tariff_id
WHERE t.band <> vm.band OR t.customer_class <> vm.customer_class OR NOT t.valid_during @> (v.vended_at AT TIME ZONE 'Africa/Lagos')::date
UNION ALL
SELECT 'vend kWh <> (amount - VAT) / rate', count(*)
FROM vend v JOIN tariff t USING (tariff_id) WHERE v.kwh <> round((v.amount - v.vat) / t.rate_per_kwh, 2)
UNION ALL
SELECT 'meter on a transformer outside the customer''s business unit', count(*)
FROM meter m JOIN customer c USING (customer_id) JOIN transformer dt USING (dt_id) JOIN feeder f USING (feeder_id) WHERE f.bu_id <> c.bu_id
UNION ALL
SELECT 'cumulative register reading lower than the previous one', count(*)
FROM (SELECT kwh_total < lag(kwh_total) OVER (PARTITION BY meter_no ORDER BY read_at) AS back FROM meter_reading) x WHERE back
UNION ALL
SELECT 'bill.paid different from the sum of its payments', count(*)
FROM bill b LEFT JOIN (SELECT bill_id, sum(amount) s FROM payment GROUP BY bill_id) p USING (bill_id) WHERE b.paid <> coalesce(p.s, 0)
UNION ALL
SELECT 'two outages of one feeder overlapping', count(*)
FROM outage a JOIN outage b ON a.feeder_id = b.feeder_id AND a.outage_id < b.outage_id
 AND tstzrange(a.started_at, a.restored_at) && tstzrange(b.started_at, b.restored_at);

\echo '=== Shape of the data ==='
SELECT meter_type, status, count(*) FROM meter GROUP BY 1, 2 ORDER BY 1, 2;
SELECT channel, count(*) AS vends, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct, round(avg(amount)) AS avg_naira
FROM vend GROUP BY 1 ORDER BY 2 DESC;
SELECT vm.band, round(sum(v.kwh) / sum(v.amount) * 1000, 1) AS kwh_per_1000_naira, count(*) AS vends
FROM vend v JOIN v_meter vm USING (meter_no) GROUP BY 1 ORDER BY 1;
SELECT f.band, round(avg(extract(epoch FROM o.restored_at - o.started_at) / 3600)::numeric, 1) AS avg_outage_hours, count(*) AS outages
FROM outage o JOIN feeder f USING (feeder_id) WHERE o.restored_at IS NOT NULL GROUP BY 1 ORDER BY 1;
SELECT tableoid::regclass AS partition, count(*) AS readings FROM meter_reading GROUP BY 1 ORDER BY 1;
