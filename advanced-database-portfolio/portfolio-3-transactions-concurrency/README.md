# Portfolio 3 — Transaction Management and Concurrency Control

Case study: **VoltGrid Power**. Money and electricity meet in the database. A customer is charged and must receive a token. A bank may send the same payment notification twice. Bills are paid from several channels at once. Tariffs change while customers are buying, and old meter readings must be archived without stopping the meters that are sending new ones. All scenarios below ran against the Portfolio 1 database (PostgreSQL 16), using real, separate database sessions.

| File | Purpose |
|---|---|
| [`00_demo_setup.sql`](00_demo_setup.sql) | demo customers and meters (prepaid ACTIVE, postpaid bakery, prepaid SUSPENDED), the bakery's October bill, and two helper tables: `sms_outbox` and `settlement_exception` |
| [`01_commit_rollback_savepoint.sql`](01_commit_rollback_savepoint.sql) | 6 single-session transaction cases → [`evidence/01_commit_rollback_savepoint_output.txt`](evidence/01_commit_rollback_savepoint_output.txt) |
| [`concurrency_demo.py`](concurrency_demo.py) | 6 concurrency scenarios with threads and barriers, timestamped → [`evidence/concurrency_demo_output.txt`](evidence/concurrency_demo_output.txt) |

## 1. Atomicity — COMMIT, ROLLBACK and SAVEPOINT

| Case | Situation | Result (from the transcript) |
|---|---|---|
| 1 | Folake buys ₦5,000 of units. The sale **and** the SMS carrying the token are written in one transaction (*transactional outbox*) → `COMMIT` | the trigger priced it: VAT ₦348.84, **20.67 kWh** at ₦225.00/kWh; 1 SMS queued. An SMS can never exist for a sale that did not happen, and a sale never exists without its SMS |
| 2 | the bank reverses the card payment before confirmation → `ROLLBACK` | inside the transaction 2 sales were visible; afterwards 1 sale and 1 SMS remain. No token leaked |
| 3 | the bakery pays ₦300,000 of its ₦638,550 bill: `INSERT payment` + `UPDATE bill.paid` → `COMMIT` | paid 300,000, outstanding 338,550, and the sum of payments equals `bill.paid` |
| 4 | a second transfer of ₦400,000 would overpay | `UPDATE bill` violates `CHECK bill_no_overpayment`; the transaction is aborted and `COMMIT` becomes `ROLLBACK`, so **the payment row inserted before it is gone too** (still 1 payment, paid 300,000) |
| 5 | a bank settlement file with 3 lines; line 2 is for a **SUSPENDED** meter | `SAVEPOINT` per line: line 2's trigger error is undone with `ROLLBACK TO SAVEPOINT line2` and logged in `settlement_exception` for a refund; lines 1 and 3 commit (12.40 and 8.27 kWh) |
| 6 | tariff review: close the open band A/R2 version, open a new one from 1 Jan 2027 | **6a** inserting the new version *first* overlaps the open-ended current one (`tariff_no_overlap`), so the change is rolled back. **6b** closing the old version first, then inserting, succeeds inside one transaction. Nobody ever sees a day with no tariff or with two tariffs (rolled back afterwards; the demo does not change real prices) |

## 2. Concurrency scenarios (real concurrent sessions)

