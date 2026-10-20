#!/usr/bin/env python3
"""Tests for bin/muster-tap — the OSC 7501 pty receiver.

    python3 tests/test_tap.py

The tap writes the records itself, so the tests point it at a temporary
XDG_STATE_HOME and read the JSON files back from the disk. There is no fake
writer and no subprocess in the write path: what the tests check is exactly
what a reader of the sessions directory sees.

Two levels are covered:
  * the receiver itself, fed with the bytes a program would write, and
  * the whole program, run as a subprocess under a pty, to prove that the
    bytes reach the terminal unchanged and that the records are written.
"""

import base64
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import resource
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)
TAP = os.path.join(ROOT, "bin", "muster-tap")

# The receiver is a script without a .py suffix; it is loaded by hand.
_loader = importlib.machinery.SourceFileLoader("muster_tap", TAP)
_spec = importlib.util.spec_from_file_location("muster_tap", TAP, loader=_loader)
muster_tap = importlib.util.module_from_spec(_spec)
_loader.exec_module(muster_tap)

PROBE_REPLY = (b"\x1b]7501;?:states=idle,working,done,blocked,error"
               b":kinds=permission,question,auth\x1b\\")

# The fields of a record, exactly. A record with more or with fewer is not
# the record this branch agreed on.
FIELDS = {"schemaVersion", "agent", "sessionId", "name", "cwd", "project",
          "state", "kind", "progress", "recordId", "message", "pid",
          "windowAddress", "herdrPane", "tmuxPane", "tmuxSocket",
          "terminalId", "updatedAt"}

passed = 0
failed = 0


def check(name, cond, extra=None):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("FAIL:", name, "" if extra is None else json.dumps(extra, default=str))


def eq(name, actual, expected):
    check(name, actual == expected, {"actual": actual, "expected": expected})


def read_records(home):
    """Every record of a state home, by file name."""
    sessions = os.path.join(home, "omarchy", "muster", "sessions")
    if not os.path.isdir(sessions):
        return {}
    records = {}
    for name in sorted(os.listdir(sessions)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(sessions, name), "rb") as handle:
            records[name] = json.loads(handle.read().decode("utf-8"))
    return records


