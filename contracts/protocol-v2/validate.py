#!/usr/bin/env python3
"""Validate DS-005 protocol v2 schemas, authentication, and public vectors."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import unicodedata
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parent
MESSAGE_TYPES = {
    "status_probe",
    "status_response",
    "input_present",
    "handover_request",
    "target_ready",
    "committed",
    "cancelled",
}
COMMON_FIELDS = {
    "version",
    "type",
    "eventID",
    "sourceEndpointID",
    "targetEndpointID",
    "sourcePlatform",
    "timestamp",
    "nonce",
    "authTag",
}
CANONICAL_FIELDS = [
    "type",
    "eventID",
    "sourceEndpointID",
    "targetEndpointID",
    "sourcePlatform",
    "timestamp",
    "nonce",
    "intent",
    "wakeSucceeded",
    "switchSucceeded",
    "reason",
]
UUID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{22}$")
TAG_PATTERN = re.compile(r"^[A-Za-z0-9_-]{43}$")


def load(name: str) -> Any:
    with (ROOT / name).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def b64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def b64url_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))


def derive_key(secret: bytes, source_endpoint_id: str) -> bytes:
    salt = f"DisplaySwitch-v2-auth|{source_endpoint_id.lower()}".encode("ascii")
    return hashlib.pbkdf2_hmac("sha256", secret, salt, 200000, dklen=32)


def canonical_auth_input(message: dict[str, Any]) -> bytes:
    lines = ["DisplaySwitch/v2", "version:2"]
    for field in CANONICAL_FIELDS:
        value = message.get(field)
        if value is None:
            encoded = "null"
        elif isinstance(value, bool):
            encoded = "true" if value else "false"
        elif field in {"eventID", "sourceEndpointID", "targetEndpointID"}:
            encoded = str(value).lower()
        else:
            encoded = str(value)
        lines.append(f"{field}:{encoded}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def auth_tag(key: bytes, message: dict[str, Any]) -> str:
    return b64url_encode(hmac.new(key, canonical_auth_input(message), hashlib.sha256).digest())


def validate(instance: Any, schema: dict[str, Any], registry: Registry) -> None:
    validator = Draft202012Validator(schema, registry=registry)
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.absolute_path))
    if errors:
        details = "\n".join(
            f"- {'/'.join(map(str, error.absolute_path)) or '<root>'}: {error.message}"
            for error in errors
        )
        raise AssertionError(details)


def classify_message(
    vector: dict[str, Any],
    reference_time: int,
    local_endpoint_id: str,
    known_source_endpoint_id: str,
    key: bytes,
    message_schema: dict[str, Any],
    registry: Registry,
) -> str:
    input_value = vector["input"]
    if input_value["encoding"] == "rawUtf8":
        try:
            message = json.loads(input_value["value"])
        except (TypeError, ValueError, json.JSONDecodeError):
            return "parse_error"
    else:
        message = input_value["value"]

    if not isinstance(message, dict):
        return "parse_error"
    if not COMMON_FIELDS.issubset(message):
        return "missing_field"

    integer_version = isinstance(message["version"], int) and not isinstance(message["version"], bool)
    integer_timestamp = isinstance(message["timestamp"], int) and not isinstance(message["timestamp"], bool)
    correct_types = (
        integer_version
        and isinstance(message["type"], str)
        and isinstance(message["eventID"], str)
        and isinstance(message["sourceEndpointID"], str)
        and (message["targetEndpointID"] is None or isinstance(message["targetEndpointID"], str))
        and isinstance(message["sourcePlatform"], str)
        and integer_timestamp
        and isinstance(message["nonce"], str)
        and isinstance(message["authTag"], str)
    )
    if not correct_types:
        return "invalid_field_type"
    if message["version"] != 2:
        return "unsupported_version"
    if message["type"] not in MESSAGE_TYPES:
        return "unknown_type"
    if not UUID_PATTERN.fullmatch(message["eventID"]):
        return "invalid_event_id"
    if not UUID_PATTERN.fullmatch(message["sourceEndpointID"]):
        return "unknown_source"
    target = message["targetEndpointID"]
    if target is not None and not UUID_PATTERN.fullmatch(target):
        return "wrong_target"
    if message["sourceEndpointID"].lower() != known_source_endpoint_id.lower():
        return "unknown_source"
    if message["type"] == "status_probe":
        if target is not None and target.lower() != local_endpoint_id.lower():
            return "wrong_target"
    elif target is None or target.lower() != local_endpoint_id.lower():
        return "wrong_target"
    if abs(message["timestamp"] - reference_time) > 10:
        return "timestamp_out_of_window"
    if not NONCE_PATTERN.fullmatch(message["nonce"]):
        return "invalid_nonce"
    if not TAG_PATTERN.fullmatch(message["authTag"]):
        return "invalid_auth_tag"

    schema_errors = list(Draft202012Validator(message_schema, registry=registry).iter_errors(message))
    if schema_errors:
        return "invalid_type_fields"

    expected_tag = auth_tag(key, message)
    if not hmac.compare_digest(message["authTag"], expected_tag):
        return "authentication_failed"
    return "accepted"


def assert_sorted(items: list[dict[str, Any]], label: str) -> None:
    times = [item["atMs"] for item in items]
    if times != sorted(times):
        raise AssertionError(f"{label} must be sorted by atMs: {times}")


def main() -> None:
    message_schema = load("message.schema.json")
    auth_schema = load("auth-vectors.schema.json")
    message_vectors_schema = load("message-validation-vectors.schema.json")
    state_vectors_schema = load("state-machine-vectors.schema.json")
    auth_vectors = load("auth-vectors.json")
    message_vectors = load("message-validation-vectors.json")
    state_vectors = load("state-machine-vectors.json")

    schemas = [message_schema, auth_schema, message_vectors_schema, state_vectors_schema]
    for schema in schemas:
        Draft202012Validator.check_schema(schema)

    registry = Registry()
    for schema in schemas:
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))

    validate(auth_vectors, auth_schema, registry)
    validate(message_vectors, message_vectors_schema, registry)
    validate(state_vectors, state_vectors_schema, registry)

    synthetic_secret = bytes.fromhex(auth_vectors["syntheticInputSecretHex"])
    normalization_ids = [vector["id"] for vector in auth_vectors["normalizationVectors"]]
    if len(normalization_ids) != len(set(normalization_ids)):
        raise AssertionError("normalization vector IDs must be unique")
    for vector in auth_vectors["normalizationVectors"]:
        input_text = bytes.fromhex(vector["inputUtf8Hex"]).decode("utf-8")
        normalized = unicodedata.normalize("NFC", input_text).encode("utf-8").hex()
        if normalized != vector["expectedNfcUtf8Hex"]:
            raise AssertionError(f"{vector['id']}: NFC normalization mismatch")

    auth_ids = [vector["id"] for vector in auth_vectors["vectors"]]
    if len(auth_ids) != len(set(auth_ids)):
        raise AssertionError("authentication vector IDs must be unique")
    for vector in auth_vectors["vectors"]:
        key = derive_key(synthetic_secret, vector["sourceEndpointID"])
        if b64url_encode(key) != vector["expectedDerivedKeyBase64Url"]:
            raise AssertionError(f"{vector['id']}: derived key mismatch")
        message = vector.get("messageWithoutAuthTag")
        if message is None:
            continue
        canonical = canonical_auth_input(message)
        if canonical.hex() != vector["expectedCanonicalUtf8Hex"]:
            raise AssertionError(f"{vector['id']}: canonical bytes mismatch")
        if auth_tag(key, message) != vector["expectedAuthTag"]:
            raise AssertionError(f"{vector['id']}: authentication tag mismatch")

    message_ids = [vector["id"] for vector in message_vectors["vectors"]]
    if len(message_ids) != len(set(message_ids)):
        raise AssertionError("message vector IDs must be unique")
    key = b64url_decode(message_vectors["authKeyBase64Url"])
    if len(key) != 32:
        raise AssertionError("message validation key must be 32 bytes")
    for vector in message_vectors["vectors"]:
        actual_reason = classify_message(
            vector,
            message_vectors["referenceTime"],
            message_vectors["localEndpointID"],
            message_vectors["knownSourceEndpointID"],
            key,
            message_schema,
            registry,
        )
        expected = vector["expected"]
        if actual_reason != expected["reason"]:
            raise AssertionError(
                f"{vector['id']}: expected reason {expected['reason']}, got {actual_reason}"
            )
        if expected["accepted"] != (actual_reason == "accepted"):
            raise AssertionError(f"{vector['id']}: accepted flag disagrees with reason")
        if expected["accepted"] != expected["refreshPeer"]:
            raise AssertionError(f"{vector['id']}: only accepted messages may refresh liveness")
        if any(expected["hardwareCalls"].values()):
            raise AssertionError(f"{vector['id']}: validation must not invoke hardware")
        replies = expected["replyTypes"]
        message = vector["input"].get("value")
        if replies and (not isinstance(message, dict) or message.get("type") != "status_probe"):
            raise AssertionError(f"{vector['id']}: only status_probe may reply during validation")

    state_ids = [vector["id"] for vector in state_vectors["vectors"]]
    expected_ids = [f"P-{index:03d}" for index in range(1, 14)] + [
        f"P-{index:03d}" for index in range(16, 21)
    ]
    if state_ids != expected_ids:
        raise AssertionError(
            "state vector IDs must be P-001 through P-013 and P-016 through P-020: "
            f"{state_ids}"
        )
    for vector in state_vectors["vectors"]:
        assert_sorted(vector["steps"], f"{vector['id']} steps")
        assert_sorted(vector["expectedActions"], f"{vector['id']} expectedActions")
        actions = vector["expectedActions"]
        wake_count = sum(action["kind"] == "requestWake" for action in actions)
        switch_count = sum(action["kind"] == "requestSwitch" for action in actions)
        hardware = vector["expectedHardwareCalls"]
        if wake_count != hardware["wake"]:
            raise AssertionError(f"{vector['id']}: wake action count mismatch")
        if switch_count != hardware["switchDisplay"]:
            raise AssertionError(f"{vector['id']}: switch action count mismatch")
        if switch_count > 1:
            raise AssertionError(f"{vector['id']}: an event may switch displays at most once")
        if hardware["inputActions"] != 0:
            raise AssertionError(f"{vector['id']}: protocol vectors cannot control USB or Bluetooth")
        for action in actions:
            if action["kind"] != "sendMessage":
                continue
            if action.get("type") == "target_ready" and "wakeSucceeded" not in action:
                raise AssertionError(f"{vector['id']}: target_ready must carry wakeSucceeded")
            if action.get("type") == "committed" and "switchSucceeded" not in action:
                raise AssertionError(f"{vector['id']}: committed must carry switchSucceeded")

    by_id = {vector["id"]: vector for vector in state_vectors["vectors"]}
    if [action["atMs"] for action in by_id["P-006"]["expectedActions"]] != [150, 3150, 3150]:
        raise AssertionError("P-006 must start discovery after debounce and time out three seconds later")
    p5_locks = [
        action["endpointID"]
        for action in by_id["P-005"]["expectedActions"]
        if action["kind"] == "lockTarget"
    ]
    first_claim = by_id["P-005"]["steps"][0]["input"]["endpointID"]
    if p5_locks != [first_claim]:
        raise AssertionError("P-005 must lock exactly the first valid declaration")
    p19_sends = [
        action["atMs"]
        for action in by_id["P-019"]["expectedActions"]
        if action["kind"] == "sendMessage" and action.get("type") == "handover_request"
    ]
    p19_switches = [
        action["atMs"]
        for action in by_id["P-019"]["expectedActions"]
        if action["kind"] == "requestSwitch"
    ]
    if p19_sends != [0, 150, 300, 450] or p19_switches != [600]:
        raise AssertionError("P-019 must preserve four retries and the 600 ms manual fallback")
    for vector_id in ("P-001", "P-006", "P-008", "P-010", "P-013", "P-016", "P-020"):
        if any(by_id[vector_id]["expectedHardwareCalls"].values()):
            raise AssertionError(f"{vector_id} must have zero hardware effects")

    print(
        f"Validated {len(schemas)} schemas, {len(auth_vectors['normalizationVectors'])} normalization vector, "
        f"{len(auth_vectors['vectors'])} authentication vectors, "
        f"{len(message_vectors['vectors'])} message vectors, and {len(state_vectors['vectors'])} state-machine vectors."
    )


if __name__ == "__main__":
    main()
