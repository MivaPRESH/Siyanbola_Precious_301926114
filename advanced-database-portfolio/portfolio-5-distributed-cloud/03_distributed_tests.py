"""
MIT 8103 - Portfolio 5 : distributed experiments on the VoltGrid 5-node lab
(01_setup_cluster.sh + 02_sharding.sql must have been run first).

  E1  Shard routing: one meter's readings -> exactly one shard (hash partition pruning)
  E2  Scatter-gather: a question that is not about one meter asks every shard
  E3  Distributed aggregation: per-meter consumption computed ON the shards (partition-wise aggregate)
  E4  Balance: hash sharding vs sharding by state
  E5  Availability when one shard is down
  E6  Streaming replication: status of the normal and the DELAYED standby, lag, read-only standby
  E7  HUMAN ERROR: "DELETE FROM payment" without WHERE - recover the rows from the delayed standby
  E8  Commit latency: async vs synchronous replication
  E9  CAP: synchronous primary with the standby down
  E10 Failover: promote the standby

Usage (as root): python3 03_distributed_tests.py > evidence/03_distributed_tests_output.txt
"""
import statistics, subprocess, threading, time
import psycopg2

PGBIN, BASE = "/usr/lib/postgresql/16/bin", "/home/claude/pg"
T0 = time.time()


def log(m):
    print(f"[{time.time() - T0:7.2f}s] {m}", flush=True)


def banner(t):
    print("\n" + "=" * 98 + f"\n{t}\n" + "=" * 98, flush=True)


def conn(port, db="voltgrid", autocommit=True):
    c = psycopg2.connect(host="localhost", port=port, dbname=db, user="postgres", connect_timeout=3)
    c.autocommit = autocommit
    return c


def q(c, sql, args=None, show=True, label=""):
    cur = c.cursor()
    if show:
        log(f"{label}SQL> " + " ".join(cur.mogrify(sql, args).decode().split())[:170])
    cur.execute(sql, args)
    rows = cur.fetchall() if cur.description else None
    if show and rows is not None:
        for r in rows[:12]:
            print("        " + " | ".join(str(x) for x in r), flush=True)
        if len(rows) > 12:
            print(f"        ... ({len(rows)} rows)", flush=True)
    return rows


def pg_ctl(node, action, port=None, mode="fast"):
    opts = f"-o '-p {port}'" if port and action in ("start", "restart") else ""
    cmd = f"su postgres -c \"{PGBIN}/pg_ctl -D {BASE}/{node} {opts} -l {BASE}/{node}.log -m {mode} -w {action}\""
    log(f"$ pg_ctl {action} {node}" + (f" (-m {mode})" if action == "stop" else ""))
    out = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    print("        " + (out.stdout + out.stderr).strip().replace("\n", "\n        "), flush=True)


def timed(c, sql, n=5):
    cur = c.cursor(); ts = []
    for _ in range(n + 1):
        t = time.perf_counter(); cur.execute(sql); cur.fetchall(); ts.append((time.perf_counter() - t) * 1000)
    return statistics.median(ts[1:])


def explain(c, sql):
    for (line,) in q(c, "EXPLAIN (VERBOSE, COSTS OFF) " + sql, show=False):
        if any(k in line for k in ("Foreign Scan", "Append", "Relations", "Remote SQL", "Aggregate")):
            print("        " + line[:150], flush=True)


coord = conn(5432)
q(coord, "SET search_path TO voltgrid_dist, voltgrid", show=False)
sa, sb = conn(5434, "voltgrid_shard"), conn(5435, "voltgrid_shard")
M_A = q(sa, "SELECT meter_no FROM reading_shard ORDER BY meter_no LIMIT 1", show=False)[0][0]
M_B = q(sb, "SELECT meter_no FROM reading_shard ORDER BY meter_no LIMIT 1", show=False)[0][0]

# ---------------------------------------------------------------------------
banner(f"E1  SHARD ROUTING - October consumption of meter {M_B} (customer portal)")
sql = f"""SELECT meter_no, max(kwh_total) - min(kwh_total) AS october_kwh, count(*) AS readings FROM readings
          WHERE meter_no = '{M_B}' AND read_at >= '2026-10-01 00:00+01' AND read_at < '2026-11-01 00:00+01' GROUP BY meter_no"""
q(coord, sql); explain(coord, sql)
log(f"hash(meter_no) sends the query to ONE shard; median {timed(coord, sql):.2f} ms")
for name, c in (("shard_a :5434", sa), ("shard_b :5435", sb)):
    n, m = q(c, "SELECT count(*), count(DISTINCT meter_no) FROM reading_shard", show=False)[0]
    log(f"{name} holds {n:,} readings of {m:,} meters")

