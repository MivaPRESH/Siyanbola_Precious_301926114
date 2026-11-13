"""
MIT 8103 - Portfolio 3 : concurrency at VoltGrid Power (real interleaved sessions, PostgreSQL 16).

  S1  The bank sends the SAME payment notification twice, at the same moment (idempotent vending)
      check-then-insert -> one caller gets an error; INSERT ... ON CONFLICT -> both get the SAME token
  S2  Two payments of one bill at the same moment: read-modify-write loses one; atomic UPDATE keeps both;
      the CHECK constraint stops an overpayment even under concurrency
  S3  Tariff changes in the middle of a sale: READ COMMITTED quotes one price and charges another
      (non-repeatable read); REPEATABLE READ uses one snapshot for the whole sale
  S4  Waiting for locks: billing holds a bill; customer care waits (default), fails at once (NOWAIT)
      or gives up after a limit (lock_timeout)
  S5  Archiving an old month: DETACH PARTITION queues behind a long report and blocks every new meter
      reading; DETACH PARTITION CONCURRENTLY lets readings continue
  S6  A month-end report with two queries: READ COMMITTED totals disagree while sales continue;
      REPEATABLE READ totals always agree

Usage: python3 concurrency_demo.py > evidence/concurrency_demo_output.txt
Needs 00_demo_setup.sql to have been run.
"""
import os, statistics, threading, time
import psycopg2
from psycopg2 import errors
from psycopg2.extensions import ISOLATION_LEVEL_READ_COMMITTED, ISOLATION_LEVEL_REPEATABLE_READ, ISOLATION_LEVEL_AUTOCOMMIT

DSN = os.environ.get("VOLTGRID_DSN", "host=localhost dbname=voltgrid user=postgres")
T0 = time.time()
_pl = threading.Lock()


def log(who, msg):
    with _pl:
        print(f"[{time.time() - T0:7.3f}s] {who:<5} {msg}", flush=True)


def banner(t):
    print("\n" + "=" * 100 + f"\n{t}\n" + "=" * 100, flush=True)


class S:
    def __init__(self, name, iso=ISOLATION_LEVEL_READ_COMMITTED):
        self.name = name
        self.conn = psycopg2.connect(DSN)
        self.conn.set_isolation_level(iso)
        self.cur = self.conn.cursor()
        self.cur.execute("SET search_path TO voltgrid, public")
        if iso != ISOLATION_LEVEL_AUTOCOMMIT:
            self.conn.commit()

    def q(self, sql, args=None, show=True):
        if show:
            log(self.name, " ".join((sql if args is None else self.cur.mogrify(sql, args).decode()).split())[:150])
        self.cur.execute(sql, args)
        rows = self.cur.fetchall() if self.cur.description else None
        if show:
            log(self.name, f"  -> {rows if rows is not None else self.cur.statusmessage}")
        return rows

    def commit(self):
        self.conn.commit(); log(self.name, "COMMIT")

    def rollback(self):
        self.conn.rollback(); log(self.name, "ROLLBACK")

    def close(self):
        self.conn.close()


def admin(sql, args=None):
    s = S("ADMIN"); r = s.q(sql, args, show=False); s.conn.commit(); s.close(); return r


METER = "99000000001"


