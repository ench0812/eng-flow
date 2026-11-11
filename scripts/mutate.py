#!/usr/bin/env python3
"""mutate.py - negative-control (mutation) runner that cannot lie about red/green.

Apply ONE byte-exact edit to ONE file, run the test command, say whether the
tests noticed, and put the file back byte for byte. Repeat per mutation.

Usage:
  mutate.py --file F --find STR --replace STR --cmd "<test command>" [options]
  mutate.py --spec mutations.json [--cmd ...] [options]

Options:
  --runner {auto,pytest,go,vitest,jest,unittest,none}
                       how to read the test output (default auto: guessed from --cmd,
                       exit 2 if it cannot be guessed or is ambiguous)
  --ran-pattern RE     replaces the runner's own "tests really ran" check (multi-line regex)
  --expect-fail RE     the failing test names must include a match, else RED_WRONG
  --label NAME         label for the single-mutation form (default FILE:LINE)
  --cwd DIR            run the test command here; relative --file is resolved here
  --timeout SEC        per test-command run, default 600 (a timeout is NOT_RUN)
  --allow-test-file    allow --file to be something that looks like a test file
  -v, --verbose        also print the tail of the test output for GREEN/RED_WRONG

--spec JSON: {"cmd": "...", "runner": "...", "ran_pattern": "...", "timeout": 300,
              "mutations": [{"label","file","find","replace","cmd","runner",
                             "ran_pattern","expect_fail","timeout"}]}
(a bare list of mutation objects also works). Precedence: mutation entry > command
line flag > spec top level. Every mutation starts from the original file. Strings in
JSON are the safest way to pass backslashes, newlines, or text starting with "/" or "-"
(Git Bash rewrites arguments that look like Unix paths before Python sees them).

Verdicts, one line per mutation: <VERDICT> exit=<test exit code> <label> failed=<names>
  RED            tests ran and failed (and, with --expect-fail, the expected test failed)
  GREEN          tests ran and passed: nothing noticed the mutation
  RED_WRONG      tests ran and failed, but not the expected test (or no names extractable)
  NOT_RUN        the tests did not run to completion (collect/build error, timeout, no
                 summary, or the file changed under us); the exit code is NOT trusted
  BASELINE_RED / BASELINE_NOT_RUN
                 the UNMUTATED run was not green-and-ran; that mutation is skipped
Exit code: 0 every mutation RED; 1 any other verdict (or interrupted: 130/143);
           2 usage or spec error (nothing was run); 3 restore failed (loud, see message).

Safeguards:
  * --find must match exactly once as raw bytes (overlapping matches count); 0 or >1 -> exit 2.
  * Files are read and written as bytes; line endings are never touched, restore is
    verified with SHA-256 against the pre-mutation bytes.
  * The test process gets PYTHONDONTWRITEBYTECODE=1 and a fresh PYTHONPYCACHEPREFIX
    directory per run, so no stale .pyc (written earlier or lying around) can be read.
  * The restore never uses git. It reverses only the mutated segment; if someone else
    edited the file meanwhile and the segment cannot be located safely, the original
    and current bytes are saved under the temp dir and the exit code is 3.
  * Ctrl+C / SIGTERM / SIGHUP (Windows: Ctrl+Break and Ctrl+C) restore before exiting.
    Hard kills (kill -9, TerminateProcess) cannot be caught: a backup of the original
    bytes stays in <tmp>/mutate-backup-<pid>/ until the restore has been verified.
  * The test command runs through the platform shell (cmd.exe on Windows). Its process
    tree is killed on timeout or interrupt.
  * Nothing but --file is written. A --file that looks like a test file is refused: a
    mutation must change the code under test, not the thing that observes it.

Runner output rules (what counts as "the tests ran", what a failing name is):
  pytest   summary line "N passed/failed ... in T s" with passed+failed > 0; names from
           "FAILED node::id - msg" and "node::id FAILED" lines.  [verified, pytest 9.2]
  go       an "ok pkg T" or "FAIL pkg T" package line, no "[build failed]" /
           "[setup failed]" and not "[no tests to run]"; names from "--- FAIL: Name"
           (subtests included).  [verified, go 1.26; use text mode, not -json]
  unittest "Ran N tests" (N > 0) without unittest.loader._FailedTest; names from
           "FAIL: / ERROR: name (path)".  [verified, python 3.11]
  vitest   "Tests  ... (T)" line with passed+failed > 0; names from "FAIL  path > name".
           [NOT verified against real output: written from the documented format]
  jest     "Tests:  ... total" line with passed+failed > 0; names from "● suite › name".
           [NOT verified against real output: written from the documented format]
  none     only --ran-pattern decides; failing names are unavailable (no --expect-fail).
"""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

