#!/usr/bin/env python3
"""Short transactions for the stall detector's shared state file.

The detector deliberately does not keep this lock while it reads reports,
walks worktrees, or observes panes.  Callers take a snapshot, do blocking work
outside the lock, and merge only their detector-owned fields against the state
that is current at commit time.
"""

from __future__ import annotations

import copy
import datetime as _datetime
import fcntl
import os
import sys
from contextlib import contextmanager
from typing import Any, Iterator

import yaml


STATE_MAP_KEYS = (
    "pane_idle_streak",
    "worktree_progress",
    "gunshi2_escalations",
    "gunshi2_capacity_notices",
    "rca_parent_cooldowns",
    "rca_elapsed",
    "resume_notifications",
)
DEFAULTS = {
    "last_scan": None,
    "last_error": None,
    "scan_count": 0,
    **{key: {} for key in STATE_MAP_KEYS},
}
TERMINAL_ESCALATION_STATES = {"dispatched", "suppressed_terminal"}
TERMINAL_CHECKPOINT_STATES = {"notified"}
ALERT_SEVERITY_RANK = {"P3": 0, "P2": 1, "P1": 2, "P0": 3}


def _timestamp(value: Any) -> _datetime.datetime | None:
    if value is None:
        return None
    try:
        parsed = _datetime.datetime.fromisoformat(str(value).strip().strip("'\""))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_datetime.timezone.utc)
    return parsed


def _newer(left: Any, right: Any) -> Any:
    """Return the value whose timestamp is later; preserve left on ties."""
    left_ts = _timestamp(left)
    right_ts = _timestamp(right)
    if left_ts is None:
        return right if right_ts is not None else left
    if right_ts is None or left_ts >= right_ts:
        return left
    return right


