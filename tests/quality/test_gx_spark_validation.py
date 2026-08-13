"""Spark-engine counterpart to test_build_expectation_suite.py's pandas validation.

Isolates spec §8 GX-on-Spark-on-Glue risk unknown #3 (does GX's Spark Datasource/
Validator work at all) from the Glue-specific unknowns (#1 dependency packaging,
#2 Data Context model) that can only be tested against a real Glue Job — see
docs/runbooks/slice1-gx-audit-verification.md for that half of the verification.

Runs a real local SparkSession (existing pyspark dev dependency, no AWS/network
needed) against the same suite and dirty/clean rows as the pandas test, so both
execution engines are checked against one shared definition of "catches all six
dirty kinds" (tests/quality/conftest.py).
"""

from pathlib import Path

import great_expectations as gx
import pytest
from pyspark.sql import SparkSession

from src.quality.build_expectation_suite import build_suite

pytestmark = pytest.mark.compat

RULES_PATH = Path(__file__).parents[2] / "src" / "quality" / "rules" / "silver_stock.yaml"


@pytest.fixture(scope="module")
def spark():
    session = SparkSession.builder.master("local[1]").appName("gx-spark-validation-test").getOrCreate()
    session.sparkContext.setLogLevel("WARN")
    yield session
    session.stop()


@pytest.fixture(scope="module")
def suite():
    return build_suite(RULES_PATH)


def _validate(df, suite: gx.ExpectationSuite):
    context = gx.get_context(mode="ephemeral")
    data_source = context.data_sources.add_spark("spark")
    asset = data_source.add_dataframe_asset("asset")
    batch_definition = asset.add_batch_definition_whole_dataframe("batch")
    batch = batch_definition.get_batch(batch_parameters={"dataframe": df})
    return batch.validate(suite)


class TestSparkSuiteValidation:
    def test_clean_batch_passes(self, spark, suite, clean_rows):
        df = spark.createDataFrame(clean_rows)
        result = _validate(df, suite)
        assert result.success is True

    def test_dirty_batch_fails(self, spark, suite, dirty_rows):
        df = spark.createDataFrame(dirty_rows)
        result = _validate(df, suite)
        assert result.success is False
