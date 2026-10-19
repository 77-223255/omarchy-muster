#!/usr/bin/env python3
"""Tests for bin/muster-tap — the OSC 7501 pty receiver.

    python3 tests/test_tap.py

The tests drive the receiver through a fake `muster-report`: a small
executable that logs its argv and the body it was given on stdin. Nothing
here depends on the real writer, so the receiver can be tested on its own.

Two levels are covered:
  * the receiver itself, fed with the bytes a program would write, and
  * the whole program, run as a subprocess under a pty, to prove that the
  bytes reach the terminal unchanged and that the records are published.

The receiver does not write while it reads: it queues the writer calls and
flushes them in batches. The tests flush the queue by hand, so the number of
writer calls is visible.
"""

import base64
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import resource
import shutil
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

# The fake writer: it records how it was called, one line per call. The log
# sits next to the fake itself, so the test needs no environment. The line
# holds the argv fields (separated by \x1f) and the body (base64, after a
# \x1e), so a body with any byte in it survives the round trip.
FAKE_REPORT = """#!/bin/bash
dir=$(cd -- "$(dirname -- "$0")" && pwd)
body=$(cat; printf X)
body=${body%X}
encoded=$(printf '%s' "$body" | base64 -w0)
line=$'ARGV'
for arg in "$@"; do line+=$'\\037'"$arg"; done
line+=$'\\036'"$encoded"
printf '%s\\n' "$line" >> "$dir/calls.log"
"""

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


