#!/usr/bin/env python3
"""Generate simulated daily OHLCV CSVs for Slice0 raw landing.

Output layout mirrors the S3 raw landing convention (see
docs/specs/slice0-batch-market-data.md §4):

    <output-dir>/dt=YYYY-MM-DD/market.csv

Stdlib only by design (Slice0 stays minimal); no pandas/numpy/boto3.
"""

import argparse
import csv
import random
from datetime import date, timedelta
from pathlib import Path

DEFAULT_SYMBOLS = ["2330", "2454", "3653"]
FIELDNAMES = ["symbol", "date", "open", "high", "low", "close", "volume"]

# Rough starting prices in TWD, just plausible magnitudes for synthetic data.
BASE_PRICES = {
    "2330": 600.0,
    "2454": 900.0,
    "3653": 150.0,
}
DEFAULT_BASE_PRICE = 500.0

INVALID_SYMBOLS = ["9999", "0000", "ABCD"]

# One kind per §6 rule dimension (docs/specs/slice1-quality-contract.md):
# empty_field -> completeness; negative_price/high_lt_low/invalid_date -> validity;
# duplicate -> uniqueness; invalid_symbol -> consistency.
DIRTY_KINDS = [
    "negative_price",
    "empty_field",
    "high_lt_low",
    "duplicate",
    "invalid_symbol",
    "invalid_date",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate simulated daily OHLCV CSVs for Slice0 raw landing."
    )
    parser.add_argument(
        "--symbols",
        default=",".join(DEFAULT_SYMBOLS),
        help="Comma-separated stock symbols",
    )
    parser.add_argument(
        "--start-date",
        default=None,
        help="YYYY-MM-DD; defaults to (today - --years)",
    )
    parser.add_argument(
        "--end-date",
        default=None,
        help="YYYY-MM-DD; requires --start-date; defaults to today when omitted",
    )
    parser.add_argument(
        "--years",
        type=float,
        default=1.0,
        help="History length in years, used when --start-date is not given",
    )
    parser.add_argument(
        "--output-dir",
        default="data/raw/market/stock",
        help="Output root directory",
    )
    parser.add_argument(
        "--dirty-rate",
        type=float,
        default=0.0,
        help=(
            "Probability [0,1] per row of injecting dirty data "
            "(reserved for Slice1's WAP Gate testing; keep 0.0 for Slice0)"
        ),
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed, for reproducible output",
    )
    args = parser.parse_args()
    if args.end_date and not args.start_date:
        parser.error("--end-date requires --start-date")
    return args


def trading_days(start: date, end: date):
    """Yield weekdays (Mon-Fri) in [start, end]. No holiday calendar modeling."""
    current = start
    while current <= end:
        if current.weekday() < 5:
            yield current
        current += timedelta(days=1)


def next_ohlcv(prev_close: float, rng: random.Random):
    """Random-walk one trading day forward from prev_close.

    Guarantees high >= max(open, close) and low <= min(open, close).
    """
    close = max(prev_close * (1 + rng.uniform(-0.03, 0.03)), 1.0)
    open_ = max(prev_close * (1 + rng.uniform(-0.01, 0.01)), 1.0)
    high = max(open_, close) * (1 + rng.uniform(0, 0.015))
    low = min(open_, close) * (1 - rng.uniform(0, 0.015))
    volume = rng.randint(500_000, 20_000_000)
    return round(open_, 2), round(high, 2), round(low, 2), round(close, 2), volume


def inject_dirty(row: dict, rng: random.Random) -> list:
    """Corrupt a row in one of the ways Slice1's quality gate (spec §6) is meant to catch."""
    kind = rng.choice(DIRTY_KINDS)
    dirty = dict(row)
    if kind == "negative_price":
        field = rng.choice(["open", "high", "low", "close"])
        dirty[field] = -abs(dirty[field])
    elif kind == "empty_field":
        field = rng.choice(FIELDNAMES)
        dirty[field] = ""
    elif kind == "high_lt_low":
        dirty["high"] = dirty["low"] - 1
    elif kind == "duplicate":
        return [row, dict(row)]
    elif kind == "invalid_symbol":
        dirty["symbol"] = rng.choice(INVALID_SYMBOLS)
    elif kind == "invalid_date":
        dirty["date"] = dirty["date"].replace("-", "/")
    return [dirty]


def main():
    args = parse_args()
    rng = random.Random(args.seed)
    symbols = [s.strip() for s in args.symbols.split(",") if s.strip()]

    if args.start_date:
        start = date.fromisoformat(args.start_date)
        end = date.fromisoformat(args.end_date) if args.end_date else date.today()
    else:
        end = date.today()
        start = end - timedelta(days=round(args.years * 365))

    last_close = {s: BASE_PRICES.get(s, DEFAULT_BASE_PRICE) for s in symbols}
    output_root = Path(args.output_dir)

    day_count = 0
    row_count = 0
    for day in trading_days(start, end):
        rows = []
        for symbol in symbols:
            open_, high, low, close, volume = next_ohlcv(last_close[symbol], rng)
            last_close[symbol] = close
            row = {
                "symbol": symbol,
                "date": day.isoformat(),
                "open": open_,
                "high": high,
                "low": low,
                "close": close,
                "volume": volume,
            }
            if args.dirty_rate > 0 and rng.random() < args.dirty_rate:
                rows.extend(inject_dirty(row, rng))
            else:
                rows.append(row)

        day_dir = output_root / f"dt={day.isoformat()}"
        day_dir.mkdir(parents=True, exist_ok=True)
        with (day_dir / "market.csv").open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
            writer.writeheader()
            writer.writerows(rows)

        day_count += 1
        row_count += len(rows)

    print(f"Generated {day_count} trading days, {row_count} rows, under {output_root}/")


if __name__ == "__main__":
    main()
