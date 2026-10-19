#!/usr/bin/env python3
"""Tests for bin/muster-report — the OSC 7501 writer.

    python3 tests/test_report.py

The writer is a bash script, so every case drives the real thing as a
subprocess against a temporary XDG_STATE_HOME and then looks at the record
it wrote — or at the record it did not write.

The cases follow the protocol (spec rev 0.4): a report is published in full
or not at all, a report without a state is ignored, an unknown kind and an
unusable progress are absent rather than fatal, and a report that breaks a
limit or carries a broken base64 value is discarded whole.
"""

import base64
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
REPORT = os.path.join(ROOT, "bin", "muster-report")

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


def b64(text):
    """A protocol free-text value: standard base64 of UTF-8."""
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


class State:
    """A throwaway state home with the writer's own environment."""

    def __init__(self, **env):
        self.dir = tempfile.mkdtemp(prefix="muster-report-test-")
        self.env = dict(os.environ)
        self.env["XDG_STATE_HOME"] = self.dir
        # The environment must not leak into the cases that do not want it.
        self.env.pop("MUSTER_TERMINAL_ID", None)
        self.env.update(env)

    def sessions(self):
        return os.path.join(self.dir, "omarchy", "muster", "sessions")

    def records(self):
        try:
            return sorted(os.listdir(self.sessions()))
        except FileNotFoundError:
            return []

    def record(self, name=None):
        """The record that was written, or None."""
        records = self.records()
        if name is None:
            if len(records) != 1:
                return None
            name = records[0]
        try:
            with open(os.path.join(self.sessions(), name)) as handle:
                return json.load(handle)
        except (FileNotFoundError, ValueError):
            return None

    def run(self, args, body=b"", **env):
        environ = dict(self.env)
        environ.update(env)
        return subprocess.run([REPORT] + list(args), input=body,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=environ)

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()


# ------------------------------------------------------------- the reports

def test_valid_body():
    with State() as state:
        body = ("state=working:app=claude:id=build/test:progress=42"
                ":title=" + b64("a title") + ":msg=" + b64("a message"))
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("a valid body: the writer accepts it", result.returncode, 0)
        record = state.record()
        check("a valid body: a record is written", record is not None)
        if record is None:
            return
        eq("a valid body: the agent", record["agent"], "claude")
        eq("a valid body: the state", record["state"], "working")
        eq("a valid body: the protocol id", record["recordId"], "build/test")
        eq("a valid body: the progress", record["progress"], 42)
        eq("a valid body: the title", record["name"], "a title")


def test_valid_blocked_body():
    with State() as state:
        body = ("state=blocked:app=claude:id=x:kind=permission"
                ":title=" + b64("waiting") + ":msg=" + b64("approve the patch"))
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("a blocked body: the writer accepts it", result.returncode, 0)
        record = state.record()
        if record is None:
            check("a blocked body: a record is written", False)
            return
        eq("a blocked body: the kind", record["kind"], "permission")
        eq("a blocked body: the message", record["message"], "approve the patch")
        eq("a blocked body: the title", record["name"], "waiting")