EXIT_OK, EXIT_NOT_PROVEN, EXIT_USAGE, EXIT_RESTORE = 0, 1, 2, 3
RUNNERS = ("pytest", "go", "vitest", "jest", "unittest")
CONTEXT_LADDER = (32, 8)          # bytes of surrounding text used to re-locate a mutated segment
TAIL_LINES = 25
MAX_NAMES_SHOWN = 6


class UsageError(Exception):
    pass


class RestoreFailure(Exception):
    pass


class Interrupted(BaseException):
    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


# --------------------------------------------------------------------------- signals

_STATE = {"critical": 0, "pending": None, "fired": False}


def _on_signal(signum, _frame):
    if _STATE["fired"]:             # the first interrupt is already unwinding and restoring: a second
        return                      # signal must not abort that cleanup half way, so it is dropped
    if _STATE["critical"]:          # never abort in the middle of write / restore: defer
        _STATE["pending"] = signum
        return
    _STATE["fired"] = True
    raise Interrupted(signum)


def install_signal_handlers() -> None:
    for name in ("SIGINT", "SIGTERM", "SIGBREAK", "SIGHUP"):
        sig = getattr(signal, name, None)
        if sig is None:
            continue
        try:
            signal.signal(sig, _on_signal)
        except (OSError, ValueError):
            pass


@contextlib.contextmanager
def critical():
    """Defer interrupts while the file is being written or restored."""
    _STATE["critical"] += 1
    clean = False
    try:
        yield
        clean = True
    finally:
        _STATE["critical"] -= 1
        if clean and _STATE["critical"] == 0 and _STATE["pending"] is not None:
            signum, _STATE["pending"] = _STATE["pending"], None
            if not _STATE["fired"]:
                _STATE["fired"] = True
                raise Interrupted(signum)


# --------------------------------------------------------------------------- runner parsing

_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def clean_output(raw: bytes) -> str:
    return _ANSI.sub("", raw.decode("utf-8", "replace")).replace("\r\n", "\n").replace("\r", "\n")


def _count(body: str, word: str) -> int:
    return sum(int(n) for n in re.findall(r"(\d+) " + word + r"\b", body))


_PYTEST_SUMMARY = re.compile(
    r"^\W*(?P<body>\d+ [a-z][a-z ]*(?:, \d+ [a-z][a-z ]*)*) in [\d.]+s(?: \(\d+:\d\d:\d\d\))?\W*$", re.M)


def parse_pytest(text: str):
    summaries = list(_PYTEST_SUMMARY.finditer(text))
    ran = False
    if summaries:
        body = summaries[-1].group("body")
        ran = _count(body, "passed") + _count(body, "failed") > 0
    names = []
    for line in text.split("\n"):
        m = re.match(r"^FAILED (.+?)(?: - .*)?$", line) or re.match(r"^(\S+::.+?) FAILED\b", line)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return ran, names


def parse_go(text: str):
    ran = bad = False
    names = []
    for line in text.split("\n"):
        if re.match(r"^FAIL\s+\S+\s+\[(?:build|setup) failed\]", line):
            bad = True
        elif re.match(r"^ok\s+\S+\s+(?:\(cached\)|\d+(?:\.\d+)?s)", line) and "[no tests to run]" not in line:
            ran = True
        elif re.match(r"^FAIL\s+\S+\s+\d+(?:\.\d+)?s", line):
            ran = True
        m = re.match(r"^\s*--- FAIL: (\S+)", line)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return ran and not bad, names


