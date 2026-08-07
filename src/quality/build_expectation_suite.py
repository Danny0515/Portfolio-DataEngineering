#!/usr/bin/env python3
"""Build a Great Expectations ExpectationSuite from a declarative YAML rules file.

Config-driven by design: adding or editing a quality rule means editing a
file under rules/ (e.g. rules/silver_stock.yaml), not this script. This
loader has no table-specific logic — it just translates YAML into GX
Expectation objects via dynamic class lookup.
"""

from pathlib import Path

import great_expectations as gx
import great_expectations.expectations as gxe
from ruamel.yaml import YAML

RULES_DIR = Path(__file__).parent / "rules"
GX_PROJECT_ROOT = Path(__file__).parent

_yaml = YAML(typ="safe")


def _expectation_class(expectation_type: str):
    """expect_column_values_to_not_be_null -> ExpectColumnValuesToNotBeNull"""
    pascal_name = "".join(part.capitalize() for part in expectation_type.split("_"))
    return getattr(gxe, pascal_name)


def build_suite(rules_path: Path) -> gx.ExpectationSuite:
    config = _yaml.load(rules_path.read_text())
    expectations = []
    for rule in config["rules"]:
        expectation_cls = _expectation_class(rule["expectation"])
        kwargs = dict(rule.get("kwargs", {}))
        if "column" in rule:
            kwargs["column"] = rule["column"]
        expectations.append(expectation_cls(notes=rule.get("notes"), **kwargs))
    return gx.ExpectationSuite(name=config["suite_name"], expectations=expectations)


def main():
    rules_path = RULES_DIR / "silver_stock.yaml"
    suite = build_suite(rules_path)

    context = gx.get_context(mode="file", project_root_dir=str(GX_PROJECT_ROOT))
    context.suites.add_or_update(suite)

    print(
        f"Saved suite '{suite.name}' ({len(suite.expectations)} expectations) "
        f"to {context.root_directory}/expectations/"
    )


if __name__ == "__main__":
    main()
