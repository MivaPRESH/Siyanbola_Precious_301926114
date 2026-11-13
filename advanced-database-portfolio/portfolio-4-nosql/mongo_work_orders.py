"""
MIT 8103 - Portfolio 4 (part C): the work-order documents through the MongoDB API (PyMongo).

The same 11,592 job cards built in document_model.sql are loaded into a collection
voltgrid.work_orders and queried with MongoDB operators. Answers are cross-checked with JSONB.

  M1  aggregation pipeline: confirmed bypasses with >= 3 photos per business unit ($match, $size, $group, $sort)
  M2  $unwind of the materials array: cable issued per business unit
  M3  query on a nested field + projection: open (ASSIGNED) disconnections in IBN
  M4  a technician app completes a job: update guarded by the current status (compare-and-set in one document);
      a second, late update from another phone matches nothing
  M5  index on nested fields and explain()

Engine: MongoDB server binaries could not be installed in the build environment, so this runs on
mongomock (an in-memory implementation of the PyMongo API). On a real server, replace
mongomock.MongoClient() with pymongo.MongoClient("mongodb://localhost:27017"). No timings are claimed.

Usage: python3 mongo_work_orders.py > evidence/mongo_api_output.txt
"""
import json, os
import mongomock, psycopg2

pg = psycopg2.connect(os.environ.get("VOLTGRID_DSN", "host=localhost dbname=voltgrid user=postgres"))
cur = pg.cursor()
cur.execute("SELECT doc FROM voltgrid_doc.work_order WHERE wo_id NOT LIKE 'WO-DEMO%' ORDER BY wo_id")
docs = [r[0] for r in cur.fetchall()]

client = mongomock.MongoClient()
wo = client.voltgrid.work_orders


def banner(t):
    print("\n" + "=" * 92 + f"\n{t}\n" + "=" * 92, flush=True)


banner("Load")
wo.insert_many(docs)
wo.create_index([("type", 1), ("bu", 1), ("status", 1)])
wo.create_index([("findings.bypass", 1)])
print(f"inserted {wo.count_documents({}):,} documents; types: "
      f"{ {t: wo.count_documents({'type': t}) for t in sorted(wo.distinct('type'))} }")
print("indexes:", sorted(wo.index_information()))

banner("M1  confirmed bypasses with >= 3 photos per business unit (aggregation pipeline)")
m1 = list(wo.aggregate([
    {"$match": {"type": "TAMPER_INSPECTION", "status": "COMPLETED", "findings.bypass": True}},
    {"$project": {"bu": 1, "kwh": "$estimated_unbilled_kwh", "n_photos": {"$size": "$photos"}}},
    {"$match": {"n_photos": {"$gte": 3}}},
    {"$group": {"_id": "$bu", "cases": {"$sum": 1}, "unbilled_kwh": {"$sum": "$kwh"}}},
    {"$sort": {"cases": -1, "_id": 1}}]))
for d in m1:
    print(f"   {d['_id']}: {d['cases']} cases, {d['unbilled_kwh']:,} kWh")
cur.execute("""SELECT doc->>'bu', count(*), sum((doc->>'estimated_unbilled_kwh')::int) FROM voltgrid_doc.work_order
               WHERE doc @> '{"type":"TAMPER_INSPECTION","status":"COMPLETED","findings":{"bypass":true}}'
               AND jsonb_path_exists(doc, '$ ? (@.photos.size() >= 3)') GROUP BY 1""")
sql_m1 = {b: (n, k) for b, n, k in cur.fetchall()}
same_m1 = sql_m1 == {d["_id"]: (d["cases"], d["unbilled_kwh"]) for d in m1}

banner("M2  $unwind the materials array: cable issued per business unit")
m2 = list(wo.aggregate([
    {"$match": {"materials": {"$exists": True}}},
    {"$unwind": "$materials"},
    {"$match": {"materials.item": "16mm cable (m)"}},
    {"$group": {"_id": "$bu", "cable_m": {"$sum": "$materials.qty"}}},
    {"$sort": {"_id": 1}}]))
print("  ", ", ".join(f"{d['_id']} {d['cable_m']:,} m" for d in m2))
cur.execute("""SELECT doc->>'bu', sum((m->>'qty')::int) FROM voltgrid_doc.work_order, jsonb_array_elements(doc->'materials') m
               WHERE m->>'item' = '16mm cable (m)' GROUP BY 1""")
same_m2 = dict(cur.fetchall()) == {d["_id"]: d["cable_m"] for d in m2}

banner("M3  open disconnections in Ibadan North, projected fields only")
q = {"type": "DISCONNECTION", "bu": "IBN", "status": "ASSIGNED"}
open_ibn = list(wo.find(q, {"_id": 1, "meter_no": 1, "arrears": 1, "technician.name": 1}).sort("arrears", -1).limit(3))
print(f"   {wo.count_documents(q)} open; largest arrears first:")
for d in open_ibn:
    print("  ", json.dumps(d, default=str))

banner("M4  completing a job: update ONLY IF the job is still ASSIGNED (compare-and-set on one document)")
target = wo.find_one({"status": "ASSIGNED"}, sort=[("_id", 1)])["_id"]
phone_a = wo.update_one({"_id": target, "status": "ASSIGNED"},
                        {"$set": {"status": "COMPLETED", "completed_by": "VGT-0121"},
                         "$push": {"history": {"at": "2026-11-12T16:20:00+01:00", "event": "completed on site", "by": "VGT-0121"}},
                         "$inc": {"visits": 1}})
phone_b = wo.update_one({"_id": target, "status": "ASSIGNED"},            # late sync from a second phone
                        {"$set": {"status": "COMPLETED", "completed_by": "VGT-0133"},
                         "$push": {"history": {"at": "2026-11-12T16:27:00+01:00", "event": "completed on site", "by": "VGT-0133"}},
                         "$inc": {"visits": 1}})
after = wo.find_one({"_id": target}, {"status": 1, "completed_by": 1, "history": 1, "visits": 1})
print(f"   phone A matched={phone_a.matched_count} modified={phone_a.modified_count}; "
      f"phone B matched={phone_b.matched_count} modified={phone_b.modified_count}")
print(f"   document now: {json.dumps(after)}")
print("   a single-document update is atomic, so the status filter acts as a compare-and-set (cf. the atomic UPDATE in Portfolio 3, S2):")
print("   the late phone must re-read the job instead of overwriting the first technician's record")

banner("M5  index on nested fields")
print("   explain() on mongomock does not show a real plan; on a MongoDB server the query")
print("   {type:'TAMPER_INSPECTION', 'findings.bypass': true} would use IXSCAN on findings.bypass_1.")
print(f"   matching documents: {wo.count_documents({'type': 'TAMPER_INSPECTION', 'findings.bypass': True})}")

banner("Cross-check: MongoDB-API answers vs PostgreSQL JSONB answers")
print("-" * 92)
print(f"  M1 same bypass cases and kWh per business unit: {same_m1}")
print(f"  M2 same cable metres per business unit: {same_m2}")
