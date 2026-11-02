-- Trade OLTP table for Slice 2a CDC demo (docs/specs/slice2a-cdc-ingestion.md §3.1 / §4 items 3-4).
--
-- No NOT NULL / CHECK constraints on purpose: the quality gate for this slice lives
-- downstream at the Schema Registry (§6), not at the source DB. Constraints here would
-- block the dirty-data injection path (generate_trade_data.py --dirty-rate) from ever
-- reaching the pipeline, defeating the later DLQ/rejection tests (§4 items 8-9).
CREATE TABLE IF NOT EXISTS trade (
    trade_id    TEXT PRIMARY KEY,
    account_id  TEXT,
    symbol      TEXT,
    price       NUMERIC(12, 2),
    quantity    INTEGER,
    side        TEXT,
    status      TEXT,
    event_time  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ
);

-- Postgres logical replication only guarantees the primary key in the UPDATE/DELETE
-- "before" image by default; REPLICA IDENTITY FULL is required so Debezium captures
-- every column's old value, which §7's "before/after 影像" acceptance criterion needs.
ALTER TABLE trade REPLICA IDENTITY FULL;

-- Heartbeat table for the Debezium connector (see infra/environments/dev-slice2/msk_connector.tf).
-- RDS writes a 64MB WAL segment every archive_timeout (300s) even when idle, but the
-- replication slot only advances when Debezium confirms a position, which it does only
-- after seeing a change on a captured table. Without a periodic write the slot pins
-- restart_lsn and WAL piles up until the disk is full. A real write (not SELECT 1) is
-- required so a WAL record exists for Debezium to acknowledge.
CREATE TABLE IF NOT EXISTS debezium_heartbeat (
    id  INTEGER PRIMARY KEY,
    ts  TIMESTAMPTZ
);