# ---------------------------------------------------------------------------
banner("E2  SCATTER-GATHER - readings received from band E meters on 11 Nov, per business unit (field-operations dashboard)")
sql = """SELECT bu_code, count(*) AS readings_11_nov FROM readings
         WHERE band = 'E' AND read_at = '2026-11-11 00:00+01' GROUP BY bu_code ORDER BY bu_code"""
q(coord, sql); explain(coord, sql)
log(f"no meter_no in the filter -> BOTH shards are asked, in parallel (Async Foreign Scan): {timed(coord, sql):.2f} ms")

# ---------------------------------------------------------------------------
banner("E3  DISTRIBUTED AGGREGATION - October energy per business unit (max - min per meter, then sum)")
sql = """SELECT bu_code, count(*) AS meters, round(sum(kwh)) AS kwh FROM (
           SELECT meter_no, bu_code, max(kwh_total) - min(kwh_total) AS kwh FROM readings
           WHERE read_at >= '2026-10-01 00:00+01' AND read_at < '2026-11-01 00:00+01' GROUP BY meter_no, bu_code) m
         GROUP BY bu_code ORDER BY bu_code"""
q(coord, "SET enable_partitionwise_aggregate = off", show=False); t_off = timed(coord, sql, 3)
log("partition-wise aggregate OFF - every October reading travels to the coordinator:"); explain(coord, sql)
q(coord, "SET enable_partitionwise_aggregate = on", show=False); t_on = timed(coord, sql, 3)
log("partition-wise aggregate ON - GROUP BY meter_no runs on each shard (the shard key is in the GROUP BY):"); explain(coord, sql)
rows = q(coord, sql, show=False)
local = conn(5432); q(local, "SET search_path TO voltgrid", show=False)
t_local = timed(local, """SELECT vm.bu_code, count(*), round(sum(kwh)) FROM (SELECT meter_no, max(kwh_total) - min(kwh_total) kwh
    FROM meter_reading WHERE read_at >= '2026-10-01 00:00+01' AND read_at < '2026-11-01 00:00+01' GROUP BY 1) m
    JOIN v_meter vm USING (meter_no) GROUP BY 1""", 3)
same = sorted((r[0], r[1], r[2]) for r in rows) == sorted(
    (r[0], r[1], r[2]) for r in q(local, """SELECT vm.bu_code, count(*), round(sum(kwh)) FROM (SELECT meter_no, max(kwh_total) - min(kwh_total) kwh
    FROM meter_reading WHERE read_at >= '2026-10-01 00:00+01' AND read_at < '2026-11-01 00:00+01' GROUP BY 1) m
    JOIN v_meter vm USING (meter_no) GROUP BY 1""", show=False))
log(f"8 rows | median: push-down OFF {t_off:.0f} ms | ON {t_on:.0f} ms | single-node partitioned table {t_local:.0f} ms | "
    f"same answer as single node: {same}")

# ---------------------------------------------------------------------------
banner("E4  BALANCE - hash on meter_no vs sharding by state (Lagos + Ogun on one shard, Oyo on the other)")
q(coord, """SELECT CASE WHEN tableoid = 'readings_a'::regclass THEN 'hash shard_a' ELSE 'hash shard_b' END AS shard, count(*) AS readings,
                   round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct FROM readings GROUP BY 1 ORDER BY 1""")
q(coord, """SELECT CASE WHEN bu_code IN ('IKJ','IKD','OTA','ABK') THEN 'state shard: Lagos + Ogun' ELSE 'state shard: Oyo' END AS shard,
                   count(*) AS readings, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct FROM readings GROUP BY 1 ORDER BY 1""")
log("hash spreads the load almost evenly; a geographic split follows the customer base and is uneven")

# ---------------------------------------------------------------------------
banner("E5  AVAILABILITY - shard_b goes down")
sb.close()
pg_ctl("shard_b", "stop")
q(coord, f"SELECT count(*) AS readings_of_meter_on_shard_a FROM readings WHERE meter_no = '{M_A}'", label="portal, meter on shard_a: ")
for label, sql in (("portal, meter on shard_b: ", f"SELECT count(*) FROM readings WHERE meter_no = '{M_B}'"),
                   ("IKJ business-unit report: ", "SELECT count(*) FROM readings WHERE bu_code = 'IKJ' AND read_at >= '2026-11-01 00:00+01'")):
    try:
        q(coord, sql, label=label)
    except Exception as e:
        log(f"!! {label}fails: {str(e).strip().splitlines()[0]}")
log("-> with hash sharding EVERY business unit has meters on both shards, so every area-wide report fails;")
log("   half of the individual meters stay available. (A geographic shard key isolates failures by area instead.)")
pg_ctl("shard_b", "start", 5435)
sb = conn(5435, "voltgrid_shard")
q(coord, "SELECT count(*) AS all_readings FROM readings", label="after restart: ")