class FakeWriter:
    """A stand-in for muster-report that logs how it was called."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="muster-tap-fake-")
        self.log = os.path.join(self.dir, "calls.log")
        self.path = os.path.join(self.dir, "muster-report")
        with open(self.path, "w") as handle:
            handle.write(FAKE_REPORT)
        # The tap refuses a writer that anyone else may write, so the fake
        # has to be as careful as the real one.
        os.chmod(self.path, 0o755)

    def calls(self):
        return read_calls(self.log)

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class Harness:
    """A receiver with a fake writer and a pipe standing in for the pty."""

    def __init__(self, agent="", session="", pid=4242, token=None):
        self.writer = FakeWriter()
        self.log = self.writer.log
        self.report = self.writer.path
        self.master_r, self.master_w = os.pipe()
        self.tap = muster_tap.Tap(pid, self.report, agent=agent, session=session,
                                  master_fd=self.master_w, token=token)

    def close(self):
        self.tap.wait_writers(time.monotonic() + 5)
        for fd in (self.master_r, self.master_w):
            try:
                os.close(fd)
            except OSError:
                pass
        self.writer.close()

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()

    def feed_raw(self, data):
        """Feed the wire without flushing the writer queue."""
        self.tap.feed(data)

    def feed(self, data):
        """Feed the wire and write out whatever it queued."""
        self.tap.feed(data)
        self.flush()

    def flush(self, limit=1024):
        deadline = time.monotonic() + 30
        while (self.tap.pending or self.tap.writers) and time.monotonic() < deadline:
            self.tap.flush(limit=limit, rate=False)
            self.tap.wait_writers(min(deadline, time.monotonic() + 1.0))

    def osc(self, body):
        """A complete OSC 7501 sequence."""
        self.feed(b"\x1b]7501;" + body + b"\x1b\\")

    def master_output(self):
        """What the receiver wrote back to the program."""
        os.set_blocking(self.master_r, False)
        try:
            return os.read(self.master_r, 65536)
        except BlockingIOError:
            return b""

    def calls(self):
        return self.writer.calls()

    def published(self):
        """The calls that wrote a record (the ones that carry a body)."""
        return [c for c in self.calls() if "--osc-fd" in c["argv"]]

    def removals(self):
        return [c for c in self.calls()
                if "--remove" in c["argv"] or option(c, "--state") == "clear"]

    @property
    def prefix(self):
        """The name every record of this tap starts with."""
        return self.tap.session_prefix


def option(call, name):
    argv = call["argv"]
    if name not in argv:
        return None
    index = argv.index(name)
    return argv[index + 1] if index + 1 < len(argv) else None


def read_calls(log):
    """The calls a fake writer logged; an unwritten log means no call."""
    if not os.path.exists(log):
        return []
    calls = []
    with open(log, "rb") as handle:
        for raw in handle:
            line = raw.rstrip(b"\n")
            if not line:
                continue
            head, _, tail = line.partition(b"\x1e")
            fields = head.split(b"\x1f")
            argv = [field.decode("utf-8", "replace") for field in fields[1:]]
            body = base64.b64decode(tail) if tail else b""
            calls.append({"argv": argv, "body": body.decode("utf-8", "replace")})
    return calls


# ------------------------------------------------------------ the probe

def test_probe():
    with Harness() as h:
        h.osc(b"?")
        eq("probe: the query is answered with the spec reply",
           h.master_output(), PROBE_REPLY)
        eq("probe: the query writes no record", h.published(), [])

    with Harness() as h:
        h.osc(b"state=working:app=claude")
        eq("probe: a report is not answered", h.master_output(), b"")
        eq("probe: a report writes one record", len(h.published()), 1)


def test_probe_is_capped():
    with Harness() as h:
        for _ in range(h.tap.probes + muster_tap.PROBE_LIMIT + 8):
            h.osc(b"?")
        out = h.master_output()
        eq("probe: the answers are capped", out.count(PROBE_REPLY),
           muster_tap.PROBE_LIMIT)
        eq("probe: a capped probe writes no record", h.published(), [])


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
        published = h.published()
        eq("working: one record published", len(published), 1)
        eq("working: the body is handed over unchanged",
           published[0]["body"], "state=working:app=claude")
        eq("working: the agent comes from the app",
           option(published[0], "--agent"), "claude")
        eq("working: the root record is named after the tap",
           option(published[0], "--session"), h.prefix)
        check("working: the terminal is named after the tap",
              option(published[0], "--terminal-id").startswith("tap:4242:"),
              option(published[0], "--terminal-id"))
        eq("working: the body rides on a descriptor",
           option(published[0], "--osc-fd"), "0")

        h.osc(b"state=done:app=claude")
        eq("done: a second record published", len(h.published()), 2)
        eq("done: the same record is filed",
           option(h.published()[1], "--session"), h.prefix)

        h.tap.close()
        h.flush()
        eq("done: a settled record survives the exit", h.removals(), [])
        eq("done: the registry keeps the settled record",
           sorted(h.tap.records), [""])


def test_working_is_removed_on_exit():
    with Harness() as h:
        # One record per id: the last report of an id is the record of that
        # id, so the four states live on four ids.
        h.osc(b"state=working:app=claude:id=work")
        h.osc(b"state=blocked:kind=permission:app=claude:id=block")
        h.osc(b"state=idle:app=claude:id=rest")
        h.osc(b"state=done:app=claude:id=settled")
        h.tap.close()
        h.flush()
        removals = h.removals()
        eq("exit: every live record is removed", len(removals), 3)
        work = next(c for c in removals if option(c, "--record-id") == "work")
        check("exit: the removal names the record",
              option(work, "--session").startswith(h.prefix + "-work"),
              removals)
        eq("exit: the removal names the agent", option(work, "--agent"), "claude")
        check("exit: the removal names the terminal",
              option(work, "--terminal-id").startswith("tap:4242:"), removals)
        eq("exit: the removal names the record id",
           option(work, "--record-id"), "work")
        eq("exit: the settled record stays", sorted(h.tap.records), ["settled"])
        eq("exit: the settled record is the done one",
           h.tap.records["settled"]["state"], "done")


def test_a_report_that_is_never_written_is_not_written():
    with Harness() as h:
        # The report is still queued when the child dies. The record goes
        # away with the child, so the report is dropped instead of being
        # written and then removed.
        h.feed_raw(b"\x1b]7501;state=working:app=claude\x1b\\")
        h.tap.close()
        h.flush()
        eq("exit: a report that was never written is not written",
           h.published(), [])
        eq("exit: the record is removed anyway", len(h.removals()), 1)


def test_blocked_is_removed_on_exit():
    with Harness() as h:
        h.osc(b"state=blocked:kind=question:app=claude")
        h.tap.close()
        h.flush()
        eq("exit: a blocked record is removed", len(h.removals()), 1)


def test_removal_carries_the_record_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build/test")
        h.tap.close()
        h.flush()
        removals = h.removals()
        eq("removal: one record is removed", len(removals), 1)
        eq("removal: the record id is on the wire",
           option(removals[0], "--record-id"), "build/test")


def test_the_root_removal_has_no_record_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.tap.close()
        h.flush()
        removals = h.removals()
        eq("removal: the root record is removed", len(removals), 1)
        eq("removal: the root has no record id",
           option(removals[0], "--record-id"), None)


# ---------------------------------------------------------- many records

def test_a_long_session_prefix_stays_within_the_writer_limit():
    with Harness(session="a" * 60) as h:
        h.osc(b"state=done:app=claude:id=build")
        session = option(h.published()[0], "--session")
        check("session: a long prefix still yields a <=64 name",
              len(session) <= 64, {"session": session, "len": len(session)})
        check("session: the name still starts with an id character",
              session[0].isalnum(), session)


def test_a_malformed_id_does_not_fall_back_to_root():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=clear:app=claude:id=bad id")
        h.flush()
        eq("broken id: the root is not cleared", sorted(h.tap.records), ["build"])


def test_several_ids():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=claude:id=lint")
        published = h.published()
        eq("ids: two records published", len(published), 2)
        sessions = [option(c, "--session") for c in published]
        check("ids: the records get different files", sessions[0] != sessions[1], sessions)
        check("ids: the files are named after the tap",
              all(s.startswith(h.prefix + "-") for s in sessions), sessions)
        check("ids: the terminal is the tap",
              option(published[0], "--terminal-id").startswith("tap:4242:"),
              option(published[0], "--terminal-id"))
        eq("ids: the registry holds both ids", sorted(h.tap.records), ["build", "lint"])


def test_id_with_slash():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build/test")
        session = option(h.published()[0], "--session")
        check("ids: a hierarchical id gets a plain token",
              session.startswith(h.prefix + "-build"), session)
        check("ids: the token carries no slash", "/" not in session, session)
        check("ids: the token fits the 64 characters", len(session) <= 64, session)


def test_long_id_is_hashed():
    with Harness() as h:
        # The longest id the grammar allows: 8 levels of 32 characters.
        long_id = "/".join("a" * 32 for _ in range(8))
        h.osc(f"state=working:app=claude:id={long_id}".encode())
        published = h.published()
        eq("ids: the longest legal id is published", len(published), 1)
        session = option(published[0], "--session")
        check("ids: a long id is shortened", len(session) <= 64, session)
        check("ids: a long id keeps a hash",
              session.startswith(h.prefix + "-aaa"), session)


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
        sessions = [option(c, "--session") for c in h.published()]
        eq("ids: both ids are published", len(sessions), 2)
        check("ids: two ids never share a file",
              sessions[0] != sessions[1], sessions)
        check("ids: the name of an id always carries a digest",
              all(len(session.rsplit("-", 1)[-1]) == 16 for session in sessions),
              sessions)


def test_record_cap_evicts_the_oldest():
    with Harness() as h:
        for index in range(muster_tap.MAX_RECORDS + 40):
            h.feed_raw(f"\x1b]7501;state=working:app=claude:id=job{index:03d}"
                        "\x1b\\".encode())
        eq("cap: the registry is bounded", len(h.tap.records),
           muster_tap.MAX_RECORDS)
        check("cap: the oldest record is gone",
              "job000" not in h.tap.records, sorted(h.tap.records)[:3])
        check("cap: the newest record is there",
              "job%03d" % (muster_tap.MAX_RECORDS + 39) in h.tap.records)
        check("cap: the app of the evicted record is gone",
              "job000" not in h.tap.apps)
        h.flush()
        removals = h.removals()
        check("cap: the evicted record is taken off the disk",
              any("job000" in (option(c, "--session") or "") for c in removals),
              [option(c, "--session") for c in removals])
        check("cap: the queue stays bounded",
              h.tap.pending_count <= muster_tap.MAX_PENDING,
              h.tap.pending_count)


def test_the_queue_is_bounded():
    with Harness() as h:
        for index in range(muster_tap.MAX_PENDING + 100):
            h.feed_raw(f"\x1b]7501;state=working:app=claude:id=job{index:04d}"
                        "\x1b\\".encode())
        check("queue: the queue is bounded",
              h.tap.pending_count <= muster_tap.MAX_PENDING,
              h.tap.pending_count)


# ------------------------------------------------------------ the clear

def test_root_clear_removes_everything():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=claude:id=build/test")
        eq("clear: three records before the clear", len(h.tap.records), 3)

        h.osc(b"state=clear")
        eq("clear: the root clear writes no record", len(h.published()), 3)
        removals = h.removals()
        eq("clear: every record is removed", len(removals), 3)
        eq("clear: the registry is empty", h.tap.records, {})
        eq("clear: the app entries are gone", h.tap.apps, {})
        sessions = sorted(option(c, "--session") for c in removals)
        check("clear: the child records are removed too",
              any(s.startswith(h.prefix + "-build") for s in sessions), sessions)


def test_id_clear_removes_descendants():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=claude:id=build/test")
        h.osc(b"state=working:app=claude:id=build/test/case")
        h.osc(b"state=working:app=claude:id=other")

        h.osc(b"state=clear:id=build")
        removals = h.removals()
        eq("clear: the id and its descendants are removed", len(removals), 3)
        eq("clear: the unrelated record survives", sorted(h.tap.records), ["other"])
        eq("clear: the app entries of the removed ids are gone",
           sorted(h.tap.apps), ["other"])
        check("clear: the descendants are the ones removed",
              all(option(c, "--session") != h.prefix for c in removals),
              [option(c, "--session") for c in removals])


def test_clear_of_an_unknown_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=clear:id=nothing")
        eq("clear: an unknown id removes nothing", h.removals(), [])
        eq("clear: an unknown id keeps the record", sorted(h.tap.records), [""])


def test_clear_with_a_malformed_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        # A clear with a broken id is ignored whole: it must not remove the
        # records of another id.
        h.osc(b"state=clear:id=" + b"a" * 300)
        h.osc(b"state=clear:id=a/b/c/d/e/f/g/h/i")
        h.osc(b"state=clear:id=build/../other")
        eq("clear: a malformed id removes nothing", h.removals(), [])
        eq("clear: a malformed id keeps the record", sorted(h.tap.records), ["build"])


# ------------------------------------------------------------- the apps

def test_app_inheritance():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:id=build")
        published = h.published()
        eq("apps: the child inherits the root app",
           option(published[1], "--agent"), "claude")
        eq("apps: the child is a record of its own",
           option(published[1], "--session") != option(published[0], "--session"), True)


def test_app_inheritance_from_the_nearest_ancestor():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=codex:id=build")
        h.osc(b"state=working:id=build/test")
        published = h.published()
        eq("apps: a grandchild inherits the nearest ancestor",
           option(published[2], "--agent"), "codex")


def test_agent_option_overrides_the_app():
    with Harness(agent="claude") as h:
        h.osc(b"state=working:app=codex")
        eq("apps: --agent wins over the reported app",
           option(h.published()[0], "--agent"), "claude")
    with Harness(agent="claude") as h:
        h.osc(b"state=working:id=build")
        eq("apps: --agent is the fallback when nothing is known",
           option(h.published()[0], "--agent"), "claude")


def test_ids_are_independent():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=done:app=claude:id=build")
        eq("ids: the root record is untouched by a child report",
           h.tap.records[""]["state"], "working")
        eq("ids: the child record is its own",
           h.tap.records["build"]["state"], "done")
        check("ids: the two records have different files",
              h.tap.records[""]["session"] != h.tap.records["build"]["session"])


def test_app_is_remembered_per_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=done:id=build")
        published = h.published()
        eq("apps: the app of an id is remembered",
           option(published[1], "--agent"), "claude")


def test_app_change_moves_the_record():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=codex:id=build")
        removals = h.removals()
        eq("apps: the old file is taken off the disk", len(removals), 1)
        eq("apps: the old file is named after the old app",
           option(removals[0], "--agent"), "claude")
        eq("apps: the record now belongs to the new app",
           h.tap.records["build"]["agent"], "codex")


def test_session_option_overrides_the_names():
    with Harness(session="my-session") as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=working:app=claude:id=build")
        published = h.published()
        eq("session: --session names the root record",
           option(published[0], "--session"), f"my-session-{h.tap.token}")
        check("session: --session prefixes every record",
              option(published[1], "--session").startswith(
                  f"my-session-{h.tap.token}-build-"), published)


# ------------------------------------------------------ broken reports

def test_unknown_state_is_ignored():
    with Harness() as h:
        h.osc(b"state=sideways:app=claude")
        h.osc(b"app=claude")
        h.osc(b"state=:app=claude")
        eq("broken: no state means no record", h.published(), [])
        eq("broken: the registry stays empty", h.tap.records, {})


def test_invalid_id_is_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=" + b"a" * 300)
        h.osc(b"state=working:app=claude:id=a/b/c/d/e/f/g/h/i")
        eq("broken: an id over the grammar is ignored", h.published(), [])
        eq("broken: the registry stays empty", h.tap.records, {})


def test_body_over_the_cap_is_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude:" + b"x" * 5000)
        eq("broken: a body over 4096 bytes is ignored", h.published(), [])


def test_an_oversized_body_is_not_a_probe():
    with Harness() as h:
        # The cap is checked before the query: a body that is too long is
        # dropped whole, and it is not a feature query either.
        h.osc(b"?" + b"x" * 5000)
        eq("broken: an oversized body is not answered", h.master_output(), b"")
        eq("broken: an oversized body writes no record", h.published(), [])


def test_malformed_pairs_are_skipped():
    with Harness() as h:
        h.osc(b"state=working:app=claude:garbage:title=aGk=")
        published = h.published()
        eq("broken: a malformed pair does not spoil the report", len(published), 1)
        eq("broken: the report is filed under the root",
           option(published[0], "--session"), h.prefix)


def test_unknown_keys_are_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude:whatever=1")
        eq("broken: an unknown key is ignored", len(h.published()), 1)


def test_last_duplicate_wins():
    with Harness() as h:
        h.osc(b"state=working:app=claude:app=codex")
        published = h.published()
        eq("broken: the last duplicate wins", option(published[0], "--agent"), "codex")


def test_whitespace_is_trimmed():
    with Harness() as h:
        h.osc(b"state = working : app = claude")
        published = h.published()
        eq("broken: whitespace around a key is trimmed", len(published), 1)
        eq("broken: whitespace around a value is trimmed",
           option(published[0], "--agent"), "claude")


def test_unicode_whitespace_is_not_trimmed():
    with Harness() as h:
        # The writer trims ASCII whitespace only. A Unicode space is not
        # whitespace on the wire, so the pair is malformed — and the tap must
        # not read it as a pair the writer would refuse.
        h.osc("state=working:app=\u00a0claude".encode())
        published = h.published()
        eq("broken: a Unicode space is not trimmed", len(published), 1)
        eq("broken: the app of a malformed pair is absent",
           option(published[0], "--agent"), "agent")

    with Harness() as h:
        h.osc("state\u00a0=working:app=claude".encode())
        eq("broken: a Unicode space in a key breaks the report",
           h.published(), [])


# ------------------------------------------------------- the whole wire

def test_split_sequence():
    with Harness() as h:
        h.feed(b"\x1b]7501;state=work")
        eq("wire: nothing is published before the terminator", h.published(), [])
        h.feed(b"ing:app=claude\x1b\\")
        published = h.published()
        eq("wire: a split sequence is published", len(published), 1)
        eq("wire: the body is the whole sequence",
           published[0]["body"], "state=working:app=claude")


def test_a_long_stream_is_scanned_once():
    with Harness() as h:
        # The scanner works on indexes: a stream of noise between the
        # sequences must not make the scan quadratic.
        noise = b"x" * 4096
        started = time.monotonic()
        for _ in range(200):
            h.feed_raw(noise)
            h.feed_raw(b"\x1b]7501;state=working:app=claude\x1b\\")
        elapsed = time.monotonic() - started
        check("wire: a long stream is scanned in time", elapsed < 10, elapsed)
        eq("wire: every report is seen", len(h.tap.records), 1)


def test_prompt_drops_working():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=done:app=claude:id=kept")
        h.feed(b"\x1b]133;A\x07")
        removals = h.removals()
        eq("prompt: the working record is removed", len(removals), 1)
        eq("prompt: the settled record survives", sorted(h.tap.records), ["kept"])
        eq("prompt: the settled record is the done one",
           h.tap.records["kept"]["state"], "done")


def test_prompt_split_across_reads():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.feed(b"\x1b]133")
        eq("prompt: a split prompt is not seen yet", h.removals(), [])
        h.feed(b";A\x1b\\")
        eq("prompt: a split prompt is seen", len(h.removals()), 1)


def test_prompt_keeps_idle():
    with Harness() as h:
        # The spec only kills the live states on a new prompt: an idle record
        # is not running, so it stays.
        h.osc(b"state=idle:app=claude:id=rest")
        h.feed(b"\x1b]133;A\x07")
        eq("prompt: an idle record survives the prompt", h.removals(), [])
        eq("prompt: the idle record is still there", sorted(h.tap.records), ["rest"])


def test_prompt_terminated_by_st():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.feed(b"\x1b]133;A\x1b\\")
        eq("prompt: ST terminates the prompt marker", len(h.removals()), 1)


def test_other_osc_133_markers_are_ignored():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.feed(b"\x1b]133;B\x1b\\")
        eq("prompt: another marker does not drop the record", h.removals(), [])
        eq("prompt: the record is still there", sorted(h.tap.records), [""])


# ------------------------------------------------------------- the names

def test_the_session_prefix_is_random():
    writer = FakeWriter()
    try:
        first = muster_tap.Tap(4242, writer.path)
        second = muster_tap.Tap(4242, writer.path)
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
        writer.close()


# --------------------------------------------------------- the writer

def test_a_burst_is_coalesced():
    with Harness() as h:
        for index in range(200):
            h.feed_raw(b"\x1b]7501;state=working:app=claude:id=build\x1b\\")
        eq("burst: nothing is written while the wire is read", h.calls(), [])
        eq("burst: the burst is one queued call", h.tap.pending_count, 1)
        h.flush()
        eq("burst: the burst costs one writer call", len(h.calls()), 1)
        eq("burst: the last report is the one that counts",
           h.calls()[0]["body"], "state=working:app=claude:id=build")


def test_a_burst_is_flushed_in_batches():
    with Harness() as h:
        for index in range(200):
            h.feed_raw(f"\x1b]7501;state=working:app=claude:id=job{index}\x1b\\"
                       .encode())
        h.tap.flush(limit=muster_tap.FLUSH_BATCH)
        check("burst: one batch is bounded",
              len(h.calls()) <= muster_tap.FLUSH_BATCH, len(h.calls()))
        check("burst: the rest is still queued", h.tap.pending_count > 0)
        h.flush()
        check("burst: writes stay bounded by the record cap",
              len(h.calls()) <= 2 * muster_tap.MAX_RECORDS + 4,
              len(h.calls()))
        eq("burst: the registry is still capped", len(h.tap.records),
           muster_tap.MAX_RECORDS)


# ---------------------------------------------------------- the writes

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
    writer = FakeWriter()
    try:
        env = {"MUSTER_REPORT": writer.path}

        sequence = b"\x1b]7501;state=working:app=claude\x1b\\"
        out, err, code = run_tap(
            ["sh", "-c",
             "printf '\\033]7501;state=working:app=claude\\033\\\\'; sleep 0.5"],
            env)
        eq("e2e: the exit code of the child is kept", code, 0)
        check("e2e: the bytes reach the terminal unchanged",
              sequence in out, {"out": out})
        eq("e2e: stderr is empty", err, b"")

        calls = writer.calls()
        published = [c for c in calls if "--osc-fd" in c["argv"]]
        eq("e2e: the report is published", len(published), 1)
        eq("e2e: the body is the report",
           published[0]["body"], "state=working:app=claude")
        terminal = option(published[0], "--terminal-id")
        session = option(published[0], "--session")
        check("e2e: the terminal is the tap", terminal.startswith("tap:"), terminal)
        eq("e2e: the terminal and the record name the same tap",
           terminal.split(":")[2], session.split("-")[2])
        removals = [c for c in calls
                    if "--remove" in c["argv"] or option(c, "--state") == "clear"]
        eq("e2e: the record is removed when the child exits", len(removals), 1)
        eq("e2e: the removal names the same record",
           option(removals[0], "--session"), option(published[0], "--session"))
    finally:
        writer.close()


def test_end_to_end_probe():
    writer = FakeWriter()
    try:
        env = {"MUSTER_REPORT": writer.path}

        # The child asks whether the terminal speaks the protocol and reads
        # the answer back; the answer has to come back on the pty.
        out, _err, _code = run_tap(
            ["sh", "-c",
             "stty -echo -icanon; printf '\\033]7501;?\\033\\\\'; timeout 2 cat"],
            env)
        check("e2e: the query reaches the terminal",
              b"\x1b]7501;?" in out, {"out": out})
        check("e2e: the query is answered", PROBE_REPLY in out, {"out": out})
        eq("e2e: the query writes no record", writer.calls(), [])
    finally:
        writer.close()


def test_end_to_end_a_grandchild_does_not_keep_the_tap_alive():
    writer = FakeWriter()
    try:
        env = {"MUSTER_REPORT": writer.path}
        # The child leaves a background process that holds the pty open and
        # then exits. The tap has to notice the exit and stop anyway.
        out, _err, code = run_tap(
            ["sh", "-c", "sleep 30 & printf 'done\\n'; exit 3"], env, timeout=20)
        eq("e2e: the exit code of the child is kept", code, 3)
        check("e2e: the output of the child arrives", b"done" in out, {"out": out})
    finally:
        writer.close()


def test_end_to_end_rejects_a_bad_option():
    proc = subprocess.run([sys.executable, TAP, "--nope", "--", "true"],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=20)
    eq("cli: an unknown option is refused", proc.returncode, 2)
    check("cli: the refusal says why", b"unknown option" in proc.stderr, proc.stderr)


def test_the_tap_does_not_spin():
    writer = FakeWriter()
    try:
        env = {"MUSTER_REPORT": writer.path}
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        run_tap(["sh", "-c", "sleep 2"], env, timeout=20)
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        used = ((after.ru_utime - before.ru_utime)
                + (after.ru_stime - before.ru_stime))
        # The tap waits for the wire; it does not burn the cpu while it waits.
        check("loop: the tap does not spin", used < 1.0, used)
    finally:
        writer.close()


def test_the_writer_override_is_vetted():
    writer = FakeWriter()
    try:
        def run(env):
            environment = dict(os.environ)
            environment.update(env)
            return subprocess.run([sys.executable, TAP, "--", "true"],
                                  stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=environment,
                                  timeout=20)

        proc = run({"MUSTER_REPORT": "relative/path"})
        eq("writer: a relative MUSTER_REPORT is refused", proc.returncode, 2)
        check("writer: the refusal says why",
              b"absolute" in proc.stderr, proc.stderr)

        loose = os.path.join(writer.dir, "loose")
        with open(loose, "w") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        os.chmod(loose, 0o777)
        proc = run({"MUSTER_REPORT": loose})
        eq("writer: a world-writable MUSTER_REPORT is refused", proc.returncode, 2)
        check("writer: the refusal says why",
              b"writable" in proc.stderr, proc.stderr)

        plain = os.path.join(writer.dir, "plain")
        with open(plain, "w") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        os.chmod(plain, 0o644)
        proc = run({"MUSTER_REPORT": plain})
        eq("writer: a MUSTER_REPORT that cannot run is refused", proc.returncode, 2)
        check("writer: the refusal says why",
              b"executable" in proc.stderr, proc.stderr)
    finally:
        writer.close()


def main():
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print(f"tap tests: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
