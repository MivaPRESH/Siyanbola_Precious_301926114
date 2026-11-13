-- =====================================================================
-- MIT 8103 - Portfolio 4 (part B): FIELD WORK ORDERS as documents (PostgreSQL JSONB)
-- A technician's job card has a different shape for every job type:
--   INSTALLATION      materials list, commissioning reading, meter type
--   TAMPER_INSPECTION checklist, findings (bypass? seal intact? method), photos, estimated unbilled kWh
--   DISCONNECTION     bill reference, arrears, where it was cut, was the customer present
--   METER_REPLACEMENT old meter + last reading, new meter + first reading, reason, materials
-- One table per job type (or dozens of nullable columns) would be needed relationally.
-- A job card is written by the field app, completed once and read whole, which suits a document.
-- Run: psql -h localhost -d voltgrid -f document_model.sql
-- =====================================================================
DROP SCHEMA IF EXISTS voltgrid_doc CASCADE;
CREATE SCHEMA voltgrid_doc;
SET search_path TO voltgrid_doc, voltgrid, public;

CREATE TABLE work_order (
    wo_id TEXT  PRIMARY KEY,
    doc   JSONB NOT NULL,
    CONSTRAINT doc_type_known CHECK (doc->>'type' IN ('INSTALLATION', 'TAMPER_INSPECTION', 'DISCONNECTION', 'METER_REPLACEMENT', 'NET_METER_SURVEY')),
    CONSTRAINT doc_has_meter  CHECK (doc ? 'meter_no'),
    -- a COMPLETED tamper inspection must say what was found
    CONSTRAINT tamper_has_findings CHECK (doc->>'type' <> 'TAMPER_INSPECTION' OR doc->>'status' <> 'COMPLETED' OR doc ? 'findings')
);

