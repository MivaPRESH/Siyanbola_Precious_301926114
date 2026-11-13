-- =====================================================================
-- MIT 8103 - Portfolio 2 : optimisation round 2 (decided after reading the round-1 plans)
-- =====================================================================
SET search_path TO voltgrid, public;

-- The database runs on SSD storage: a random page read costs about the same as a sequential one.
-- The default random_page_cost = 4 makes index plans look too expensive.
ALTER DATABASE voltgrid SET random_page_cost = 1.1;
ALTER DATABASE voltgrid SET effective_cache_size = '2GB';

-- Q4: round 1 did NOT help - the plan still aggregated all ~820,000 sales (max(vended_at) per meter)
-- before filtering. Round 2 REWRITES it as an anti-join: for each active prepaid meter, probe the
-- ix_vend_meter_time index for one sale in the last 90 days (NOT EXISTS), and only for the meters that
-- have none, read the latest sale (LATERAL max = first index entry).
-- The run_benchmark.py harness runs VACUUM ANALYZE vend after this file, so that the probes become
-- index-ONLY scans (VACUUM cannot run inside the transaction block this file is executed in).
ANALYZE;
