MIT 8103 ADVANCED DATABASE SYSTEMS - PRACTICAL DATABASE PORTFOLIO
Student    : Precious Siyanbola
Student ID : 301926114
Programme  : Master of Information Technology, Miva Open University
Session    : 2026/2027 First Semester Continuous Assessment
Case study : VoltGrid Power (simulated Nigerian electricity distribution company: Lagos, Ogun, Oyo)
GitHub     : https://github.com/<your-username>/advanced-database-portfolio   (private; assessor added as collaborator)

FILES IN THIS SUBMISSION
  Siyanbola_Precious_301926114_Documentation.docx         2-3 page LMS documentation (Word)
  Siyanbola_Precious_301926114_Documentation.pdf          same document as PDF
  Siyanbola_Precious_301926114_Portfolio_Repository.zip   full copy of the GitHub repository
  Siyanbola_Precious_301926114_README.txt                 this file

REPOSITORY CONTENTS (advanced-database-portfolio/)
  README.md                                  overview, case study, environment, how to run everything
  portfolio-1-database-design/               ERD (dot/png/svg), schema DDL with pricing trigger, exclusion constraints and monthly partitions, seed data, 13 constraint tests, seed-rule checks
  portfolio-2-query-optimisation/            5 workload queries, 2 optimisation rounds (partition pruning, MV, anti-join), benchmark harness, 15 execution plans
  portfolio-3-transactions-concurrency/      demo setup, 6 transaction cases (outbox, savepoints, tariff versions), 6 concurrency scenarios
  portfolio-4-nosql/                         Redis (rate limit, idempotency, bitmaps, status board), JSONB work orders, MongoDB-API version
  portfolio-5-distributed-cloud/             5-node lab: hash sharding, sync/async replication, delayed standby recovery, failover, cloud design
  Every portfolio folder has a README.md (what, how tested, results) and an evidence/ folder (raw outputs, screenshots).

SOFTWARE
  PostgreSQL 16, Redis 7, Python 3 (psycopg2-binary, redis, pymongo, mongomock, matplotlib), Graphviz.

QUICK START
  createdb voltgrid
  psql -d voltgrid -f portfolio-1-database-design/01_schema.sql
  psql -d voltgrid -f portfolio-1-database-design/02_seed_data.sql
  then follow the order given in README.md.

AI USE
  Declared in Section 6 of the documentation.
