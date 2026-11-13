-- =====================================================================
-- MIT 8103 - Portfolio 2 : VoltGrid Power workload queries
-- Blocks separated by "-- @Qn" markers (read by run_benchmark.py).
-- Reference "now" of the data set = 2026-11-12 23:59 (Africa/Lagos).
-- =====================================================================

-- @Q1 Customer app: "my last 10 token purchases" for a meter (opened on every app launch)
SELECT v.vended_at, v.channel, v.amount, v.kwh, v.token
FROM   vend v
WHERE  v.meter_no = '45100000291'
ORDER  BY v.vended_at DESC
LIMIT  10;

-- @Q2 Energy accounting: October consumption of postpaid meters per business unit and band
WITH m AS (
  SELECT meter_no, max(kwh_total) - min(kwh_total) AS kwh
  FROM   meter_reading
  WHERE  date_trunc('month', read_at AT TIME ZONE 'Africa/Lagos') = timestamp '2026-10-01'
  GROUP  BY meter_no)
SELECT vm.bu_code, vm.band, count(*) AS meters, round(sum(m.kwh)) AS kwh
FROM   m JOIN v_meter vm USING (meter_no)
GROUP  BY vm.bu_code, vm.band
ORDER  BY vm.bu_code, vm.band;

-- @Q3 Management dashboard: monthly token revenue per business unit and sales channel, 2026
SELECT b.bu_code, v.channel, date_trunc('month', v.vended_at AT TIME ZONE 'Africa/Lagos')::date AS month,
       count(*) AS vends, sum(v.amount) AS revenue, sum(v.kwh) AS kwh
FROM   vend v
JOIN   meter m         USING (meter_no)
JOIN   customer c      USING (customer_id)
JOIN   business_unit b USING (bu_id)
WHERE  v.vended_at >= timestamptz '2026-01-01 00:00+01'
GROUP  BY b.bu_code, v.channel, date_trunc('month', v.vended_at AT TIME ZONE 'Africa/Lagos')
ORDER  BY b.bu_code, v.channel, month;

-- @Q4 Revenue protection: active prepaid meters with NO token bought in the last 90 days (possible bypass)
SELECT vm.bu_code, vm.feeder_code, vm.meter_no, vm.full_name, lv.last_vend
FROM   v_meter vm
LEFT   JOIN (SELECT meter_no, max(vended_at) AS last_vend FROM vend GROUP BY meter_no) lv USING (meter_no)
WHERE  vm.meter_type = 'PREPAID' AND vm.status = 'ACTIVE'
AND    (lv.last_vend IS NULL OR lv.last_vend < timestamptz '2026-11-12 23:59+01' - interval '90 days')
ORDER  BY lv.last_vend NULLS FIRST, vm.meter_no
LIMIT  50;

-- @Q5 Regulator report: average daily hours of supply of band A feeders, last 30 days (promise: >= 20 h)
SELECT f.feeder_code, b.bu_code,
       round(24 - coalesce(sum(extract(epoch FROM
             LEAST(coalesce(o.restored_at, timestamptz '2026-11-12 00:00+01'), timestamptz '2026-11-12 00:00+01')
           - GREATEST(o.started_at, timestamptz '2026-10-13 00:00+01'))), 0) / 3600 / 30, 2) AS avg_supply_hours
FROM   feeder f
JOIN   business_unit b ON b.bu_id = f.bu_id
LEFT   JOIN outage o ON o.feeder_id = f.feeder_id
                    AND o.started_at < timestamptz '2026-11-12 00:00+01'
                    AND (o.restored_at > timestamptz '2026-10-13 00:00+01' OR o.restored_at IS NULL)
WHERE  f.band = 'A'
GROUP  BY f.feeder_code, b.bu_code
ORDER  BY avg_supply_hours, f.feeder_code;
