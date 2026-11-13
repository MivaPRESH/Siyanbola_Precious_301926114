-- =====================================================================
-- MIT 8103 - Portfolio 1 : VoltGrid Power - electricity distribution company
-- Prepaid token vending, postpaid metering and billing, feeder outages.
-- PostgreSQL 16.   Run: psql -h localhost -d voltgrid -f 01_schema.sql
-- =====================================================================
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS btree_gist;     -- '=' on scalar columns inside GiST exclusion constraints
DROP SCHEMA IF EXISTS voltgrid CASCADE;
CREATE SCHEMA voltgrid;
SET search_path TO voltgrid, public;

-- ---------------------------------------------------------------- network
CREATE TABLE business_unit (
    bu_id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bu_code  CHAR(3)     NOT NULL UNIQUE CHECK (bu_code ~ '^[A-Z]{3}$'),
    bu_name  VARCHAR(40) NOT NULL,
    state    VARCHAR(10) NOT NULL CHECK (state IN ('Lagos', 'Ogun', 'Oyo'))
);

-- NERC "service-based tariff": a feeder's band is set by the hours of supply it is meant to deliver
-- (A >= 20 h/day, B >= 16 h, C >= 12 h, D >= 8 h, E >= 4 h)
CREATE TABLE feeder (
    feeder_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bu_id       SMALLINT    NOT NULL REFERENCES business_unit,
    feeder_code VARCHAR(12) NOT NULL UNIQUE,
    voltage_kv  SMALLINT    NOT NULL CHECK (voltage_kv IN (11, 33)),
    band        CHAR(1)     NOT NULL CHECK (band IN ('A', 'B', 'C', 'D', 'E'))
);

CREATE TABLE transformer (
    dt_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feeder_id    SMALLINT    NOT NULL REFERENCES feeder,
    dt_code      VARCHAR(14) NOT NULL UNIQUE,
    capacity_kva SMALLINT    NOT NULL CHECK (capacity_kva IN (100, 200, 300, 500))
);

-- tariff versions: the price per kWh for a band and customer class over a period of dates.
-- Two versions of the same band+class may never be valid on the same day.
CREATE TABLE tariff (
    tariff_id      SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    band           CHAR(1)      NOT NULL CHECK (band IN ('A', 'B', 'C', 'D', 'E')),
    customer_class VARCHAR(3)   NOT NULL CHECK (customer_class IN ('R2', 'C1', 'C2', 'D1')),
    rate_per_kwh   NUMERIC(7,2) NOT NULL CHECK (rate_per_kwh > 0),
    valid_during   DATERANGE    NOT NULL CHECK (NOT isempty(valid_during)),
    CONSTRAINT tariff_no_overlap EXCLUDE USING gist (band WITH =, customer_class WITH =, valid_during WITH &&)
);

-- ---------------------------------------------------------------- customers and meters
CREATE TABLE customer (
    customer_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_no     CHAR(12)    NOT NULL UNIQUE CHECK (account_no ~ '^VG[0-9]{10}$'),
    full_name      VARCHAR(80) NOT NULL,
    phone          VARCHAR(14) CHECK (phone ~ '^\+234[789][01][0-9]{8}$'),
    customer_class VARCHAR(3)  NOT NULL CHECK (customer_class IN ('R2', 'C1', 'C2', 'D1')),
    bu_id          SMALLINT    NOT NULL REFERENCES business_unit,
    address        VARCHAR(120) NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE meter (
    meter_no     CHAR(11)    PRIMARY KEY CHECK (meter_no ~ '^[0-9]{11}$'),
    customer_id  INT         NOT NULL REFERENCES customer,
    dt_id        INT         NOT NULL REFERENCES transformer,
    meter_type   VARCHAR(8)  NOT NULL CHECK (meter_type IN ('PREPAID', 'POSTPAID')),
    status       VARCHAR(10) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'SUSPENDED', 'REMOVED')),
    installed_on DATE        NOT NULL
);

-- ---------------------------------------------------------------- prepaid token vending
-- payment_ref is the payment provider's reference: UNIQUE makes vending IDEMPOTENT, so a
-- payment notification that arrives twice can never produce two tokens.
CREATE TABLE vend (
    vend_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meter_no    CHAR(11)      NOT NULL REFERENCES meter,
    payment_ref VARCHAR(30)   NOT NULL UNIQUE,
    channel     VARCHAR(5)    NOT NULL CHECK (channel IN ('APP', 'BANK', 'POS', 'USSD', 'AGENT')),
    amount      NUMERIC(10,2) NOT NULL CHECK (amount BETWEEN 500 AND 1000000),   -- naira paid, VAT inclusive
    vat         NUMERIC(10,2) NOT NULL,
    tariff_id   SMALLINT      NOT NULL REFERENCES tariff,
    kwh         NUMERIC(9,2)  NOT NULL CHECK (kwh > 0),
    token       CHAR(20)      NOT NULL UNIQUE CHECK (token ~ '^[0-9]{20}$'),
    vended_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT vend_vat_7_5_pct CHECK (vat = round(amount * 0.075 / 1.075, 2))
);