WITH src AS (
  -- 1) tamper inspections: every suspended meter, plus a random 5% of active prepaid meters
  SELECT 'TAMPER_INSPECTION' AS typ, m.meter_no, m.status = 'SUSPENDED' AS hit, NULL::numeric AS amt, NULL::bigint AS bill_id,
         DATE '2026-01-05' + abs(hashtext(m.meter_no || 'ti')) % 300 AS d
  FROM meter m WHERE m.status = 'SUSPENDED' OR (m.meter_type = 'PREPAID' AND abs(hashtext(m.meter_no || 'sample')) % 20 = 0)
  UNION ALL
  -- 2) disconnections: postpaid bills left completely unpaid before October 2026
  SELECT 'DISCONNECTION', b.meter_no, false, b.energy + b.vat, b.bill_id, b.due_date + 7 + abs(hashtext(b.meter_no)) % 20
  FROM bill b WHERE b.paid = 0 AND b.period < DATE '2026-10-01'
  UNION ALL
  -- 3) replacements of removed meters
  SELECT 'METER_REPLACEMENT', m.meter_no, false, NULL, NULL, DATE '2026-02-01' + abs(hashtext(m.meter_no)) % 250
  FROM meter m WHERE m.status = 'REMOVED'
  UNION ALL
  -- 4) installations of meters installed from 2025
  SELECT 'INSTALLATION', m.meter_no, false, NULL, NULL, m.installed_on FROM meter m WHERE m.installed_on >= DATE '2025-01-01'
),
w AS (
  SELECT row_number() OVER (ORDER BY s.d, s.meter_no, s.typ) AS n, s.*, abs(hashtext(s.meter_no || s.typ || s.d)) AS h, vm.bu_code, vm.feeder_code, vm.meter_type
  FROM src s JOIN v_meter vm USING (meter_no)
)
INSERT INTO work_order (wo_id, doc)
SELECT 'WO-' || lpad(n::text, 6, '0'),
  jsonb_build_object(
    '_id', 'WO-' || lpad(n::text, 6, '0'), 'type', typ, 'meter_no', meter_no, 'bu', bu_code, 'feeder', feeder_code,
    'status', CASE WHEN d > DATE '2026-11-05' AND h % 3 = 0 THEN 'ASSIGNED' ELSE 'COMPLETED' END,
    'scheduled_for', to_char(d, 'YYYY-MM-DD'),
    'technician', jsonb_build_object('name', (ARRAY['Engr. S. Ogunleye','Mr K. Bakare','Mr A. Lawal','Ms T. Ajayi','Mr D. Alabi','Mr O. Sanni'])[1 + h % 6],
                                     'staff_no', 'VGT-' || lpad((100 + h % 60)::text, 4, '0')),
    'gps', jsonb_build_object('lat', round((g.lat + (h % 400) / 10000.0)::numeric, 4), 'lng', round((g.lng + (h / 400 % 400) / 10000.0)::numeric, 4)))
  || CASE typ
     WHEN 'TAMPER_INSPECTION' THEN jsonb_build_object(
        'checklist', jsonb_build_array(
            jsonb_build_object('item', 'Terminal seal', 'ok', NOT (hit AND h % 3 <> 0)),
            jsonb_build_object('item', 'Cover screws', 'ok', NOT hit OR h % 2 = 0),
            jsonb_build_object('item', 'Incoming cable', 'ok', NOT (hit AND h % 3 = 0)),
            jsonb_build_object('item', 'Display working', 'ok', h % 25 <> 0)),
        'findings', jsonb_build_object('bypass', hit AND h % 3 = 0, 'seal_intact', NOT (hit AND h % 3 <> 0),
                                       'method', CASE WHEN NOT hit THEN 'none' WHEN h % 3 = 0 THEN 'direct cable bypass' ELSE 'broken seal, magnet on meter' END),
        'photos', CASE WHEN hit THEN jsonb_build_array('s3://vg-field/' || meter_no || '/1.jpg', 's3://vg-field/' || meter_no || '/2.jpg')
                       || CASE WHEN h % 2 = 0 THEN jsonb_build_array('s3://vg-field/' || meter_no || '/3.jpg') ELSE '[]'::jsonb END
                       ELSE '[]'::jsonb END)
        || CASE WHEN hit THEN jsonb_build_object('estimated_unbilled_kwh', 150 + h % 900) ELSE '{}'::jsonb END
     WHEN 'DISCONNECTION' THEN jsonb_build_object('bill_id', bill_id, 'arrears', amt,
        'cut_at', (ARRAY['meter', 'pole', 'transformer feeder pillar'])[1 + h % 3], 'customer_present', h % 4 = 0)
     WHEN 'METER_REPLACEMENT' THEN jsonb_build_object(
        'old_meter', jsonb_build_object('no', meter_no, 'last_reading', 1000 + h % 40000),
        'new_meter', jsonb_build_object('no', '47' || lpad((h % 1000000000)::text, 9, '0'), 'initial_reading', 0),
        'reason', (ARRAY['faulty display', 'burnt terminal', 'obsolete (not STS compliant)', 'customer request'])[1 + h % 4],
        'materials', jsonb_build_array(jsonb_build_object('item', 'Meter seal', 'qty', 2), jsonb_build_object('item', '16mm cable (m)', 'qty', 2 + h % 4)))
     ELSE jsonb_build_object(
        'meter_type', meter_type, 'commissioning_reading', 0,
        'materials', jsonb_build_array(jsonb_build_object('item', 'Meter seal', 'qty', 2), jsonb_build_object('item', '16mm cable (m)', 'qty', 5 + h % 20),
                                       jsonb_build_object('item', 'Cut-out fuse', 'qty', 1))
                     || CASE WHEN h % 3 = 0 THEN jsonb_build_array(jsonb_build_object('item', 'Pole clamp', 'qty', 1 + h % 2)) ELSE '[]'::jsonb END)
     END
FROM w JOIN (VALUES ('IKJ', 6.58, 3.33), ('IKD', 6.60, 3.49), ('OTA', 6.67, 3.21), ('ABK', 7.14, 3.33),
                    ('IBN', 7.42, 3.90), ('IBS', 7.35, 3.87), ('OGB', 8.12, 4.23), ('OYO', 7.83, 3.92)) g(bu, lat, lng) ON g.bu = w.bu_code;
ANALYZE work_order;
SELECT doc->>'type' AS type, count(*) FROM work_order GROUP BY 1 ORDER BY 1;
