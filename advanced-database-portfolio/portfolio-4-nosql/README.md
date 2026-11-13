# Portfolio 4 — NoSQL and Advanced Data Models

Case study: **VoltGrid Power**. Sales, bills, payments and tariffs must stay relational (constraints, triggers, transactions; Portfolios 1–3). Two other kinds of data fit different models better:
- **high-volume operational signals:** API rate limits, duplicate payment notifications, "did this meter report today?", feeder status during a blackout, live revenue counters;
- **field work orders:** job cards whose content depends on the job type.

Both were built on the same data as Portfolios 1–3.

| Part | Model | Engine | VoltGrid data |
|---|---|---|---|
| A | Key-value: sorted sets, strings with TTL, **bitmaps**, hashes | **Redis 7** (real server) | rate limiting, idempotency guard, daily meter-reporting bitmaps, feeder status board, revenue counters |
| B | Document | **PostgreSQL 16 JSONB** + GIN, SQL/JSON path | 11,592 work orders of 4 job types (installation, tamper inspection, disconnection, meter replacement) |
| C | Document (MongoDB API) | PyMongo API via `mongomock` (see note) | the same work orders: aggregation pipelines, `$unwind`, conditional single-document update |

## A. Redis ([`redis_keyvalue.py`](redis_keyvalue.py) → [`evidence/redis_output.txt`](evidence/redis_output.txt))

| Key / type | Use | Result |
|---|---|---|
| `rl:vend:{meter}` ZSET + Lua | sliding-window rate limit: at most 5 token requests per meter per 60 s | a faulty POS terminal sent **30 requests at the same instant: 5 allowed, 25 refused** (HTTP 429). Another meter was unaffected. Removing old entries, counting and adding run in one script, so the 30 requests could not all see "4 so far" |
| `idem:{payment_ref}` `SET NX EX 86400` | drop duplicate payment notifications at the API, before the token engine is called | 3 workers at once: **exactly 1 wins**; the key expires after 24 h. The UNIQUE `payment_ref` in PostgreSQL (Portfolio 3, S1) stays the final guarantee |
| `rd:{yyyymmdd}` **bitmap**, 1 bit per postpaid meter | "which meters sent a reading on each of the last 7 days?" | each day's `BITCOUNT` equals the SQL count (7,001–7,023). `BITOP AND` over 7 days: **6,590 meters reported every day** (SQL: 6,590); `BITOP OR`: 7,086. **496 meters missed at least one day** and go on the field-visit list. 7,087 meters × 7 days take **7,560 bytes** (1,080 per day) |
| `feeder:status` HASH | live supply board for the customer app during a blackout | rebuilt from PostgreSQL: 120 feeders; 3 out (IKJ-F12 FAULT since 19:40, ABK-F02 load shedding, OGB-F11 FAULT); a restoration event sets IKJ-F12 back to `ON` |
| `rev:today` ZSET (`ZINCRBY`) | live revenue ranking per business unit | 2,203 sales of 12 Nov replayed as events; Ikeja first (₦6.71 m); **Redis totals equal the SQL totals** |

**Why Redis here:** each use is a small, very frequent operation on one key. It must be atomic, it is mostly short-lived, and it would otherwise add load to the database that holds the money. **Redis holds no financial record:** rate limits and idempotency keys expire, while bitmaps, the status board and counters can be rebuilt from PostgreSQL. Bitmaps are the right choice only because meters have small, dense integer positions (the row number of the meter); for sparse IDs a set or a HyperLogLog would be used instead.

## B. Work orders as documents — JSONB ([`document_model.sql`](document_model.sql), [`document_queries.sql`](document_queries.sql) → [`evidence/document_queries_output.txt`](evidence/document_queries_output.txt))

**Why documents.** A tamper inspection records a *checklist*, *findings* (bypass? seal intact? method), *photos* and *estimated unbilled kWh*. A disconnection records the *bill, arrears, where it was cut* and *whether the customer was present*. A replacement records the *old and new meter with readings*, and installations record a *materials list*. A relational design would need four job tables plus child tables for checklists, photos and materials. A job card is created by the field app, completed once and read whole.

```json
{ "_id": "WO-004990", "type": "TAMPER_INSPECTION", "meter_no": "45102215771", "bu": "IKJ", "feeder": "IKJ-F13",
  "status": "COMPLETED", "scheduled_for": "2026-01-05", "technician": {"name": "Engr. S. Ogunleye", "staff_no": "VGT-0148"},
  "checklist": [{"item": "Terminal seal", "ok": true}, {"item": "Incoming cable", "ok": false}, ...],
  "findings": {"bypass": true, "seal_intact": true, "method": "direct cable bypass"},
  "photos": ["s3://vg-field/45102215771/1.jpg", "..."], "estimated_unbilled_kwh": 858 }
```