def parse_unittest(text: str):
    m = None
    for m in re.finditer(r"^Ran (\d+) tests? in ", text, re.M):
        pass
    ran = bool(m) and int(m.group(1)) > 0 and "unittest.loader._FailedTest" not in text
    names = []
    for mm in re.finditer(r"^(?:FAIL|ERROR): (.+)$", text, re.M):
        if mm.group(1) not in names:
            names.append(mm.group(1))
    return ran, names


def parse_vitest(text: str):
    # NOT verified against real vitest output.
    m = None
    for m in re.finditer(r"^\s*Tests\s+(?P<body>.*?)\s*\((?P<total>\d+)\)\s*$", text, re.M):
        pass
    ran = bool(m) and int(m.group("total")) > 0 and _count(m.group("body"), "passed") + _count(m.group("body"), "failed") > 0
    names = []
    for mm in re.finditer(r"^\s*FAIL\s+(\S.*?)\s*$", text, re.M):
        name = re.sub(r"\s+\[.*\]$", "", mm.group(1))
        if name not in names:
            names.append(name)
    return ran, names


def parse_jest(text: str):
    # NOT verified against real jest output.
    m = None
    for m in re.finditer(r"^\s*Tests:\s+(?P<body>.*\btotal)\s*$", text, re.M):
        pass
    ran = bool(m) and _count(m.group("body"), "passed") + _count(m.group("body"), "failed") > 0
    names = []
    for mm in re.finditer(r"^\s*\u25cf\s+(\S.*?)\s*$", text, re.M):
        name = mm.group(1)
        if name.startswith("Console") or "Test suite failed to run" in name:
            continue
        if name not in names:
            names.append(name)
    return ran, names


PARSERS = {"pytest": parse_pytest, "go": parse_go, "unittest": parse_unittest,
           "vitest": parse_vitest, "jest": parse_jest}

_DETECT = {
    "pytest": r"(?<![\w-])(?:pytest|py\.test)(?![\w-])",
    "go": r"(?<![\w-])go\s+test(?![\w-])",
    "unittest": r"(?<![\w-])unittest(?![\w-])",
    "vitest": r"(?<![\w-])vitest(?![\w-])",
    "jest": r"(?<![\w-])jest(?![\w-])",
}


def detect_runner(cmd: str) -> str | None:
    hits = [name for name, pat in _DETECT.items() if re.search(pat, cmd)]
    if len(hits) > 1:
        raise UsageError("cannot tell the runner from --cmd (%s all match); pass --runner" % ", ".join(hits))
    return hits[0] if hits else None


def judge_output(runner: str | None, ran_pattern, text: str):
    """Stage 1 of the verdict: did the tests really run?  Returns (ran, failed_names)."""
    ran_r, names = PARSERS[runner](text) if runner else (False, [])
    if ran_pattern is not None:
        return bool(ran_pattern.search(text)), names
    return ran_r, names


# --------------------------------------------------------------------------- bytes + locate

def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_bytes(path: str) -> bytes:
    with open(path, "rb") as fh:
        return fh.read()


def write_in_place(path: str, data: bytes) -> None:
    # r+b keeps the inode, mode and every byte we do not touch; write_text/newline
    # translation (CRLF on Windows) never gets a chance to run.
    with open(path, "r+b") as fh:
        fh.seek(0)
        fh.write(data)
        fh.truncate()
        fh.flush()
        os.fsync(fh.fileno())


def positions(data: bytes, needle: bytes, limit: int = 50) -> list[int]:
    out, i = [], data.find(needle)
    while i != -1 and len(out) < limit:
        out.append(i)
        i = data.find(needle, i + 1)          # overlapping matches are ambiguity too
    return out


def line_of(data: bytes, index: int) -> int:
    return data.count(b"\n", 0, index) + 1


def locate(path: str, data: bytes, needle: bytes) -> int:
    found = positions(data, needle)
    if not found:
        raise UsageError("--find has no match in %s (byte-exact, line endings included)" % path)
    if len(found) > 1:
        lines = ", ".join(str(line_of(data, i)) for i in found[:5])
        more = "+" if len(found) >= 50 else ""
        raise UsageError("--find matches %d%s times in %s (lines %s...): make it unique, never guess which one"
                         % (len(found), more, path, lines))
    return found[0]


