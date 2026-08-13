"""Shared fixtures for GX suite validation, exercised against multiple execution
engines (pandas: test_build_expectation_suite.py, Spark: test_gx_spark_validation.py)
so "which dirty kind trips which rule" is defined once and stays in sync across engines.
"""

import pytest

# One row per generate_stock_data.py dirty kind (spec §6 / runbook mapping),
# plus one clean baseline row mixed in.
DIRTY_ROWS: list[dict] = [
    # clean baseline
    {
        "symbol": "2330",
        "trade_date": "2026-01-01",
        "open": 100.0,
        "high": 105.0,
        "low": 95.0,
        "close": 102.0,
        "volume": 1000,
    },
    # negative_price
    {
        "symbol": "2454",
        "trade_date": "2026-01-01",
        "open": -10.0,
        "high": 105.0,
        "low": 95.0,
        "close": 102.0,
        "volume": 1000,
    },
    # high_lt_low
    {
        "symbol": "3653",
        "trade_date": "2026-01-01",
        "open": 100.0,
        "high": 90.0,
        "low": 95.0,
        "close": 92.0,
        "volume": 1000,
    },
    # empty_field -> null close (post-cast shape)
    {
        "symbol": "2330",
        "trade_date": "2026-01-02",
        "open": 100.0,
        "high": 105.0,
        "low": 95.0,
        "close": None,
        "volume": 1000,
    },
    # invalid_symbol
    {
        "symbol": "9999",
        "trade_date": "2026-01-02",
        "open": 100.0,
        "high": 105.0,
        "low": 95.0,
        "close": 102.0,
        "volume": 1000,
    },
    # invalid_date -> null trade_date (post-cast shape, see rules YAML notes)
    {
        "symbol": "2454",
        "trade_date": None,
        "open": 100.0,
        "high": 105.0,
        "low": 95.0,
        "close": 102.0,
        "volume": 1000,
    },
    # duplicate (symbol, trade_date), two identical rows
    {
        "symbol": "3653",
        "trade_date": "2026-01-03",
        "open": 100.0,
        "high": 105.0,
        "low": 95.0,
        "close": 102.0,
        "volume": 1000,
    },
    {
        "symbol": "3653",
        "trade_date": "2026-01-03",
        "open": 100.0,
        "high": 105.0,
        "low": 95.0,
        "close": 102.0,
        "volume": 1000,
    },
]

CLEAN_ROWS: list[dict] = [
    {
        "symbol": "2330",
        "trade_date": "2026-01-01",
        "open": 100.0,
        "high": 105.0,
        "low": 95.0,
        "close": 102.0,
        "volume": 1000,
    },
    {
        "symbol": "2454",
        "trade_date": "2026-01-01",
        "open": 900.0,
        "high": 910.0,
        "low": 895.0,
        "close": 905.0,
        "volume": 2000,
    },
    {
        "symbol": "3653",
        "trade_date": "2026-01-02",
        "open": 150.0,
        "high": 155.0,
        "low": 148.0,
        "close": 152.0,
        "volume": 3000,
    },
]


@pytest.fixture(scope="session")
def dirty_rows():
    return DIRTY_ROWS


@pytest.fixture(scope="session")
def clean_rows():
    return CLEAN_ROWS
