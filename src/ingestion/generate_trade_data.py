#!/usr/bin/env python3
"""Simulate a trade order state machine against the Slice2a source OLTP DB.

Unlike generate_stock_data.py (which only produces CSV files), this generator writes
directly to a live Postgres table -- Debezium's CDC capture reads the database's WAL,
not files, so the source data has to actually land in a real table for the pipeline
downstream of this script to have anything to capture.

Deployed as a Lambda (see infra/environments/dev-slice2/lambda.tf) because the RDS
instance lives in a private subnet with no IGW/NAT; the Lambda runs inside the VPC and
is triggered over the public Lambda API (`aws lambda invoke`), so nothing needs a direct
network path into the VPC. `pg8000` (pure Python, no C extension) is used instead of
psycopg specifically so the deployment zip needs no cross-platform build step for
Lambda's Amazon Linux runtime.

See docs/specs/slice2a-cdc-ingestion.md §3.1 / §4 items 3-4.
"""

import argparse
import os
import random
import time
from pathlib import Path

import pg8000

SYMBOLS = ["2330", "2454", "3653"]
SIDES = ["BUY", "SELL"]
INVALID_SYMBOLS = ["9999", "0000", "ABCD"]

# Same rough magnitudes as generate_stock_data.py's BASE_PRICES, kept independent since
# the two generators aren't meant to share state.
BASE_PRICES = {
    "2330": 600.0,
    "2454": 900.0,
    "3653": 150.0,
}
DEFAULT_BASE_PRICE = 500.0

# One kind per §6 rule dimension: negative_price/zero_quantity/invalid_side -> validity;
# null_account_id -> completeness; invalid_symbol -> consistency.
# Never touches `status` -- corrupting it would derail this generator's own state-machine
# branching below, not just the downstream quality check it's meant to exercise later.
DIRTY_KINDS = [
    "negative_price",
    "zero_quantity",
    "invalid_side",
    "null_account_id",
    "invalid_symbol",
]

# Lifecycle path weights: most trades fill gradually, some fill in one shot, some get
# cancelled. The cancelled path ends in a DELETE (not just an UPDATE to CANCELLED) so the
# generator actually exercises all three CDC operation types -- this is what ADR-0007's
# "deletion detection" argument (batch polling can't see deletes) depends on being able
# to demonstrate, and it mirrors a real OLTP pattern of purging cancelled orders from the
# live table while history lives downstream.
PATH_WEIGHTS = {"full": 60, "direct_fill": 20, "cancelled": 20}

DDL_PATH = Path(__file__).parent / "sql" / "create_trade_table.sql"


def _now():
    return time.time()


def inject_dirty(row: dict, rng: random.Random) -> tuple[dict, str]:
    """Corrupt the initial NEW row in one of the ways §6's quality gate is meant to catch."""
    kind = rng.choice(DIRTY_KINDS)
    dirty = dict(row)
    if kind == "negative_price":
        dirty["price"] = -abs(dirty["price"])
    elif kind == "zero_quantity":
        dirty["quantity"] = 0
    elif kind == "invalid_side":
        dirty["side"] = "HOLD"
    elif kind == "null_account_id":
        dirty["account_id"] = None
    elif kind == "invalid_symbol":
        dirty["symbol"] = rng.choice(INVALID_SYMBOLS)
    return dirty, kind


def generate_trade_lifecycle(
    rng: random.Random, trade_id: str, dirty_rate: float = 0.0
) -> tuple[list[tuple[str, dict]], str | None]:
    """Return the full (operation, row) sequence for one trade, with no I/O.

    `event_time` is set once at INSERT and never changes (order origination time);
    `updated_at` is refreshed on every UPDATE (standard last-modified audit column).
    """
    symbol = rng.choice(SYMBOLS)
    price = round(BASE_PRICES.get(symbol, DEFAULT_BASE_PRICE) * (1 + rng.uniform(-0.05, 0.05)), 2)
    created_at = _now()
    row = {
        "trade_id": trade_id,
        "account_id": f"ACC{rng.randint(1, 20):04d}",
        "symbol": symbol,
        "price": price,
        "quantity": rng.randint(1, 50) * 1000,
        "side": rng.choice(SIDES),
        "status": "NEW",
        "event_time": created_at,
        "updated_at": created_at,
    }

    dirty_kind = None
    if dirty_rate > 0 and rng.random() < dirty_rate:
        row, dirty_kind = inject_dirty(row, rng)

    operations: list[tuple[str, dict]] = [("INSERT", dict(row))]

    path = rng.choices(
        list(PATH_WEIGHTS.keys()), weights=list(PATH_WEIGHTS.values())
    )[0]

    if path == "full":
        row = {**row, "status": "PARTIALLY_FILLED", "updated_at": _now()}
        operations.append(("UPDATE", dict(row)))
        row = {**row, "status": "FILLED", "updated_at": _now()}
        operations.append(("UPDATE", dict(row)))
    elif path == "direct_fill":
        row = {**row, "status": "FILLED", "updated_at": _now()}
        operations.append(("UPDATE", dict(row)))
    else:  # cancelled
        row = {**row, "status": "CANCELLED", "updated_at": _now()}
        operations.append(("UPDATE", dict(row)))
        operations.append(("DELETE", {"trade_id": trade_id}))

    return operations, dirty_kind


