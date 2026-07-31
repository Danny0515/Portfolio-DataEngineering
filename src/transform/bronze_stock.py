"""Bronze landing for Slice0: land raw OHLCV CSV into Iceberg as-is.

Runs as an AWS Glue Job (GlueVersion 5.0, --datalake-formats=iceberg). The
Glue Data Catalog is the Iceberg catalog (registered as `glue_catalog` via
job-level --conf, see infra/environments/dev/glue.tf); this script never
sets those spark.sql.catalog.* configs itself, to avoid two sources of
truth.

Bronze is intentionally a thin provenance-tagging pass, not a quality gate:
no dedup, no negative/null filtering, no high>=low check, no type coercion
at all. Every column lands as StringType (inferSchema=false) so Bronze's
schema is stable regardless of how malformed the source CSV is — a single
dirty row can otherwise silently shift Spark's inferred column type. Type
parsing (price -> decimal, date -> date type, volume -> integer) is 100%
owned by Silver (spec docs/specs/slice0-batch-market-data.md §5/§6, item 6)
— see docs/architecture/adr/0002-medallion-layering.md for the reasoning.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import current_timestamp, input_file_name
from pyspark.sql.utils import AnalysisException

args = getResolvedOptions(
    sys.argv, ["JOB_NAME", "RAW_INPUT_PATH", "ICEBERG_DB", "ICEBERG_TABLE"]
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

CATALOG = "glue_catalog"
TABLE_FQN = f"{CATALOG}.{args['ICEBERG_DB']}.{args['ICEBERG_TABLE']}"

# inferSchema=false is deliberate (and written out explicitly rather than
# relying on Spark's default): every column lands as StringType, so Bronze
# never has to guess a type from the data. Silver (item 6) owns 100% of type
# parsing (price -> decimal, date -> date type, volume -> integer).
raw_df = (
    spark.read.option("header", "true")
    .option("inferSchema", "false")
    .option("recursiveFileLookup", "true")
    .csv(args["RAW_INPUT_PATH"])
)

bronze_df = raw_df.withColumn("ingest_time", current_timestamp()).withColumn(
    "source_file", input_file_name()
)

try:
    spark.sql(f"DESCRIBE TABLE {TABLE_FQN}")
    table_exists = True
except AnalysisException:
    table_exists = False

if table_exists:
    bronze_df.writeTo(TABLE_FQN).append()
else:
    # No partitionedBy: partition design is spec item 9, deferred. Iceberg's
    # hidden partitioning lets it be added later via ALTER TABLE ... ADD
    # PARTITION FIELD without rewriting data already landed here.
    bronze_df.writeTo(TABLE_FQN).using("iceberg").tableProperty(
        "format-version", "2"
    ).create()

job.commit()
