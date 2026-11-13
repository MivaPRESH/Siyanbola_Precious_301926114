"""
MIT 8103 - Portfolio 2 : before / round-1 / round-2 benchmark harness.

Phases
  baseline : no secondary indexes, default planner settings
  round1   : optimisations_round1.sql (vend index, dashboard MV) + sargable rewrites of Q2 and Q5
  round2   : optimisations_round2.sql (SSD costs) + VACUUM + Q4 rewritten as an index anti-join

For each query and phase: one warm-up run (discarded) then RUNS x EXPLAIN (ANALYZE, BUFFERS);
the median execution time is reported and the plan is saved to plans/<Q>_<phase>.txt.
Rewritten queries (Q2, Q3, Q5 from round1; Q4 in round2) are checked to return EXACTLY the same rows
as the original query, so the optimisation does not change the answer.

Outputs: plans/*.txt, evidence/benchmark_results.csv, evidence/benchmark_chart.png,
         evidence/result_equivalence.txt
Usage:   python3 run_benchmark.py
"""
import csv, os, re, statistics
import psycopg2

HERE = os.path.dirname(os.path.abspath(__file__))
DSN = os.environ.get("VOLTGRID_DSN", "host=localhost dbname=voltgrid user=postgres")
RUNS = 7
PHASES = os.environ.get("PHASES", "baseline,round1,round2").split(",")

RESET = """
SET search_path TO voltgrid, public;
DROP INDEX IF EXISTS ix_vend_meter_time, ix_vend_active_meter_cover;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_vend_revenue;
ALTER DATABASE voltgrid RESET random_page_cost;
ALTER DATABASE voltgrid RESET effective_cache_size;
ANALYZE;
"""

Q2_PRUNED = """
WITH m AS (
  SELECT meter_no, max(kwh_total) - min(kwh_total) AS kwh
  FROM   meter_reading
  WHERE  read_at >= timestamptz '2026-10-01 00:00+01' AND read_at < timestamptz '2026-11-01 00:00+01'
  GROUP  BY meter_no)
SELECT vm.bu_code, vm.band, count(*) AS meters, round(sum(m.kwh)) AS kwh
FROM   m JOIN v_meter vm USING (meter_no)
GROUP  BY vm.bu_code, vm.band
ORDER  BY vm.bu_code, vm.band;"""

Q3_MV = """
SELECT bu_code, channel, month, vends, revenue, kwh
FROM   mv_monthly_vend_revenue
WHERE  month >= date '2026-01-01'
ORDER  BY bu_code, channel, month;"""

Q5_RANGE = """
SELECT f.feeder_code, b.bu_code,
       round(24 - coalesce(sum(extract(epoch FROM
             LEAST(coalesce(o.restored_at, timestamptz '2026-11-12 00:00+01'), timestamptz '2026-11-12 00:00+01')
           - GREATEST(o.started_at, timestamptz '2026-10-13 00:00+01'))), 0) / 3600 / 30, 2) AS avg_supply_hours
FROM   feeder f
JOIN   business_unit b ON b.bu_id = f.bu_id
LEFT   JOIN outage o ON o.feeder_id = f.feeder_id
                    AND tstzrange(o.started_at, o.restored_at)
                     && tstzrange(timestamptz '2026-10-13 00:00+01', timestamptz '2026-11-12 00:00+01')
WHERE  f.band = 'A'
GROUP  BY f.feeder_code, b.bu_code
ORDER  BY avg_supply_hours, f.feeder_code;"""

Q4_ANTI = """
SELECT vm.bu_code, vm.feeder_code, vm.meter_no, vm.full_name, lv.last_vend
FROM   v_meter vm
CROSS  JOIN LATERAL (SELECT max(x.vended_at) AS last_vend FROM vend x WHERE x.meter_no = vm.meter_no) lv
WHERE  vm.meter_type = 'PREPAID' AND vm.status = 'ACTIVE'
AND    NOT EXISTS (SELECT 1 FROM vend v WHERE v.meter_no = vm.meter_no
                   AND v.vended_at >= timestamptz '2026-11-12 23:59+01' - interval '90 days')
ORDER  BY lv.last_vend NULLS FIRST, vm.meter_no
LIMIT  50;"""

REWRITES = {("Q4", "round2"): Q4_ANTI}
for ph in ("round1", "round2"):
    REWRITES[("Q2", ph)] = Q2_PRUNED
    REWRITES[("Q3", ph)] = Q3_MV
    REWRITES[("Q5", ph)] = Q5_RANGE


def load_queries():
    text = open(os.path.join(HERE, "queries.sql")).read()
    parts = re.split(r"^-- @(Q\d) (.*)$", text, flags=re.M)
    return {parts[i]: (parts[i + 1].strip(), parts[i + 2].strip()) for i in range(1, len(parts), 3)}


def new_conn():
    # new connection per phase so ALTER DATABASE settings take effect
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET search_path TO voltgrid, public")
    return conn, cur


def run_explain(cur, sql):
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql)
    return cur.fetchone()[0][0]


