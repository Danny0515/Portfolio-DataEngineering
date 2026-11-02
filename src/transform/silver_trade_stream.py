"""Glue Streaming job (Slice 2b spike, spec §4 item 1(b)): Bronze (Iceberg) -> Silver (Iceberg).

Reads the append-only Bronze event table as a stream and, per micro-batch, collapses the
events to the latest state per trade (by source.lsn) and MERGEs it into Silver:
  - op in (r, c, u): upsert the `after` image
  - op = d:          keep the `before` image and mark is_deleted = true (soft delete)
  - MERGE only overwrites a row when the incoming source_lsn is strictly greater, so replays
    and out-of-order events never move a row backwards.

Spike scope: no row-level quality rules and no rejects table (spec §4 item 5).

The awsglue imports live inside main() so latest_per_trade() can be imported and unit-tested
with a plain local PySpark session (tests/transform/test_silver_trade_stream.py).
"""

import sys

from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.window import Window

CATALOG = "glue_catalog"
BATCH_VIEW = "spike_trade_batch"

SILVER_DDL = """
    CREATE TABLE IF NOT EXISTS {target} (
        trade_id    STRING,
        account_id  STRING,
        symbol      STRING,
        price       DECIMAL(38, 2),
        quantity    INT,
        side        STRING,
        status      STRING,
        event_time  TIMESTAMP,
        updated_at  TIMESTAMP,
        source_lsn  BIGINT,
        is_deleted  BOOLEAN
    )
    USING iceberg
    TBLPROPERTIES ('format-version' = '2')
"""


def latest_per_trade(df: DataFrame) -> DataFrame:
    """Collapse Bronze change events to one row per trade_id: the one with the highest source.lsn."""
    is_delete = F.col("op") == "d"
    record = F.when(is_delete, F.col("before")).otherwise(F.col("after"))

    flat = (
        df.filter(F.col("op").isin("r", "c", "u", "d"))
        .select(
            record["trade_id"].alias("trade_id"),
            record["account_id"].alias("account_id"),
            record["symbol"].alias("symbol"),
            record["price"].alias("price"),
            record["quantity"].alias("quantity"),
            record["side"].alias("side"),
            record["status"].alias("status"),
            record["event_time"].cast("timestamp").alias("event_time"),
            record["updated_at"].cast("timestamp").alias("updated_at"),
            F.col("source.lsn").alias("source_lsn"),
            is_delete.alias("is_deleted"),
            F.col("ts_ms").alias("_ts_ms"),
        )
        .filter(F.col("trade_id").isNotNull() & F.col("source_lsn").isNotNull())
    )

    # ts_ms breaks ties between events that share an LSN so the result is deterministic.
    window = Window.partitionBy("trade_id").orderBy(F.col("source_lsn").desc(), F.col("_ts_ms").desc())
    return flat.withColumn("_rn", F.row_number().over(window)).filter(F.col("_rn") == 1).drop("_rn", "_ts_ms")


def build_merge_sql(target: str, use_alias: bool) -> str:
    """Glue 5.0 (Spark 3.5.4) resolves MERGE aliases differently from 4.0 (ADR-0010), so the
    default uses fully qualified names; use_alias is a fallback switch for the spike."""
    if use_alias:
        t, s = "t", "s"
        target_ref = f"{target} AS t"
        source_ref = f"{BATCH_VIEW} AS s"
    else:
        t, s = target, BATCH_VIEW
        target_ref = target
        source_ref = BATCH_VIEW
    return f"""
        MERGE INTO {target_ref}
        USING {source_ref}
        ON {t}.trade_id = {s}.trade_id
        WHEN MATCHED AND {s}.source_lsn > {t}.source_lsn THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
    """


def make_batch_handler(target: str, use_alias: bool):
    merge_sql = build_merge_sql(target, use_alias)

    def handle(batch_df: DataFrame, batch_id: int) -> None:
        # Persist so count() and MERGE share one scan of the Bronze micro-batch instead of
        # each action re-reading the source (observed ~4x numInputRows without this).
        latest = latest_per_trade(batch_df).persist()
        try:
            count = latest.count()
            if count == 0:
                print(f"batch {batch_id}: no events")
                return
            latest.createOrReplaceTempView(BATCH_VIEW)
            batch_df.sparkSession.sql(merge_sql)
            print(f"batch {batch_id}: merged {count} trade(s)")
        finally:
            latest.unpersist()

    return handle


def main() -> None:
    from awsglue.context import GlueContext
    from awsglue.job import Job
    from awsglue.utils import getResolvedOptions
    from pyspark.context import SparkContext

    required = ["JOB_NAME", "CHECKPOINT_PATH"]
    optional_defaults = {
        "SOURCE_TABLE": "bronze.spike_trade_events",
        "TARGET_TABLE": "silver.spike_trade",
        "TRIGGER_SECONDS": "60",
        "STREAM_FROM_TIMESTAMP": "",
        "MERGE_USE_ALIAS": "false",
        # Cap on rows per micro-batch; empty = unlimited. Used to replay history in many small
        # batches so older events reach MERGE after Silver already holds newer state.
        "MAX_ROWS_PER_BATCH": "",
    }
    # getResolvedOptions fails on arguments that are absent, so only request the ones passed.
    present = [name for name in optional_defaults if f"--{name}" in sys.argv]
    args = getResolvedOptions(sys.argv, required + present)
    options = {**optional_defaults, **{name: args[name] for name in present}}

    sc = SparkContext()
    glue_context = GlueContext(sc)
    spark = glue_context.spark_session
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    source = f"{CATALOG}.{options['SOURCE_TABLE']}"
    target = f"{CATALOG}.{options['TARGET_TABLE']}"
    use_alias = options["MERGE_USE_ALIAS"].lower() == "true"

    spark.sql(SILVER_DDL.format(target=target))

    reader = spark.readStream.format("iceberg")
    if options["STREAM_FROM_TIMESTAMP"]:
        reader = reader.option("stream-from-timestamp", options["STREAM_FROM_TIMESTAMP"])
    if options["MAX_ROWS_PER_BATCH"]:
        reader = reader.option("streaming-max-rows-per-micro-batch", options["MAX_ROWS_PER_BATCH"])
    stream = reader.load(source)

    query = (
        stream.writeStream.foreachBatch(make_batch_handler(target, use_alias))
        .option("checkpointLocation", args["CHECKPOINT_PATH"])
        .trigger(processingTime=f"{options['TRIGGER_SECONDS']} seconds")
        .start()
    )
    query.awaitTermination()
    job.commit()


if __name__ == "__main__":
    main()