# --------------------------------------------------------------------------- data model

@dataclasses.dataclass
class Mutation:
    label: str
    file: str
    path: str
    find: bytes
    replace: bytes
    cmd: str
    runner: str | None
    ran_pattern: "re.Pattern | None"
    expect_fail: "re.Pattern | None"
    timeout: float


@dataclasses.dataclass
class Outcome:
    rc: int | None
    text: str
    timed_out: bool


@dataclasses.dataclass
class Result:
    label: str
    verdict: str
    rc: int | None
    failed: list
    note: str = ""


_TESTISH = re.compile(
    r"(^|[\\/])(tests?|__tests__|specs?)([\\/]|$)"
    r"|(^|[\\/])(test_[^\\/]*\.py|conftest\.py|[^\\/]*_test\.(py|go)|[^\\/]*\.(test|spec)\.[cm]?[jt]sx?)$", re.I)


def looks_like_test_file(path: str, cwd: str) -> bool:
    rel = os.path.relpath(path, cwd) if os.path.splitdrive(path)[0].lower() == os.path.splitdrive(cwd)[0].lower() else path
    if rel.startswith(".."):
        rel = os.path.basename(path)
    return bool(_TESTISH.search(rel))


# --------------------------------------------------------------------------- spec / args

_MUT_KEYS = {"label", "file", "find", "replace", "cmd", "runner", "ran_pattern", "expect_fail", "timeout"}
_TOP_KEYS = {"cmd", "runner", "ran_pattern", "timeout", "mutations"}


def _compile(pattern, what: str):
    if pattern is None:
        return None
    if not isinstance(pattern, str):
        raise UsageError("%s must be a string" % what)
    try:
        return re.compile(pattern, re.M)
    except re.error as exc:
        raise UsageError("%s is not a valid regex: %s" % (what, exc))


def _to_bytes(value, what: str, from_argv: bool) -> bytes:
    if not isinstance(value, str):
        raise UsageError("%s must be a string" % what)
    try:
        return os.fsencode(value) if from_argv else value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise UsageError("%s is not encodable as UTF-8: %s" % (what, exc))


