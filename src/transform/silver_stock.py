"""Silver cleanse/standardize for Slice0: dedup, type-correct, rename Bronze OHLCV.

Runs as an AWS Glue Job; catalog wiring (spark.sql.catalog.*) lives in
infra/environments/dev/glue.tf, not here.

Every run full-recomputes from Bronze rather than .append()-ing: Bronze
accumulates duplicate rows on reprocess (docs/architecture/adr/0002-medallion-layering.md)
and those must be fully absorbed here, not doubled on every rerun — see
docs/architecture/adr/0003-append-vs-overwrite.md for the full rationale
(also covers why Silver/Gold partition by months(...) and Bronze doesn't).

Bronze lands every column as StringType, so Silver owns all type parsing.
Processing order is dedup -> cast -> quality filter: casting first means the
filter runs on real numeric/date comparisons, not Spark's implicit
string-to-numeric coercion.

WAP write stage (docs/specs/slice1-quality-contract.md §4 item 3): from the
2nd run onward this writes to Iceberg's `staging` branch instead of main.

Audit (item 4, spike form per §8's GX-on-Spark-on-Glue verification plan):
after the staging write, reads staging back and runs it through the Great
Expectations suite built in item 2 (src/quality/gx/expectations/silver_stock.json,
shipped alongside this script via Glue's --extra-files). Result is only
printed to CloudWatch for now — Publish/fast-forward (item 5) and a queryable
audit-record table (item 6) aren't implemented yet, so nothing is blocked or
persisted based on the outcome.
"""

import json
import os
import sys
from pathlib import Path

import great_expectations as gx
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import col, lit, months, row_number, to_date
from pyspark.sql.types import DecimalType, IntegerType
from pyspark.sql.utils import AnalysisException
from pyspark.sql.window import Window

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "SOURCE_DB", "SOURCE_TABLE", "ICEBERG_DB", "ICEBERG_TABLE"],
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

CATALOG = "glue_catalog"
SOURCE_FQN = f"{CATALOG}.{args['SOURCE_DB']}.{args['SOURCE_TABLE']}"
TABLE_FQN = f"{CATALOG}.{args['ICEBERG_DB']}.{args['ICEBERG_TABLE']}"
STAGING_BRANCH = "staging"

bronze_df = spark.table(SOURCE_FQN)

# Ties (same ingest_time, since current_timestamp() is per-query) broken by
# source_file so row_number() stays deterministic.
dedup_window = Window.partitionBy("symbol", "date").orderBy(
    col("ingest_time").desc(), col("source_file").desc()
)
deduped_df = (
    bronze_df.withColumn("_rank", row_number().over(dedup_window))
    .filter(col("_rank") == 1)
    .drop("_rank")
)

# TODO 型態之後改由外部傳入(e.g. 數據字典)
typed_df = deduped_df.select(
    col("symbol"),
    to_date(col("date")).alias("trade_date"),
    col("open").cast(DecimalType(10, 2)).alias("open"),
    col("high").cast(DecimalType(10, 2)).alias("high"),
    col("low").cast(DecimalType(10, 2)).alias("low"),
    col("close").cast(DecimalType(10, 2)).alias("close"),
    col("volume").cast(IntegerType()).alias("volume"),
)

# Data quality rules (spec §6): no negative/null OHLC prices, high >= low.
silver_df = typed_df.filter(
    col("open").isNotNull()
    & col("high").isNotNull()
    & col("low").isNotNull()
    & col("close").isNotNull()
    & (col("open") >= 0)
    & (col("high") >= 0)
    & (col("low") >= 0)
    & (col("close") >= 0)
    & (col("high") >= col("low"))
)

try:
    spark.sql(f"DESCRIBE TABLE {TABLE_FQN}")
    table_exists = True
except AnalysisException:
    table_exists = False

if table_exists:
    # CREATE BRANCH IF NOT EXISTS is idempotent (no-op if staging already
    # exists), so a rerun never resets staging's HEAD — main stays an
    # ancestor of every staging snapshot even across rejected-Audit cycles,
    # which item 5's future fast_forward depends on.
    #
    # overwrite(lit(True)), not createOrReplace(): only append()/overwrite()/
    # overwritePartitions() resolve a `.branch_X` identifier suffix;
    # createOrReplace() treats it as a literal table name and fails.
    spark.sql(f"ALTER TABLE {TABLE_FQN} CREATE BRANCH IF NOT EXISTS {STAGING_BRANCH}")
    silver_df.writeTo(f"{TABLE_FQN}.branch_{STAGING_BRANCH}").overwrite(lit(True))

    # Audit (item 4 spike): validate staging's current contents against the
    # Silver quality suite. --extra-files' landing directory wasn't confirmed
    # ahead of time, so cwd is logged to diagnose Path("silver_stock_suite.json")
    # if it doesn't resolve.
    print(f"[Audit] cwd={os.getcwd()}")
    staging_df = spark.table(f"{TABLE_FQN}.branch_{STAGING_BRANCH}")
    suite_data = json.loads(Path("silver_stock_suite.json").read_text())
    suite = gx.ExpectationSuite(**suite_data)

    gx_context = gx.get_context(mode="ephemeral")
    data_source = gx_context.data_sources.add_spark("glue_spark")
    asset = data_source.add_dataframe_asset("staging_asset")
    batch_definition = asset.add_batch_definition_whole_dataframe("staging_batch")
    batch = batch_definition.get_batch(batch_parameters={"dataframe": staging_df})
    audit_result = batch.validate(suite)

    print(f"[Audit] staging validation success={audit_result.success}")
    for r in audit_result.results:
        if not r.success:
            print(f"[Audit] FAILED: {r.expectation_config.type} kwargs={r.expectation_config.kwargs}")
else:
    # Bootstrap: main doesn't exist yet, so there's nothing for WAP to
    # protect and no table for CREATE BRANCH to branch from. From the 2nd
    # run onward this branch is dead code.
    silver_df.writeTo(TABLE_FQN).using("iceberg").tableProperty(
        "format-version", "2"
    ).partitionedBy(months(col("trade_date"))).createOrReplace()

job.commit()
