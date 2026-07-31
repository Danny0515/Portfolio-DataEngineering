"""Silver cleanse/standardize for Slice0: dedup, type-correct, rename Bronze OHLCV.

Runs as an AWS Glue Job (GlueVersion 5.0, --datalake-formats=iceberg), same
catalog wiring convention as Bronze (see infra/environments/dev/glue.tf and
src/transform/bronze_stock.py) — no spark.sql.catalog.* configs here.

Every run reads the FULL Bronze table and writes with createOrReplace(), not
.append(). This is a deliberate departure from Bronze's create-or-append
pattern: Bronze is allowed to accumulate duplicate rows on reprocess (see
docs/architecture/adr/0002-medallion-layering.md), and those duplicates must
be fully absorbed here rather than leaking into Silver. If Silver appended
its deduped batch onto whatever was already there, re-running Silver itself
would double-count on every run. A full recompute + overwrite is the only
way to satisfy spec §7's "Bronze can be reprocessed without corrupting
Silver/Gold" acceptance criterion. Spec §5 labels this write mode "append"
to mean "no row-level MERGE/upsert" (contrasted with Slice 2's upsert) — not
literal Spark append semantics.

No partitionedBy: partition design is spec item 9, deferred (same reasoning
as Bronze — see docs/specs/slice0-batch-market-data.md §4 item 9).

Bronze now lands every column as StringType (inferSchema=false, see
src/transform/bronze_stock.py), so Silver owns 100% of type parsing —
not just price/date as before, but also volume. Processing order is dedup
-> type cast -> quality filter: casting first means the quality filter runs
against properly-typed columns instead of relying on Spark's implicit
string-to-numeric comparison coercion. A cast of an invalid numeric literal
(e.g. spec §6's dirty "empty_field" injection, an empty string) evaluates
to null under Spark's default (non-ANSI) cast semantics, which the
isNotNull() checks below then drop — no special-casing needed.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import col, row_number, to_date
from pyspark.sql.types import DecimalType, IntegerType
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

bronze_df = spark.table(SOURCE_FQN)

# Dedup key is (symbol, date) per spec §6. Tie-break keeps the row from the
# most recent Bronze run (ingest_time desc); source_file is a secondary sort
# key only to make row_number() deterministic when ingest_time ties within
# the same Bronze run (current_timestamp() is evaluated once per query, so
# every row from one Bronze run shares the same ingest_time).
dedup_window = Window.partitionBy("symbol", "date").orderBy(
    col("ingest_time").desc(), col("source_file").desc()
)
deduped_df = (
    bronze_df.withColumn("_rank", row_number().over(dedup_window))
    .filter(col("_rank") == 1)
    .drop("_rank")
)

# Type correction (spec item 6): every column from Bronze is a string, so
# all of open/high/low/close/volume/date need an explicit cast here — none
# of this is free from Bronze's reader anymore. Column standardization:
# `date` -> `trade_date` (avoids the generic bare name once this table is
# joined against others). Bronze's provenance columns (ingest_time,
# source_file) are intentionally not carried forward — spec §5 describes
# Silver's content as pure OHLCV, no lineage columns.
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
# Runs after casting so these are real numeric/date comparisons, not
# Spark's implicit string-to-numeric coercion. Dirty "empty_field"
# injections become null during the cast above (caught by isNotNull());
# dirty "negative_price" injections stay a valid, real negative number
# (caught by the >= 0 checks).
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

silver_df.writeTo(TABLE_FQN).using("iceberg").tableProperty(
    "format-version", "2"
).createOrReplace()

job.commit()
