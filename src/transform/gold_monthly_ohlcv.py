"""Gold monthly OHLCV aggregation for Slice0.

Runs as an AWS Glue Job (GlueVersion 5.0, --datalake-formats=iceberg), same
catalog wiring convention as Bronze/Silver — no spark.sql.catalog.* configs
here (see infra/environments/dev/glue.tf).

Aggregation grain is monthly, not daily: Silver already guarantees exactly
one row per (symbol, trade_date) (spec §6 dedup), so grouping by
(symbol, trade_date) here would be a no-op that can't demonstrate real
aggregation. Grouping by (symbol, month) instead produces a genuine
multi-row-per-group aggregation — every trading day in the month collapses
into one summary row, which is what "gold.monthly_ohlcv" actually contains
(see docs/specs/slice0-batch-market-data.md §4 item 7 and §1 for the
renamed data-flow step).

open/close use min_by/max_by (ordered by trade_date) rather than first()/
last(): with multiple rows per group, first()/last() have no guaranteed
order unless the DataFrame is pre-sorted, which is easy to get wrong
silently. min_by("open", "trade_date") / max_by("close", "trade_date")
make the "earliest/latest trading day in the month" ordering explicit and
correct regardless of upstream row order.

Every run reads the FULL Silver table and writes with createOrReplace(),
matching Silver's full-recompute-and-overwrite semantics (see
src/transform/silver_stock.py's docstring for the reasoning) — spec §5
label "append" here likewise means "no row-level upsert", not literal Spark
append.

No partitionedBy: partition design is spec item 9, deferred, same as
Bronze/Silver.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import col, max_by, min_by, trunc
from pyspark.sql.functions import max as spark_max
from pyspark.sql.functions import min as spark_min
from pyspark.sql.functions import sum as spark_sum

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

silver_df = spark.table(SOURCE_FQN)

monthly_df = silver_df.withColumn("year_month", trunc(col("trade_date"), "MM"))

gold_df = monthly_df.groupBy("symbol", "year_month").agg(
    min_by("open", "trade_date").alias("open"),
    spark_max("high").alias("high"),
    spark_min("low").alias("low"),
    max_by("close", "trade_date").alias("close"),
    spark_sum("volume").alias("volume"),
)

gold_df.writeTo(TABLE_FQN).using("iceberg").tableProperty(
    "format-version", "2"
).createOrReplace()

job.commit()
