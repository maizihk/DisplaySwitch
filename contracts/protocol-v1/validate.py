#!/usr/bin/env python3
"""Validate DS-001 JSON Schemas, vectors, and cross-file invariants."""

from __future__ import annotations

import json
import math
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parent
MESSAGE_TYPES = {
    "handover_request",
    "usb_present",
    "usb_attached_and_awake",
    "committed",
    "status_probe",
    "status_response",
}
UUID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)


def load(name: str) -> Any:
    with (ROOT / name).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate(instance: Any, schema: dict[str, Any], registry: Registry) -> None:
    validator = Draft202012Validator(schema, registry=registry)
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.absolute_path))
    if errors:
        details = "\n".join(
            f"- {'/'.join(map(str, error.absolute_path)) or '<root>'}: {error.message}"
            for error in errors
        )
        raise AssertionError(details)


def assert_sorted(items: list[dict[str, Any]], label: str) -> None:
    values = [item["atMs"] for item in items]
    if values != sorted(values):
        raise AssertionError(f"{label} must be sorted by atMs: {values}")


def classify_message(vector: dict[str, Any], reference_time: float, pairing_code: str) -> str:
    input_value = vector["input"]
    if input_value["encoding"] == "rawUtf8":
        try:
            message = json.loads(
                input_value["value"],
                parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
            )
        except (TypeError, ValueError, json.JSONDecodeError):
            return "parse_error"
    else:
        message = input_value["value"]

    if not isinstance(message, dict):
        return "parse_error"

    required = {"version", "type", "eventID", "source", "target", "timestamp", "pairingCode"}
    if not required.issubset(message):
        return "missing_field"

    integer_version = isinstance(message["version"], int) and not isinstance(message["version"], bool)
    numeric_timestamp = isinstance(message["timestamp"], (int, float)) and not isinstance(message["timestamp"], bool)
    correct_types = (
        integer_version
        and isinstance(message["type"], str)
        and isinstance(message["eventID"], str)
        and isinstance(message["source"], str)
        and isinstance(message["target"], str)
        and numeric_timestamp
        and isinstance(message["pairingCode"], str)
        and ("wakeSucceeded" not in message or isinstance(message["wakeSucceeded"], bool))
    )
    if not correct_types or not math.isfinite(float(message["timestamp"])):
        return "invalid_field_type"
    if message["version"] != 1:
        return "unsupported_version"
    if message["type"] not in MESSAGE_TYPES:
        return "unknown_type"
    if not UUID_PATTERN.fullmatch(message["eventID"]):
        return "invalid_event_id"

    local = vector["localPlatform"]
    expected_source = "windows" if local == "mac" else "mac"
    if message["source"] != expected_source or message["target"] != local:
        return "wrong_direction"
    if message["pairingCode"] != pairing_code:
        return "pairing_mismatch"
    if abs(float(message["timestamp"]) - reference_time) > 10:
        return "timestamp_out_of_window"
    return "accepted"


def main() -> None:
    message_schema = load("message.schema.json")
    message_vectors_schema = load("message-validation-vectors.schema.json")
    state_vectors_schema = load("state-machine-vectors.schema.json")
    message_vectors = load("message-validation-vectors.json")
    state_vectors = load("state-machine-vectors.json")

    schemas = [message_schema, message_vectors_schema, state_vectors_schema]
    for schema in schemas:
        Draft202012Validator.check_schema(schema)

    registry = Registry()
    for schema in schemas:
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))

    validate(message_vectors, message_vectors_schema, registry)
    validate(state_vectors, state_vectors_schema, registry)

    message_ids = [vector["id"] for vector in message_vectors["vectors"]]
    if len(message_ids) != len(set(message_ids)):
        raise AssertionError("message vector IDs must be unique")

    for vector in message_vectors["vectors"]:
        expected = vector["expected"]
        hardware_total = sum(expected["hardwareCalls"].values())
        actual_reason = classify_message(
            vector,
            float(message_vectors["referenceTime"]),
            message_vectors["configuredPairingCode"],
        )
        if actual_reason != expected["reason"]:
            raise AssertionError(
                f"{vector['id']}: expected reason {expected['reason']}, got {actual_reason}"
            )
        if expected["accepted"]:
            if expected["reason"] != "accepted" or not expected["refreshPeer"]:
                raise AssertionError(f"{vector['id']}: accepted message must refresh peer")
            if vector["input"]["encoding"] != "jsonObject":
                raise AssertionError(f"{vector['id']}: accepted input must be a JSON object")
            validate(vector["input"]["value"], message_schema, registry)
        else:
            if expected["reason"] == "accepted":
                raise AssertionError(f"{vector['id']}: rejected message cannot use accepted reason")
            if expected["refreshPeer"] or expected["replyTypes"] or hardware_total:
                raise AssertionError(f"{vector['id']}: rejected message has forbidden side effects")

        if expected["replyTypes"] and vector["input"]["value"].get("type") != "status_probe":
            raise AssertionError(f"{vector['id']}: only status_probe may have a validation reply")

    state_ids = [vector["id"] for vector in state_vectors["vectors"]]
    if len(state_ids) != len(set(state_ids)):
        raise AssertionError("state vector IDs must be unique")

    for vector in state_vectors["vectors"]:
        assert_sorted(vector["steps"], f"{vector['id']} steps")
        assert_sorted(vector["expectedActions"], f"{vector['id']} expectedActions")

        local = vector["initialState"]["localPlatform"]
        expected_source = "windows" if local == "mac" else "mac"
        for step in vector["steps"]:
            input_value = step["input"]
            if input_value["kind"] != "receiveMessage":
                continue
            message = input_value["message"]
            validate(message, message_schema, registry)
            if message["source"] != expected_source or message["target"] != local:
                raise AssertionError(f"{vector['id']}: receive direction does not match local platform")

        actions = vector["expectedActions"]
        wake_count = sum(action["kind"] == "requestWake" for action in actions)
        switch_count = sum(action["kind"] == "requestSwitch" for action in actions)
        hardware = vector["expectedHardwareCalls"]
        if wake_count != hardware["wake"]:
            raise AssertionError(f"{vector['id']}: wake action count does not match hardware total")
        if switch_count != hardware["switchDisplay"]:
            raise AssertionError(f"{vector['id']}: switch action count does not match hardware total")
        if switch_count > 1:
            raise AssertionError(f"{vector['id']}: a scenario may request at most one display switch")

        for action in actions:
            if action["kind"] == "sendBurst" and action["count"] != 3:
                raise AssertionError(f"{vector['id']}: acknowledgement bursts must contain three messages")

    by_id = {vector["id"]: vector for vector in state_vectors["vectors"]}
    fallback = by_id["SM-003"]["expectedActions"]
    request_times = [
        action["atMs"]
        for action in fallback
        if action["kind"] == "sendMessage" and action["type"] == "handover_request"
    ]
    switch_times = [action["atMs"] for action in fallback if action["kind"] == "requestSwitch"]
    if request_times != [150, 300, 450, 600] or switch_times != [750]:
        raise AssertionError("SM-003 must preserve debounce, retry, and fallback timing")

    liveness = by_id["SM-013"]
    if [step["atMs"] for step in liveness["steps"]] != [6000, 6001]:
        raise AssertionError("SM-013 must cover the inclusive six-second liveness boundary")

    print(
        "Validated 3 schemas, "
        f"{len(message_vectors['vectors'])} message vectors, and "
        f"{len(state_vectors['vectors'])} state-machine vectors."
    )


if __name__ == "__main__":
    main()