def parse_args(argv: list[str]):
    ap = argparse.ArgumentParser(prog="mutate.py", add_help=False)
    ap.add_argument("-h", "--help", action="store_true")
    ap.add_argument("--file")
    ap.add_argument("--find")
    ap.add_argument("--replace")
    ap.add_argument("--spec")
    ap.add_argument("--cmd")
    ap.add_argument("--runner", choices=("auto",) + RUNNERS + ("none",))
    ap.add_argument("--ran-pattern")
    ap.add_argument("--expect-fail")
    ap.add_argument("--label")
    ap.add_argument("--cwd")
    ap.add_argument("--timeout", type=float)
    ap.add_argument("--allow-test-file", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    try:
        return ap.parse_args(argv)
    except SystemExit as exc:                       # argparse exits 2 on its own; keep our message
        raise UsageError("bad arguments (see --help; use --find=-x for text starting with '-')") from exc


def build_mutations(args):
    cwd = os.path.abspath(args.cwd or os.getcwd())
    if not os.path.isdir(cwd):
        raise UsageError("--cwd is not a directory: %s" % cwd)
    single = [args.file, args.find, args.replace]
    if args.spec:
        if any(v is not None for v in single) or args.label or args.expect_fail:
            raise UsageError("--spec cannot be combined with --file/--find/--replace/--label/--expect-fail "
                             "(put them in each mutation entry)")
        try:
            with open(args.spec, "rb") as fh:
                doc = json.loads(fh.read().decode("utf-8"))
        except (OSError, ValueError) as exc:
            raise UsageError("cannot read --spec %s: %s" % (args.spec, exc))
        if isinstance(doc, list):
            doc = {"mutations": doc}
        if not isinstance(doc, dict) or not isinstance(doc.get("mutations"), list) or not doc["mutations"]:
            raise UsageError("--spec needs a non-empty list of mutations")
        unknown = set(doc) - _TOP_KEYS
        if unknown:
            raise UsageError("--spec has unknown top-level keys: %s" % ", ".join(sorted(unknown)))
        raws, from_argv = doc["mutations"], False
        top = {k: doc.get(k) for k in ("cmd", "runner", "ran_pattern", "timeout")}
    else:
        if any(v is None for v in single):
            raise UsageError("single form needs --file, --find and --replace (or use --spec)")
        raws = [{"file": args.file, "find": args.find, "replace": args.replace, "label": args.label,
                 "expect_fail": args.expect_fail}]
        from_argv, top = True, {}
    cli = {"cmd": args.cmd, "runner": args.runner, "ran_pattern": args.ran_pattern, "timeout": args.timeout}

    muts, seen = [], set()
    for n, raw in enumerate(raws, 1):
        where = "mutation #%d" % n
        if not isinstance(raw, dict):
            raise UsageError("%s must be an object" % where)
        unknown = set(raw) - _MUT_KEYS
        if unknown:
            raise UsageError("%s has unknown keys: %s" % (where, ", ".join(sorted(unknown))))
        for key in ("file", "find", "replace"):
            if raw.get(key) is None:
                raise UsageError("%s is missing %r" % (where, key))
        pick = lambda key: next((src[key] for src in (raw, cli, top) if src.get(key) is not None), None)
        cmd = pick("cmd")
        if not isinstance(cmd, str) or not cmd.strip():
            raise UsageError("%s has no test command (--cmd or \"cmd\")" % where)
        find = _to_bytes(raw["find"], where + " find", from_argv)
        replace = _to_bytes(raw["replace"], where + " replace", from_argv)
        if not find:
            raise UsageError("%s: find must not be empty" % where)
        if find == replace:
            raise UsageError("%s: replace equals find; a no-op mutation proves nothing" % where)
        runner = pick("runner")
        if runner in (None, "auto"):
            runner = detect_runner(cmd)
        elif runner == "none":
            runner = None
        elif runner not in RUNNERS:
            raise UsageError("%s: unknown runner %r" % (where, runner))
        ran_pattern = _compile(pick("ran_pattern"), where + " ran-pattern")
        expect = _compile(raw.get("expect_fail"), where + " expect-fail")
        if runner is None and ran_pattern is None:
            raise UsageError("%s: cannot tell how to know the tests ran; pass --runner or --ran-pattern" % where)
        if expect is not None and runner is None:
            raise UsageError("%s: --expect-fail needs a known runner to extract failing test names" % where)
        timeout = pick("timeout")
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) and timeout is not None:
            raise UsageError("%s: timeout must be a number" % where)
        timeout = 600.0 if timeout is None else float(timeout)
        if timeout <= 0:
            raise UsageError("%s: timeout must be > 0" % where)
        file = raw["file"]
        if not isinstance(file, str) or not file:
            raise UsageError("%s: file must be a non-empty string" % where)
        path = os.path.abspath(os.path.join(cwd, file))
        if not os.path.isfile(path):
            raise UsageError("%s: file does not exist: %s" % (where, path))
        if not args.allow_test_file and looks_like_test_file(path, cwd):
            raise UsageError("%s: %s looks like a test file; mutate the code under test, not the observer "
                             "(--allow-test-file overrides)" % (where, file))
        try:
            data = read_bytes(path)
        except OSError as exc:
            raise UsageError("%s: cannot read %s: %s" % (where, path, exc))
        index = locate(path, data, find)
        label = raw.get("label")
        if label is None:
            label = "%s:%d" % (file, line_of(data, index))
        if not isinstance(label, str) or not label:
            raise UsageError("%s: label must be a non-empty string" % where)
        if label in seen:
            raise UsageError("%s: duplicate label %r" % (where, label))
        seen.add(label)
        muts.append(Mutation(label, file, path, find, replace, cmd, runner, ran_pattern, expect, timeout))
    return muts, cwd


# --------------------------------------------------------------------------- running the tests

def kill_tree(proc: subprocess.Popen) -> None:
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=30)
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (OSError, subprocess.SubprocessError, ProcessLookupError):
        pass
    try:
        proc.kill()
    except OSError:
        pass