def measure(cur, sql):
    run_explain(cur, sql)                                    # warm-up
    js = [run_explain(cur, sql) for _ in range(RUNS)]
    times = [j["Execution Time"] for j in js]
    cur.execute("EXPLAIN (ANALYZE, BUFFERS) " + sql)
    text = "\n".join(r[0] for r in cur.fetchall())
    root = js[-1]["Plan"]
    blocks = root.get("Shared Hit Blocks", 0) + root.get("Shared Read Blocks", 0)
    return statistics.median(times), min(times), max(times), js[-1]["Planning Time"], blocks, text


def plan_nodes(text):
    found = re.findall(r"(Parallel Seq Scan|Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan|Hash Join|"
                       r"Nested Loop|Merge Join)(?: (?:on|using) (\w+))?", text)
    out = []
    for node, obj in found:
        label = f"{node} {obj}".strip()
        if label not in out:
            out.append(label)
    return "; ".join(out[:5])



def main():
    queries = load_queries()
    os.makedirs(os.path.join(HERE, "plans"), exist_ok=True)
    os.makedirs(os.path.join(HERE, "evidence"), exist_ok=True)
    results, equivalence = {}, []

    for phase in PHASES:
        conn, cur = new_conn()
        if phase == "baseline":
            cur.execute(RESET)
        elif phase == "round1":
            cur.execute(open(os.path.join(HERE, "optimisations_round1.sql")).read())
        else:
            cur.execute(open(os.path.join(HERE, "optimisations_round2.sql")).read())
            cur.execute("VACUUM ANALYZE voltgrid.vend")              # visibility map for index-only scans
        conn.close()
        conn, cur = new_conn()
        cur.execute("SHOW random_page_cost")
        rpc = cur.fetchone()[0]

        for qid, (title, sql) in queries.items():
            run_sql = REWRITES.get((qid, phase), sql)
            if run_sql is not sql:
                cur.execute(sql); original = cur.fetchall()
                cur.execute(run_sql); rewritten = cur.fetchall()
                equivalence.append(f"{qid} {phase}: original rows={len(original)}, rewritten rows={len(rewritten)}, "
                                   f"identical={original == rewritten}")
            med, lo, hi, plan_ms, blocks, text = measure(cur, run_sql)
            header = (f"-- {qid} [{phase}] {title}\n"
                      f"-- random_page_cost={rpc}; median of {RUNS} warm runs: {med:.3f} ms (min {lo:.3f}, max {hi:.3f}); "
                      f"planning {plan_ms:.3f} ms; shared buffers touched: {blocks}\n"
                      f"-- SQL executed:\n" + "\n".join("--   " + l for l in run_sql.strip().splitlines()) + "\n\n")
            with open(os.path.join(HERE, "plans", f"{qid}_{phase}.txt"), "w") as f:
                f.write(header + text + "\n")
            results.setdefault(qid, {"title": title})[phase] = (med, blocks, plan_nodes(text))
            print(f"{qid} {phase:8s} {med:10.3f} ms  buffers {blocks:6d}  {plan_nodes(text)}")

        conn.close()

    with open(os.path.join(HERE, "evidence", "result_equivalence.txt"), "w") as f:
        f.write("Rewritten queries must return exactly the same rows as the originals\n" + "\n".join(equivalence) + "\n")

    with open(os.path.join(HERE, "evidence", "benchmark_results.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["query", "description"] + [f"{p}_ms" for p in PHASES] + ["overall_speedup_x"]
                   + [f"{p}_buffers" for p in PHASES] + [f"{p}_plan" for p in PHASES])
        for qid, r in results.items():
            w.writerow([qid, r["title"]] + [f"{r[p][0]:.3f}" for p in PHASES]
                       + [f"{r['baseline'][0] / r['round2'][0]:.1f}"]
                       + [r[p][1] for p in PHASES] + [r[p][2] for p in PHASES])

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    qids = list(results)
    colors = {"baseline": "#94a3b8", "round1": "#60a5fa", "round2": "#1d4ed8"}
    labels = {"baseline": "Baseline (PK/unique indexes only)", "round1": "Round 1: vend index, MV, sargable rewrites",
              "round2": "Round 2: SSD costs, VACUUM, Q4 anti-join"}
    fig, ax = plt.subplots(figsize=(8.5, 4.3), dpi=150)
    w = 0.27
    for k, p in enumerate(PHASES):
        vals = [results[q][p][0] for q in qids]
        ax.bar([i + (k - 1) * w for i in range(len(qids))], vals, width=w, color=colors[p], label=labels[p])
    for i, q in enumerate(qids):
        sp = results[q]["baseline"][0] / results[q]["round2"][0]
        ax.text(i + w, results[q]["round2"][0] * 1.25, f"{sp:,.0f}x" if sp >= 2 else f"{sp:.1f}x",
                ha="center", fontsize=8, color="#1e293b")
    ax.set_yscale("log")
    ax.set_xticks(range(len(qids)))
    ax.set_xticklabels([f"{q}" for q in qids])
    ax.set_ylabel("Median execution time, ms (log scale)")
    ax.set_title("VoltGrid workload - execution time per optimisation round", fontsize=11)
    ax.spines[["top", "right"]].set_visible(False)
    ax.legend(frameon=False, fontsize=8, loc="upper right")
    fig.tight_layout()
    fig.savefig(os.path.join(HERE, "evidence", "benchmark_chart.png"))
    print("done")


if __name__ == "__main__":
    main()