class Harness:
    """A tap with a temporary state home; the records are read back from disk."""

    def __init__(self, agent="", session="", pid=4242, token=None,
                 window="0x1234"):
        self.home = tempfile.mkdtemp(prefix="muster-tap-state-")
        self.previous = os.environ.get("XDG_STATE_HOME")
        os.environ["XDG_STATE_HOME"] = self.home
        self.store = muster_tap.RecordStore()
        self.store.open()
        self.master_r, self.master_w = os.pipe()
        self.tap = muster_tap.Tap(pid, self.store, agent=agent, session=session,
                                  master_fd=self.master_w, token=token,
                                  window=window)
        os.set_blocking(self.master_r, False)

    def close(self):
        for fd in (self.master_r, self.master_w):
            try:
                os.close(fd)
            except OSError:
                pass
        self.store.close()
        if self.previous is None:
            os.environ.pop("XDG_STATE_HOME", None)
        else:
            os.environ["XDG_STATE_HOME"] = self.previous
        shutil.rmtree(self.home, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()

    @property
    def sessions(self):
        """The sessions directory of this tap."""
        return self.store.path

    def records(self):
        """Every record of this tap, by file name."""
        return read_records(self.home)

    def feed(self, data):
        """Feed the wire; a record is written where the report is read."""
        self.tap.feed(data)

    def osc(self, body):
        """A complete OSC 7501 sequence."""
        self.feed(b"\x1b]7501;" + body + b"\x1b\\")

    def master_output(self):
        """What the receiver wrote back to the program."""
        try:
            return os.read(self.master_r, 65536)
        except BlockingIOError:
            return b""

    @property
    def prefix(self):
        """The name every record of this tap starts with."""
        return self.tap.session_prefix


# ------------------------------------------------------------ the probe

def test_probe():
    with Harness() as h:
        h.osc(b"?")
        eq("probe: the query is answered with the spec reply",
           h.master_output(), PROBE_REPLY)
        eq("probe: the query writes no record", h.records(), {})

    with Harness() as h:
        h.osc(b"state=working:app=claude")
        eq("probe: a report is not answered", h.master_output(), b"")
        eq("probe: a report writes one record", len(h.records()), 1)


def test_probe_is_capped():
    with Harness() as h:
        for _ in range(h.tap.probes + muster_tap.PROBE_LIMIT + 8):
            h.osc(b"?")
        out = h.master_output()
        eq("probe: the answers are capped", out.count(PROBE_REPLY),
           muster_tap.PROBE_LIMIT)
        eq("probe: a capped probe writes no record", h.records(), {})


def test_probe_master_is_not_blocking():
    with Harness() as h:
        check("probe: the pty master is not blocking",
              os.get_blocking(h.tap.master_fd) is False)
        # A child that never reads its stdin fills the pty queue. The answer
        # to the query must not block on that: it is best effort.
        h.osc(b"?")
        eq("probe: the answer is written anyway", h.master_output(), PROBE_REPLY)


# ------------------------------------------------------- a single record

def test_working_then_done():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        records = h.records()
        eq("working: one record is written", len(records), 1)
        name = list(records)[0]
        record = records[name]
        eq("working: the file is named after the agent and the session",
           name, f"claude~{h.prefix}.json")
        eq("working: the state is on the disk", record["state"], "working")
        eq("working: the agent comes from the app", record["agent"], "claude")
        eq("working: the session is named after the tap",
           record["sessionId"], h.prefix)
        eq("working: the terminal is named after the tap",
           record["terminalId"], f"tap:4242:{h.tap.token}")
        eq("working: the pid is the child's", record["pid"], 4242)
        eq("working: the window is pinned at the start",
           record["windowAddress"], "0x1234")
        eq("working: a report without a title has no name", record["name"], "")
        eq("working: a report without a message has no message",
           record["message"], "")
        eq("working: the schema is version 2", record["schemaVersion"], 2)
        eq("working: the record has exactly the agreed fields",
           set(record), FIELDS)
        eq("working: the record id of the root is empty",
           record["recordId"], "")

        h.osc(b"state=done:app=claude")
        records = h.records()
        eq("done: the record is replaced, not added", len(records), 1)
        eq("done: the state is on the disk",
           list(records.values())[0]["state"], "done")

        h.tap.close()
        eq("done: a settled record survives the exit", len(h.records()), 1)
        eq("done: the registry keeps the settled record",
           sorted(h.tap.records), [""])


def test_live_records_are_removed_on_exit():
    with Harness() as h:
        # One record per id: the last report of an id is the record of that
        # id, so the four states live on four ids.
        h.osc(b"state=working:app=claude:id=work")
        h.osc(b"state=blocked:kind=permission:app=claude:id=block")
        h.osc(b"state=idle:app=claude:id=rest")
        h.osc(b"state=done:app=claude:id=settled")
        eq("exit: four records are written", len(h.records()), 4)

        h.tap.close()
        records = h.records()
        eq("exit: every live record is removed", len(records), 1)
        eq("exit: the settled record is the one that stays",
           list(records.values())[0]["recordId"], "settled")
        eq("exit: the registry keeps the settled record",
           sorted(h.tap.records), ["settled"])
        eq("exit: the settled record is the done one",
           h.tap.records["settled"]["state"], "done")


def test_a_blocked_record_is_removed_on_exit():
    with Harness() as h:
        h.osc(b"state=blocked:kind=question:app=claude")
        h.tap.close()
        eq("exit: a blocked record is removed", h.records(), {})


def test_the_prompt_drops_the_running_records():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=done:app=claude:id=kept")
        h.feed(b"\x1b]133;A\x07")
        records = h.records()
        eq("prompt: the working record is removed", len(records), 1)
        eq("prompt: the settled record survives",
           list(records.values())[0]["recordId"], "kept")
        eq("prompt: the registry agrees", sorted(h.tap.records), ["kept"])


def test_the_prompt_keeps_an_idle_record():
    with Harness() as h:
        # The spec only kills the live states on a new prompt: an idle record
        # is not running, so it stays.
        h.osc(b"state=idle:app=claude:id=rest")
        h.feed(b"\x1b]133;A\x07")
        eq("prompt: an idle record survives the prompt", len(h.records()), 1)
        eq("prompt: the idle record is still there",
           sorted(h.tap.records), ["rest"])


# ---------------------------------------------------------- many records

def test_several_ids():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=claude:id=lint")
        records = h.records()
        eq("ids: two records are written", len(records), 2)
        sessions = [record["sessionId"] for record in records.values()]
        check("ids: the records get different files", sessions[0] != sessions[1],
              sessions)
        check("ids: the files are named after the tap",
              all(s.startswith(h.prefix + "-") for s in sessions), sessions)
        eq("ids: the registry holds both ids", sorted(h.tap.records),
           ["build", "lint"])
        by_id = {record["recordId"]: record for record in records.values()}
        eq("ids: every record keeps its own id", sorted(by_id),
           ["build", "lint"])


def test_id_with_slash():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build/test")
        record = list(h.records().values())[0]
        session = record["sessionId"]
        check("ids: a hierarchical id gets a plain token",
              session.startswith(h.prefix + "-build"), session)
        check("ids: the token carries no slash", "/" not in session, session)
        check("ids: the token fits the 64 characters", len(session) <= 64,
              session)
        eq("ids: the raw id stays in the record", record["recordId"],
           "build/test")


def test_long_id_is_hashed():
    with Harness() as h:
        # The longest id the grammar allows: 8 levels of 32 characters.
        long_id = "/".join("a" * 32 for _ in range(8))
        h.osc(f"state=working:app=claude:id={long_id}".encode())
        records = h.records()
        eq("ids: the longest legal id is written", len(records), 1)
        record = list(records.values())[0]
        check("ids: a long id is shortened", len(record["sessionId"]) <= 64,
              record["sessionId"])
        check("ids: a long id keeps a hash",
              record["sessionId"].startswith(h.prefix + "-aaa"),
              record["sessionId"])
        eq("ids: the raw id is not cut short", record["recordId"], long_id)


def test_ids_never_share_a_file():
    with Harness() as h:
        # `a/b` and the literal `a_b-<digest>` are two different ids, and
        # the second one is spelled exactly like the file the first one used
        # to name. A digest that is only added to a lossy token would let the
        # two share a file, and one of them would delete the other's record.
        digest = hashlib.blake2b(b"a/b", digest_size=4).hexdigest()
        literal = f"a_b-{digest}"
        h.osc(b"state=working:app=claude:id=a/b")
        h.osc(f"state=working:app=claude:id={literal}".encode())
        records = h.records()
        eq("ids: both ids are written", len(records), 2)
        sessions = [record["sessionId"] for record in records.values()]
        check("ids: two ids never share a file", sessions[0] != sessions[1],
              sessions)
        check("ids: the name of an id always carries a digest",
              all(len(session.rsplit("-", 1)[-1]) == 16 for session in sessions),
              sessions)


def test_a_long_session_prefix_stays_within_the_limit():
    with Harness(session="a" * 60) as h:
        h.osc(b"state=done:app=claude:id=build")
        record = list(h.records().values())[0]
        check("session: a long prefix still yields a <=64 name",
              len(record["sessionId"]) <= 64, record["sessionId"])
        check("session: the name still starts with an id character",
              record["sessionId"][0].isalnum(), record["sessionId"])


def test_the_session_option_overrides_the_names():
    with Harness(session="my-session") as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=claude:id=build")
        by_id = {record["recordId"]: record
                 for record in h.records().values()}
        eq("session: --session names the root record",
           by_id[""]["sessionId"], f"my-session-{h.tap.token}")
        check("session: --session prefixes every record",
              by_id["build"]["sessionId"].startswith(
                  f"my-session-{h.tap.token}-build-"), by_id["build"])


def test_the_record_cap_evicts_the_oldest():
    with Harness() as h:
        for index in range(muster_tap.MAX_RECORDS + 8):
            # Let the rate bucket refill: this test is about the registry cap.
            h.tap.tokens = muster_tap.WRITE_BURST
            h.osc(f"state=working:app=claude:id=job{index:03d}".encode())
        eq("cap: the registry is bounded", len(h.tap.records),
           muster_tap.MAX_RECORDS)
        check("cap: the oldest record is gone",
              "job000" not in h.tap.records, sorted(h.tap.records)[:3])
        check("cap: the newest record is there",
              "job%03d" % (muster_tap.MAX_RECORDS + 7) in h.tap.records)
        check("cap: the app of the evicted record is gone",
              "job000" not in h.tap.apps)
        records = h.records()
        eq("cap: the files on the disk are bounded", len(records),
           muster_tap.MAX_RECORDS)
        check("cap: the evicted record is taken off the disk",
              all(r["recordId"] != "job000" for r in records.values()),
              sorted(r["recordId"] for r in records.values())[:4])


def test_the_event_cap():
    with Harness() as h:
        noise = b"".join(b"\x1b]7501;state=working:app=claude:id=x%d\x1b\\"
                         % index
                         for index in range(muster_tap.MAX_EVENTS_PER_READ + 50))
        events = h.tap.scanner.feed(noise)
        eq("cap: one read creates at most MAX_EVENTS events", len(events),
           muster_tap.MAX_EVENTS_PER_READ)


def test_identical_reports_replace_the_same_record():
    with Harness() as h:
        for _ in range(5):
            h.osc(b"state=working:app=claude:id=build")
        eq("repeat: one record file", len(h.records()), 1)
        eq("repeat: the record is still working",
           list(h.records().values())[0]["state"], "working")
        h.osc(b"state=done:app=claude:id=build")
        eq("repeat: the record is replaced, not added", len(h.records()), 1)
        eq("repeat: the state is the last one",
           list(h.records().values())[0]["state"], "done")


def test_the_write_rate_is_capped():
    with Harness() as h:
        writes = []
        original = h.store.write

        def counted(agent, session, record):
            writes.append(record)
            return original(agent, session, record)

        h.store.write = counted
        # The bucket is empty: the report is dropped, and the registry still
        # knows about the record.
        h.tap.tokens = 0.0
        h.osc(b"state=working:app=claude:id=build")
        eq("rate: the write is skipped", len(writes), 0)
        eq("rate: the registry does not track an unwritten record",
           sorted(h.tap.records), [])
        eq("rate: nothing is on the disk", h.records(), {})
        # The next report of that id is written again.
        h.tap.tokens = muster_tap.WRITE_BURST
        h.osc(b"state=done:app=claude:id=build")
        eq("rate: the next report is written", len(writes), 1)
        eq("rate: the record is on the disk", len(h.records()), 1)


# ------------------------------------------------------------ the clear

def test_root_clear_removes_everything():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=claude:id=build/test")
        eq("clear: three records before the clear", len(h.records()), 3)

        h.osc(b"state=clear")
        eq("clear: every record is removed", h.records(), {})
        eq("clear: the registry is empty", h.tap.records, {})
        eq("clear: the app entries are gone", h.tap.apps, {})


def test_id_clear_removes_descendants():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=claude:id=build/test")
        h.osc(b"state=working:app=claude:id=build/test/case")
        h.osc(b"state=working:app=claude:id=other")
        eq("clear: five records before the clear", len(h.records()), 5)

        h.osc(b"state=clear:id=build")
        records = h.records()
        eq("clear: the id and its descendants are removed", len(records), 2)
        by_id = {record["recordId"]: record for record in records.values()}
        eq("clear: the unrelated record survives", sorted(by_id), ["", "other"])
        eq("clear: the root survives a clear of a child",
           by_id[""]["recordId"], "")
        eq("clear: the app entries of the removed ids are gone",
           sorted(h.tap.apps), ["", "other"])


def test_clear_of_an_unknown_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=clear:id=nothing")
        eq("clear: an unknown id removes nothing", len(h.records()), 1)
        eq("clear: an unknown id keeps the record", sorted(h.tap.records), [""])


def test_clear_with_a_malformed_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        # A clear with a broken id is ignored whole: it must not remove the
        # records of another id.
        h.osc(b"state=clear:id=" + b"a" * 300)
        h.osc(b"state=clear:id=a/b/c/d/e/f/g/h/i")
        h.osc(b"state=clear:id=build/../other")
        h.osc(b"state=clear:id=")
        eq("clear: a malformed id removes nothing", len(h.records()), 1)
        eq("clear: a malformed id keeps the record", sorted(h.tap.records),
           ["build"])


def test_a_clear_only_touches_the_files_of_this_tap():
    with Harness() as h:
        # A record of another tap lives in the same directory.
        other = os.path.join(h.sessions, "claude~someone-else.json")
        with open(other, "w") as handle:
            json.dump({"schemaVersion": 2, "agent": "claude",
                       "sessionId": "someone-else", "state": "working"},
                      handle)
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=clear")
        eq("clear: the record of another tap is not touched",
           os.path.exists(other), True)
        os.unlink(other)


# ------------------------------------------------------------- the apps

def test_app_inheritance():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:id=build")
        records = h.records()
        eq("apps: two records are written", len(records), 2)
        by_id = {record["recordId"]: record for record in records.values()}
        eq("apps: the child inherits the root app", by_id["build"]["agent"],
           "claude")
        check("apps: the child is a record of its own",
              by_id["build"]["sessionId"] != by_id[""]["sessionId"])


def test_app_inheritance_from_the_nearest_ancestor():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=codex:id=build")
        h.osc(b"state=working:id=build/test")
        by_id = {record["recordId"]: record
                 for record in h.records().values()}
        eq("apps: a grandchild inherits the nearest ancestor",
           by_id["build/test"]["agent"], "codex")


def test_the_agent_option_overrides_the_app():
    with Harness(agent="claude") as h:
        h.osc(b"state=working:app=codex")
        eq("apps: --agent wins over the reported app",
           list(h.records().values())[0]["agent"], "claude")
    with Harness(agent="claude") as h:
        h.osc(b"state=working:id=build")
        eq("apps: --agent is the fallback when nothing is known",
           list(h.records().values())[0]["agent"], "claude")


def test_the_app_of_an_id_is_remembered():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=done:id=build")
        by_id = {record["recordId"]: record
                 for record in h.records().values()}
        eq("apps: the app of an id is remembered", by_id["build"]["agent"],
           "claude")


def test_an_app_change_moves_the_record():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=codex:id=build")
        records = h.records()
        eq("apps: one record is left", len(records), 1)
        record = list(records.values())[0]
        eq("apps: the record belongs to the new app", record["agent"], "codex")
        eq("apps: the registry agrees", h.tap.records["build"]["agent"], "codex")


def test_the_ids_are_independent():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=done:app=claude:id=build")
        eq("ids: the root record is untouched by a child report",
           h.tap.records[""]["state"], "working")
        eq("ids: the child record is its own",
           h.tap.records["build"]["state"], "done")
        check("ids: the two records have different files",
              h.tap.records[""]["session"] != h.tap.records["build"]["session"])


# ------------------------------------------------------ broken reports

def test_an_unknown_state_is_ignored():
    with Harness() as h:
        h.osc(b"state=sideways:app=claude")
        h.osc(b"app=claude")
        h.osc(b"state=:app=claude")
        eq("broken: no state means no record", h.records(), {})
        eq("broken: the registry stays empty", h.tap.records, {})


def test_an_invalid_id_is_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=" + b"a" * 300)
        h.osc(b"state=working:app=claude:id=a/b/c/d/e/f/g/h/i")
        # An explicit empty id is not the root record: it is discarded whole,
        # so it cannot overwrite or clear the root.
        h.osc(b"state=working:app=claude:id=")
        eq("broken: an id over the grammar is ignored", h.records(), {})
        eq("broken: the registry stays empty", h.tap.records, {})


def test_an_empty_id_does_not_touch_the_root():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=claude:id=")
        h.osc(b"state=clear:id=")
        records = h.records()
        eq("broken: the root record survives", len(records), 1)
        eq("broken: the root is the root", list(records.values())[0]["recordId"],
           "")


def test_a_body_over_the_cap_is_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude:" + b"x" * 5000)
        eq("broken: a body over 4096 bytes is ignored", h.records(), {})


def test_an_oversized_body_is_not_a_probe():
    with Harness() as h:
        # The cap is checked before the query: a body that is too long is
        # dropped whole, and it is not a feature query either.
        h.osc(b"?" + b"x" * 5000)
        eq("broken: an oversized body is not answered", h.master_output(), b"")
        eq("broken: an oversized body writes no record", h.records(), {})


def test_malformed_pairs_are_skipped():
    with Harness() as h:
        h.osc(b"state=working:app=claude:garbage:title=aGk=")
        records = h.records()
        eq("broken: a malformed pair does not spoil the report", len(records), 1)
        eq("broken: the report is filed under the root",
           list(records.values())[0]["recordId"], "")


def test_unknown_keys_are_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude:whatever=1")
        eq("broken: an unknown key is ignored", len(h.records()), 1)


def test_the_last_duplicate_wins():
    with Harness() as h:
        h.osc(b"state=working:app=claude:app=codex")
        eq("broken: the last duplicate wins",
           list(h.records().values())[0]["agent"], "codex")


def test_whitespace_is_trimmed():
    with Harness() as h:
        h.osc(b"state = working : app = claude")
        records = h.records()
        eq("broken: whitespace around a key is trimmed", len(records), 1)
        eq("broken: whitespace around a value is trimmed",
           list(records.values())[0]["agent"], "claude")


def test_unicode_whitespace_is_not_trimmed():
    with Harness() as h:
        # Only ASCII whitespace is whitespace on the wire, so a Unicode space
        # is not part of the charset and the pair is malformed.
        h.osc("state=working:app= claude".encode())
        records = h.records()
        eq("broken: a Unicode space is not trimmed", len(records), 1)
        eq("broken: the app of a malformed pair is absent",
           list(records.values())[0]["agent"], "agent")

    with Harness() as h:
        h.osc("state =working:app=claude".encode())
        eq("broken: a Unicode space in a key breaks the report", h.records(), {})


# ------------------------------------------------------ the free text

def test_the_title_and_the_message_are_decoded():
    with Harness() as h:
        title = base64.b64encode("Building".encode()).decode()
        message = base64.b64encode("the patch is ready".encode()).decode()
        h.osc(f"state=blocked:kind=question:app=claude:title={title}"
              f":msg={message}".encode())
        record = list(h.records().values())[0]
        eq("text: the title is decoded", record["name"], "Building")
        eq("text: the message is decoded", record["message"],
           "the patch is ready")
        eq("text: the kind is kept", record["kind"], "question")


def test_a_broken_title_discards_the_report():
    with Harness() as h:
        # A title that decodes to a control character is not a title: the
        # whole report is discarded, not just the text.
        h.osc(b"state=working:app=claude:title=" + base64.b64encode(b"a\nb"))
        eq("text: a title with a control character discards the report",
           h.records(), {})


def test_an_over_long_title_discards_the_report():
    with Harness() as h:
        long_title = base64.b64encode(b"x" * 200)
        h.osc(b"state=working:app=claude:title=" + long_title)
        eq("text: a title over the spec's limit discards the report",
           h.records(), {})


def test_a_title_at_the_limit_is_kept():
    with Harness() as h:
        title = base64.b64encode(b"x" * 192)
        h.osc(b"state=working:app=claude:title=" + title)
        record = list(h.records().values())[0]
        eq("text: a title at the limit is kept", len(record["name"]), 192)


def test_progress_and_kind():
    with Harness() as h:
        h.osc(b"state=working:app=claude:progress=42")
        eq("progress: a progress is kept",
           list(h.records().values())[0]["progress"], 42)
        h.osc(b"state=working:app=claude:progress=101")
        eq("progress: a progress over 100 is absent",
           list(h.records().values())[0]["progress"], -1)
        h.osc(b"state=working:app=claude:progress=abc")
        eq("progress: a progress that is not a number is absent",
           list(h.records().values())[0]["progress"], -1)
        h.osc(b"state=done:app=claude:progress=42")
        eq("progress: a settled record has no progress",
           list(h.records().values())[0]["progress"], -1)
        h.osc(b"state=blocked:app=claude:kind=permission")
        eq("kind: a kind is kept for a blocked record",
           list(h.records().values())[0]["kind"], "permission")
        h.osc(b"state=blocked:app=claude:kind=sideways")
        eq("kind: an unknown kind is absent",
           list(h.records().values())[0]["kind"], "")
        h.osc(b"state=working:app=claude:kind=permission")
        eq("kind: a kind means nothing outside a blocked report",
           list(h.records().values())[0]["kind"], "")


# ------------------------------------------------------- the whole wire

def test_a_split_sequence():
    with Harness() as h:
        h.feed(b"\x1b]7501;state=work")
        eq("wire: nothing is written before the terminator", h.records(), {})
        h.feed(b"ing:app=claude\x1b\\")
        records = h.records()
        eq("wire: a split sequence is written", len(records), 1)
        eq("wire: the state is complete", list(records.values())[0]["state"],
           "working")


def test_a_c1_terminated_sequence():
    with Harness() as h:
        h.feed(b"\x1b]7501;state=working:app=claude\x9c")
        records = h.records()
        eq("wire: a C1 terminator is a terminator", len(records), 1)
        eq("wire: the report is the body", list(records.values())[0]["state"],
           "working")


def test_a_stray_prefix_does_not_swallow_the_next_report():
    with Harness() as h:
        # A prefix without a terminator must not eat the next report.
        h.feed(b"\x1b]7501;state=working:app=claude")
        h.feed(b"\x1b]7501;state=done:app=claude\x1b\\")
        records = h.records()
        eq("wire: one report is written", len(records), 1)
        eq("wire: the report is the one with a terminator",
           list(records.values())[0]["state"], "done")


def test_a_prompt_split_across_reads():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.feed(b"\x1b]133")
        eq("prompt: a split prompt is not seen yet", len(h.records()), 1)
        h.feed(b";A\x1b\\")
        eq("prompt: a split prompt is seen", h.records(), {})


def test_other_prompt_markers_are_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.feed(b"\x1b]133;B\x1b\\")
        eq("prompt: another marker does not drop the record", len(h.records()), 1)


def test_a_long_stream_is_scanned_once():
    with Harness() as h:
        # The scanner works on indexes: a stream of noise between the
        # sequences must not make the scan quadratic.
        noise = b"x" * 4096
        started = time.monotonic()
        for _ in range(100):
            h.feed(noise)
            h.feed(b"\x1b]7501;state=working:app=claude\x1b\\")
        elapsed = time.monotonic() - started
        check("wire: a long stream is scanned in time", elapsed < 10, elapsed)
        eq("wire: every report is seen", len(h.records()), 1)


# ------------------------------------------------------------- the names

def test_the_session_prefix_is_random():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    previous = os.environ.get("XDG_STATE_HOME")
    os.environ["XDG_STATE_HOME"] = home
    store = muster_tap.RecordStore()
    try:
        store.open()
        first = muster_tap.Tap(4242, store)
        second = muster_tap.Tap(4242, store)
        check("names: two taps of the same pid differ",
              first.session_prefix != second.session_prefix,
              [first.session_prefix, second.session_prefix])
        check("names: the prefix carries the pid",
              first.session_prefix.startswith("tap-4242-"), first.session_prefix)
        check("names: the terminal carries the token",
              first.terminal_id.startswith("tap:4242:"), first.terminal_id)
        check("names: the token is in both",
              first.token in first.session_prefix
              and first.token in first.terminal_id, first.token)
        check("names: the session fits the 64 characters",
              len(first.session_prefix) <= 64, first.session_prefix)
    finally:
        store.close()
        if previous is None:
            os.environ.pop("XDG_STATE_HOME", None)
        else:
            os.environ["XDG_STATE_HOME"] = previous
        shutil.rmtree(home, ignore_errors=True)


# ---------------------------------------------------------- the store

def test_the_store_makes_its_chain():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    previous = os.environ.get("XDG_STATE_HOME")
    os.environ["XDG_STATE_HOME"] = home
    try:
        store = muster_tap.RecordStore()
        store.open()
        try:
            eq("store: the sessions directory is where it belongs",
               store.path, os.path.join(home, "omarchy", "muster", "sessions"))
            path = home
            for part in ("omarchy", "muster", "sessions"):
                path = os.path.join(path, part)
                eq(f"store: {part} is mode 0700",
                   stat.S_IMODE(os.stat(path).st_mode), 0o700)
        finally:
            store.close()
    finally:
        if previous is None:
            os.environ.pop("XDG_STATE_HOME", None)
        else:
            os.environ["XDG_STATE_HOME"] = previous
        shutil.rmtree(home, ignore_errors=True)


def test_a_relative_state_home_is_refused():
    previous = os.environ.get("XDG_STATE_HOME")
    os.environ["XDG_STATE_HOME"] = "relative/state"
    try:
        store = muster_tap.RecordStore()
        try:
            store.open()
            check("store: a relative state home is refused", False, "relative")
        except muster_tap.StoreError:
            check("store: a relative state home is refused", True)
        finally:
            store.close()
    finally:
        if previous is None:
            os.environ.pop("XDG_STATE_HOME", None)
        else:
            os.environ["XDG_STATE_HOME"] = previous


def test_a_symlinked_sessions_dir_is_refused():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    elsewhere = tempfile.mkdtemp(prefix="muster-tap-other-")
    previous = os.environ.get("XDG_STATE_HOME")
    os.environ["XDG_STATE_HOME"] = home
    try:
        os.makedirs(os.path.join(home, "omarchy", "muster"))
        os.symlink(elsewhere, os.path.join(home, "omarchy", "muster", "sessions"))
        store = muster_tap.RecordStore()
        try:
            store.open()
            check("store: a symlinked sessions directory is refused", False, home)
        except muster_tap.StoreError:
            check("store: a symlinked sessions directory is refused", True)
        finally:
            store.close()
    finally:
        if previous is None:
            os.environ.pop("XDG_STATE_HOME", None)
        else:
            os.environ["XDG_STATE_HOME"] = previous
        shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(elsewhere, ignore_errors=True)


def test_the_modes():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        eq("modes: the sessions directory is 0700",
           stat.S_IMODE(os.stat(h.sessions).st_mode), 0o700)
        for name in os.listdir(h.sessions):
            if not name.endswith(".json"):
                continue
            path = os.path.join(h.sessions, name)
            eq(f"modes: the record {name} is 0600",
               stat.S_IMODE(os.stat(path).st_mode), 0o600)


def test_no_staging_file_is_left_behind():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=done:app=claude")
        leftovers = [name for name in os.listdir(h.sessions)
                     if not name.endswith(".json")]
        eq("store: no staging file is left behind", leftovers, [])


def test_the_tap_has_no_subprocess_writer():
    with open(TAP, "r", encoding="utf-8") as handle:
        source = handle.read()
    for needle in ("muster-report", "MUSTER_REPORT", "Popen", "shell=True",
                   "os.system", "check_output", "jq ", "flock", "iconv"):
        check(f"writer: the tap does not use {needle.strip()}",
              needle not in source, needle)
    check("writer: the tap writes the records itself",
          "os.replace" in source)


# ---------------------------------------------------------- the writes

def test_read_input_returns_the_bytes():
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, b"hello")
        eq("input: data is returned, not swallowed",
           muster_tap.read_input(read_fd), b"hello")
    finally:
        os.close(read_fd)
        os.close(write_fd)


