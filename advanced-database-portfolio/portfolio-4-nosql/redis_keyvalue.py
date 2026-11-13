"""
MIT 8103 - Portfolio 4 (part A): VoltGrid workloads on Redis 7.

Keys (namespace:entity:id)
  rl:vend:{meter}               ZSET    sliding-window rate limit of token requests per meter (Lua)
  idem:{payment_ref}            STRING  idempotency guard at the API edge: SET NX EX (first caller wins)
  rd:{yyyymmdd}                 BITMAP  one bit per postpaid meter: "a reading arrived that day"
  feeder:status                 HASH    live supply status of every feeder (rebuilt from PostgreSQL outages)
  rev:today                     ZSET    running token revenue per business unit (ZINCRBY)

Redis holds no financial record of truth: sales, bills and payments stay in PostgreSQL.
Everything here is either short-lived (rate limits, idempotency guards), rebuildable
(bitmaps, feeder status, counters) or a cache.

Usage: python3 redis_keyvalue.py > evidence/redis_output.txt
"""
import os, threading, time
from datetime import date, timedelta
import psycopg2, redis

r = redis.Redis(host="localhost", port=6379, decode_responses=True)
pg = psycopg2.connect(os.environ.get("VOLTGRID_DSN", "host=localhost dbname=voltgrid user=postgres"))
pg.autocommit = True
cur = pg.cursor()
cur.execute("SET search_path TO voltgrid, public")


def banner(t):
    print("\n" + "=" * 92 + f"\n{t}\n" + "=" * 92, flush=True)


def show(cmd, res):
    print(f"redis> {cmd}\n       {res}", flush=True)


banner("0. Environment")
print(f"Redis {r.info('server')['redis_version']} - removing VoltGrid demo keys only")
for pat in ("rl:*", "idem:*", "rd:*", "feeder:status", "rev:today"):
    for k in r.scan_iter(pat):
        r.delete(k)

# ---------------------------------------------------------------------------
banner("1. RATE LIMIT - at most 5 token requests per meter per 60 s (sliding window, one Lua script)")
LIMIT = r.register_script("""
local now, window, limit = tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, now - window)          -- forget requests older than the window
if redis.call('ZCARD', KEYS[1]) < limit then
  redis.call('ZADD', KEYS[1], now, ARGV[4]); redis.call('PEXPIRE', KEYS[1], window)
  return 1
end
return 0""")
res, bar = [], threading.Barrier(30)


def request(i):
    c = redis.Redis(host="localhost", port=6379, decode_responses=True); s = c.register_script(LIMIT.script); bar.wait()
    res.append(s(keys=["rl:vend:45100000291"], args=[int(time.time() * 1000), 60000, 5, f"req-{i}"]))


ths = [threading.Thread(target=request, args=(i,)) for i in range(30)]
[t.start() for t in ths]; [t.join() for t in ths]
print(f"   a misbehaving POS terminal sends 30 requests for meter 45100000291 in the same instant:")
print(f"   allowed={res.count(1)}, refused (HTTP 429)={res.count(0)}; another meter is not affected: "
      f"{LIMIT(keys=['rl:vend:45100000097'], args=[int(time.time() * 1000), 60000, 5, 'x'])}")
show("ZCARD rl:vend:45100000291 / PTTL", (r.zcard("rl:vend:45100000291"), r.pttl("rl:vend:45100000291")))
print("   the check and the insert run in one script, so 30 simultaneous requests cannot all see '4 so far'")

# ---------------------------------------------------------------------------
banner("2. IDEMPOTENCY GUARD AT THE API EDGE - the same payment notification arrives 3 times")
fresh = "DEMO-REDIS-" + str(int(time.time()))
out, bar = [], threading.Barrier(3)


def notify(n):
    c = redis.Redis(host="localhost", port=6379, decode_responses=True); bar.wait()
    won = c.set(f"idem:{fresh}", f"worker-{n}", nx=True, ex=86400)       # only the first SET succeeds
    out.append((n, bool(won)))


ths = [threading.Thread(target=notify, args=(i,)) for i in (1, 2, 3)]
[t.start() for t in ths]; [t.join() for t in ths]
print(f"   SET idem:{fresh} <worker> NX EX 86400 from 3 workers at once -> {sorted(out)}")
print(f"   exactly one worker calls the token engine: {sum(w for _, w in out) == 1}; key owner = {r.get(f'idem:{fresh}')}, TTL {r.ttl(f'idem:{fresh}')} s")
print("   Redis only filters duplicates early; the UNIQUE payment_ref in PostgreSQL (Portfolio 3, S1) remains the final guarantee")

# ---------------------------------------------------------------------------
banner("3. WHICH METERS REPORTED? - one bitmap per day, one bit per postpaid meter (last 7 complete days)")
cur.execute("SELECT meter_no, row_number() OVER (ORDER BY meter_no) - 1 FROM meter WHERE meter_type = 'POSTPAID' ORDER BY meter_no")
offset = dict(cur.fetchall())
days = [date(2026, 11, 5) + timedelta(d) for d in range(7)]
cur.execute("SELECT meter_no, (read_at AT TIME ZONE 'Africa/Lagos')::date FROM meter_reading "
            "WHERE read_at >= '2026-11-05 00:00+01' AND read_at < '2026-11-12 00:00+01'")
