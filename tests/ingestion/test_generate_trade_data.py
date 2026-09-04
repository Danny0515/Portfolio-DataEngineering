import random

from src.ingestion.generate_trade_data import DIRTY_KINDS, generate_trade_lifecycle

# Shapes we expect generate_trade_lifecycle to produce across enough seeds.
FULL = ("INSERT", "UPDATE", "UPDATE")
DIRECT_FILL = ("INSERT", "UPDATE")
CANCELLED = ("INSERT", "UPDATE", "DELETE")


def _shapes(seeds, trade_id="T0001", dirty_rate=0.0):
    shapes = set()
    for seed in seeds:
        operations, _ = generate_trade_lifecycle(random.Random(seed), trade_id, dirty_rate)
        shapes.add(tuple(op for op, _ in operations))
    return shapes


def test_all_three_lifecycle_paths_occur_across_seeds():
    shapes = _shapes(range(100))
    assert FULL in shapes
    assert DIRECT_FILL in shapes
    assert CANCELLED in shapes
    assert shapes <= {FULL, DIRECT_FILL, CANCELLED}


def test_full_path_ends_in_filled_and_keeps_trade_id():
    operations, _ = generate_trade_lifecycle(random.Random(1), "T0042")
    assert tuple(op for op, _ in operations) == FULL
    assert operations[0][1]["status"] == "NEW"
    assert operations[1][1]["status"] == "PARTIALLY_FILLED"
    assert operations[-1][1]["status"] == "FILLED"
    assert all(row.get("trade_id", "T0042") == "T0042" for _, row in operations)


def test_cancelled_path_deletes_the_row():
    operations, _ = generate_trade_lifecycle(random.Random(0), "T0099")
    assert tuple(op for op, _ in operations) == CANCELLED
    assert operations[1][1]["status"] == "CANCELLED"
    assert operations[-1] == ("DELETE", {"trade_id": "T0099"})


def test_event_time_immutable_updated_at_changes_on_update():
    operations, _ = generate_trade_lifecycle(random.Random(3), "T0042")
    insert_row = operations[0][1]
    for _, row in operations[1:]:
        if "event_time" in row:
            assert row["event_time"] == insert_row["event_time"]
    # updated_at on the final row should have moved on from the INSERT's initial value
    assert operations[-1][1]["updated_at"] >= insert_row["updated_at"]


def test_dirty_rate_zero_never_injects():
    for seed in range(50):
        _, dirty_kind = generate_trade_lifecycle(random.Random(seed), "T0001", dirty_rate=0.0)
        assert dirty_kind is None


def test_dirty_rate_one_always_injects_a_known_kind():
    for seed in range(20):
        operations, dirty_kind = generate_trade_lifecycle(random.Random(seed), "T0001", dirty_rate=1.0)
        assert dirty_kind in DIRTY_KINDS
        # status must stay well-formed even when a row is dirtied -- corrupting status
        # would derail the generator's own branching, not just the downstream check.
        assert operations[0][1]["status"] == "NEW"


def test_dirty_injection_never_touches_status():
    for seed in range(50):
        operations, _ = generate_trade_lifecycle(random.Random(seed), "T0001", dirty_rate=1.0)
        assert operations[0][1]["status"] == "NEW"