# ---------------------------------------------------------------------------
def s1():
    banner("S1  DUPLICATE PAYMENT NOTIFICATION - the bank's webhook delivers payment DEMO-WH-xxxx twice, 1 ms apart")

    def naive(ref, name, out, bar):
        s = S(name); bar.wait()
        try:
            n = s.q("SELECT count(*) FROM vend WHERE payment_ref = %s", (ref,))[0][0]
            if n == 0:
                time.sleep(0.2)                                   # call to the token engine
                tok = s.q("INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) "
                          "VALUES (%s, %s, 'BANK', 5000, 0, 1, 1) RETURNING token", (METER, ref))[0][0]
                s.commit(); out[name] = f"token {tok}"
        except errors.UniqueViolation as e:
            s.rollback(); out[name] = f"ERROR 23505 {e.diag.constraint_name} -> customer charged, no token shown"
        s.close()

    def idempotent(ref, name, out, bar):
        s = S(name); bar.wait()
        r = s.q("INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) VALUES (%s, %s, 'BANK', 5000, 0, 1, 1) "
                "ON CONFLICT (payment_ref) DO NOTHING RETURNING token", (METER, ref))
        if not r:                                                 # someone else already vended this payment
            r = s.q("SELECT token FROM vend WHERE payment_ref = %s", (ref,))
            out[name] = f"token {r[0][0]} (existing sale returned)"
        else:
            out[name] = f"token {r[0][0]} (new sale)"
        s.commit(); s.close()

    for label, fn, ref in (("check-then-insert (SELECT count, then INSERT)", naive, "DEMO-WH-0001"),
                           ("INSERT ... ON CONFLICT (payment_ref) DO NOTHING + read back", idempotent, "DEMO-WH-0002")):
        print(f"\n--- {label} ---", flush=True)
        out, bar = {}, threading.Barrier(2)
        th = [threading.Thread(target=fn, args=(ref, n, out, bar)) for n in ("WH-1", "WH-2")]
        [t.start() for t in th]; [t.join() for t in th]
        sales = admin("SELECT count(*) FROM vend WHERE payment_ref = %s", (ref,))[0][0]
        same = len({v.split()[1] for v in out.values() if v.startswith("token")}) == 1 and len(out) == 2 and all(v.startswith("token") for v in out.values())
        print(f"RESULT: WH-1: {out.get('WH-1')} | WH-2: {out.get('WH-2')} | sales recorded = {sales} | "
              f"both callers got the same token = {same}", flush=True)


# ---------------------------------------------------------------------------
def s2():
    banner("S2  BILL PAYMENT - the bakery pays 100,000 by app and 100,000 at the bank at the same moment (bill total 638,550)")
    bill = admin("SELECT bill_id FROM bill WHERE meter_no = '99000000002' AND period = '2026-10-01'")[0][0]

    def reset():
        admin("DELETE FROM payment WHERE bill_id = %s", (bill,)); admin("UPDATE bill SET paid = 0 WHERE bill_id = %s", (bill,))

    def pay(name, ref, amt, atomic, bar, out):
        s = S(name); bar.wait()
        try:
            s.q("INSERT INTO payment (bill_id, payment_ref, amount) VALUES (%s, %s, %s)", (bill, ref, amt))
            if atomic:
                s.q("UPDATE bill SET paid = paid + %s WHERE bill_id = %s RETURNING paid", (amt, bill))
            else:
                paid = s.q("SELECT paid FROM bill WHERE bill_id = %s", (bill,))[0][0]
                time.sleep(0.2)
                s.q("UPDATE bill SET paid = %s WHERE bill_id = %s", (paid + amt, bill))
            s.commit(); out[name] = "ok"
        except errors.CheckViolation:
            s.rollback(); out[name] = "rejected by CHECK bill_no_overpayment"
        s.close()

    def run(label, payments, atomic):
        print(f"\n--- {label} ---", flush=True)
        reset(); out, bar = {}, threading.Barrier(len(payments))
        th = [threading.Thread(target=pay, args=(n, r, a, atomic, bar, out)) for n, r, a in payments]
        [t.start() for t in th]; [t.join() for t in th]
        paid, total, s = admin("SELECT b.paid, b.energy + b.vat, coalesce((SELECT sum(amount) FROM payment p WHERE p.bill_id = b.bill_id), 0) "
                               "FROM bill b WHERE bill_id = %s", (bill,))[0]
        ok = "consistent" if paid == s else f"WRONG: {s - paid:,.2f} naira paid but not credited (LOST UPDATE)"
        print(f"RESULT: {out} | payments recorded = {s:,.2f}; bill.paid = {paid:,.2f} of {total:,.2f} => {ok}", flush=True)

    two = [("APP", "DEMO-S2-APP", 100000), ("BANK", "DEMO-S2-BANK", 100000)]
    run("read paid, add in the application, write it back", two, atomic=False)
    run("UPDATE bill SET paid = paid + amount (atomic)", two, atomic=True)
    run("three payments of 300,000 at once on a 638,550 bill (atomic) - the third would overpay",
        [("APP", "DEMO-S2-A", 300000), ("BANK", "DEMO-S2-B", 300000), ("POS", "DEMO-S2-C", 300000)], atomic=True)
    reset()
    admin("INSERT INTO payment (bill_id, payment_ref, amount) VALUES (%s, 'DEMO-BLP-0001', 300000)", (bill,))
    admin("UPDATE bill SET paid = 300000 WHERE bill_id = %s", (bill,))           # back to the state left by 01_...sql


