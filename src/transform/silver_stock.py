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
Audit (item 4) and Publish/fast-forward (item 5) aren't implemented yet, so
every write currently lands on staging and stays there.
"""

import sys

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
else:
    # Bootstrap: main doesn't exist yet, so there's nothing for WAP to
    # protect and no table for CREATE BRANCH to branch from. From the 2nd
    # run onward this branch is dead code.
    silver_df.writeTo(TABLE_FQN).using("iceberg").tableProperty(
        "format-version", "2"
    ).partitionedBy(months(col("trade_date"))).createOrReplace()

job.commit()