# ---------------------------------------------------------------------------
banner("E6  STREAMING REPLICATION - primary 5432 -> replica1 5433 (immediate) and replica_delayed 5436 (30 s late)")
prim, repl, dly = conn(5432), conn(5433), conn(5436)
q(prim, """SELECT application_name, state, sync_state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_not_applied,
                  replay_lag FROM pg_stat_replication ORDER BY 1""", label="primary: ")
q(prim, "CREATE TABLE IF NOT EXISTS voltgrid.replication_probe (id BIGSERIAL PRIMARY KEY, note TEXT, at TIMESTAMPTZ DEFAULT clock_timestamp())", show=False)
for _ in range(300):
    try:
        q(repl, "SELECT 1 FROM voltgrid.replication_probe LIMIT 1", show=False); break
    except psycopg2.errors.UndefinedTable:
        time.sleep(0.01)
lags = []
for _ in range(20):
    rid = q(prim, "INSERT INTO voltgrid.replication_probe (note) VALUES ('lag') RETURNING id", show=False)[0][0]
    t = time.perf_counter()
    while not q(repl, "SELECT 1 FROM voltgrid.replication_probe WHERE id = %s", (rid,), show=False):
        time.sleep(0.0005)
    lags.append((time.perf_counter() - t) * 1000)
log(f"commit on primary -> visible on replica1, 20 trials: median {statistics.median(lags):.2f} ms, max {max(lags):.2f} ms")
try:
    q(repl, "UPDATE voltgrid.tariff SET rate_per_kwh = 1 WHERE tariff_id = 1", label="replica1: ")
except Exception as e:
    log(f"!! standby rejects writes: {str(e).strip().splitlines()[0]}")

# ---------------------------------------------------------------------------
banner("E7  HUMAN ERROR - an operator meant to delete the demo payments but forgot the WHERE clause")
before = q(prim, "SELECT count(*), sum(amount) FROM voltgrid.payment", show=False)[0]
log(f"payments before: {before[0]:,} rows, {before[1]:,.2f} naira")
t_del = time.perf_counter()
q(prim, "DELETE FROM voltgrid.payment", label="primary (the mistake): ")
time.sleep(0.2)
q(repl, "SELECT count(*) AS payments_on_replica1 FROM voltgrid.payment", label="replica1 200 ms later: ")
log("-> ordinary replication copies the mistake to the standby at once: it protects against hardware failure, not human error")
q(dly, "SELECT count(*) AS payments_on_replica_delayed FROM voltgrid.payment", label="replica_delayed: ")
q(dly, "SELECT pg_wal_replay_pause()", label="DBA, within 30 s: ")
q(dly, "SELECT pg_get_wal_replay_pause_state() AS replay, now() - pg_last_xact_replay_timestamp() AS applied_up_to_ago",
  label="replica_delayed: ")
dly.autocommit = False                                   # a server-side cursor needs a transaction
cur = dly.cursor(name="copy"); cur.itersize = 20000
cur.execute("SELECT payment_id, bill_id, payment_ref, amount, paid_at FROM voltgrid.payment")
wcur = prim.cursor(); n = 0
prim.autocommit = False
while True:
    batch = cur.fetchmany(20000)
    if not batch:
        break
    wcur.executemany("INSERT INTO voltgrid.payment (payment_id, bill_id, payment_ref, amount, paid_at) OVERRIDING SYSTEM VALUE "
                     "VALUES (%s, %s, %s, %s, %s)", batch)
    n += len(batch)
prim.commit(); prim.autocommit = True; dly.commit(); dly.autocommit = True
after = q(prim, "SELECT count(*), sum(amount) FROM voltgrid.payment", show=False)[0]
log(f"copied {n:,} rows back from the delayed standby; primary now {after[0]:,} rows, {after[1]:,.2f} naira -> "
    f"{'fully recovered' if tuple(after) == tuple(before) else 'MISMATCH'} {(time.perf_counter() - t_del):.1f} s after the mistake")
q(dly, "SELECT pg_wal_replay_resume()", label="replica_delayed: ")
log("the delayed standby will now apply the DELETE and then the re-insert, 30 s late, and end up identical to the primary")

# ---------------------------------------------------------------------------
banner("E8  COMMIT LATENCY - 300 commits each: async vs synchronous replication to replica1")
q(prim, "ALTER SYSTEM SET synchronous_standby_names = 'replica1'", show=False)
q(prim, "SELECT pg_reload_conf()", show=False); time.sleep(1)
q(prim, "SELECT application_name, sync_state FROM pg_stat_replication ORDER BY 1", label="primary: ")
res = {}
for mode in ("local", "on", "remote_apply"):
    c = conn(5432); q(c, f"SET synchronous_commit = {mode}", show=False); cur = c.cursor(); ts = []
    for _ in range(300):
        t = time.perf_counter(); cur.execute("INSERT INTO voltgrid.replication_probe (note) VALUES (%s)", (mode,))
        ts.append((time.perf_counter() - t) * 1000)
    res[mode] = (statistics.median(ts), sorted(ts)[284]); c.close()