| Query | Result |
|---|---|
| D1 confirmed bypasses with ≥ 3 photos (containment `@>` + path `$.photos.size() >= 3`) | 163 cases in 8 business units; Ota leads with 27 cases, Ikeja has the most unbilled energy (17,046 kWh) |
| D2 materials issued per business unit (`jsonb_array_elements` over the materials array) | e.g. Ikeja: 13,412 m of cable, 1,906 seals, 911 fuses, 459 pole clamps |
| D3 checklist items that fail most often (`$.checklist[*] ? (@.ok == false).item`) | terminal seal 717, cover screws 519, incoming cable 338, display 114 |
| **GIN index** (`jsonb_path_ops`) | `type = DISCONNECTION, bu = IBN, cut_at = pole`: Seq Scan, 846 buffers, 3.2 ms → Bitmap Index Scan, 150 buffers, **0.49 ms**. Index 2.7 MB for a 9.9 MB collection |
| Partial update | an ASSIGNED job set to COMPLETED, with a `history` entry appended, in one `UPDATE` (`jsonb_set` + `||`) |
| New job type `NET_METER_SURVEY` with nested `roof` and `proposed` blocks | stored and queried, no `ALTER TABLE` |
| Validation | **rejected:** a COMPLETED tamper inspection without `findings` (`CHECK tamper_has_findings`) and an unknown job type (`CHECK doc_type_known`) |

"Schema-less" does not have to mean "rule-less": the CHECK constraints enforce the few rules that matter, and every other field can vary.

## C. MongoDB API ([`mongo_work_orders.py`](mongo_work_orders.py) → [`evidence/mongo_api_output.txt`](evidence/mongo_api_output.txt))

- **M1 aggregation pipeline** (`$match` → `$project` with `$size` → `$match` → `$group` → `$sort`): the same bypass cases and unbilled kWh per business unit as D1.
- **M2 `$unwind`** of the materials array: cable issued per business unit (Ikeja 13,412 m), the same as D2.
- **M3** nested-field query with projection: 5 open disconnections in Ibadan North, the largest arrears first.
- **M4 compare-and-set on one document:** two phones complete the same job. Phone A's `update_one({_id, status: "ASSIGNED"}, {$set, $push history, $inc visits})` **matched 1**. Phone B's late sync **matched 0**, so it cannot overwrite the first technician's record. A single-document update is atomic, so no multi-document transaction is needed.
- Cross-check with JSONB: **M1 and M2 both `True`.**

> **Engine note:** MongoDB server binaries could not be downloaded in the build environment, so Part C runs on `mongomock`, an in-memory implementation of the PyMongo API. On a real server, change `mongomock.MongoClient()` to `pymongo.MongoClient("mongodb://...")`. `explain()` is not meaningful on mongomock, so **no performance figures are claimed for Part C**.

## D. Which model for which VoltGrid data

| Data | Model | Reason |
|---|---|---|
| Customers, meters, tariffs, token sales, bills, payments | **Relational** | money: idempotent sales, CHECK on overpayment, tariff exclusion constraint, transactions (Portfolios 1–3) |
| Field work orders, inspection reports | **Document** | shape varies by job type; written once and read whole; new job types without migrations |
| Rate limits, idempotency guards, meter-reporting bitmaps, live status, counters | **Key-value (Redis)** | high-frequency atomic operations on one key; short-lived or rebuildable |
| Meter readings at 15-minute intervals from smart meters | **Time-series** (e.g. TimescaleDB, or a wide-column store such as Cassandra keyed by meter and day) | append-only, queried by meter and time range, compressed; daily readings stay in the partitioned PostgreSQL table (Portfolio 1) — *considered, not implemented* |
| The network itself: substation → feeder → transformer → meter, for fault tracing | **Graph** (e.g. Neo4j) | "which customers lose supply if this transformer fails?" is a path query — *considered, not implemented* |

Customer data (names, phones, addresses, GPS points and photos of premises) is personal data under the **Nigeria Data Protection Act 2023**, so each additional store must be secured and audited. For that reason the Redis keys use meter numbers and codes only, never names or phone numbers.

## How to run

```bash
redis-server --daemonize yes
pip install redis psycopg2-binary mongomock pymongo
python3 redis_keyvalue.py > evidence/redis_output.txt
psql -d voltgrid -f document_model.sql
psql -d voltgrid -f document_queries.sql > evidence/document_queries_output.txt 2>&1
python3 mongo_work_orders.py > evidence/mongo_api_output.txt
```
