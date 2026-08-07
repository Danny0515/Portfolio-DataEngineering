"""Tests for the YAML-driven GX suite loader (spec §6, slice1-quality-contract.md §4 item 2).

Runs real Great Expectations validation against an ephemeral pandas context
(no mocking, no Spark/AWS) — local execution only, per plan.
"""

from pathlib import Path
from typing import ClassVar

import great_expectations as gx
import pandas as pd
import pytest

from src.quality.build_expectation_suite import build_suite

RULES_PATH = Path(__file__).parents[2] / "src" / "quality" / "rules" / "silver_stock.yaml"


@pytest.fixture(scope="module")
def suite():
    return build_suite(RULES_PATH)


def _validate(df: pd.DataFrame, suite: gx.ExpectationSuite):
    context = gx.get_context(mode="ephemeral")
    data_source = context.data_sources.add_pandas("pandas")
    asset = data_source.add_dataframe_asset("asset")
    batch_definition = asset.add_batch_definition_whole_dataframe("batch")
    batch = batch_definition.get_batch(batch_parameters={"dataframe": df})
    return batch.validate(suite)


def _failed_type_column_pairs(result):
    """Set of (expectation_type, column-or-None) for failed expectations."""
    pairs = set()
    for r in result.results:
        if r.success:
            continue
        kwargs = r.expectation_config.kwargs
        pairs.add((r.expectation_config.type, kwargs.get("column")))
    return pairs


class TestBuildSuite:
    def test_expectation_count(self, suite):
        assert len(suite.expectations) == 14

    def test_completeness_covers_all_seven_columns(self, suite):
        not_null_columns = {
            e.configuration.kwargs["column"]
            for e in suite.expectations
            if e.expectation_type == "expect_column_values_to_not_be_null"
        }
        assert not_null_columns == {
            "symbol",
            "trade_date",
            "open",
            "high",
            "low",
            "close",
            "volume",
        }

    def test_validity_non_negative_covers_four_price_columns(self, suite):
        between = [
            e
            for e in suite.expectations
            if e.expectation_type == "expect_column_values_to_be_between"
        ]
        assert {e.configuration.kwargs["column"] for e in between} == {
            "open",
            "high",
            "low",
            "close",
        }
        assert all(e.configuration.kwargs["min_value"] == 0 for e in between)

    def test_validity_high_gte_low(self, suite):
        pair = [
            e
            for e in suite.expectations
            if e.expectation_type == "expect_column_pair_values_a_to_be_greater_than_b"
        ]
        assert len(pair) == 1
        assert pair[0].configuration.kwargs["column_A"] == "high"
        assert pair[0].configuration.kwargs["column_B"] == "low"
        assert pair[0].configuration.kwargs["or_equal"] is True

    def test_uniqueness_on_symbol_and_trade_date(self, suite):
        unique = [
            e
            for e in suite.expectations
            if e.expectation_type == "expect_compound_columns_to_be_unique"
        ]
        assert len(unique) == 1
        assert unique[0].configuration.kwargs["column_list"] == ["symbol", "trade_date"]

    def test_consistency_symbol_whitelist(self, suite):
        in_set = [
            e
            for e in suite.expectations
            if e.expectation_type == "expect_column_values_to_be_in_set"
        ]
        assert len(in_set) == 1
        assert in_set[0].configuration.kwargs["column"] == "symbol"
        assert in_set[0].configuration.kwargs["value_set"] == ["2330", "2454", "3653"]


class TestSuiteCatchesDirtyData:
    """One row per generate_stock_data.py dirty kind (spec §6 / runbook mapping)."""

    DIRTY_ROWS: ClassVar[list[dict]] = [
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
        # invalid_date -> null trade_date (post-cast shape, see YAML notes)
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

    def test_dirty_batch_fails_and_catches_all_six_kinds(self, suite):
        df = pd.DataFrame(self.DIRTY_ROWS)
        result = _validate(df, suite)

        assert result.success is False
        failed = _failed_type_column_pairs(result)
        assert ("expect_column_values_to_be_between", "open") in failed  # negative_price
        assert (
            "expect_column_pair_values_a_to_be_greater_than_b",
            None,
        ) in failed  # high_lt_low
        assert ("expect_column_values_to_not_be_null", "close") in failed  # empty_field
        assert ("expect_column_values_to_be_in_set", "symbol") in failed  # invalid_symbol
        assert (
            "expect_column_values_to_not_be_null",
            "trade_date",
        ) in failed  # invalid_date -> null
        assert ("expect_compound_columns_to_be_unique", None) in failed  # duplicate

    def test_clean_batch_passes(self, suite):
        clean_rows = [
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
        df = pd.DataFrame(clean_rows)
        result = _validate(df, suite)
        assert result.success is True