def run_ddl(conn) -> None:
    with conn.cursor() as cur:
        cur.execute(DDL_PATH.read_text())
    conn.commit()


def execute_operation(conn, operation: str, row: dict) -> None:
    with conn.cursor() as cur:
        if operation == "INSERT":
            cur.execute(
                """
                INSERT INTO trade
                    (trade_id, account_id, symbol, price, quantity, side, status, event_time, updated_at)
                VALUES
                    (%s, %s, %s, %s, %s, %s, %s, to_timestamp(%s), to_timestamp(%s))
                """,
                (
                    row["trade_id"], row["account_id"], row["symbol"], row["price"],
                    row["quantity"], row["side"], row["status"],
                    row["event_time"], row["updated_at"],
                ),
            )
        elif operation == "UPDATE":
            cur.execute(
                "UPDATE trade SET status = %s, updated_at = to_timestamp(%s) WHERE trade_id = %s",
                (row["status"], row["updated_at"], row["trade_id"]),
            )
        elif operation == "DELETE":
            cur.execute("DELETE FROM trade WHERE trade_id = %s", (row["trade_id"],))
        else:
            raise ValueError(f"Unknown operation: {operation}")
    conn.commit()


def summarize(conn) -> dict:
    with conn.cursor() as cur:
        cur.execute("SELECT status, COUNT(*) FROM trade GROUP BY status ORDER BY status")
        return dict(cur.fetchall())


def generate(conn, num_trades: int, seed: int, dirty_rate: float, delay_seconds: float) -> dict:
    rng = random.Random(seed)
    op_counts = {"INSERT": 0, "UPDATE": 0, "DELETE": 0}
    dirty_count = 0
    base_id = int(time.time())

    for i in range(num_trades):
        trade_id = f"T{base_id}-{i:04d}"
        operations, dirty_kind = generate_trade_lifecycle(rng, trade_id, dirty_rate)
        if dirty_kind:
            dirty_count += 1
        for operation, row in operations:
            execute_operation(conn, operation, row)
            op_counts[operation] += 1
            if delay_seconds > 0:
                time.sleep(delay_seconds)

    return {
        "trades": num_trades,
        "dirty_injected": dirty_count,
        "operations": op_counts,
        "status_counts": summarize(conn),
    }


def fetch_rows(conn, limit: int) -> list:
    """Peek at current table contents. No psql/bastion path reaches this RDS instance,
    so this doubles as the DB-inspection tool for humans (and later §4 items 8-9)."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT trade_id, account_id, symbol, price, quantity, side, status, event_time, updated_at
            FROM trade ORDER BY updated_at DESC LIMIT %s
            """,
            (limit,),
        )
        cols = [d[0] for d in cur.description]
        rows = []
        for record in cur.fetchall():
            row = dict(zip(cols, record))
            row["price"] = float(row["price"]) if row["price"] is not None else None
            row["event_time"] = row["event_time"].isoformat() if row["event_time"] else None
            row["updated_at"] = row["updated_at"].isoformat() if row["updated_at"] else None
            rows.append(row)
        return rows


def get_connection():
    return pg8000.connect(
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ.get("DB_NAME", "postgres"),
    )


def lambda_handler(event, context):
    """Event payload: {init_schema?, query?, limit?, num_trades?, seed?, dirty_rate?, delay_seconds?}."""
    event = event or {}
    conn = get_connection()
    try:
        if event.get("init_schema"):
            run_ddl(conn)
            return {"init_schema": "done"}
        if event.get("query"):
            return {"rows": fetch_rows(conn, event.get("limit", 10))}
        result = generate(
            conn,
            num_trades=event.get("num_trades", 10),
            seed=event.get("seed", 42),
            dirty_rate=event.get("dirty_rate", 0.0),
            delay_seconds=event.get("delay_seconds", 0.2),
        )
        print(f"generate_trade_data summary: {result}")
        return result
    finally:
        conn.close()


def parse_args():
    parser = argparse.ArgumentParser(
        description="Simulate trade order lifecycles against a Postgres trade table."
    )
    parser.add_argument("--host", default=os.environ.get("DB_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DB_PORT", "5432")))
    parser.add_argument("--database", default=os.environ.get("DB_NAME", "postgres"))
    parser.add_argument("--user", default=os.environ.get("DB_USER", "postgres"))
    parser.add_argument("--password", default=os.environ.get("DB_PASSWORD", "postgres"))
    parser.add_argument("--init-schema", action="store_true", help="Run the DDL once, then exit")
    parser.add_argument("--num-trades", type=int, default=10)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--dirty-rate",
        type=float,
        default=0.0,
        help="Probability [0,1] per trade of injecting dirty data (reserved for §4 items 8-9)",
    )
    parser.add_argument("--delay-seconds", type=float, default=0.2)
    return parser.parse_args()


def main():
    args = parse_args()
    conn = pg8000.connect(
        user=args.user, password=args.password, host=args.host, port=args.port,
        database=args.database,
    )
    try:
        if args.init_schema:
            run_ddl(conn)
            print("Schema initialized.")
            return
        result = generate(conn, args.num_trades, args.seed, args.dirty_rate, args.delay_seconds)
        print(result)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