def _drain(proc: subprocess.Popen) -> bytes:
    try:
        out, _ = proc.communicate(timeout=10)
        return out or b""
    except (subprocess.TimeoutExpired, OSError, ValueError):
        return b""


def run_tests(cmd: str, cwd: str, timeout: float) -> Outcome:
    pyc_dir = tempfile.mkdtemp(prefix="mutate-pyc-")
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"          # nothing new is cached ...
    env["PYTHONPYCACHEPREFIX"] = pyc_dir          # ... and no pre-existing __pycache__ is ever read
    kwargs = {"cwd": cwd, "env": env, "shell": True, "stdin": subprocess.DEVNULL,
              "stdout": subprocess.PIPE, "stderr": subprocess.STDOUT}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    proc = None
    deadline = time.monotonic() + timeout
    try:
        proc = subprocess.Popen(cmd, **kwargs)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                kill_tree(proc)
                return Outcome(None, clean_output(_drain(proc)), True)
            try:
                out, _ = proc.communicate(timeout=min(0.25, remaining))   # short slices: Windows only
                return Outcome(proc.returncode, clean_output(out or b""), False)  # delivers signals between them
            except subprocess.TimeoutExpired:
                continue
    except BaseException:
        if proc is not None:
            kill_tree(proc)
            _drain(proc)
        raise
    finally:
        shutil.rmtree(pyc_dir, ignore_errors=True)


# --------------------------------------------------------------------------- restore

@dataclasses.dataclass
class Applied:
    mut: Mutation
    orig: bytes
    orig_sha: str
    index: int
    mutated: bytes
    backup: str | None = None
    foreign: bool = False


def reverse_segment(cur: bytes, ap: Applied) -> bytes | None:
    """Undo only the mutated segment inside bytes someone else has also edited."""
    m = ap.mut
    for ctx in CONTEXT_LADDER:
        pre = ap.orig[max(0, ap.index - ctx):ap.index]
        post = ap.orig[ap.index + len(m.find): ap.index + len(m.find) + ctx]
        anchored = pre + m.replace + post
        if len(positions(cur, anchored, 2)) == 1:
            at = cur.find(anchored) + len(pre)
            return cur[:at] + m.find + cur[at + len(m.replace):]
    return None


BACKUP_PREFIX = "mutate-backup-"


def save_backup(ap: Applied) -> str:
    # A unique folder per mutation (mkdtemp): a pid alone is not unique, Windows reuses them, and a
    # folder left by a hard-killed run may hold the only good copy of somebody's file.
    folder = tempfile.mkdtemp(prefix="%s%d-" % (BACKUP_PREFIX, os.getpid()))
    stem = os.path.join(folder, "%s-%s" % (os.path.basename(ap.mut.path), ap.orig_sha[:12]))
    try:
        with open(stem + ".orig", "wb") as fh:
            fh.write(ap.orig)
            fh.flush()
            os.fsync(fh.fileno())
        with open(stem + ".path.txt", "w", encoding="utf-8") as fh:
            fh.write(ap.mut.path + "\n" + ap.orig_sha + "\n")
    except BaseException:
        shutil.rmtree(folder, ignore_errors=True)     # our own, brand-new folder: safe to drop
        raise
    return stem + ".orig"


def discard_backup(ap: Applied) -> None:
    """After a verified restore: delete the files this run wrote, and the folder only if it is empty."""
    if not ap.backup:
        return
    stem = ap.backup[:-len(".orig")]
    for suffix in (".orig", ".path.txt"):
        with contextlib.suppress(OSError):
            os.remove(stem + suffix)
    with contextlib.suppress(OSError):
        os.rmdir(os.path.dirname(ap.backup))          # fails (and is ignored) when anything else is inside


def restore(ap: Applied) -> None:
    path = ap.mut.path
    try:
        cur = read_bytes(path)
    except OSError as exc:
        raise _restore_failure(ap, None, "cannot read the file back (%s)" % exc)
    if cur == ap.orig:
        return
    if cur == ap.mutated:
        target = ap.orig
    else:
        ap.foreign = True
        target = reverse_segment(cur, ap)
        if target is None:
            raise _restore_failure(ap, cur, "the file was edited during the run and the mutated segment "
                                            "cannot be located unambiguously")
    try:
        write_in_place(path, target)
        back = read_bytes(path)
    except OSError as exc:
        raise _restore_failure(ap, cur, "writing the restore failed (%s)" % exc)
    if back != target or (not ap.foreign and sha256(back) != ap.orig_sha):
        raise _restore_failure(ap, back, "restore verification failed (SHA-256 differs from the original)")


