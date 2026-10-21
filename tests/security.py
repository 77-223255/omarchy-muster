#!/usr/bin/env python3
"""Adversarial security checks for Muster.

Run from the repository root:

    python3 tests/security.py

The suite follows the agent-security-playbook workflow: static tools for
known shapes, then concrete attacks against the writer, the reader, the state
directory, the multiplexer fields, and the QML text surfaces. It uses only
temporary state homes and never touches the installed plugin's records.

Exit status is 0 only when every check passes.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
REPORT = BIN / "muster-report"
TAP = BIN / "muster-tap"
SERVICE = ROOT / "Service.qml"
RECORD = ROOT / "Record.qml"
MODEL = ROOT / "Model.js"

passed = 0
failed = 0


def check(name: str, condition: bool, detail=None) -> None:
    global passed, failed
    if condition:
        passed += 1
    else:
        failed += 1
        print(f"FAIL: {name}", "" if detail is None else json.dumps(detail, default=str))


def eq(name: str, actual, expected, detail=None) -> None:
    extra = {"actual": actual, "expected": expected}
    if detail is not None:
        extra["detail"] = detail
    check(name, actual == expected, extra)


def run(cmd, cwd=ROOT, env=None, timeout=30, input_data=None, **kwargs):
    return subprocess.run(
        cmd, cwd=cwd, env=env, timeout=timeout, input=input_data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def run_qml_script(script: str, args, env=None, timeout=10):
    """Run a QML Process script the way Quickshell does: bash -c script name ..."""
    return run(["bash", "-c", script, "muster-security"] + [str(a) for a in args],
               env=env, timeout=timeout)


def qml_array(path: Path, name: str) -> str:
    """Extract a `readonly property string NAME: [ "line", ... ].join("\n")`."""
    text = path.read_text(encoding="utf-8")
    marker = f"readonly property string {name}: ["
    start = text.find(marker)
    if start < 0:
        raise AssertionError(f"{path}: {name} not found")
    start = text.find("[", start) + 1
    end = text.find("].join", start)
    if end < 0:
        raise AssertionError(f"{path}: {name} has no join")
    lines = []
    for raw in text[start:end].splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        line = line.rstrip(",")
        if not (line.startswith('"') and line.endswith('"')):
            raise AssertionError(f"{path}: unexpected {name} line: {line!r}")
        lines.append(json.loads(line))
    return "\n".join(lines)


def state_home() -> Path:
    return Path(tempfile.mkdtemp(prefix="muster-security-"))


def state_sessions(home: Path) -> Path:
    return home / "omarchy" / "muster" / "sessions"


def stat_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def report_env(home: Path, extra=None):
    env = os.environ.copy()
    env["XDG_STATE_HOME"] = str(home)
    env["HOME"] = str(home)
    if extra:
        env.update(extra)
    return env


def report(home: Path, args, *, input_data=None, env_extra=None, timeout=15,
           fd_data=None, fd_option=None):
    """Run muster-report with a temp state home and --window none by default."""
    args = list(args)
    if "--window" not in args:
        args += ["--window", "none"]
    env = report_env(home, env_extra)
    kwargs = {}
    pass_fds = ()
    if fd_data is not None:
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, fd_data)
        finally:
            os.close(write_fd)
        args += [fd_option, str(read_fd)]
        pass_fds = (read_fd,)
    try:
        return run([str(REPORT)] + args, env=env, input_data=input_data,
                   timeout=timeout, pass_fds=pass_fds)
    finally:
        if fd_data is not None:
            os.close(read_fd)


def fresh_writer_state():
    home = state_home()
    result = report(home, ["--agent", "pi", "--session", "base", "--state", "working"])
    if result.returncode != 0:
        raise AssertionError(result.stderr.decode("utf-8", "replace"))
    return home


def test_static_tools():
    shellcheck = shutil.which("shellcheck")
    if shellcheck:
        result = run([shellcheck, "-x", "-S", "style"] + sorted(str(p) for p in BIN.iterdir() if p.is_file()))
        check("static: shellcheck clean", result.returncode == 0,
              {"stderr": result.stderr.decode("utf-8", "replace")[:2000]})
    else:
        print("SKIP: shellcheck not installed")

    semgrep = shutil.which("semgrep")
    if semgrep:
        result = run([semgrep, "scan", "--config", "p/command-injection",
                      "--config", "p/secrets", "--config", "p/javascript",
                      "--config", "p/default", "--quiet", "."], timeout=240)
        check("static: semgrep shell/js clean", result.returncode == 0,
              {"stdout": result.stdout.decode("utf-8", "replace")[-4000:],
               "stderr": result.stderr.decode("utf-8", "replace")[-2000:]})
    else:
        print("SKIP: semgrep not installed")

    gitleaks = shutil.which("gitleaks")
    if gitleaks:
        result = run([gitleaks, "dir", ".", "--no-banner", "--redact"], timeout=120)
        check("static: gitleaks clean", result.returncode == 0,
              {"stdout": result.stdout.decode("utf-8", "replace")[-2000:]})
    else:
        print("SKIP: gitleaks not installed")

    qmllint = shutil.which("qmllint") or "/usr/lib/qt6/bin/qmllint"
    if Path(qmllint).exists():
        with tempfile.TemporaryDirectory(prefix="muster-security-qml-") as td:
            os.symlink("/usr/share/omarchy/shell", os.path.join(td, "qs"))
            result = run([qmllint, "-I", td, "-I", "/usr/lib/qt6/qml"]
                         + sorted(str(p) for p in ROOT.glob("*.qml")), timeout=120)
            output = (result.stdout + result.stderr).decode("utf-8", "replace")
            check("static: qmllint has no errors",
                  result.returncode == 0 and "Error:" not in output,
                  {"output": output[-3000:]})
    else:
        print("SKIP: qmllint not installed")

    if shutil.which("omarchy"):
        result = run(["omarchy", "plugin", "validate", "."], timeout=60)
        check("static: plugin validate", result.returncode == 0,
              {"output": (result.stdout + result.stderr).decode("utf-8", "replace")})

    check("static: no eval in executable scripts",
          not any(re.search(r"\beval\b", p.read_text(errors="replace"))
                  for p in BIN.iterdir() if p.is_file()))
    check("static: no rich/auto text in QML",
          not any(re.search(r"Text\.(?:RichText|AutoText)", p.read_text(errors="replace"))
                  for p in ROOT.glob("*.qml")))

    # Every Text bound to record data must say PlainText explicitly.
    for path in sorted(ROOT.glob("*.qml")):
        text = path.read_text(errors="replace")
        for match in re.finditer(r"(?<![A-Za-z0-9_.])Text\s*\{", text):
            start = match.end() - 1
            depth = 0
            end = start
            while end < len(text):
                if text[end] == "{":
                    depth += 1
                elif text[end] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
            block = text[start:end + 1]
            check(f"static: {path.name} Text block is PlainText",
                  "textFormat: Text.PlainText" in block,
                  {"snippet": block[:400]})

    if REPORT.exists():
        report_text = REPORT.read_text(errors="replace")
        lines = report_text.splitlines()
        leaks = [line for line in lines
                 if not line.lstrip().startswith("#")
                 and re.search(r"--arg\s", line)
                 and "--argjson" not in line and "--rawfile" not in line]
        check("static: no --arg value leaks in muster-report", not leaks, leaks)
        check("static: writer sets umask 077", "umask 077" in report_text)
        check("static: staging uses O_EXCL", "conv=excl" in report_text)
        check("static: lock is bounded", "flock -w 5 -x 9" in report_text)
        check("static: jq text uses --rawfile", "--rawfile" in report_text)
        check("static: --pid is validated before arithmetic",
              '[[ $pid =~ ^[0-9]{1,10}$ ]]' in report_text)

    if SERVICE.exists():
        service_text = SERVICE.read_text(errors="replace")
        check("static: herdr focus uses -- before the pane",
              'herdr agent focus -- "$2"' in service_text)
        check("static: tmux focus passes the pane after -t",
              'select-window -t "$3"' in service_text)
        check("static: focus data is positional, not interpolated",
              'steps.join("\\n")' in service_text and 'address:$1' in service_text)


def test_model_helpers():
    js = r"""
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync('Model.js', 'utf8').split('\n')
  .filter((line) => !/^\s*\.pragma\b/.test(line)).join('\n');