# ---------------------------------------------------------------------------
def s3():
    banner("S3  TARIFF CHANGES DURING A SALE - Folake (band A, R2) is quoted, then pays; the tariff team commits a new rate in between")
    tid, old = admin("SELECT tariff_id, rate_per_kwh FROM tariff WHERE band = 'A' AND customer_class = 'R2' AND upper_inf(valid_during)")[0]
    new = old + 25
    for iso, label in ((ISOLATION_LEVEL_READ_COMMITTED, "READ COMMITTED"), (ISOLATION_LEVEL_REPEATABLE_READ, "REPEATABLE READ")):
        print(f"\n--- {label} ---", flush=True)
        admin("UPDATE tariff SET rate_per_kwh = %s WHERE tariff_id = %s", (old, tid))
        sale, adm = S("SALE", iso), S("TARIF")
        quote, q_rate = sale.q("SELECT round((10000 - round(10000 * 0.075 / 1.075, 2)) / rate_per_kwh, 2), rate_per_kwh "
                               "FROM tariff WHERE tariff_id = %s", (tid,))[0]
        log("SALE", f"  app shows: 10,000 naira buys {quote} kWh at {q_rate}/kWh - customer confirms ...")
        adm.q("UPDATE tariff SET rate_per_kwh = %s WHERE tariff_id = %s", (new, tid)); adm.commit()
        kwh, rate = sale.q("WITH v AS (INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh) "
                           "VALUES (%s, %s, 'APP', 10000, 0, 1, 1) RETURNING kwh, tariff_id) "
                           "SELECT v.kwh, t.rate_per_kwh FROM v JOIN tariff t USING (tariff_id)",
                           (METER, "DEMO-S3-" + ("RC" if iso == ISOLATION_LEVEL_READ_COMMITTED else "RR")))[0]
        sale.commit(); sale.close(); adm.close()
        verdict = "consistent" if kwh == quote else "INCONSISTENT: quoted one price, charged another (non-repeatable read)"
        print(f"RESULT ({label}): quoted {quote} kWh at {q_rate}; token issued for {kwh} kWh at {rate} => {verdict}", flush=True)
    admin("UPDATE tariff SET rate_per_kwh = %s WHERE tariff_id = %s", (old, tid))
    print("(tariff restored to", old, ")", flush=True)


# ---------------------------------------------------------------------------
def s4():
    banner("S4  LOCK WAITS - the billing job holds the bakery's bill for 3 s; customer care tries to add a 5,000 naira credit")
    bill = admin("SELECT bill_id FROM bill WHERE meter_no = '99000000002' AND period = '2026-10-01'")[0][0]
    for label, prefix in (("default: wait", ""), ("NOWAIT", "NOWAIT"), ("lock_timeout = 500ms", "TIMEOUT")):
        print(f"\n--- {label} ---", flush=True)
        job, care = S("BILL"), S("CARE")
        job.q("SELECT bill_id, paid FROM bill WHERE bill_id = %s FOR UPDATE", (bill,))
        threading.Timer(3.0, lambda: job.rollback()).start()
        t = time.time()
        try:
            if prefix == "TIMEOUT":
                care.q("SET lock_timeout = '500ms'")
            care.q(f"SELECT paid FROM bill WHERE bill_id = %s FOR UPDATE {'NOWAIT' if prefix == 'NOWAIT' else ''}", (bill,))
            care.rollback(); res = "got the lock"
        except errors.LockNotAvailable as e:
            care.rollback(); res = f"ERROR {e.pgcode} {str(e).strip().splitlines()[0]}"
        print(f"RESULT ({label}): {res} after {time.time() - t:.2f} s", flush=True)
        time.sleep(3.2 - (time.time() - t) if time.time() - t < 3.2 else 0)
        job.close(); care.close()