def _restore_failure(ap: Applied, cur: bytes | None, why: str) -> RestoreFailure:
    keep = ap.backup or save_backup(ap)
    lines = ["RESTORE FAILED for %s: %s" % (ap.mut.path, why),
             "  original bytes (sha256 %s) saved at: %s" % (ap.orig_sha, keep)]
    if cur is not None:
        side = keep[:-len(".orig")] + ".current"
        with open(side, "wb") as fh:
            fh.write(cur)
        lines.append("  bytes found on disk saved at: %s" % side)
    lines.append("  fix by hand, e.g. copy the .orig file over the target if nobody else's edits matter")
    return RestoreFailure("\n".join(lines))


# --------------------------------------------------------------------------- one mutation

def verdict_for(mut: Mutation, outcome: Outcome):
    if outcome.timed_out:
        return "NOT_RUN", [], "timed out after %gs (process tree killed)" % mut.timeout
    ran, names = judge_output(mut.runner, mut.ran_pattern, outcome.text)
    if not ran:
        return "NOT_RUN", names, "no sign the tests ran to completion (exit code ignored)"
    if outcome.rc == 0:
        return "GREEN", [], "tests passed: nothing noticed this mutation"
    if mut.expect_fail is not None:
        if any(mut.expect_fail.search(n) for n in names):
            return "RED", names, ""
        why = "expected %r among failures" % mut.expect_fail.pattern
        return "RED_WRONG", names, why if names else why + "; no failing names extracted (is -rN/-q hiding them?)"
    return "RED", names, ""


def apply_and_test(mut: Mutation, cwd: str):
    orig = read_bytes(mut.path)
    index = locate(mut.path, orig, mut.find)      # re-checked: the file may have changed since parsing
    ap = Applied(mut, orig, sha256(orig), index,
                 orig[:index] + mut.replace + orig[index + len(mut.find):])
    outcome = None
    try:
        with critical():
            ap.backup = save_backup(ap)
            write_in_place(mut.path, ap.mutated)
        outcome = run_tests(mut.cmd, cwd, mut.timeout)
    finally:
        with critical():
            restore(ap)
            discard_backup(ap)                  # only reached when the restore was verified
    verdict, names, note = verdict_for(mut, outcome)
    if ap.foreign:
        verdict = "NOT_RUN"
        note = ("file was edited by someone else during the run (only the mutated segment was "
                "reversed); result untrusted")
    return Result(mut.label, verdict, outcome.rc, names, note), outcome, ap.foreign


def baseline_key(mut: Mutation):
    return (mut.cmd, mut.runner, mut.ran_pattern.pattern if mut.ran_pattern else None, mut.timeout)


def run_baseline(mut: Mutation, cwd: str):
    outcome = run_tests(mut.cmd, cwd, mut.timeout)
    if outcome.timed_out:
        return "BASELINE_NOT_RUN", outcome, "timed out"
    ran, _ = judge_output(mut.runner, mut.ran_pattern, outcome.text)
    if not ran:
        return "BASELINE_NOT_RUN", outcome, "unmutated run shows no sign the tests ran"
    if outcome.rc != 0:
        return "BASELINE_RED", outcome, "unmutated tests already fail; a red mutation would mean nothing"
    return "OK", outcome, ""


# --------------------------------------------------------------------------- output / main

def show(text: str) -> None:
    print(text, flush=True)


def tail(outcome: Outcome) -> None:
    lines = [ln for ln in outcome.text.split("\n") if ln.strip()][-TAIL_LINES:]
    for ln in lines:
        show("    | " + ln)