def _load_unlocked(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as stream:
            return yaml.safe_load(stream)
    except FileNotFoundError:
        return None


def _atomic_write(path: str, document: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    temporary = f"{path}.tmp.state.{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as stream:
        yaml.safe_dump(document, stream, allow_unicode=True, sort_keys=False)
    os.replace(temporary, path)


@contextmanager
def locked_yaml(path: str) -> Iterator[Any]:
    """Hold a short per-document lock for an atomic YAML read/replace.

    The stall detector performs report and pane work outside this lock.  This
    helper is intentionally generic so the alert document can use the same
    short-transaction discipline without sharing the detector state lock.
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    lock = open(f"{path}.lock", "a+", encoding="utf-8")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield _load_unlocked(path)
    finally:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()


def _alert_map(alerts: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(alerts, list):
        return {}
    return {
        str(item["key"]): item
        for item in alerts
        if isinstance(item, dict) and item.get("key")
    }


def _alert_changed(current: Any, baseline: Any) -> bool:
    if not isinstance(current, dict) or not isinstance(baseline, dict):
        return current != baseline
    fields = (
        "status", "severity", "first_seen", "last_seen", "observed_at",
        "resolved_at", "last_notified", "count", "evidence",
    )
    return any(current.get(field) != baseline.get(field) for field in fields)


def _alert_severity(value: Any) -> str:
    value = str(value or "P2")
    return value if value in ALERT_SEVERITY_RANK else "P2"


def _alert_max_severity(left: Any, right: Any) -> str:
    left = _alert_severity(left)
    right = _alert_severity(right)
    return left if ALERT_SEVERITY_RANK[left] >= ALERT_SEVERITY_RANK[right] else right


def _alert_newer(left: Any, right: Any) -> Any:
    """Return the later alert timestamp, preserving left on ties."""
    return _newer(left, right)


def _alert_observation(record: Any) -> _datetime.datetime | None:
    """Return the generation timestamp used to order concurrent observations.

    ``observed_at`` is written by current detector versions.  ``last_seen``
    remains the compatibility fallback for alerts written by older versions;
    it is intentionally not inferred from ``last_notified`` because delivery
    time is not an observation generation.
    """
    if not isinstance(record, dict):
        return None
    for field in ("observed_at", "last_seen", "resolved_at", "first_seen"):
        parsed = _timestamp(record.get(field))
        if parsed is not None:
            return parsed
    return None


def _alert_observation_value(record: Any) -> Any:
    """Return the original timestamp spelling for an accepted observation."""
    if not isinstance(record, dict):
        return None
    for field in ("observed_at", "last_seen", "resolved_at", "first_seen"):
        if _timestamp(record.get(field)) is not None:
            return record.get(field)
    return None


def _alert_wins(proposed: Any, current: Any, baseline: Any) -> bool:
    """Decide whether a proposal may replace the current alert record.

    A proposal with a newer explicit observation wins.  Equal observations use
    a deterministic terminal-status tie rule, so overlapping active/resolving
    scans commute regardless of arrival order.  When an
    old record has no generation timestamp, the pre-existing baseline change
    guard is retained as a conservative compatibility fallback.
    """
    if not isinstance(current, dict):
        return True
    proposed_observed = _alert_observation(proposed)
    current_observed = _alert_observation(current)
    if proposed_observed is not None and current_observed is not None:
        return proposed_observed > current_observed
    if proposed_observed is not None and current_observed is None:
        return True
    if proposed_observed is None and current_observed is not None:
        return False
    if isinstance(baseline, dict) and _alert_changed(current, baseline):
        return False
    return current == baseline


def _merge_alert_winner(current: Any, proposed: dict[str, Any]) -> dict[str, Any]:
    """Merge monotonic fields when a newer proposal wins the observation race."""
    merged = copy.deepcopy(proposed)
    if not isinstance(current, dict):
        return merged
    merged["first_seen"] = _alert_earliest(
        current.get("first_seen"), proposed.get("first_seen"))
    merged["last_seen"] = _alert_newer(
        current.get("last_seen"), proposed.get("last_seen"))
    merged["resolved_at"] = _alert_newer(
        current.get("resolved_at"), proposed.get("resolved_at"))
    merged["severity"] = _alert_max_severity(
        current.get("severity"), proposed.get("severity"))
    merged["last_notified"] = _newer(
        current.get("last_notified"), proposed.get("last_notified"))
    try:
        merged["count"] = max(
            int(current.get("count", 0) or 0),
            int(proposed.get("count", 0) or 0),
        )
    except (TypeError, ValueError):
        merged["count"] = current.get("count", proposed.get("count", 0))
    observation = _alert_observation_value(proposed)
    if observation is not None:
        merged["observed_at"] = observation
    return merged


def _merge_alert_tie(current: dict[str, Any], proposed: dict[str, Any]) -> dict[str, Any]:
    """Keep the committed event on an observation tie and merge monotonic data.

    Equal observations can be produced by overlapping scans after one of them
    releases the alert lock.  A terminal resolution wins an exact observation
    tie so active/resolving arrival order is commutative.  Timestamps, severity,
    count, and first_seen remain monotonic even when the proposal loses.
    """
    merged = copy.deepcopy(current)
    merged["first_seen"] = _alert_earliest(
        current.get("first_seen"), proposed.get("first_seen"))
    merged["last_seen"] = _alert_newer(
        current.get("last_seen"), proposed.get("last_seen"))
    merged["resolved_at"] = _alert_newer(
        current.get("resolved_at"), proposed.get("resolved_at"))
    merged["severity"] = _alert_max_severity(
        current.get("severity"), proposed.get("severity"))
    merged["last_notified"] = _newer(
        current.get("last_notified"), proposed.get("last_notified"))
    try:
        merged["count"] = max(
            int(current.get("count", 0) or 0),
            int(proposed.get("count", 0) or 0),
        )
    except (TypeError, ValueError):
        merged["count"] = current.get("count", proposed.get("count", 0))
    if (_alert_observation(current) is not None
            and _alert_observation(current) == _alert_observation(proposed)
            and "resolved" in {current.get("status"), proposed.get("status")}):
        merged["status"] = "resolved"
    return merged


def _alert_earliest(left: Any, right: Any) -> Any:
    """Return the earliest alert timestamp, preserving left on ties."""
    left_ts = _timestamp(left)
    right_ts = _timestamp(right)
    if left_ts is None:
        return right
    if right_ts is None or left_ts <= right_ts:
        return left
    return right


def merge_alerts(path: str, baseline_alerts: Any, proposed_alerts: Any,
                 active_keys: Any, notify_intents: Any, now_iso: str,
                 repeat_cooldown_min: int = 30) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Merge one detector observation and atomically claim its notifications.

    ``proposed_alerts`` is the detector's observation assembled outside the
    lock.  Under the lock we re-read the current document, merge active and
    resolved records, and decide notification ownership from the current
    ``last_notified`` value.  Thus two overlapping scans can both observe the
    same candidate, but only the first commit claims a notification.  A stale
    resolver also cannot overwrite a record changed since its baseline.
    """
    baseline_map = _alert_map(baseline_alerts)
    proposed_map = _alert_map(proposed_alerts)
    active = {str(key) for key in (active_keys or [])}
    intents = {}
    for raw_intent in notify_intents or []:
        if not isinstance(raw_intent, dict) or not raw_intent.get("key"):
            continue
        intents.setdefault(str(raw_intent["key"]), raw_intent)

    with locked_yaml(path) as raw:
        current_alerts = raw.get("alerts") if isinstance(raw, dict) else []
        if not isinstance(current_alerts, list):
            current_alerts = []
        current_alerts = copy.deepcopy(current_alerts)
        current_map = _alert_map(current_alerts)
        output = copy.deepcopy(current_alerts)
        output_map = _alert_map(output)

        def install(record: dict[str, Any]) -> None:
            key = str(record.get("key"))
            if key in output_map:
                for index, existing in enumerate(output):
                    if isinstance(existing, dict) and str(existing.get("key")) == key:
                        output[index] = record
                        break
            else:
                output.append(record)
            output_map[key] = record

        winning_active_keys: set[str] = set()

        # Merge every record observed by this scan. Records introduced by a
        # concurrent scan but absent from this proposal remain in ``output``.
        for key, proposed in proposed_map.items():
            current = current_map.get(key)
            if not isinstance(proposed, dict):
                continue
            baseline = baseline_map.get(key)
            if not _alert_wins(proposed, current, baseline):
                # The current record is already newer (or tied).  This branch
                # applies equally to active and resolving proposals: an older
                # active scan must not reopen a newer resolution, and an older
                # resolution must not close a newer active observation.  The
                # losing proposal may still carry an earlier first_seen.
                if isinstance(current, dict):
                    install(_merge_alert_tie(current, proposed))
                continue

            merged = _merge_alert_winner(current, proposed)
            if key in active:
                merged["status"] = "open"
                winning_active_keys.add(key)
            install(merged)

        claimed: list[dict[str, Any]] = []
        now = _timestamp(now_iso)
        for key, intent in intents.items():
            if key not in winning_active_keys:
                continue
            current = current_map.get(key)
            proposed = proposed_map.get(key) or {}
            record = output_map.get(key)
            if not isinstance(record, dict):
                continue
            candidate_severity = _alert_severity(intent.get("severity", proposed.get("severity")))
            current_severity = _alert_severity(current.get("severity")) if isinstance(current, dict) else None
            last_notified = _timestamp(current.get("last_notified")) if isinstance(current, dict) else None
            elapsed = None
            if now is not None and last_notified is not None:
                elapsed = (now - last_notified).total_seconds() / 60.0
            should_notify = (
                current is None
                or (isinstance(current, dict) and current.get("status") != "open")
                or ALERT_SEVERITY_RANK[candidate_severity] > ALERT_SEVERITY_RANK.get(current_severity or "P2", 1)
                or last_notified is None
                or (elapsed is not None and elapsed >= repeat_cooldown_min)
            )
            if not should_notify:
                continue

            try:
                count = max(
                    int(record.get("count", 0) or 0),
                    int(current.get("count", 0) or 0) if isinstance(current, dict) else 0,
                )
            except (TypeError, ValueError):
                count = 0
            count += 0 if current is None and count > 0 else 1
            if current is None and count < 1:
                count = 1
            record["count"] = count
            record["last_notified"] = _newer(record.get("last_notified"), now_iso)
            record["status"] = "open"
            record["severity"] = _alert_max_severity(record.get("severity"), candidate_severity)
            install(record)
            claimed.append({
                "key": key,
                "severity": record["severity"],
                "summary": str(intent.get("summary") or ""),
                # Keep the alert family stable while giving each committed
                # notification episode its own explicit inbox dedup key.
                "dedup_key": f"{str(intent.get('dedup_key') or f'stall-alert:{key}')}:{count}",
            })

        if len(output) > 200:
            output = output[-200:]
        _atomic_write(path, {"alerts": output})
        return output, claimed


def normalize_state(raw: Any) -> tuple[dict[str, Any], bool]:
    changed = not isinstance(raw, dict)
    state = copy.deepcopy(raw) if isinstance(raw, dict) else {}

    # Migrate the partial implementation without losing a pending episode.
    if (not state.get("resume_notifications")
            and isinstance(state.get("assigned_resume_notifications"), dict)):
        state["resume_notifications"] = state["assigned_resume_notifications"]
        changed = True
    if "assigned_resume_notifications" in state:
        state.pop("assigned_resume_notifications", None)
        changed = True

    for key, default in DEFAULTS.items():
        if key not in state:
            state[key] = copy.deepcopy(default)
            changed = True
    for key in STATE_MAP_KEYS:
        if not isinstance(state.get(key), dict):
            state[key] = {}
            changed = True
    if not isinstance(state.get("scan_count"), int):
        try:
            state["scan_count"] = int(state.get("scan_count") or 0)
        except (TypeError, ValueError):
            state["scan_count"] = 0
        changed = True
    return state, changed


@contextmanager
def locked_state(path: str) -> Iterator[dict[str, Any]]:
    """Yield normalized state while holding the lock only for this transaction."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    lock = open(f"{path}.lock", "a+", encoding="utf-8")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        state, changed = normalize_state(_load_unlocked(path))
        if changed or not os.path.exists(path):
            _atomic_write(path, state)
        yield state
    finally:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()


def snapshot(path: str) -> dict[str, Any]:
    """Read/initialize state under a short lock and return a detached snapshot."""
    with locked_state(path) as state:
        return copy.deepcopy(state)


def _merge_resume(current: Any, baseline: Any, candidate: Any) -> Any:
    if not isinstance(current, dict):
        return copy.deepcopy(candidate)
    if not isinstance(candidate, dict):
        return copy.deepcopy(current)

    current_progress = _timestamp(current.get("progress_at"))
    candidate_progress = _timestamp(candidate.get("progress_at"))
    current_task = current.get("task_id")
    candidate_task = candidate.get("task_id")
    current_episode = current.get("episode_key")
    candidate_episode = candidate.get("episode_key")

    # A later task/progress episode wins.  This prevents an older scan from
    # replacing a freshly assigned task or a newer progress observation.
    if (candidate_task != current_task or candidate_episode != current_episode):
        if (candidate_progress is not None
                and (current_progress is None or candidate_progress > current_progress)):
            return copy.deepcopy(candidate)
        return copy.deepcopy(current)

    merged = copy.deepcopy(candidate)
    # Delivery is a monotonic commit for one episode.  A scan may only create
    # or update the pending intent; it can never roll delivered=true back.
    if current.get("delivered") is True:
        merged["delivered"] = True
        for key in ("delivered_at", "delivery_mode"):
            if key in current:
                merged[key] = current[key]
    elif current.get("delivered") is not None and "delivered" not in merged:
        merged["delivered"] = current["delivered"]
    if baseline == current and candidate != baseline:
        return copy.deepcopy(candidate)
    return merged


def _merge_rca(current: Any, baseline: Any, candidate: Any) -> Any:
    if not isinstance(current, dict):
        return copy.deepcopy(candidate)
    if not isinstance(candidate, dict):
        return copy.deepcopy(current)
    if baseline == current and candidate != baseline:
        return copy.deepcopy(candidate)

    merged = copy.deepcopy(current)
    for key, value in candidate.items():
        if key not in merged:
            merged[key] = copy.deepcopy(value)
    current_checkpoint = current.get("checkpoint")
    candidate_checkpoint = candidate.get("checkpoint")
    if isinstance(candidate_checkpoint, dict):
        if not isinstance(current_checkpoint, dict):
            merged["checkpoint"] = copy.deepcopy(candidate_checkpoint)
        elif (candidate_checkpoint.get("state") in TERMINAL_CHECKPOINT_STATES
              and current_checkpoint.get("state") not in TERMINAL_CHECKPOINT_STATES):
            merged["checkpoint"] = copy.deepcopy(candidate_checkpoint)
    current_esc = current.get("escalation")
    candidate_esc = candidate.get("escalation")
    if isinstance(candidate_esc, dict):
        if not isinstance(current_esc, dict):
            merged["escalation"] = copy.deepcopy(candidate_esc)
        else:
            current_state = current_esc.get("state")
            candidate_state = candidate_esc.get("state")
            if (candidate_state in TERMINAL_ESCALATION_STATES
                    and current_state not in TERMINAL_ESCALATION_STATES):
                merged["escalation"] = copy.deepcopy(candidate_esc)
            elif current_state in TERMINAL_ESCALATION_STATES:
                merged["escalation"] = copy.deepcopy(current_esc)
    return merged


def _merge_record(current: Any, baseline: Any, candidate: Any, key: str) -> Any:
    if current is None:
        return copy.deepcopy(candidate)
    if baseline == current:
        return copy.deepcopy(candidate)
    if key == "resume_notifications":
        return _merge_resume(current, baseline, candidate)
    if key == "rca_elapsed":
        return _merge_rca(current, baseline, candidate)
    if not isinstance(current, dict) or not isinstance(candidate, dict):
        # Scalar streaks are monotonic only within the same scan generation;
        # preserve the current value when another scan already changed it.
        return copy.deepcopy(current)
    merged = copy.deepcopy(current)
    for field, value in candidate.items():
        if field not in merged:
            merged[field] = copy.deepcopy(value)
        elif field.endswith("_at") or field in {"last_scan", "timestamp"}:
            merged[field] = _newer(merged[field], value)
    return merged


def _merge_map(current: dict[str, Any], baseline: Any, candidate: Any, key: str) -> None:
    baseline_map = baseline if isinstance(baseline, dict) else {}
    candidate_map = candidate if isinstance(candidate, dict) else {}
    for record_key, record in candidate_map.items():
        current[record_key] = _merge_record(
            current.get(record_key), baseline_map.get(record_key), record, key)


def merge_scan(path: str, baseline: dict[str, Any], candidate: dict[str, Any],
               now_iso: str) -> dict[str, Any]:
    """Merge one scan after blocking work, preserving concurrent commits."""
    with locked_state(path) as current:
        for key in STATE_MAP_KEYS:
            _merge_map(current[key], baseline.get(key), candidate.get(key), key)

        current_scan = current.get("scan_count", 0)
        try:
            current_scan = int(current_scan or 0)
        except (TypeError, ValueError):
            current_scan = 0
        current["scan_count"] = current_scan + 1
        current["last_scan"] = _newer(current.get("last_scan"), now_iso)
        current["last_error"] = None
        _atomic_write(path, current)
        # The returned detached copy gives the caller the committed scan number
        # without holding the state lock while shell output is processed.
        return copy.deepcopy(current)


def mark_resume_delivered(path: str, agent: str, task_id: str,
                          episode_key: str, progress_at: str,
                          dedup_key: str) -> bool:
    with locked_state(path) as state:
        records = state["resume_notifications"]
        record = records.get(agent)
        if not isinstance(record, dict):
            return False
        if (record.get("task_id") != task_id
                or record.get("episode_key") != episode_key
                or record.get("dedup_key") != dedup_key):
            return False
        record["progress_at"] = progress_at if progress_at != "unknown" else None
        record["delivered"] = True
        record["delivered_at"] = _datetime.datetime.now(
            _datetime.timezone.utc).astimezone().replace(microsecond=0).isoformat()
        records[agent] = record
        _atomic_write(path, state)
        return True


def mark_rca_dispatched(path: str, parent_cmd: str, family_id: str,
                        severity: str, dispatched_at: str,
                        task_id: str, cooldown_min: int) -> bool:
    with locked_state(path) as state:
        dispatched = _timestamp(dispatched_at)
        if dispatched is None:
            return False
        expires = dispatched + _datetime.timedelta(minutes=cooldown_min)
        state["rca_parent_cooldowns"][parent_cmd] = {
            "family_id": family_id,
            "severity": severity,
            "dispatched_at": dispatched_at,
            "expires_at": expires.isoformat(),
        }
        entry = state["rca_elapsed"].get(f"{parent_cmd}|{family_id}")
        if isinstance(entry, dict):
            escalation = entry.setdefault("escalation", {})
            escalation["state"] = "dispatched"
            escalation["dispatched_at"] = dispatched_at
            escalation["gunshi2_task_id"] = task_id
            state["rca_elapsed"][f"{parent_cmd}|{family_id}"] = entry
        _atomic_write(path, state)
        return True


def _ensure(path: str) -> None:
    with locked_state(path):
        pass


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return 2
    command = argv[1]
    if command == "ensure" and len(argv) == 3:
        _ensure(argv[2])
        return 0
    if command == "mark-delivered" and len(argv) == 8:
        return 0 if mark_resume_delivered(*argv[2:]) else 2
    if command == "mark-rca" and len(argv) == 9:
        return 0 if mark_rca_dispatched(
            argv[2], argv[3], argv[4], argv[5], argv[6], argv[7], int(argv[8])) else 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