-- Rules that need OTHER tables, so they cannot be CHECK constraints:
--   * only an ACTIVE PREPAID meter can buy a token
--   * the tariff is the one valid that day for the meter's feeder band and the customer's class
--   * VAT and kWh are computed by the database, never trusted from the client
CREATE FUNCTION vend_price() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE m RECORD; t RECORD;
BEGIN
    SELECT me.meter_type, me.status, f.band, c.customer_class INTO m
    FROM meter me JOIN transformer dt USING (dt_id) JOIN feeder f USING (feeder_id) JOIN customer c USING (customer_id)
    WHERE me.meter_no = NEW.meter_no;
    IF NOT FOUND THEN
        RETURN NEW;                                       -- the foreign key will reject it
    ELSIF m.meter_type <> 'PREPAID' THEN
        RAISE EXCEPTION 'meter % is %: tokens are only sold to prepaid meters', NEW.meter_no, m.meter_type
              USING ERRCODE = 'check_violation';
    ELSIF m.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'meter % is %: vending blocked', NEW.meter_no, m.status USING ERRCODE = 'check_violation';
    END IF;
    SELECT tariff_id, rate_per_kwh INTO t FROM tariff
    WHERE band = m.band AND customer_class = m.customer_class
      AND valid_during @> (NEW.vended_at AT TIME ZONE 'Africa/Lagos')::date;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no tariff for band % class % on %', m.band, m.customer_class, NEW.vended_at::date
              USING ERRCODE = 'check_violation';
    END IF;
    NEW.tariff_id := t.tariff_id;
    NEW.vat       := round(NEW.amount * 0.075 / 1.075, 2);
    NEW.kwh       := round((NEW.amount - NEW.vat) / t.rate_per_kwh, 2);
    IF NEW.token IS NULL THEN                             -- 20-digit STS-style token
        NEW.token := lpad(floor(random() * 1e10)::bigint::text, 10, '0') || lpad(floor(random() * 1e10)::bigint::text, 10, '0');
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_vend_price BEFORE INSERT ON vend FOR EACH ROW EXECUTE FUNCTION vend_price();

-- ---------------------------------------------------------------- postpaid metering and billing
-- Daily cumulative readings from postpaid (maximum-demand) meters: the largest table, so it is
-- RANGE-PARTITIONED by month. Old months can be detached and archived; queries on one month
-- touch one partition (partition pruning, Portfolio 2).
CREATE TABLE meter_reading (
    meter_no  CHAR(11)      NOT NULL REFERENCES meter,
    read_at   TIMESTAMPTZ   NOT NULL,
    kwh_total NUMERIC(11,1) NOT NULL CHECK (kwh_total >= 0),
    PRIMARY KEY (meter_no, read_at)
) PARTITION BY RANGE (read_at);
DO $$
DECLARE m DATE;
BEGIN
    FOR m IN SELECT generate_series(DATE '2025-11-01', DATE '2026-11-01', interval '1 month')::date LOOP
        EXECUTE format('CREATE TABLE meter_reading_%s PARTITION OF meter_reading FOR VALUES FROM (%L) TO (%L)',
                       to_char(m, 'YYYY_MM'), m::timestamp AT TIME ZONE 'Africa/Lagos',
                       (m + interval '1 month')::timestamp AT TIME ZONE 'Africa/Lagos');
    END LOOP;
END $$;
-- no DEFAULT partition on purpose: a reading dated outside the known months is rejected, not hidden

CREATE TABLE bill (
    bill_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meter_no  CHAR(11)      NOT NULL REFERENCES meter,
    period    DATE          NOT NULL CHECK (period = date_trunc('month', period)::date),
    kwh       NUMERIC(10,1) NOT NULL CHECK (kwh >= 0),
    tariff_id SMALLINT      NOT NULL REFERENCES tariff,
    energy    NUMERIC(12,2) NOT NULL CHECK (energy >= 0),
    vat       NUMERIC(12,2) NOT NULL CHECK (vat >= 0),
    paid      NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_date  DATE          NOT NULL,
    UNIQUE (meter_no, period),
    CONSTRAINT bill_no_overpayment CHECK (paid >= 0 AND paid <= energy + vat)
);

CREATE TABLE payment (
    payment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bill_id     BIGINT        NOT NULL REFERENCES bill,
    payment_ref VARCHAR(30)   NOT NULL UNIQUE,
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- outages
-- restored_at NULL = still out. One feeder cannot have two outages at the same moment.
CREATE TABLE outage (
    outage_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feeder_id   SMALLINT    NOT NULL REFERENCES feeder,
    started_at  TIMESTAMPTZ NOT NULL,
    restored_at TIMESTAMPTZ,
    cause       VARCHAR(13) NOT NULL CHECK (cause IN ('FAULT', 'LOAD_SHEDDING', 'MAINTENANCE', 'GRID_COLLAPSE')),
    CONSTRAINT outage_restored_after_start CHECK (restored_at > started_at),
    CONSTRAINT outage_no_overlap EXCLUDE USING gist (feeder_id WITH =, tstzrange(started_at, restored_at) WITH &&)
);

-- ---------------------------------------------------------------- convenience view (derived data is not stored)
CREATE VIEW v_meter AS
SELECT me.meter_no, me.meter_type, me.status, c.account_no, c.full_name, c.customer_class,
       f.feeder_code, f.band, b.bu_code, b.state
FROM meter me JOIN customer c USING (customer_id) JOIN transformer dt USING (dt_id)
JOIN feeder f USING (feeder_id) JOIN business_unit b ON b.bu_id = f.bu_id;