def fmt(res: Result) -> str:
    names = "; ".join(res.failed[:MAX_NAMES_SHOWN]) or "-"
    if len(res.failed) > MAX_NAMES_SHOWN:
        names += " (+%d more)" % (len(res.failed) - MAX_NAMES_SHOWN)
    rc = "-" if res.rc is None else str(res.rc)
    line = "%-16s exit=%-4s %s  failed=%s" % (res.verdict, rc, res.label, names)
    return line + ("  -- " + res.note if res.note else "")


def unrestored(originals: dict, foreign_paths: set) -> list:
    """Paths whose bytes on disk differ from what they were before the first mutation.

    Files someone else edited during a run are skipped: they cannot be compared (reported separately).
    """
    bad = []
    for path, digest in originals.items():
        if path in foreign_paths:
            continue
        try:
            now = sha256(read_bytes(path))
        except OSError as exc:
            bad.append("%s (cannot be read: %s)" % (path, exc))
            continue
        if now != digest:
            bad.append(path)
    return bad


def main(argv: list[str]) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    try:
        args = parse_args(argv)
        if args.help:
            print(__doc__)
            return EXIT_OK
        muts, cwd = build_mutations(args)
    except UsageError as exc:
        print("mutate: usage error: %s" % exc, file=sys.stderr)
        return EXIT_USAGE

    results: list[Result] = []
    originals: dict[str, str] = {}
    foreign_paths: set = set()
    try:
        # Stage 0: the unmutated tests must be green AND must have run (once per distinct command).
        bases: dict = {}
        for mut in muts:
            originals.setdefault(mut.path, sha256(read_bytes(mut.path)))
            key = baseline_key(mut)
            if key not in bases:
                verdict, outcome, why = run_baseline(mut, cwd)
                bases[key] = (verdict, why)
                show("%-16s exit=%-4s %s" % ("baseline-" + ("ok" if verdict == "OK" else verdict.lower()),
                                              "-" if outcome.rc is None else outcome.rc, mut.cmd))
                if verdict != "OK":
                    show("    baseline: " + why)
                    tail(outcome)
        for mut in muts:
            verdict, why = bases[baseline_key(mut)]
            if verdict != "OK":
                results.append(Result(mut.label, verdict, None, [], "skipped: " + why))
                show(fmt(results[-1]))
                continue
            res, outcome, foreign = apply_and_test(mut, cwd)
            if foreign:
                foreign_paths.add(mut.path)
            results.append(res)
            show(fmt(res))
            if res.verdict in ("NOT_RUN",) or (args.verbose and res.verdict != "RED"):
                tail(outcome)
    except RestoreFailure as exc:
        print("mutate: " + str(exc), file=sys.stderr)
        return EXIT_RESTORE
    except Interrupted as exc:
        bad = unrestored(originals, foreign_paths)
        if bad:
            print("mutate: interrupted (signal %d) and NOT everything is back to its pre-run bytes:\n  %s\n"
                  "  look for the backup under %s (mutate-backup-*) and compare before trusting these files"
                  % (exc.signum, "\n  ".join(bad), tempfile.gettempdir()), file=sys.stderr)
            return EXIT_RESTORE
        print("mutate: interrupted (signal %d); every touched file was restored and checked (SHA-256) "
              "before exiting" % exc.signum, file=sys.stderr)
        return 128 + exc.signum
    except UsageError as exc:
        print("mutate: usage error: %s" % exc, file=sys.stderr)
        return EXIT_USAGE

    for path, digest in originals.items():
        now = sha256(read_bytes(path))
        if path in foreign_paths:
            show("not comparable %s (edited by someone else during the run) sha256=%s" % (os.path.relpath(path, cwd), now))
        elif now != digest:
            print("mutate: RESTORE FAILED: %s differs from its pre-run bytes after all mutations" % path, file=sys.stderr)
            return EXIT_RESTORE
        else:
            show("restored %s sha256=%s" % (os.path.relpath(path, cwd), now))
    counts: dict = {}
    for r in results:
        counts[r.verdict] = counts.get(r.verdict, 0) + 1
    show("summary: " + " ".join("%s=%d" % kv for kv in sorted(counts.items())))
    return EXIT_OK if results and all(r.verdict == "RED" for r in results) else EXIT_NOT_PROVEN


if __name__ == "__main__":
    install_signal_handlers()
    sys.exit(main(sys.argv[1:]))
