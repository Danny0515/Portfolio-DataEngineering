"""Consume and summarize CDC events from an MSK topic for Slice 2a verification.

Unlike generate_trade_data.py (which writes into the pipeline), this reads out of it: it
drains a bounded window of a Kafka topic to prove insert/update/delete produce Debezium
envelopes with before/after images and a source LSN (docs/specs/slice2a-cdc-ingestion.md
§4 item 8), and is built to be reused unmodified for item 9's DLQ inspection by pointing
`topic` at `transaction.trade.v1.dlq` instead.

Deployed as a Lambda for the same reason as generate_trade_data.py (ADR-0008): the MSK
brokers sit in a private subnet with no IGW/NAT, so nothing outside the VPC can open a
socket to them directly; the Lambda's ENI can, and is triggered over the public
`lambda:Invoke` API.

Two things intentionally NOT hardcoded, because nobody has inspected a real decoded
message from this pipeline yet (see the runbook this feeds): the exact Debezium envelope
field layout (assumed here to be Kafka Connect's standard before/after/source/op/ts_ms
shape, LSN at source.lsn per Debezium's Postgres connector docs) and the raw Kafka
message key's shape (Debezium keys by the row's primary-key Struct; with no
ExtractField$Key SMT configured in msk_connector.tf, StringConverter's plain
`.toString()` on that Struct is likely "Struct{trade_id=...}", not a bare trade_id -- so
grouping below uses the trade_id parsed out of the envelope's own before/after payload
instead of trusting the raw key's shape). `sample_raw_envelope` is always included in the
summary so the first real invocation confirms or corrects both assumptions instead of
failing silently.

Deserialization happens by hand per message (KafkaDeserializer.deserialize(topic, bytes_)
is called directly, not wired in as KafkaConsumer's `value_deserializer`) specifically so
one malformed/undecodable message can't crash the whole poll -- required for this Lambda
to be reusable against the DLQ topic (item 9) without modification, since DLQ payloads
are, by definition, the ones that failed to serialize/convert.

See docs/specs/slice2a-cdc-ingestion.md §4 item 8, §7.
"""

import os
import time
import uuid
from collections import defaultdict

import boto3
from aws_schema_registry import SchemaRegistryClient
from aws_schema_registry.adapter.kafka import KafkaDeserializer
from kafka import KafkaConsumer

BOOTSTRAP_BROKERS = os.environ.get("MSK_BOOTSTRAP_BROKERS", "")
GLUE_REGISTRY_NAME = os.environ.get("GLUE_REGISTRY_NAME", "slice2-trade-events")


def _build_consumer(topic: str) -> KafkaConsumer:
    """Fresh, unique consumer group per call -- every invocation sees the topic's full
    history regardless of cold starts, at the cost of re-reading from the start each
    time (see runbook for the tradeoff writeup)."""
    return KafkaConsumer(
        topic,
        bootstrap_servers=BOOTSTRAP_BROKERS.split(","),
        security_protocol="SSL",  # unauthenticated MSK, TLS-only broker listener (msk.tf)
        group_id=f"slice2-cdc-verifier-{uuid.uuid4()}",
        auto_offset_reset="earliest",
        enable_auto_commit=False,
        key_deserializer=lambda k: k.decode("utf-8") if k is not None else None,
        value_deserializer=lambda v: v,  # raw bytes; decoded by hand below (see docstring)
    )


def _field(record, name):
    """Debezium records decode to *something* dict-like; support both mapping and
    attribute access since aws_schema_registry's exact Avro return shape hasn't been
    inspected against a real message yet."""
    if record is None:
        return None
    if hasattr(record, "get"):
        return record.get(name)
    return getattr(record, name, None)


def _trade_id_for(before, after, raw_key):
    """Prefer the envelope's own payload over the raw Kafka key: see module docstring
    for why the raw key likely isn't a bare trade_id."""
    return _field(after, "trade_id") or _field(before, "trade_id") or raw_key


def _decode(deserializer, topic, raw_value):
    if raw_value is None:
        return None, None  # Debezium delete tombstone: null value, same key
    try:
        return deserializer.deserialize(topic, raw_value).data, None
    except Exception as exc:  # noqa: BLE001 -- deliberately broad, see module docstring
        return None, f"{type(exc).__name__}: {exc}"


def consume(topic: str, max_messages: int, timeout_seconds: int) -> dict:
    glue_client = boto3.client("glue")
    registry_client = SchemaRegistryClient(glue_client, registry_name=GLUE_REGISTRY_NAME)
    deserializer = KafkaDeserializer(registry_client)

    consumer = _build_consumer(topic)
    op_counts: dict[str, int] = defaultdict(int)
    by_key: dict[str, list] = defaultdict(list)
    sample_raw_envelope = None
    total = 0
    deadline = time.monotonic() + timeout_seconds

    try:
        while total < max_messages and time.monotonic() < deadline:
            batch = consumer.poll(timeout_ms=1000, max_records=max_messages - total)
            for records in batch.values():
                for record in records:
                    total += 1
                    envelope, error = _decode(deserializer, topic, record.value)

                    if error:
                        op_counts["decode_error"] += 1
                        by_key[record.key or "<unknown>"].append(
                            {"partition": record.partition, "offset": record.offset, "error": error}
                        )
                        continue
                    if envelope is None:
                        op_counts["tombstone"] += 1
                        by_key[record.key or "<unknown>"].append(
                            {"partition": record.partition, "offset": record.offset, "op": "tombstone"}
                        )
                        continue

                    before, after = _field(envelope, "before"), _field(envelope, "after")
                    op = _field(envelope, "op") or "unknown"
                    source = _field(envelope, "source")
                    trade_id = _trade_id_for(before, after, record.key)

                    op_counts[op] += 1
                    if sample_raw_envelope is None:
                        sample_raw_envelope = envelope if isinstance(envelope, dict) else str(envelope)

                    by_key[trade_id].append(
                        {
                            "partition": record.partition,
                            "offset": record.offset,
                            "op": op,
                            "before": before,
                            "after": after,
                            "lsn": _field(source, "lsn"),
                            "ts_ms": _field(envelope, "ts_ms"),
                        }
                    )
                    if total >= max_messages:
                        break
    finally:
        consumer.close()

    for events in by_key.values():
        events.sort(key=lambda e: (e["partition"], e["offset"]))

    return {
        "topic": topic,
        "total_messages": total,
        "op_counts": dict(op_counts),
        "distinct_keys": len(by_key),
        "events_by_key": dict(by_key),
        "sample_raw_envelope": sample_raw_envelope,
    }


def lambda_handler(event, context):
    """Event payload: {topic?, max_messages?, timeout_seconds?}. Reused unmodified for
    §4 item 9 by passing topic="transaction.trade.v1.dlq"."""
    event = event or {}
    result = consume(
        topic=event.get("topic", "transaction.trade.v1"),
        max_messages=event.get("max_messages", 100),
        timeout_seconds=event.get("timeout_seconds", 20),
    )
    print(f"verify_cdc_events summary: total={result['total_messages']} ops={result['op_counts']}")
    return result