pipe = r.pipeline()
for meter_no, d in cur.fetchall():
    pipe.setbit(f"rd:{d:%Y%m%d}", offset[meter_no], 1)
pipe.execute()
for d in days:
    k = f"rd:{d:%Y%m%d}"
    cur.execute("SELECT count(DISTINCT meter_no) FROM meter_reading WHERE read_at >= %s::date::timestamp AT TIME ZONE 'Africa/Lagos' "
                "AND read_at < (%s::date + 1)::timestamp AT TIME ZONE 'Africa/Lagos'", (d, d))
    print(f"   {d}: BITCOUNT {r.bitcount(k):>5}  (SQL count {cur.fetchone()[0]:>5})  memory {r.memory_usage(k)} bytes")
keys = [f"rd:{d:%Y%m%d}" for d in days]
r.bitop("AND", "rd:all7", *keys); r.bitop("OR", "rd:any7", *keys)
all7, any7 = r.bitcount("rd:all7"), r.bitcount("rd:any7")
cur.execute("""SELECT count(*) FROM (SELECT meter_no FROM meter_reading WHERE read_at >= '2026-11-05 00:00+01' AND read_at < '2026-11-12 00:00+01'
               GROUP BY meter_no HAVING count(*) = 7) x""")
print(f"   BITOP AND over 7 days: {all7} meters reported every day (SQL: {cur.fetchone()[0]}); "
      f"BITOP OR: {any7} reported at least once; {any7 - all7} missed one or more days -> field visit list")
print(f"   {len(offset):,} meters x 7 days stored in {sum(r.memory_usage(k) for k in keys):,} bytes; the same question in SQL scans "
      f"~{len(offset) * 7:,} readings")
r.delete("rd:all7", "rd:any7")

# ---------------------------------------------------------------------------
banner("4. LIVE FEEDER STATUS BOARD - a hash rebuilt from PostgreSQL, updated by events")
cur.execute("""SELECT f.feeder_code, coalesce('OUT since ' || to_char(o.started_at AT TIME ZONE 'Africa/Lagos', 'HH24:MI') || ' (' || o.cause || ')', 'ON')
               FROM feeder f LEFT JOIN outage o ON o.feeder_id = f.feeder_id AND o.restored_at IS NULL ORDER BY f.feeder_id""")
r.hset("feeder:status", mapping=dict(cur.fetchall()))
out_now = {k: v for k, v in r.hgetall("feeder:status").items() if v != "ON"}
show("HLEN feeder:status", r.hlen("feeder:status"))
show("feeders out now (HGETALL, filtered)", out_now)
r.hset("feeder:status", "IKJ-F12", "ON")                   # restoration event from the control room
show("HGET feeder:status IKJ-F12   (after the restoration event)", r.hget("feeder:status", "IKJ-F12"))
print("   the customer app reads one hash (no join) when 40,000 customers open it during a blackout;")
print("   PostgreSQL's outage table stays the record used for the regulator's supply-hours report (Portfolio 2, Q5)")

# ---------------------------------------------------------------------------
banner("5. TODAY'S REVENUE PER BUSINESS UNIT - sorted-set counters (ZINCRBY) vs SQL")
cur.execute("""SELECT b.bu_code, v.amount FROM vend v JOIN meter m USING (meter_no) JOIN customer c USING (customer_id)
               JOIN business_unit b USING (bu_id) WHERE v.vended_at >= '2026-11-12 00:00+01' AND v.vended_at < '2026-11-13 00:00+01'
               AND v.payment_ref NOT LIKE 'DEMO-%'""")
rows = cur.fetchall()
pipe = r.pipeline()
for bu, amt in rows:
    pipe.zincrby("rev:today", float(amt), bu)
pipe.execute()
cur.execute("""SELECT b.bu_code, sum(v.amount) FROM vend v JOIN meter m USING (meter_no) JOIN customer c USING (customer_id)
               JOIN business_unit b USING (bu_id) WHERE v.vended_at >= '2026-11-12 00:00+01' AND v.vended_at < '2026-11-13 00:00+01'
               AND v.payment_ref NOT LIKE 'DEMO-%' GROUP BY 1""")
exact = {k: float(v) for k, v in cur.fetchall()}
top = r.zrevrange("rev:today", 0, -1, withscores=True)
for bu, s in top[:4]:
    print(f"   {bu}: {s:>12,.0f} naira")
print(f"   {len(rows)} sales of 12 Nov replayed as ZINCRBY events; Redis totals equal SQL totals: "
      f"{all(abs(exact[b] - s) < 0.01 for b, s in top)}")
print("   ZREVRANGE gives the ranking directly; at midnight the key is renamed and the day's figures come from SQL")