const ctx = vm.createContext({});
vm.runInContext(src, ctx);
const M = vm.runInContext('({normalizeRecord, safeAgentLabel, safeHerdrPane, safeTmuxSocket})', ctx);
const base = {agent: 'pi', state: 'working'};
const id = (raw) => M.normalizeRecord({...base, ...raw}, '/r.json');
const out = {
  herdr_bad: id({herdrPane: '-rf'}).herdrPane,
  herdr_good: id({herdrPane: 'w1:p1'}).herdrPane,
  socket_dot: id({tmuxSocket: '/tmp/./sock'}).tmuxSocket,
  socket_dotdot: id({tmuxSocket: '/tmp/../etc/sock'}).tmuxSocket,
  socket_empty: id({tmuxSocket: '/tmp//sock'}).tmuxSocket,
  socket_good: id({tmuxSocket: '/tmp/tmux-1000/default'}).tmuxSocket,
  window_bad: id({windowAddress: '0x1; touch /tmp/x'}).windowAddress,
  pane_bad: id({tmuxPane: '%1; touch /tmp/x'}).tmuxPane,
  label_bad: M.safeAgentLabel({agent: '../evil', agentLabel: '<b>x</b>'}).id,
};
console.log(JSON.stringify(out));
"""
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as handle:
        handle.write(js)
        name = handle.name
    try:
        result = run(["node", name], cwd=ROOT, timeout=30)
        if result.returncode != 0:
            check("model: helper check ran", False,
                  {"stderr": result.stderr.decode("utf-8", "replace")})
            return
        out = json.loads(result.stdout.decode("utf-8"))
        eq("model: leading-dash herdr pane dropped", out["herdr_bad"], "")
        eq("model: valid herdr pane kept", out["herdr_good"], "w1:p1")
        eq("model: . tmux socket segment dropped", out["socket_dot"], "")
        eq("model: .. tmux socket segment dropped", out["socket_dotdot"], "")
        eq("model: empty tmux socket segment dropped", out["socket_empty"], "")
        eq("model: valid tmux socket kept", out["socket_good"],
           "/tmp/tmux-1000/default")
        eq("model: injected window dropped", out["window_bad"], "")
        eq("model: injected tmux pane dropped", out["pane_bad"], "")
        eq("model: malicious agent id sanitized", out["label_bad"], "evil")
    finally:
        os.unlink(name)


def test_writer_permissions_and_repair():
    home = state_home()
    sessions = state_sessions(home)
    sessions.mkdir(parents=True)
    os.chmod(sessions, 0o755)
    old = sessions / "pi~base.json"
    old.write_text("{}", encoding="utf-8")
    os.chmod(old, 0o644)
    result = report(home, ["--agent", "pi", "--session", "base", "--state", "working"])
    eq("writer: hostile pre-existing state still writes", result.returncode, 0)
    eq("writer: sessions directory repaired to 0700", stat_mode(sessions), 0o700)
    eq("writer: record created 0600", stat_mode(old), 0o600)
    check("writer: repaired record stays readable by owner",
          os.access(old, os.R_OK))
    shutil.rmtree(home, ignore_errors=True)


def test_writer_prompt_not_in_argv():
    home = state_home()
    probe = "probe-value-7f3a"
    wrap = home / "wrap"
    wrap.mkdir()
    log = home / "argv.log"
    tools = ["jq", "dd", "tr", "sed", "stat", "mv", "flock", "chmod",
             "cut", "date", "wc", "awk", "cat", "head", "od", "rm"]
    for tool in tools:
        real = shutil.which(tool)
        if not real:
            continue
        path = wrap / tool
        path.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$0 $*\" >> \"$MUSTER_ARGV_LOG\"\n"
            f"exec {real} \"$@\"\n", encoding="utf-8")
        os.chmod(path, 0o755)
    result = report(home, ["--agent", "pi", "--session", "base", "--state", "working",
                           "--prompt-fd", "0"],
                    input_data=probe.encode(),
                    env_extra={"PATH": f"{wrap}:{os.environ['PATH']}",
                               "MUSTER_ARGV_LOG": str(log)})
    eq("writer: prompt-through-fd write succeeds", result.returncode, 0)
    record = load_json(state_sessions(home) / "pi~base.json")
    eq("writer: prompt reaches the record", record.get("lastPrompt"), probe)
    logged = log.read_text(errors="replace") if log.exists() else ""
    check("writer: prompt never appears in a child argv", probe not in logged,
          {"log": logged[-2000:]})
    check("writer: jq receives --rawfile, not --arg",
          "--rawfile" in logged and "--arg " not in logged,
          {"log": logged[-2000:]})
    shutil.rmtree(home, ignore_errors=True)


def test_writer_arithmetic_injection():
    home = state_home()
    pwned = home / "pwned"
    payloads = [
        f"i[$(touch {pwned})]",
        f"1; touch {pwned}",
        f"$(touch {pwned})",
    ]
    for payload in payloads:
        result = report(home, ["--agent", "pi", "--session", "base",
                               "--state", "working", "--pid", payload])
        check("writer: arithmetic payload rejected", result.returncode != 0,
              {"payload": payload, "stderr": result.stderr.decode("utf-8", "replace")})
    check("writer: arithmetic payload never executed", not pwned.exists())
    shutil.rmtree(home, ignore_errors=True)


def test_writer_symlinks_and_special_files():
    home = fresh_writer_state()
    sessions = state_sessions(home)
    victim = home / "victim"
    victim.write_text("important\n", encoding="utf-8")
    record_path = sessions / "pi~sym.json"
    os.symlink(victim, record_path)
    result = report(home, ["--agent", "pi", "--session", "sym", "--state", "working"])
    check("writer: symlinked record path is refused", result.returncode != 0,
          {"stderr": result.stderr.decode("utf-8", "replace")})
    eq("writer: symlinked record victim unchanged", victim.read_text(), "important\n")
    check("writer: symlink record is not followed", record_path.is_symlink())

    # A hardlink at the destination is replaced, not written through.
    os.unlink(record_path)
    os.link(victim, record_path)
    result = report(home, ["--agent", "pi", "--session", "sym", "--state", "working"])
    eq("writer: hardlinked record path still writes", result.returncode, 0)
    eq("writer: hardlinked record victim unchanged", victim.read_text(), "important\n")

    # A FIFO at the destination must be refused, not opened or followed.
    fifo = sessions / "pi~fifo.json"
    if hasattr(os, "mkfifo"):
        os.mkfifo(fifo)
        result = report(home, ["--agent", "pi", "--session", "fifo",
                               "--state", "working"], timeout=5)
        check("writer: FIFO record refused without blocking",
              result.returncode != 0, {"stderr": result.stderr.decode("utf-8", "replace")})
        os.unlink(fifo)

    # A symlinked state component must be refused.
    other = state_home()
    (other / "omarchy").mkdir()
    target = other / "elsewhere"
    target.mkdir()
    os.symlink(target, other / "omarchy" / "muster")
    result = report(other, ["--agent", "pi", "--session", "x", "--state", "working"],
                    timeout=5)
    check("writer: symlinked muster component refused",
          result.returncode != 0, {"stderr": result.stderr.decode("utf-8", "replace")})
    eq("writer: symlinked component writes nowhere",
       list(target.iterdir()), [])
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(other, ignore_errors=True)


def test_writer_oversized_previous():
    home = fresh_writer_state()
    record_path = state_sessions(home) / "pi~base.json"
    record_path.write_bytes(b"{" + b" " * (70 * 1024) + b"}")
    result = report(home, ["--agent", "pi", "--session", "base", "--state", "working"],
                    timeout=10)
    eq("writer: oversized previous record does not wedge the writer",
       result.returncode, 0)
    check("writer: the published record is back under the reader cap",
          record_path.stat().st_size <= 65536)
    check("writer: the published record parses",
          isinstance(load_json(record_path), dict))
    shutil.rmtree(home, ignore_errors=True)


def test_writer_concurrency():
    home = fresh_writer_state()
    procs = [subprocess.Popen([str(REPORT), "--agent", "pi", "--session", "base",
                               "--state", "working", "--completed", "--window", "none"],
                              env=report_env(home),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
             for _ in range(10)]
    for proc in procs:
        proc.wait(timeout=20)
    check("writer: concurrent completions all exit 0",
          all(proc.returncode == 0 for proc in procs),
          [proc.returncode for proc in procs])
    record = load_json(state_sessions(home) / "pi~base.json")
    eq("writer: concurrent increments are not lost", record.get("completedRuns"), 10)
    shutil.rmtree(home, ignore_errors=True)


def test_writer_lock_timeout():
    home = fresh_writer_state()
    sessions = state_sessions(home)
    fd = os.open(sessions, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        started = time.monotonic()
        result = report(home, ["--agent", "pi", "--session", "base",
                               "--state", "working"], timeout=8)
        elapsed = time.monotonic() - started
        check("writer: held lock fails within the timeout",
              result.returncode != 0 and elapsed < 8,
              {"elapsed": elapsed, "stderr": result.stderr.decode("utf-8", "replace")})
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        shutil.rmtree(home, ignore_errors=True)


def test_writer_caps_and_controls():
    home = state_home()
    huge = ("A" * 5000 + "\x1b[31m" + "\u202eB").encode("utf-8")
    result = report(home, ["--agent", "pi", "--session", "base", "--state", "blocked"],
                    fd_data=huge, fd_option="--prompt-fd")
    eq("writer: huge prompt still writes", result.returncode, 0)
    record = load_json(state_sessions(home) / "pi~base.json")
    prompt = record.get("lastPrompt", "")
    check("writer: prompt is capped", len(prompt) <= 240, {"len": len(prompt)})
    check("writer: control and bidi bytes are stripped",
          "\x1b" not in prompt and "\u202e" not in prompt, {"prompt": prompt[:80]})

    base_args = ["--agent", "pi", "--session", "x", "--state", "working"]
    for option, value in (("--agent", "a" * 65),
                          ("--session", "../../escape"),
                          ("--window", "0x1; touch /tmp/x"),
                          ("--tmux-pane", "-rf"),
                          ("--prompt", "text"),
                          ("--message", "text"),
                          ("--name", "text"),
                          ("--cwd", "/tmp")):
        args = base_args.copy()
        if option == "--agent":
            args[1] = value
        elif option == "--session":
            args[3] = value
        else:
            args += [option, value]
        result = report(home, args, timeout=5)
        check(f"writer: {option} malformed/text form rejected",
              result.returncode != 0, {"stderr": result.stderr.decode("utf-8", "replace")})
    shutil.rmtree(home, ignore_errors=True)


def test_writer_focus_fields():
    home = state_home()
    result = report(home, ["--agent", "pi", "--session", "base", "--state", "working",
                           "--tmux-pane", "%3",
                           "--tmux-socket", "/tmp/../etc/socket"])
    eq("writer: hostile focus fields do not fail the write", result.returncode, 0)
    record = load_json(state_sessions(home) / "pi~base.json")
    eq("writer: traversal tmux socket dropped", record.get("tmuxSocket"), "")
    eq("writer: valid tmux pane kept", record.get("tmuxPane"), "%3")

    result = report(home, ["--agent", "pi", "--session", "badpane", "--state", "working",
                           "--herdr-pane", "-rf"])
    check("writer: leading-dash herdr pane rejected", result.returncode != 0)

    result = report(home, ["--agent", "pi", "--session", "base2", "--state", "working",
                           "--tmux-socket", "/tmp/tmux-1000/default",
                           "--herdr-pane", "w1:p1"])
    eq("writer: valid focus fields accepted", result.returncode, 0)
    record = load_json(state_sessions(home) / "pi~base2.json")
    eq("writer: valid tmux socket kept", record.get("tmuxSocket"), "/tmp/tmux-1000/default")
    eq("writer: valid herdr pane kept", record.get("herdrPane"), "w1:p1")
    shutil.rmtree(home, ignore_errors=True)


def test_read_script():
    home = state_home()
    sessions = state_sessions(home)
    sessions.mkdir(parents=True)
    os.chmod(sessions, 0o700)
    script = qml_array(RECORD, "readScript")
    valid = sessions / "pi~ok.json"
    valid.write_text('{"agent":"pi","state":"working","lastPrompt":"ok"}', encoding="utf-8")
    os.chmod(valid, 0o600)
    result = run_qml_script(script, [valid, 65536, home])
    eq("reader: valid record is read", result.returncode, 0)
    outside = run_qml_script(script, ["/etc/passwd", 65536, home])
    eq("reader: a path outside the state home is refused", outside.stdout, b"")
    eq("reader: valid record content survives", result.stdout,
       valid.read_bytes())

    victim = home / "victim"
    victim.write_text("important\n", encoding="utf-8")
    link = sessions / "pi~link.json"
    os.symlink(victim, link)
    result = run_qml_script(script, [link, 65536, home])
    eq("reader: symlink record refused", result.stdout, b"")

    fifo = sessions / "pi~fifo.json"
    if hasattr(os, "mkfifo"):
        os.mkfifo(fifo)
        started = time.monotonic()
        result = run_qml_script(script, [fifo, 65536, home], timeout=3)
        elapsed = time.monotonic() - started
        eq("reader: FIFO record refused", result.stdout, b"")
        check("reader: FIFO does not block", elapsed < 3, {"elapsed": elapsed})
        os.unlink(fifo)

    big = sessions / "pi~big.json"
    big.write_bytes(b"{" + b" " * 70000 + b"}")
    result = run_qml_script(script, [big, 65536, home])
    eq("reader: oversized record refused", result.stdout, b"")

    # A symlinked component is refused even though the final name is regular.
    other = state_home()
    (other / "omarchy").mkdir()
    target = other / "target"
    target.mkdir()
    os.symlink(target, other / "omarchy" / "muster")
    result = run_qml_script(script, [other / "omarchy" / "muster" / "sessions" / "x.json",
                                     65536, other])
    eq("reader: symlinked component refused", result.stdout, b"")
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(other, ignore_errors=True)


def test_mkdir_script():
    home = state_home()
    script = qml_array(SERVICE, "mkdirScript")
    result = run_qml_script(script, [home], timeout=30)
    eq("mkdir: normal setup succeeds", result.returncode, 0,
       {"stderr": result.stderr.decode("utf-8", "replace")})
    eq("mkdir: sessions mode is 0700", stat_mode(state_sessions(home)), 0o700)
    eq("mkdir: marks mode is 0755",
       stat_mode(home / "omarchy" / "muster" / "marks"), 0o755)

    # Repair a directory left world-readable by an older version.
    os.chmod(state_sessions(home), 0o755)
    result = run_qml_script(script, [home], timeout=30)
    eq("mkdir: world-readable sessions repaired", result.returncode, 0)
    eq("mkdir: sessions repaired to 0700", stat_mode(state_sessions(home)), 0o700)

    other = state_home()
    (other / "omarchy").mkdir()
    target = other / "target"
    target.mkdir()
    os.symlink(target, other / "omarchy" / "muster")
    result = run_qml_script(script, [other], timeout=30)
    check("mkdir: symlinked component refused", result.returncode != 0,
          {"stderr": result.stderr.decode("utf-8", "replace")})
    eq("mkdir: symlinked component writes nowhere", list(target.iterdir()), [])
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(other, ignore_errors=True)


def test_list_script():
    home = state_home()
    sessions = state_sessions(home)
    sessions.mkdir(parents=True)
    os.chmod(sessions, 0o700)
    script = qml_array(SERVICE, "listScript")
    valid = sessions / "pi~ok.json"
    valid.write_text("{}", encoding="utf-8")
    os.chmod(valid, 0o600)
    if hasattr(os, "mkfifo"):
        os.mkfifo(sessions / "pi~fifo.json")
    os.symlink(valid, sessions / "pi~link.json")
    sessions.joinpath("bad\nname.json").write_text("{}", encoding="utf-8")
    result = run_qml_script(script, [home], timeout=6)
    eq("list: normal listing succeeds", result.returncode, 0)
    output = result.stdout.decode("utf-8", "replace")
    check("list: valid record listed", "pi~ok.json" in output, {"output": output[:1000]})
    check("list: symlink, FIFO and newline names are not listed",
          "pi~link.json" not in output and "pi~fifo.json" not in output
          and "bad" not in output, {"output": output[:1000]})

    # A flood is capped and still bounded by the caller's timeout.
    for index in range(10000):
        (sessions / f"pi~{index:05d}.json").write_text("{}", encoding="utf-8")
    started = time.monotonic()
    result = run_qml_script(script, [home], timeout=6)
    elapsed = time.monotonic() - started
    lines = [line for line in result.stdout.decode("utf-8", "replace").splitlines()
             if line and not line.startswith("#dir ")]
    check("list: a 10000-file flood stays under the timeout", elapsed < 6,
          {"elapsed": elapsed})
    check("list: the listing is capped at 256", len(lines) <= 256,
          {"lines": len(lines)})

    other = state_home()
    (other / "omarchy").mkdir()
    target = other / "target"
    target.mkdir()
    os.symlink(target, other / "omarchy" / "muster")
    result = run_qml_script(script, [other], timeout=6)
    check("list: symlinked component refused", result.returncode != 0)
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(other, ignore_errors=True)


def test_mark_script():
    home = state_home()
    script = qml_array(SERVICE, "markScript")
    (home / "omarchy" / "muster").mkdir(parents=True)
    marks = home / "omarchy" / "muster" / "marks"
    marks.mkdir()
    victim = home / "victim"
    victim.write_text("important\n", encoding="utf-8")
    os.symlink(victim, marks / "pi.svg")
    result = run_qml_script(script, [marks, "#ffffff", "#ff8800", "#ff0000", home],
                            timeout=30)
    eq("marks: normal write succeeds", result.returncode, 0,
       {"stderr": result.stderr.decode("utf-8", "replace")})
    eq("marks: symlinked mark victim unchanged", victim.read_text(), "important\n")
    check("marks: symlink replaced by a regular SVG",
          (marks / "pi.svg").is_file() and not (marks / "pi.svg").is_symlink())
    for agent in ("kimi", "agy", "ori", "pi"):
        check(f"marks: {agent} mark generated", (marks / f"{agent}.svg").is_file())
    eq("marks: marks directory stays 0755", stat_mode(marks), 0o755)
    shutil.rmtree(home, ignore_errors=True)


def test_tap_security():
    if not TAP.exists():
        return
    test = ROOT / "tests" / "test_tap.py"
    if test.exists():
        result = run([sys.executable, str(test)], cwd=ROOT, timeout=240)
        check("tap: existing security suite passes", result.returncode == 0,
              {"stdout": result.stdout.decode("utf-8", "replace")[-2000:],
               "stderr": result.stderr.decode("utf-8", "replace")[-2000:]})
    # The record store must refuse a symlinked sessions directory.
    with tempfile.TemporaryDirectory(prefix="muster-security-tap-") as home:
        base = Path(home)
        (base / "omarchy" / "muster").mkdir(parents=True)
        target = base / "target"
        target.mkdir()
        os.symlink(target, base / "omarchy" / "muster" / "sessions")
        result = run([sys.executable, str(TAP), "--", "true"],
                     env=report_env(base), timeout=20)
        check("tap: symlinked sessions directory refused", result.returncode != 0,
              {"stderr": result.stderr.decode("utf-8", "replace")})


def test_model_unit_tests():
    test = ROOT / "tests" / "test_model.js"
    if test.exists():
        result = run(["node", str(test)], cwd=ROOT, timeout=60)
        check("model: unit tests pass", result.returncode == 0,
              {"stdout": result.stdout.decode("utf-8", "replace")[-1000:],
               "stderr": result.stderr.decode("utf-8", "replace")[-1000:]})


def main():
    print(f"security: {ROOT}")
    test_static_tools()
    test_model_helpers()
    if REPORT.exists():
        test_writer_permissions_and_repair()
        test_writer_prompt_not_in_argv()
        test_writer_arithmetic_injection()
        test_writer_symlinks_and_special_files()
        test_writer_oversized_previous()
        test_writer_concurrency()
        test_writer_lock_timeout()
        test_writer_caps_and_controls()
        test_writer_focus_fields()
    test_read_script()
    test_mkdir_script()
    test_list_script()
    test_mark_script()
    test_tap_security()
    test_model_unit_tests()
    print(f"security tests: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