| # | Scenario | Unsafe version | Safe version |
|---|---|---|---|
| S1 | the bank's webhook delivers the **same payment twice**, 1 ms apart | *check-then-insert*: both sessions see "no sale yet". The second blocks on the unique index until the first commits, then gets **ERROR 23505**: the customer was charged and shown an error | `INSERT … ON CONFLICT (payment_ref) DO NOTHING RETURNING token`, and if nothing is returned, read the existing sale: **both callers receive the same token**, 1 sale recorded. The unique key makes the operation **idempotent** |
| S2 | the bakery pays ₦100,000 by app and ₦100,000 at the bank at the same moment | read `paid`, add in Python, write back: 2 payments recorded (₦200,000) but `bill.paid` = ₦100,000. A **lost update** of ₦100,000 | `UPDATE bill SET paid = paid + amount`: the row lock serialises the two updates, so `paid` = ₦200,000. With **three** ₦300,000 payments on the ₦638,550 bill, two succeed and the third is **rejected by the CHECK constraint**: the rule holds even under concurrency |
| S3 | the tariff team commits a new rate (₦225 → ₦250) **between** the quote and the payment | READ COMMITTED: quoted **41.34 kWh** at ₦225, token issued for **37.21 kWh** at ₦250. A **non-repeatable read** inside one sale | REPEATABLE READ: quote and token both use ₦225 (41.34 kWh), because the whole sale sees one snapshot. The new price applies to the next sale |
| S4 | the billing job holds the bakery's bill (`FOR UPDATE`) for 3 s; customer care wants to add a credit | default: customer care **waits 3.00 s**, with the screen frozen | `NOWAIT`: fails **at once** (55P03) and the screen can say "bill is being processed, try again". `lock_timeout = 500ms`: gives up after **0.50 s**. The application chooses how long it is prepared to wait |
| S5 | archive November 2025 while a 2 s energy report runs and meters send readings every 50 ms | `DETACH PARTITION` needs an ACCESS EXCLUSIVE lock. It queues behind the report's lock, and **every new meter reading queues behind it**: slowest insert **1,963 ms**, only 21 readings stored | `DETACH PARTITION CONCURRENTLY` takes a weaker lock: readings continue, slowest insert **7 ms**, 59 readings stored. Both detaches finished when the report did (2.00 s) |
| S6 | month-end report: a "total revenue" line, then "revenue by channel", while the app keeps selling | READ COMMITTED: each statement sees new sales, so the total is ₦379,301,000 but the channel lines add up to ₦379,386,000. **The report does not add up** (₦85,000 difference) | REPEATABLE READ: both lines are ₦379,392,000. A multi-statement report needs one snapshot |

## 3. Analysis

- **Idempotency is a database rule, not an application habit (S1).** Payment systems deliver notifications *at least once*, so duplicates are normal. The check-then-insert pattern looks correct, but there is always a gap between the check and the insert. The `UNIQUE (payment_ref)` constraint closes that gap, and `ON CONFLICT` turns a duplicate from an error into "return the earlier result".
- **Let the database do the arithmetic (S2).** `paid = paid + x` is computed under the row lock, while a value read earlier and written back is not. The `CHECK (paid <= energy + vat)` constraint is checked on the *final* value of each update, so it stops an overpayment even when three payments race.
- **Choose the isolation level for each transaction (S3, S6).** The default READ COMMITTED is right for short single-statement work such as one sale. A *quote-then-charge* flow, or a report made of several queries, needs REPEATABLE READ so that all its statements agree. Neither scenario needed SERIALIZABLE, because nothing was written based on a rule over many rows.
- **Lock waiting is a design decision (S4, S5).** A screen should not freeze for as long as a batch job runs, so `NOWAIT` or `lock_timeout` give a quick, explainable error. S5 showed the most dangerous effect: a DDL statement that is *waiting* for a lock already blocks everyone who arrives after it. Maintenance on busy tables should use the `CONCURRENTLY` variants and a `lock_timeout`.
- **Recovery and durability:** a committed sale is in the WAL before `COMMIT` returns. Case 2 and Case 4 show that nothing from an aborted transaction remains. Portfolio 5 tests what happens to committed sales when the server itself fails.

## How to run

```bash
psql -h localhost -U postgres -d voltgrid -f 00_demo_setup.sql
psql -h localhost -U postgres -d voltgrid -e -f 01_commit_rollback_savepoint.sql > evidence/01_commit_rollback_savepoint_output.txt 2>&1
pip install psycopg2-binary
python3 concurrency_demo.py > evidence/concurrency_demo_output.txt     # about 25 seconds; restores the tariff, bill and partitions
```