def test_write_all_writes_everything():
    read_fd, write_fd = os.pipe()
    data = b"x" * (1 << 20)
    got = []
    total = [0]

    def reader():
        while total[0] < len(data):
            chunk = os.read(read_fd, 65536)
            if not chunk:
                break
            total[0] += len(chunk)
            got.append(chunk)
        os.close(read_fd)

    thread = threading.Thread(target=reader)
    thread.start()
    try:
        ok = muster_tap.write_all(write_fd, data)
    finally:
        thread.join()
        os.close(write_fd)
    eq("write: the whole buffer is written", ok, True)
    eq("write: the reader got all of it", b"".join(got), data)


def test_write_all_waits_for_a_full_pipe():
    read_fd, write_fd = os.pipe()
    os.set_blocking(write_fd, False)
    # Fill the pipe, so the next write cannot go through at once.
    while True:
        try:
            os.write(write_fd, b"y" * 65536)
        except BlockingIOError:
            break

    def reader():
        time.sleep(0.2)
        seen = b""
        while b"z" * 100 not in seen:
            try:
                chunk = os.read(read_fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            seen += chunk
        os.close(read_fd)

    thread = threading.Thread(target=reader)
    thread.start()
    try:
        ok = muster_tap.write_all(write_fd, b"z" * 100, timeout=5)
    finally:
        thread.join()
        os.close(write_fd)
    eq("write: a full pipe is waited out", ok, True)


# ------------------------------------------------------- the whole program

def run_tap(command, env=None, timeout=20):
    """Run bin/muster-tap under a pty and return (stdout, stderr, returncode)."""
    environment = dict(os.environ)
    environment.update(env or {})
    proc = subprocess.run([sys.executable, TAP, "--"] + command,
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=environment,
                          timeout=timeout)
    return proc.stdout, proc.stderr, proc.returncode


def test_end_to_end():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    try:
        sequence = b"\x1b]7501;state=done:app=claude\x1b\\"
        out, err, code = run_tap(
            ["sh", "-c",
             "printf '\\033]7501;state=done:app=claude\\033\\\\'"],
            {"XDG_STATE_HOME": home})
        eq("e2e: the exit code of the child is kept", code, 0)
        check("e2e: the bytes reach the terminal unchanged",
              sequence in out, {"out": out})
        eq("e2e: stderr is empty", err, b"")

        records = read_records(home)
        eq("e2e: the record is written", len(records), 1)
        record = list(records.values())[0]
        eq("e2e: the state is on the disk", record["state"], "done")
        eq("e2e: the agent comes from the app", record["agent"], "claude")
        check("e2e: the terminal is the tap",
              record["terminalId"].startswith("tap:"), record["terminalId"])
        eq("e2e: the record has exactly the agreed fields",
           set(record), FIELDS)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_end_to_end_a_working_record_goes_with_the_child():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    try:
        out, _err, code = run_tap(
            ["sh", "-c",
             "printf '\\033]7501;state=working:app=claude\\033\\\\'"],
            {"XDG_STATE_HOME": home})
        eq("e2e: the exit code of the child is kept", code, 0)
        eq("e2e: a working record does not survive the child",
           read_records(home), {})
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_end_to_end_probe():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    try:
        # The child asks whether the terminal speaks the protocol and reads
        # the answer back; the answer has to come back on the pty.
        out, _err, _code = run_tap(
            ["sh", "-c",
             "stty -echo -icanon; printf '\\033]7501;?\\033\\\\'; timeout 2 cat"],
            {"XDG_STATE_HOME": home})
        check("e2e: the query reaches the terminal",
              b"\x1b]7501;?" in out, {"out": out})
        check("e2e: the query is answered", PROBE_REPLY in out, {"out": out})
        eq("e2e: the query writes no record", read_records(home), {})
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_end_to_end_a_broken_store_still_relays():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    elsewhere = tempfile.mkdtemp(prefix="muster-tap-other-")
    try:
        os.makedirs(os.path.join(home, "omarchy", "muster"))
        os.symlink(elsewhere, os.path.join(home, "omarchy", "muster",
                                           "sessions"))
        out, err, code = run_tap(["sh", "-c", "printf 'hello\\n'"],
                                 {"XDG_STATE_HOME": home})
        eq("e2e: the exit code is kept", code, 0)
        check("e2e: the bytes still reach the terminal", b"hello" in out,
              {"out": out})
        check("e2e: the tap says once that it does not record",
              b"not recording" in err, {"err": err})
        eq("e2e: nothing is written", read_records(home), {})
    finally:
        shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(elsewhere, ignore_errors=True)


def test_end_to_end_the_child_inherits_no_descriptor():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    try:
        out, _err, code = run_tap(
            ["sh", "-c", "ls -l /proc/self/fd 2>&1"],
            {"XDG_STATE_HOME": home})
        eq("e2e: the exit code is kept", code, 0)
        check("e2e: the child has no descriptor of the sessions directory",
              b"omarchy" not in out, {"out": out.decode("utf-8", "replace")})
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_end_to_end_the_child_knows_the_tap_owns_the_session():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    try:
        out, _err, code = run_tap(
            ["sh", "-c", "printf '%s' \"$MUSTER_TAP\""],
            {"XDG_STATE_HOME": home})
        eq("e2e: the exit code is kept", code, 0)
        eq("e2e: the child is told that the tap owns the session", out, b"1")
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_end_to_end_a_grandchild_does_not_keep_the_tap_alive():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    try:
        # The child leaves a background process that holds the pty open and
        # then exits. The tap has to notice the exit and stop anyway.
        out, _err, code = run_tap(
            ["sh", "-c", "sleep 30 & printf 'done\\n'; exit 3"],
            {"XDG_STATE_HOME": home}, timeout=20)
        eq("e2e: the exit code of the child is kept", code, 3)
        check("e2e: the output of the child arrives", b"done" in out,
              {"out": out})
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_end_to_end_rejects_a_bad_option():
    proc = subprocess.run([sys.executable, TAP, "--nope", "--", "true"],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=20)
    eq("cli: an unknown option is refused", proc.returncode, 2)
    check("cli: the refusal says why", b"unknown option" in proc.stderr,
          proc.stderr)


def test_the_tap_does_not_spin():
    home = tempfile.mkdtemp(prefix="muster-tap-state-")
    try:
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        run_tap(["sh", "-c", "sleep 1"], {"XDG_STATE_HOME": home}, timeout=20)
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        used = ((after.ru_utime - before.ru_utime)
                + (after.ru_stime - before.ru_stime))
        # The tap waits for the wire; it does not burn the cpu while it waits.
        check("loop: the tap does not spin", used < 1.0, used)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main():
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print(f"tap tests: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