for mode, d in (("local", "async - standby may lag"), ("on", "standby has flushed WAL"), ("remote_apply", "standby has applied it")):
    log(f"synchronous_commit={mode:<12} median {res[mode][0]:.3f} ms, p95 {res[mode][1]:.3f} ms  ({d})")
log("the delayed standby is NOT listed as synchronous: with a 30 s apply delay, remote_apply commits would wait 30 s")

# ---------------------------------------------------------------------------
banner("E9  CAP IN PRACTICE - synchronous replication, standby unreachable")
pg_ctl("replica1", "stop")
w = conn(5432); pid = q(w, "SELECT pg_backend_pid()", show=False)[0][0]; q(w, "SET synchronous_commit = on", show=False)
out = {}


def writer():
    try:
        t = time.perf_counter()
        w.cursor().execute("INSERT INTO voltgrid.replication_probe (note) VALUES ('token sale during partition')")
        out["m"] = f"returned after {time.perf_counter() - t:.1f}s; notices: {[n.strip() for n in w.notices]}"
    except Exception as e:
        out["m"] = f"error: {e}"


th = threading.Thread(target=writer); th.start(); time.sleep(3)
q(prim, "SELECT pid, wait_event_type, wait_event, state FROM pg_stat_activity WHERE pid = %s", (pid,), label="primary: ")
log("-> the sale cannot be confirmed: the primary waits for a standby that cannot answer (Consistency over Availability)")
q(prim, "SELECT pg_cancel_backend(%s)", (pid,), label="operator cancels the wait: ")
th.join(5); log(f"writer: {out.get('m')}")
q(prim, "ALTER SYSTEM RESET synchronous_standby_names", show=False); q(prim, "SELECT pg_reload_conf()", show=False)
log("sync requirement removed -> primary accepts writes again in async mode (Availability over Consistency)")
q(prim, "INSERT INTO voltgrid.replication_probe (note) VALUES ('async while standby down') RETURNING id", label="primary: ")
pg_ctl("replica1", "start", 5433); time.sleep(2)
q(prim, "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_not_applied FROM pg_stat_replication ORDER BY 1",
  label="primary: ")
log("-> replica1 reconnected through its replication slot and caught up")

# ---------------------------------------------------------------------------
banner("E10 FAILOVER - primary crashes, replica1 is promoted")
repl = conn(5433); prim = conn(5432)
q(prim, "INSERT INTO voltgrid.replication_probe (note) VALUES ('last write before crash')", show=False)
n_before, max_id = q(prim, "SELECT count(*), max(id) FROM voltgrid.replication_probe", show=False)[0]
pay_before = q(prim, "SELECT count(*) FROM voltgrid.payment", show=False)[0][0]
prim.close(); time.sleep(0.05)
log(f"primary just before crash: {n_before} probe rows, newest id {max_id}; {pay_before:,} payments")
pg_ctl("primary", "stop", mode="immediate")
try:
    conn(5432)
except Exception as e:
    log(f"!! primary unreachable: {str(e).strip().splitlines()[0]}")
t = time.perf_counter(); q(repl, "SELECT pg_promote(wait => true)", label="replica1: ")
log(f"promotion took {(time.perf_counter() - t) * 1000:.0f} ms")
q(repl, "SELECT pg_is_in_recovery() AS still_standby", label="new primary: ")
q(repl, "INSERT INTO voltgrid.replication_probe (note) VALUES ('first write after failover') RETURNING id", label="new primary: ")
got = q(repl, "SELECT count(*) FROM voltgrid.replication_probe WHERE id <= %s", (max_id,), show=False)[0][0]
pay_after = q(repl, "SELECT count(*) FROM voltgrid.payment", show=False)[0][0]
log(f"rows committed on old primary present on new primary: {got} of {n_before}; payments {pay_after:,} of {pay_before:,} -> "
    f"{'no committed data lost' if got == n_before and pay_after == pay_before else 'DATA LOSS'}")
log("-> replica_delayed still follows the OLD primary: its primary_conninfo must be re-pointed to the new one")
repl.close()

banner("CLEAN-UP - restore lab topology")
pg_ctl("replica1", "stop")
pg_ctl("primary", "start", "5432 -c wal_level=replica -c max_wal_senders=10 -c max_replication_slots=10 -c max_prepared_transactions=20")
log("re-run 01_setup_cluster.sh to rebuild the standbys (production: pg_rewind the old primary into the new standby)")
