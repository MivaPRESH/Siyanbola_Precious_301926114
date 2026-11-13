-- =====================================================================
-- MIT 8103 - Portfolio 2 : optimisation round 1
-- =====================================================================
SET search_path TO voltgrid, public;

-- Q1, Q4: every lookup of a meter's purchases. The vend table only had indexes on vend_id,
-- payment_ref and token, so "purchases of meter X" read all ~820,000 rows.
CREATE INDEX IF NOT EXISTS ix_vend_meter_time ON vend (meter_no, vended_at DESC);

-- Q2: no index - the query is REWRITTEN (see run_benchmark.py) so that the planner can prune partitions:
--   date_trunc('month', read_at AT TIME ZONE ...) = '2026-10-01'   hides read_at inside a function -> all 13 partitions
--   read_at >= '2026-10-01 00:00+01' AND read_at < '2026-11-01 00:00+01'   -> only meter_reading_2026_10

-- Q3: dashboard reads summaries, not 820,000 sales. Refreshed after each day's sales are settled.
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_vend_revenue;
CREATE MATERIALIZED VIEW mv_monthly_vend_revenue AS
SELECT b.bu_code, v.channel, date_trunc('month', v.vended_at AT TIME ZONE 'Africa/Lagos')::date AS month,
       count(*) AS vends, sum(v.amount) AS revenue, sum(v.kwh) AS kwh
FROM vend v JOIN meter m USING (meter_no) JOIN customer c USING (customer_id) JOIN business_unit b USING (bu_id)
GROUP BY 1, 2, 3;
CREATE UNIQUE INDEX ux_mv_monthly_vend_revenue ON mv_monthly_vend_revenue (bu_code, channel, month);  -- allows REFRESH ... CONCURRENTLY

-- Q5: no new index. The exclusion constraint outage_no_overlap ALREADY built a GiST index on
-- (feeder_id, tstzrange(started_at, restored_at)). The query is rewritten to use that exact expression
-- with the overlap operator &&, so the planner can use the constraint's index.
ANALYZE;