def test_broken_base64_discards_the_report():
    with State() as state:
        # A value in the wire charset that is not base64: the whole report
        # is discarded, the state is not kept without its text.
        body = "state=working:app=claude:id=x:title=not_base64"
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("broken base64: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("broken base64: no record", state.records(), [])


def test_control_character_discards_the_report():
    with State() as state:
        body = "state=working:app=claude:id=x:title=" + b64("a\nb")
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("a control character: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("a control character: no record", state.records(), [])

    with State() as state:
        # A C1 control (U+0085) is two bytes in UTF-8 and is forbidden too.
        body = "state=working:app=claude:id=x:title=" + b64("a\u0085b")
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("a C1 control: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("a C1 control: no record", state.records(), [])


def test_oversize_text_discards_the_report():
    with State() as state:
        body = "state=working:app=claude:id=x:title=" + b64("A" * 193)
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("an oversize title: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("an oversize title: no record", state.records(), [])

    with State() as state:
        body = "state=working:app=claude:id=x:msg=" + b64("B" * 2049)
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("an oversize message: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("an oversize message: no record", state.records(), [])


def test_oversize_body_discards_the_report():
    with State() as state:
        body = "state=working:app=claude:id=x:msg=" + "A" * 4200
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("an oversize body: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("an oversize body: no record", state.records(), [])


def test_report_without_a_state_is_ignored():
    with State() as state:
        body = "app=claude:id=x:title=" + b64("hello")
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("no state: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("no state: no record", state.records(), [])

    with State() as state:
        # The default is a convenience of the command line, and only there.
        result = state.run(["--agent", "claude", "--session", "s",
                            "--window", "none"])
        eq("no state: a plain call still defaults to working",
           result.returncode, 0)
        record = state.record()
        check("no state: a plain call writes a record", record is not None)
        if record:
            eq("no state: the default state", record["state"], "working")


def test_unknown_kind_and_progress_are_absent():
    with State() as state:
        body = "state=blocked:app=claude:id=x:kind=whatever:progress=abc"
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("an unknown kind: the report is not failed", result.returncode, 0)
        record = state.record()
        check("an unknown kind: a record is written", record is not None)
        if record is None:
            return
        eq("an unknown kind: it is absent", record["kind"], "")
        eq("a bad progress: it is absent", record["progress"], -1)
        eq("an unknown kind: the state is kept", record["state"], "blocked")

    with State() as state:
        body = "state=working:app=claude:id=x:progress=101"
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("an out of range progress: the report is not failed",
           result.returncode, 0)
        record = state.record()
        if record:
            eq("an out of range progress: it is absent", record["progress"], -1)


def test_the_kind_only_means_something_while_blocked():
    with State() as state:
        # A kind on a running report is stale data: it says why a session
        # waited, and this one is not waiting.
        body = "state=working:app=claude:id=x:kind=permission"
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("a kind on a working report: the report is not failed",
           result.returncode, 0)
        record = state.record()
        check("a kind on a working report: a record is written", record is not None)
        if record:
            eq("a kind on a working report: it is absent", record["kind"], "")


def test_invalid_id_discards_the_report():
    with State() as state:
        # A segment longer than 32 characters breaks the id grammar.
        body = "state=working:app=claude:id=" + "a" * 33
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        check("an invalid id: the writer refuses the report",
              result.returncode != 0, result.stderr.decode())
        eq("an invalid id: no record", state.records(), [])


def test_invalid_app_is_absent():
    with State() as state:
        # An app the agent shape does not allow is absent, not fatal: the
        # report is still published, under the agent that was given.
        body = "state=working:app=my/app:id=x"
        result = state.run(["--agent", "claude", "--session", "s",
                            "--osc-fd", "0", "--window", "none"], body.encode())
        eq("an unusable app: the report is not failed", result.returncode, 0)
        record = state.record()
        check("an unusable app: a record is written", record is not None)
        if record:
            eq("an unusable app: the app is absent", record["agent"], "claude")

    with State() as state:
        # An app over the spec's 32 bytes is absent as well.
        body = "state=working:app=" + "a" * 33 + ":id=x"
        result = state.run(["--agent", "claude", "--session", "s",
                            "--osc-fd", "0", "--window", "none"], body.encode())
        eq("an oversize app: the report is not failed", result.returncode, 0)
        record = state.record()
        if record:
            eq("an oversize app: the app is absent", record["agent"], "claude")


def test_malformed_pair_is_skipped():
    with State() as state:
        body = ("state=working:app=claude:id=x"
                ":this pair is broken:no equals sign here:app=pi")
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("a malformed pair: the report is not failed", result.returncode, 0)
        record = state.record()
        check("a malformed pair: a record is written", record is not None)
        if record is None:
            return
        eq("a malformed pair: the rest of the report is applied",
           record["state"], "working")
        eq("a malformed pair: a repeated key keeps the last value",
           record["agent"], "pi")


def test_whitespace_around_a_pair_is_trimmed():
    with State() as state:
        body = "state = working : app=claude:id=x"
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("whitespace: the report is not failed", result.returncode, 0)
        record = state.record()
        if record:
            eq("whitespace: the state is trimmed", record["state"], "working")
            eq("whitespace: the app is trimmed", record["agent"], "claude")


def test_long_id_is_accepted():
    ident = "/".join(["a" * 32] * 8)
    eq("the id is 263 characters", len(ident), 263)
    with State() as state:
        body = "state=working:app=claude:id=" + ident
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("a 263 character id: the report is written", result.returncode, 0)
        record = state.record()
        check("a 263 character id: a record is written", record is not None)
        if record:
            eq("a 263 character id: it is kept whole", record["recordId"], ident)


def test_the_text_limits_are_kept():
    with State() as state:
        title = "A" * 192
        message = "B" * 2048
        body = ("state=blocked:app=claude:id=x:title=" + b64(title)
                + ":msg=" + b64(message))
        result = state.run(["--osc-fd", "0", "--window", "none"], body.encode())
        eq("the limits: the report is written", result.returncode, 0)
        record = state.record()
        check("the limits: a record is written", record is not None)
        if record is None:
            return
        eq("the limits: the title is kept whole", len(record["name"]), 192)
        eq("the limits: the message is kept whole", len(record["message"]), 2048)


# ------------------------------------------------------------ the terminal id

def test_terminal_id():
    with State() as state:
        result = state.run(["--agent", "claude", "--session", "s",
                            "--terminal-id", "tap:4711", "--window", "none"])
        eq("the terminal id: the writer accepts it", result.returncode, 0)
        record = state.record()
        check("the terminal id: a record is written", record is not None)
        if record:
            eq("the terminal id: it is stored", record["terminalId"], "tap:4711")

    with State(MUSTER_TERMINAL_ID="tap:99") as state:
        result = state.run(["--agent", "claude", "--session", "s", "--window", "none"])
        eq("the environment: the writer accepts it", result.returncode, 0)
        record = state.record()
        if record:
            eq("the environment: it is the fallback",
               record["terminalId"], "tap:99")

    with State() as state:
        state.run(["--agent", "claude", "--session", "s", "--window", "none"])
        record = state.record()
        if record:
            eq("no terminal id: it is absent", record["terminalId"], "")

    with State() as state:
        # An absent terminal id must not erase one that is already known.
        state.run(["--agent", "claude", "--session", "s",
                   "--terminal-id", "tap:4711", "--window", "none"])
        state.run(["--agent", "claude", "--session", "s", "--window", "none"])
        record = state.record()
        if record:
            eq("no terminal id: the old one is kept",
               record["terminalId"], "tap:4711")

    with State() as state:
        result = state.run(["--agent", "claude", "--session", "s",
                            "--terminal-id", "not an id", "--window", "none"])
        check("an invalid terminal id: the writer refuses it",
              result.returncode != 0)
        eq("an invalid terminal id: no record", state.records(), [])

    with State(MUSTER_TERMINAL_ID="not an id") as state:
        result = state.run(["--agent", "claude", "--session", "s", "--window", "none"])
        eq("an invalid terminal id in the environment: the write still works",
           result.returncode, 0)
        record = state.record()
        if record:
            eq("an invalid terminal id in the environment: it is absent",
               record["terminalId"], "")


# ------------------------------------------------------------- the emitted OSC

def test_remove_emits_clear():
    with State() as state:
        state.run(["--agent", "claude", "--session", "s", "--window", "none"])
        check("the removal: a record is there to remove",
              len(state.records()) == 1)
        result = state.run(["--agent", "claude", "--session", "s", "--remove",
                            "--emit-osc", "1", "--window", "none"])
        out = result.stdout.decode()
        check("the removal: the sequence says clear", "state=clear" in out, out)
        check("the removal: the sequence is not working",
              "state=working" not in out, out)
        check("the removal: the sequence names the app", "app=claude" in out, out)
        eq("the removal: the record is gone", state.records(), [])


def test_clear_state_emits_clear():
    with State() as state:
        state.run(["--agent", "claude", "--session", "s", "--window", "none"])
        result = state.run(["--agent", "claude", "--session", "s",
                            "--state", "clear", "--emit-osc", "1", "--window", "none"])
        out = result.stdout.decode()
        check("the clear state: the sequence says clear",
              "state=clear" in out, out)
        eq("the clear state: the record is gone", state.records(), [])


def test_emit_only_carries_kind_and_progress_while_running():
    with State() as state:
        result = state.run(["--agent", "claude", "--session", "s",
                            "--state", "working", "--kind", "permission",
                            "--progress", "40", "--emit-osc", "1", "--window", "none"])
        out = result.stdout.decode()
        check("a working report carries its kind", "kind=permission" in out, out)
        check("a working report carries its progress", "progress=40" in out, out)

    for state_name in ("done", "error", "idle"):
        with State() as state:
            result = state.run(["--agent", "claude", "--session", "s",
                                "--state", state_name, "--kind", "permission",
                                "--progress", "40", "--emit-osc", "1",
                                "--window", "none"])
            out = result.stdout.decode()
            check("a " + state_name + " report carries no kind",
                  "kind=" not in out, out)
            check("a " + state_name + " report carries no progress",
                  "progress=" not in out, out)


def test_a_discarded_report_is_not_emitted():
    with State() as state:
        body = "state=working:app=claude:id=x:title=not_base64"
        result = state.run(["--osc-fd", "0", "--emit-osc", "1", "--window", "none"],
                           body.encode())
        eq("a discarded report is not emitted", result.stdout, b"")
        eq("a discarded report writes no record", state.records(), [])

    with State() as state:
        body = "app=claude:id=x"
        result = state.run(["--osc-fd", "0", "--emit-osc", "1", "--window", "none"],
                           body.encode())
        eq("a report without a state is not emitted", result.stdout, b"")


# --------------------------------------------------------------- the fd options

def test_strip_control_applies_to_the_descriptor_text():
    with State() as state:
        name = os.path.join(state.dir, "name")
        message = os.path.join(state.dir, "message")
        with open(name, "wb") as handle:
            handle.write(b"a\x1b[31mname")
        with open(message, "wb") as handle:
            handle.write(b"a\nmessage")
        # The text enters through a descriptor, never as an argument: the
        # shell hands the two files to the writer as fd 3 and fd 4.
        command = ("exec 3< {0} 4< {1}; exec {2} --agent claude --session s"
                   " --window none --state blocked --name-fd 3 --message-fd 4"
                   ).format(shlex.quote(name), shlex.quote(message),
                            shlex.quote(REPORT))
        result = subprocess.run(["/bin/sh", "-c", command],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=state.env)
        eq("the descriptor text: the writer accepts it", result.returncode, 0)
        record = state.record()
        check("the descriptor text: a record is written", record is not None)
        if record:
            eq("the descriptor text: the control bytes are stripped",
               record["name"], "a[31mname")
            eq("the descriptor text: the newline is stripped",
               record["message"], "amessage")


def main():
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print("%d passed, %d failed" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
