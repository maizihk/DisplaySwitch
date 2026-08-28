#!/usr/bin/env python3
import json
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent


def load(name: str):
    with (ROOT / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def main() -> None:
    schema = load("usb-switch-vectors.schema.json")
    vectors = load("usb-switch-vectors.json")
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(vectors)

    expected_ids = [f"USB-{index:03d}" for index in range(1, 17)]
    actual_ids = [vector["id"] for vector in vectors["vectors"]]
    if actual_ids != expected_ids:
        raise AssertionError(f"USB vector IDs must be USB-001 through USB-016: {actual_ids}")

    forbidden_keys = {"ip", "host", "port", "pairingCode", "serialNumber", "vid", "pid", "path", "uuid"}
    serialized = json.dumps(vectors, ensure_ascii=False)
    for key in forbidden_keys:
        if f'"{key}"' in serialized:
            raise AssertionError(f"public USB vectors contain forbidden local field: {key}")

    by_id = {vector["id"]: vector for vector in vectors["vectors"]}
    for vector_id in ("USB-001", "USB-002"):
        if [action["kind"] for action in by_id[vector_id]["expectedActions"]] != ["establishBaseline"]:
            raise AssertionError(f"{vector_id} must only establish the initial baseline")
    for vector_id in ("USB-003", "USB-013"):
        if any(action["kind"] == "sendWakeDisplay" for action in by_id[vector_id]["expectedActions"]):
            raise AssertionError(f"{vector_id} must have zero network calls")
    actions_14 = by_id["USB-014"]["expectedActions"]
    if [action["atMs"] for action in actions_14] != [10, 10] or {action["kind"] for action in actions_14} != {"switchDisplay", "sendWakeDisplay"}:
        raise AssertionError("USB-014 must schedule local DDC and wake-only network send concurrently")
    if [action["kind"] for action in by_id["USB-016"]["expectedActions"]] != ["wakeDisplay"]:
        raise AssertionError("USB-016 must coalesce network and local wake into one hardware call")

    print(f"Validated {len(vectors['vectors'])} USB switch vectors for config schema v{vectors['configSchemaVersion']}.")


if __name__ == "__main__":
    main()
