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
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

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

# The fake writer: it records how it was called, one JSON object per line.
# The log sits next to the fake itself, so the test needs no environment.
FAKE_REPORT = """#!/usr/bin/env python3
import json, os, sys
body = sys.stdin.buffer.read().decode("utf-8", "replace")
log_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "calls.jsonl")
with open(log_path, "a") as log:
    log.write(json.dumps({"argv": sys.argv[1:], "body": body}) + "\\n")
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
        self.log = os.path.join(self.dir, "calls.jsonl")
        self.path = os.path.join(self.dir, "muster-report")
        with open(self.path, "w") as handle:
            handle.write(FAKE_REPORT)
        os.chmod(self.path, 0o755)

    def calls(self):
        return read_calls(self.log)

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class Harness:
    """A receiver with a fake writer and a pipe standing in for the pty."""

    def __init__(self, agent="", session="", pid=4242):
        self.writer = FakeWriter()
        self.log = self.writer.log
        self.report = self.writer.path
        self.master_r, self.master_w = os.pipe()
        self.tap = muster_tap.Tap(pid, self.report, agent=agent, session=session,
                                  master_fd=self.master_w)

    def close(self):
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

    def feed(self, data):
        self.tap.feed(data)

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
        return [c for c in self.calls() if "--remove" in c["argv"]]


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
    with open(log) as handle:
        return [json.loads(line) for line in handle if line.strip()]


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
           option(published[0], "--session"), "tap-4242")
        eq("working: the terminal is named after the tap",
           option(published[0], "--terminal-id"), "tap:4242")
        eq("working: the body rides on a descriptor",
           option(published[0], "--osc-fd"), "0")

        h.osc(b"state=done:app=claude")
        eq("done: a second record published", len(h.published()), 2)
        eq("done: the same record is filed",
           option(h.published()[1], "--session"), "tap-4242")

        h.tap.close()
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
        removals = h.removals()
        eq("exit: every live record is removed", len(removals), 3)
        check("exit: the removal names the record",
              option(removals[0], "--session").startswith("tap-4242-work"),
              removals)
        eq("exit: the removal names the agent",
           option(removals[0], "--agent"), "claude")
        eq("exit: the removal names the terminal",
           option(removals[0], "--terminal-id"), "tap:4242")
        eq("exit: the settled record stays", sorted(h.tap.records), ["settled"])
        eq("exit: the settled record is the done one",
           h.tap.records["settled"]["state"], "done")


def test_blocked_is_removed_on_exit():
    with Harness() as h:
        h.osc(b"state=blocked:kind=question:app=claude")
        h.tap.close()
        eq("exit: a blocked record is removed", len(h.removals()), 1)


# ---------------------------------------------------------- many records

def test_several_ids():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build")
        h.osc(b"state=working:app=claude:id=lint")
        published = h.published()
        eq("ids: two records published", len(published), 2)
        sessions = [option(c, "--session") for c in published]
        check("ids: the records get different files", sessions[0] != sessions[1], sessions)
        check("ids: the files are named after the tap",
              all(s.startswith("tap-4242-") for s in sessions), sessions)
        eq("ids: the terminal is the tap", option(published[0], "--terminal-id"), "tap:4242")
        eq("ids: the registry holds both ids", sorted(h.tap.records), ["build", "lint"])


def test_id_with_slash():
    with Harness() as h:
        h.osc(b"state=working:app=claude:id=build/test")
        session = option(h.published()[0], "--session")
        check("ids: a hierarchical id gets a plain token",
              session.startswith("tap-4242-build"), session)
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
              session.startswith("tap-4242-aaa"), session)


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
              any(s.startswith("tap-4242-build") for s in sessions), sessions)


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
              all(option(c, "--session") != "tap-4242" for c in removals),
              [option(c, "--session") for c in removals])


def test_clear_of_an_unknown_id():
    with Harness() as h:
        h.osc(b"state=working:app=claude")
        h.osc(b"state=clear:id=nothing")
        eq("clear: an unknown id removes nothing", h.removals(), [])
        eq("clear: an unknown id keeps the record", sorted(h.tap.records), [""])


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
           option(published[0], "--session"), "my-session")
        eq("session: --session names every record",
           option(published[1], "--session"), "my-session")


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


def test_malformed_pairs_are_skipped():
    with Harness() as h:
        h.osc(b"state=working:app=claude:garbage:title=aGk=")
        published = h.published()
        eq("broken: a malformed pair does not spoil the report", len(published), 1)
        eq("broken: the report is filed under the root",
           option(published[0], "--session"), "tap-4242")


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


def test_clear_is_not_a_state():
    with Harness() as h:
        h.osc(b"state=clear")
        eq("broken: a clear writes no record", h.published(), [])


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
            ["sh", "-c", "printf '\\033]7501;state=working:app=claude\\033\\\\'"],
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
           terminal.split(":", 1)[1], session.split("-", 1)[1])
        removals = [c for c in calls if "--remove" in c["argv"]]
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


def test_end_to_end_rejects_a_bad_option():
    proc = subprocess.run([sys.executable, TAP, "--nope", "--", "true"],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=20)
    eq("cli: an unknown option is refused", proc.returncode, 2)
    check("cli: the refusal says why", b"unknown option" in proc.stderr, proc.stderr)


def main():
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print(f"tap tests: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