# ---------------------------------------------------------------------------
def s5():
    banner("S5  ARCHIVING NOVEMBER 2025 - a 2 s energy report is running; meters keep sending readings every 50 ms")
    meters = [r[0] for r in admin("SELECT meter_no FROM meter WHERE meter_type = 'POSTPAID' AND status = 'ACTIVE' ORDER BY meter_no LIMIT 40")]

    def readings(stop, lat):
        s = S("METER", ISOLATION_LEVEL_AUTOCOMMIT); i = 0
        while not stop.is_set():
            t = time.time()
            s.cur.execute("INSERT INTO meter_reading VALUES (%s, now() + %s * interval '1 microsecond', 1) ON CONFLICT DO NOTHING",
                          (meters[i % 40], i))
            lat.append(time.time() - t); i += 1; time.sleep(0.05)
        s.close()

    for label, sql in (("ALTER TABLE ... DETACH PARTITION", "ALTER TABLE meter_reading DETACH PARTITION meter_reading_2025_11"),
                       ("ALTER TABLE ... DETACH PARTITION CONCURRENTLY",
                        "ALTER TABLE meter_reading DETACH PARTITION meter_reading_2025_11 CONCURRENTLY")):
        print(f"\n--- {label} ---", flush=True)
        stop, lat = threading.Event(), []
        th = threading.Thread(target=readings, args=(stop, lat)); th.start(); time.sleep(0.5)
        rep = S("REPRT")
        rep.q("SELECT count(*) FROM meter_reading WHERE read_at >= '2026-10-01 00:00+01'")   # holds ACCESS SHARE until commit
        threading.Timer(2.0, lambda: rep.commit()).start()
        adm = S("ADMIN", ISOLATION_LEVEL_AUTOCOMMIT); t = time.time()
        adm.q(sql)
        log("ADMIN", f"  detach finished after {time.time() - t:.2f} s")
        time.sleep(0.5); stop.set(); th.join()
        n_partitions = admin("SELECT count(*) FROM pg_inherits WHERE inhparent = 'meter_reading'::regclass")[0][0]
        print(f"RESULT ({label}): {len(lat)} readings inserted; slowest insert {max(lat) * 1000:.0f} ms, median {statistics.median(lat) * 1000:.1f} ms; "
              f"partitions now attached = {n_partitions}", flush=True)
        adm.q("ALTER TABLE meter_reading ATTACH PARTITION meter_reading_2025_11 "
              "FOR VALUES FROM ('2025-11-01 00:00+01') TO ('2025-12-01 00:00+01')", show=False)
        adm.close(); rep.close()
    admin("DELETE FROM meter_reading WHERE kwh_total = 1 AND read_at > now() - interval '1 hour'")


# ---------------------------------------------------------------------------
def s6():
    banner("S6  MONTH-END REPORT - total revenue, then revenue by channel, while the app keeps selling tokens")
    stop = threading.Event()

    def sell():
        s = S("SALES", ISOLATION_LEVEL_AUTOCOMMIT); i = 0
        while not stop.is_set():
            s.cur.execute("INSERT INTO vend (meter_no, payment_ref, channel, amount, vat, tariff_id, kwh, vended_at) "
                          "VALUES (%s, %s, 'APP', 1000, 0, 1, 1, '2026-11-12 23:00+01')", (METER, f"DEMO-S6-{time.time_ns()}"))
            i += 1; time.sleep(0.005)
        s.close()

    th = threading.Thread(target=sell); th.start(); time.sleep(0.3)
    for iso, label in ((ISOLATION_LEVEL_READ_COMMITTED, "READ COMMITTED"), (ISOLATION_LEVEL_REPEATABLE_READ, "REPEATABLE READ")):
        print(f"\n--- {label} ---", flush=True)
        r = S("REPRT", iso)
        total = r.q("SELECT sum(amount) FROM vend WHERE vended_at >= '2026-11-01 00:00+01'")[0][0]
        time.sleep(0.5)                                            # the report's other sections run
        by_ch = r.q("SELECT sum(s) FROM (SELECT channel, sum(amount) s FROM vend WHERE vended_at >= '2026-11-01 00:00+01' GROUP BY channel) x")[0][0]
        r.commit(); r.close()
        print(f"RESULT ({label}): total line {total:,.2f}; sum of channel lines {by_ch:,.2f} => "
              f"{'totals agree' if total == by_ch else f'REPORT DOES NOT ADD UP (difference {by_ch - total:,.2f})'}", flush=True)
    stop.set(); th.join()
    n = admin("DELETE FROM vend WHERE payment_ref LIKE 'DEMO-S6-%' RETURNING 1")
    print(f"(removed {len(n)} demo sales made during S6)", flush=True)


if __name__ == "__main__":
    admin("DELETE FROM vend WHERE payment_ref LIKE 'DEMO-WH-%' OR payment_ref LIKE 'DEMO-S3-%' OR payment_ref LIKE 'DEMO-S6-%'")
    admin("DELETE FROM payment WHERE payment_ref LIKE 'DEMO-S2-%'")
    for f in (s1, s2, s3, s4, s5, s6):
        f()
    print("\nAll scenarios completed.", flush=True)
