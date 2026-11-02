"""Unit tests for the pure transform in src/transform/silver_trade_stream.py.

Runs against a real local SparkSession (existing pyspark dev dependency). The MERGE itself
needs the Iceberg runtime and is verified on Glue, not here.
"""

from decimal import Decimal

import pytest
from pyspark.sql import SparkSession
from pyspark.sql.types import (
    DecimalType,
    IntegerType,
    LongType,
    StringType,
    StructField,
    StructType,
)

from src.transform.silver_trade_stream import build_merge_sql, latest_per_trade

IMAGE = StructType(
    [
        StructField("trade_id", StringType()),
        StructField("account_id", StringType()),
        StructField("symbol", StringType()),
        StructField("price", DecimalType(38, 2)),
        StructField("quantity", IntegerType()),
        StructField("side", StringType()),
        StructField("status", StringType()),
        StructField("event_time", StringType()),
        StructField("updated_at", StringType()),
    ]
)
BRONZE = StructType(
    [
        StructField("before", IMAGE),
        StructField("after", IMAGE),
        StructField("source", StructType([StructField("lsn", LongType())])),
        StructField("op", StringType()),
        StructField("ts_ms", LongType()),
    ]
)


def image(trade_id, status="NEW", price="100.00"):
    return (
        trade_id,
        "A1",
        "2330",
        Decimal(price),
        1000,
        "BUY",
        status,
        "2026-10-30T08:45:36.123456Z",
        "2026-10-30T08:45:37.000000Z",
    )


def event(op, lsn, before=None, after=None, ts_ms=0):
    return (before, after, (lsn,), op, ts_ms)


@pytest.fixture(scope="module")
def spark():
    session = SparkSession.builder.master("local[1]").appName("silver-trade-stream-test").getOrCreate()
    session.sparkContext.setLogLevel("WARN")
    yield session
    session.stop()


def collect(spark, events):
    rows = latest_per_trade(spark.createDataFrame(events, BRONZE)).collect()
    return {r["trade_id"]: r for r in rows}


def test_picks_highest_lsn_per_trade_within_a_batch(spark):
    result = collect(
        spark,
        [
            event("c", 10, after=image("T1", "NEW")),
            event("u", 30, after=image("T1", "FILLED")),
            event("u", 20, after=image("T1", "PARTIALLY_FILLED")),
        ],
    )
    assert result["T1"]["status"] == "FILLED"
    assert result["T1"]["source_lsn"] == 30
    assert result["T1"]["is_deleted"] is False


def test_delete_keeps_before_image_and_marks_soft_delete(spark):
    result = collect(
        spark,
        [
            event("c", 10, after=image("T2", "NEW")),
            event("d", 20, before=image("T2", "CANCELLED", "150.62")),
        ],
    )
    assert result["T2"]["is_deleted"] is True
    assert result["T2"]["status"] == "CANCELLED"
    assert result["T2"]["price"] == Decimal("150.62")
    assert result["T2"]["source_lsn"] == 20


def test_snapshot_read_event_is_treated_as_upsert(spark):
    result = collect(spark, [event("r", 99, after=image("T3", "FILLED"))])
    assert result["T3"]["is_deleted"] is False
    assert result["T3"]["status"] == "FILLED"


def test_one_row_per_trade_across_multiple_trades(spark):
    result = collect(
        spark,
        [
            event("c", 1, after=image("T4")),
            event("c", 2, after=image("T5")),
            event("u", 3, after=image("T4", "FILLED")),
        ],
    )
    assert set(result) == {"T4", "T5"}
    assert result["T4"]["status"] == "FILLED"


def test_same_lsn_tie_is_broken_by_ts_ms(spark):
    result = collect(
        spark,
        [
            event("u", 50, after=image("T6", "NEW"), ts_ms=1),
            event("u", 50, after=image("T6", "FILLED"), ts_ms=2),
        ],
    )
    assert result["T6"]["status"] == "FILLED"


def test_timestamp_strings_are_cast_to_timestamps(spark):
    result = collect(spark, [event("c", 1, after=image("T7"))])
    assert result["T7"]["event_time"] is not None
    assert result["T7"]["updated_at"] is not None


def test_events_without_a_trade_id_or_lsn_are_dropped(spark):
    result = collect(
        spark,
        [
            event("c", 1, after=image(None)),
            event("c", None, after=image("T8")),
            event("c", 2, after=image("T9")),
        ],
    )
    assert set(result) == {"T9"}


def test_merge_uses_strict_greater_than_and_both_styles_render():
    qualified = build_merge_sql("glue_catalog.silver.spike_trade", use_alias=False)
    aliased = build_merge_sql("glue_catalog.silver.spike_trade", use_alias=True)
    assert "spike_trade_batch.source_lsn > glue_catalog.silver.spike_trade.source_lsn" in qualified
    assert "s.source_lsn > t.source_lsn" in aliased
    assert ">=" not in qualified and ">=" not in aliased
