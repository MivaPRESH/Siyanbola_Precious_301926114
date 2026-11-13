-- =====================================================================
-- MIT 8103 - Portfolio 4 (part B): querying field work-order documents
-- Run: psql -h localhost -d voltgrid -f document_queries.sql
-- =====================================================================
SET search_path TO voltgrid_doc, public;
\timing on

\echo '=== D1  revenue protection: confirmed bypasses with photo evidence (>= 3 photos), per business unit ==='
SELECT doc->>'bu' AS bu, count(*) AS bypass_cases, sum((doc->>'estimated_unbilled_kwh')::int) AS unbilled_kwh
FROM   work_order
WHERE  doc @> '{"type":"TAMPER_INSPECTION","status":"COMPLETED","findings":{"bypass":true}}'
AND    jsonb_path_exists(doc, '$ ? (@.photos.size() >= 3)')
GROUP  BY 1 ORDER BY 2 DESC;

\echo '=== D2  stores report: materials issued per business unit (array of sub-documents, installations + replacements) ==='
SELECT doc->>'bu' AS bu,
       sum((m->>'qty')::int) FILTER (WHERE m->>'item' = '16mm cable (m)') AS cable_m,
       sum((m->>'qty')::int) FILTER (WHERE m->>'item' = 'Meter seal')     AS seals,
       sum((m->>'qty')::int) FILTER (WHERE m->>'item' = 'Cut-out fuse')   AS fuses,
       sum((m->>'qty')::int) FILTER (WHERE m->>'item' = 'Pole clamp')     AS pole_clamps
FROM   work_order, jsonb_array_elements(doc->'materials') m
GROUP  BY 1 ORDER BY 1;

\echo '=== D3  which checklist items fail most often (path query into an array) ==='
SELECT item #>> '{}' AS failed_item, count(*)
FROM   work_order, jsonb_path_query(doc, '$.checklist[*] ? (@.ok == false).item') item
GROUP  BY 1 ORDER BY 2 DESC;

\echo '=== D4  a whole job card is one read ==='
SELECT jsonb_pretty(doc) FROM work_order WHERE doc @> '{"type":"METER_REPLACEMENT"}' ORDER BY wo_id LIMIT 1;

\echo '=== Containment query before and after a GIN (jsonb_path_ops) index ==='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT wo_id, doc->>'meter_no' FROM work_order WHERE doc @> '{"type":"DISCONNECTION","bu":"IBN","cut_at":"pole"}';
CREATE INDEX IF NOT EXISTS ix_work_order_doc ON work_order USING gin (doc jsonb_path_ops);
ANALYZE work_order;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT wo_id, doc->>'meter_no' FROM work_order WHERE doc @> '{"type":"DISCONNECTION","bu":"IBN","cut_at":"pole"}';
SELECT pg_size_pretty(pg_relation_size('ix_work_order_doc')) AS gin_index, pg_size_pretty(pg_total_relation_size('work_order')) AS collection;

\echo '=== Updating part of a document: technician completes an ASSIGNED job (status + appended history entry) ==='
SELECT wo_id AS open_wo FROM work_order WHERE doc->>'status' = 'ASSIGNED' ORDER BY wo_id LIMIT 1 \gset
UPDATE work_order
SET    doc = jsonb_set(doc, '{status}', '"COMPLETED"')
             || jsonb_build_object('history', coalesce(doc->'history', '[]') || jsonb_build_object('at', '2026-11-12T16:20:00+01:00', 'event', 'completed on site'))
WHERE  wo_id = :'open_wo' AND doc->>'status' = 'ASSIGNED'
RETURNING wo_id, doc->>'type' AS type, doc->>'status' AS status, doc->'history' AS history;

\echo '=== Schema flexibility: a NEW job type (solar net-meter survey) with its own fields - no ALTER TABLE ==='
INSERT INTO work_order VALUES ('WO-DEMO-SOLAR', '{"_id":"WO-DEMO-SOLAR","type":"NET_METER_SURVEY","meter_no":"45100000291","bu":"IKJ",
  "status":"COMPLETED","roof":{"area_m2":64,"orientation":"south","shading":"low"},
  "proposed":{"panels_kwp":5.4,"inverter_kva":5,"battery_kwh":10},"export_allowed":false}')
ON CONFLICT (wo_id) DO NOTHING;
SELECT doc->>'type' AS type, doc#>>'{proposed,panels_kwp}' AS kwp, doc#>>'{roof,orientation}' AS roof FROM work_order WHERE wo_id = 'WO-DEMO-SOLAR';

\echo '=== Validation still applies: a COMPLETED tamper inspection without findings is rejected ==='
INSERT INTO work_order VALUES ('WO-BAD-1', '{"type":"TAMPER_INSPECTION","meter_no":"45100000291","status":"COMPLETED"}');
\echo '=== ... and so is an unknown job type ==='
INSERT INTO work_order VALUES ('WO-BAD-2', '{"type":"PAINT_POLE","meter_no":"45100000291"}');
