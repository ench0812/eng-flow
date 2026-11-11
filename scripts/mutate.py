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
  -v, --verbose        also print the tail of the test output for every verdict (RED too, so
                       the failing assertion's expected/actual can be quoted as evidence)

--spec JSON: {"cmd": "...", "runner": "...", "ran_pattern": "...", "timeout": 300,
              "mutations": [{"label","file","find","replace","cmd","runner",
                             "ran_pattern","expect_fail","timeout"}]}
(a bare list of mutation objects also works). Precedence: mutation entry > command
line flag > spec top level. Every mutation starts from the original file. Strings in
JSON are the safest way to pass backslashes, newlines, or text starting with "/" or "-"
(Git Bash rewrites arguments that look like Unix paths before Python sees them).

Verdicts, one line per mutation: <VERDICT> exit=<test exit code> <label> failed=<names>
  RED            tests ran and failed (and, with --expect-fail, the expected test failed).
                 When the output names no failing test and gives no failure count the line
                 says "not confirmed as a test failure"
  GREEN          tests ran and passed: nothing noticed the mutation
  RED_WRONG      tests ran and failed, but not the expected test (or no names extractable)
  RED_NONTEST    the command exited non-zero but the runner's own summary reports 0 failed
                 tests (coverage gate, lint, a second command in --cmd): not a red
  NOT_RUN        the tests did not run to completion (collect/build error, timeout, no
                 summary, every test skipped, or the file changed under us); the exit code
                 is NOT trusted
  BASELINE_RED / BASELINE_NOT_RUN
                 the UNMUTATED run was not green-and-ran; that mutation is skipped
  A line judged by the vitest or jest parser ends with "(unverified parser)".
Exit code: 0 every mutation RED; 1 any other verdict;
           2 usage or spec error (nothing was run);
           3 restore failed, or an earlier hard-killed run's backup still points at the file
             (loud, see message);
           4 the target cannot be written (read-only, locked): nothing was mutated;
           128+signal after an interrupt (SIGINT 130, SIGTERM 143, Windows Ctrl+Break 149).

Safeguards:
  * --find must match exactly once as raw bytes (overlapping matches count); 0 or >1 -> exit 2.
  * Files are read and written as bytes; line endings are never touched, restore is
    verified with SHA-256 against the pre-mutation bytes (the original mtime is put back too).
  * Stale Python bytecode: the test process gets PYTHONDONTWRITEBYTECODE=1 and a fresh
    PYTHONPYCACHEPREFIX directory per run. That reaches only a Python that inherits the
    environment and is not started with -E or -I (a warning is printed for those). For
    those, the mutated file additionally gets an mtime a random number of whole seconds
    away from the original's and from every earlier mutation's, which defeats any .pyc that
    checks timestamps (CPython compares whole seconds and size). NOT covered: a hash-based
    .pyc with unchecked-hash invalidation read by a Python started with -E or -I, and
    caches of other tools.
  * The restore never uses git. It reverses only the mutated segment; if someone else
    edited the file meanwhile and the segment cannot be located safely, the original
    and current bytes are saved under the temp dir and the exit code is 3. A transient
    lock on the restore write is retried 3 times (0.5 s apart).
  * Ctrl+C / SIGTERM / SIGHUP (Windows: Ctrl+Break and Ctrl+C) restore before exiting; a
    second signal during that cleanup is ignored, and the files are re-checked by SHA-256
    before the "restored" message (a mismatch exits 3 instead). Hard kills (taskkill /F,
    TerminateProcess, kill -9) cannot be caught: the file stays mutated and a backup of the
    original bytes stays in <tmp>/mutate-backup-<pid>-<random>/ (deleted only after a
    verified restore, and only the files this run wrote). The next run that is about to
    mutate the same file refuses to start (exit 3) while such a backup exists, its writer
    process is gone and the file differs from it, and prints the .orig path and how to
    compare. Caveat: if the dead run's pid has been reused by a live process, the backup
    looks owned and is not reported.
  * A run can take (1 + N) x --timeout at worst (a baseline plus N mutations). Start it in the
    background, or keep the caller's own timeout above that: a hard kill of the script
    mid-mutation (e.g. a tool timeout that uses taskkill /F) is the one thing it cannot undo.
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
  unittest "Ran N tests" with N greater than the skipped count, without
           unittest.loader._FailedTest; names from "FAIL: / ERROR: name (path)".
           [verified, python 3.11]
  vitest   "Tests  ... (T)" line with passed+failed > 0; names from "FAIL  path > name".
           [NOT verified against real output: written from the documented format]
  jest     "Tests:  ... total" line with passed+failed > 0; names from "● suite › name".
           [NOT verified against real output: written from the documented format]
  none     only --ran-pattern decides; failing names are unavailable (no --expect-fail).
  Failure count (what separates RED from RED_NONTEST): pytest failed + errors in the
  summary; go named failures + failed packages; unittest failures + errors + unexpected
  successes; vitest / jest the "failed" figure of the Tests line. Unreadable = unknown, not 0.
"""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

EXIT_OK, EXIT_NOT_PROVEN, EXIT_USAGE, EXIT_RESTORE, EXIT_IO = 0, 1, 2, 3, 4
RETRIES, RETRY_WAIT = 3, 0.5      # a transient lock (antivirus, indexer) gets a few short waits, never a long one
RUNNERS = ("pytest", "go", "vitest", "jest", "unittest")
CONTEXT_LADDER = (32, 8)          # bytes of surrounding text used to re-locate a mutated segment
TAIL_LINES = 25
MAX_NAMES_SHOWN = 6


class UsageError(Exception):
    pass


class RestoreFailure(Exception):
    pass


class WriteFailure(Exception):
    """The target cannot be opened for writing (read-only, locked, disk full): nothing was mutated."""


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


# Every parser returns (ran, failing names, failure count). The count is the runner's own summary
# of how many tests failed, or None when no summary could be read: "None" means unknown, never zero.

# A module that failed to import is a collection error ("ERROR collecting x.py" header, "ERROR x.py"
# summary line without "::"). With --continue-on-collection-errors the other modules still run and the
# summary reads "1 passed, 1 error": that is a mutation that broke an import, not a test noticing it.
# A fixture error ("ERROR x.py::test_y - ...") names a test and still counts as a failure.
_PYTEST_COLLECT_ERROR = re.compile(r"^_* ?ERROR collecting\b|^ERROR (?![^\n]*::)\S+", re.M)


def parse_pytest(text: str):
    summaries = list(_PYTEST_SUMMARY.finditer(text))
    ran, nfail = False, None
    if summaries:
        body = summaries[-1].group("body")
        ran = _count(body, "passed") + _count(body, "failed") > 0
        nfail = _count(body, "failed") + _count(body, "errors?")
    if _PYTEST_COLLECT_ERROR.search(text):
        ran = False
    names = []
    for line in text.split("\n"):
        m = re.match(r"^FAILED (.+?)(?: - .*)?$", line) or re.match(r"^(\S+::.+?) FAILED\b", line)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return ran, names, nfail


def parse_go(text: str):
    ran = bad = False
    names, failed_packages = [], 0
    for line in text.split("\n"):
        if re.match(r"^FAIL\s+\S+\s+\[(?:build|setup) failed\]", line):
            bad = True
        elif re.match(r"^ok\s+\S+\s+(?:\(cached\)|\d+(?:\.\d+)?s)", line) and "[no tests to run]" not in line:
            ran = True
        elif re.match(r"^FAIL\s+\S+\s+\d+(?:\.\d+)?s", line):
            ran = True
            failed_packages += 1                    # a test binary that failed, named test or not
        m = re.match(r"^\s*--- FAIL: (\S+)", line)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return ran and not bad, names, len(names) + failed_packages


def parse_unittest(text: str):
    m = None
    for m in re.finditer(r"^Ran (\d+) tests? in ", text, re.M):
        pass
    status = None
    for status in re.finditer(r"^(?:OK|FAILED)(?: \((?P<detail>.*)\))?\s*$", text, re.M):
        pass
    detail = (status.group("detail") or "") if status else ""
    skipped = sum(int(n) for n in re.findall(r"skipped=(\d+)", detail))
    # "Ran 3 tests ... OK (skipped=3)": nothing was executed, whatever the exit code says
    ran = bool(m) and int(m.group(1)) - skipped > 0 and "unittest.loader._FailedTest" not in text
    names = []
    for mm in re.finditer(r"^(?:FAIL|ERROR): (.+)$", text, re.M):
        if mm.group(1) not in names:
            names.append(mm.group(1))
    nfail = None
    if m:
        nfail = sum(int(n) for n in re.findall(r"(?:failures|errors|unexpected successes)=(\d+)", detail))
    return ran, names, nfail


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
    return ran, names, (_count(m.group("body"), "failed") if m else None)


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
    return ran, names, (_count(m.group("body"), "failed") if m else None)


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


UNVERIFIED_PARSERS = ("vitest", "jest")     # written from the documented format, never run against the real tool


def judge_output(runner: str | None, ran_pattern, text: str):
    """Stage 1 of the verdict: did the tests really run?  Returns (ran, failed_names, failure_count)."""
    ran_r, names, nfail = PARSERS[runner](text) if runner else (False, [], None)
    if ran_pattern is not None:
        return bool(ran_pattern.search(text)), names, nfail
    return ran_r, names, nfail


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
        try:
            fh.seek(0)
            fh.write(data)
            fh.truncate()
            fh.flush()
            os.fsync(fh.fileno())
        except OSError as exc:
            # The open succeeded, so some of our bytes may be on disk. A failed open wrote nothing and
            # carries no mark: restore must then treat any difference as someone else's.
            exc.mutate_wrote = True
            raise


def write_with_retry(path: str, data: bytes) -> None:
    for attempt in range(RETRIES):
        try:
            write_in_place(path, data)
            return
        except OSError:
            if attempt == RETRIES - 1:
                raise
            time.sleep(RETRY_WAIT)


def preflight_writable(paths) -> None:
    """Open every target for writing (without writing) so a read-only file fails before any test run."""
    for path in sorted(set(paths)):
        try:
            with open(path, "r+b"):
                pass
        except OSError as exc:
            raise WriteFailure("cannot write %s (%s); nothing was run. Make it writable (read-only flag, a program "
                               "holding a lock) and run again" % (path, exc))


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


_PYTHON_EXE = re.compile(r"(?:python|pythonw|py)[\d.]*(?:\.exe)?", re.I)
_PY_ENV_BLIND_FLAG = re.compile(r"-[A-Za-z]*[EI][A-Za-z]*")


def python_ignores_env(cmd: str) -> bool:
    """True when --cmd starts a Python with -E or -I (it then ignores PYTHON* environment variables)."""
    tokens = cmd.replace('"', " ").replace("'", " ").split()
    for i, tok in enumerate(tokens):
        if not _PYTHON_EXE.fullmatch(os.path.basename(tok.replace("\\", "/"))):
            continue
        j = i + 1
        while j < len(tokens) and tokens[j].startswith("-") and tokens[j] not in ("-m", "-c"):
            if _PY_ENV_BLIND_FLAG.fullmatch(tokens[j]):
                return True
            j += 2 if tokens[j] in ("-W", "-X") else 1      # these two take a separate argument
    return False


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
    orig_times: tuple | None = None        # (atime_ns, mtime_ns) before the first write
    write_incomplete: bool = False         # our own mutation write failed part-way: the bytes on disk are ours


_USED_MTIMES: set = set()


def shift_mtime(ap: Applied) -> None:
    """Give the mutated file an mtime in a different whole second than the original's.

    CPython trusts a .pyc when the source's mtime (whole seconds) and size equal what the pyc
    recorded; an edit within the same second of the same size is invisible to it. The env vars set
    for the test process cannot help when Python is started with -E or -I, but a different mtime
    does, for every pyc that checks timestamps. The shift is random (and never reused in this run)
    so it cannot equal the mtime recorded by an earlier mutation of the same size either.
    """
    if ap.orig_times is None:
        return
    atime, mtime = ap.orig_times
    new = mtime
    for _ in range(16):
        new = mtime + random.randrange(2 * 3600, 30 * 86400) * 1_000_000_000      # 2 hours .. 30 days
        if new not in _USED_MTIMES:
            break
    _USED_MTIMES.add(new)
    with contextlib.suppress(OSError):          # best effort: the env protection still applies
        os.utime(ap.mut.path, ns=(atime, new))


def restore_mtime(ap: Applied) -> None:
    if ap.orig_times is not None and not ap.foreign:
        with contextlib.suppress(OSError):
            os.utime(ap.mut.path, ns=ap.orig_times)


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


def pid_alive(pid: int) -> bool:
    if pid == os.getpid():
        return True
    if os.name == "nt":                               # os.kill(pid, 0) would TERMINATE the process here
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.restype = wintypes.HANDLE
        handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ctypes.get_last_error() == 5       # access denied: it exists; 87 (bad pid): it does not
        try:
            code = wintypes.DWORD()
            return not k32.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value == 259   # STILL_ACTIVE
        finally:
            k32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _norm(path: str) -> str:
    return os.path.normcase(os.path.abspath(path))


def find_stale_backups(paths: set) -> list:
    """Backups of files we are about to mutate whose writer is gone and whose file still differs.

    A hard kill (taskkill /F, TerminateProcess, kill -9) cannot be caught: the target stays
    mutated and the only record of the original is the backup folder. Returns
    [(orig_file, target_path, folder, pid)].
    """
    wanted = {_norm(p) for p in paths}
    root, found = tempfile.gettempdir(), []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return found
    for name in names:
        m = re.match(r"^" + re.escape(BACKUP_PREFIX) + r"(\d+)(?:-.*)?$", name)
        if not m or pid_alive(int(m.group(1))):
            continue
        folder = os.path.join(root, name)
        try:
            entries = sorted(os.listdir(folder))
        except OSError:
            continue
        for entry in entries:
            if not entry.endswith(".path.txt"):
                continue
            try:
                with open(os.path.join(folder, entry), "rb") as fh:
                    lines = fh.read().decode("utf-8", "replace").splitlines()
            except OSError:
                continue
            orig = os.path.join(folder, entry[:-len(".path.txt")] + ".orig")
            if len(lines) < 2 or _norm(lines[0]) not in wanted or not os.path.isfile(orig):
                continue
            try:
                same = sha256(read_bytes(lines[0])) == lines[1].strip()
            except OSError:
                same = False
            if not same:                              # a file that equals the recorded original needs no repair
                found.append((orig, lines[0], folder, int(m.group(1))))
    return found


def refuse_on_stale_backups(paths: set) -> bool:
    stale = find_stale_backups(paths)
    for orig, target, folder, pid in stale:
        compare = 'fc /b "%s" "%s"' % (target, orig) if os.name == "nt" else 'cmp "%s" "%s"' % (target, orig)
        print("mutate: refusing to run: an earlier mutate run (pid %d, no longer running; hard-killed?) left a "
              "backup for %s\n"
              "  original bytes: %s\n"
              "  the file may still contain that run's mutation. Compare:  %s\n"
              "  if it differs, put the original back (copy the .orig over the file), then delete %s and run again;\n"
              "  if the file is fine as it is, just delete that folder"
              % (pid, target, orig, compare, folder), file=sys.stderr)
    return bool(stale)


def restore(ap: Applied) -> None:
    path = ap.mut.path
    try:
        cur = read_bytes(path)
    except OSError as exc:
        raise _restore_failure(ap, None, "cannot read the file back (%s)" % exc)
    if cur == ap.orig:
        restore_mtime(ap)
        return
    if cur == ap.mutated or (ap.write_incomplete and _our_partial_write(cur, ap)):
        # a half-written mutation is our own partial bytes, not someone else's edit: put the original back whole
        target = ap.orig
    else:
        ap.foreign = True
        target = reverse_segment(cur, ap)
        if target is None:
            raise _restore_failure(ap, cur, "the file was edited during the run and the mutated segment "
                                            "cannot be located unambiguously")
    try:
        write_with_retry(path, target)
        back = read_bytes(path)
    except OSError as exc:
        raise _restore_failure(ap, cur, "writing the restore failed (%s)" % exc)
    if back != target or (not ap.foreign and sha256(back) != ap.orig_sha):
        raise _restore_failure(ap, back, "restore verification failed (SHA-256 differs from the original)")
    restore_mtime(ap)


def _our_partial_write(cur: bytes, ap: Applied) -> bool:
    """True only when the bytes on disk are what an interrupted in-place write of ap.mutated leaves:
    a prefix of the mutated bytes followed by the original's own tail from that offset (write raised
    part-way, or truncate raised after the write; truncate never runs after a failed write, so a
    shortened file is not ours). Anything else may be someone else's save and must not be overwritten.
    Only consulted when write_in_place marked the failure as having written (the open succeeded)."""
    m, o = ap.mutated, ap.orig
    k, n = 0, min(len(cur), len(m))
    while k < n and cur[k] == m[k]:
        k += 1
    return cur[k:] == o[k:]


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
    verdict, names, note = _verdict_core(mut, outcome)
    if mut.runner in UNVERIFIED_PARSERS:
        note = (note + " (unverified parser)").strip()
    return verdict, names, note


def _verdict_core(mut: Mutation, outcome: Outcome):
    if outcome.timed_out:
        return "NOT_RUN", [], "timed out after %gs (process tree killed)" % mut.timeout
    ran, names, nfail = judge_output(mut.runner, mut.ran_pattern, outcome.text)
    if not ran:
        return "NOT_RUN", names, "no sign the tests ran to completion (exit code ignored)"
    if outcome.rc == 0:
        return "GREEN", [], "tests passed: nothing noticed this mutation"
    confirmed = bool(names) or bool(nfail)         # a failing name, or a runner count above zero
    if not confirmed and nfail == 0:
        # the runner's own summary says nothing failed, so this non-zero exit came from something else in
        # the command (coverage threshold, lint, a second command): not evidence that a test noticed
        return ("RED_NONTEST", names,
                "the runner reports 0 failed tests but the command exited %s (coverage gate, lint, a second "
                "command in --cmd?): not counted as red" % outcome.rc)
    if mut.expect_fail is not None:
        if any(mut.expect_fail.search(n) for n in names):
            return "RED", names, ""
        why = "expected %r among failures" % mut.expect_fail.pattern
        return "RED_WRONG", names, why if names else why + "; no failing names extracted (is -rN/-q hiding them?)"
    if not confirmed:
        return "RED", names, ("non-zero exit, but the output names no failing test and gives no failure count: "
                              "not confirmed as a test failure")
    return "RED", names, ""


def apply_and_test(mut: Mutation, cwd: str):
    orig = read_bytes(mut.path)
    index = locate(mut.path, orig, mut.find)      # re-checked: the file may have changed since parsing
    st = os.stat(mut.path)
    ap = Applied(mut, orig, sha256(orig), index,
                 orig[:index] + mut.replace + orig[index + len(mut.find):],
                 orig_times=(st.st_atime_ns, st.st_mtime_ns))
    outcome = None
    try:
        with critical():
            ap.backup = save_backup(ap)
            try:
                write_with_retry(mut.path, ap.mutated)
            except OSError as exc:
                ap.write_incomplete = bool(getattr(exc, "mutate_wrote", False))
                raise WriteFailure("cannot write %s (%s); the original bytes were written back and no test ran for %s"
                                   % (mut.path, exc, mut.label))
            shift_mtime(ap)
        outcome = run_tests(mut.cmd, cwd, mut.timeout)
    finally:
        with critical():
            restore(ap)
            # The backup is the only full copy of the original: drop it only when the file on disk is
            # byte-identical to it. A foreign edit (only our segment reversed) keeps it for the user.
            try:
                whole = sha256(read_bytes(mut.path)) == ap.orig_sha
            except OSError:
                whole = False
            if whole:
                discard_backup(ap)
    verdict, names, note = verdict_for(mut, outcome)
    if ap.foreign:
        verdict = "NOT_RUN"
        note = ("file was edited by someone else during the run (only the mutated segment was "
                "reversed); result untrusted; the original before the run is kept at %s" % ap.backup)
    return Result(mut.label, verdict, outcome.rc, names, note), outcome, ap.foreign


def baseline_key(mut: Mutation):
    return (mut.cmd, mut.runner, mut.ran_pattern.pattern if mut.ran_pattern else None, mut.timeout)


def run_baseline(mut: Mutation, cwd: str):
    outcome = run_tests(mut.cmd, cwd, mut.timeout)
    if outcome.timed_out:
        return "BASELINE_NOT_RUN", outcome, "timed out"
    ran, _, _ = judge_output(mut.runner, mut.ran_pattern, outcome.text)
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

    if refuse_on_stale_backups({mut.path for mut in muts}):
        return EXIT_RESTORE
    for cmd in sorted({mut.cmd for mut in muts}):
        if python_ignores_env(cmd):
            print("mutate: warning: this command starts Python with -E or -I, which ignores "
                  "PYTHONPYCACHEPREFIX and PYTHONDONTWRITEBYTECODE; a stale .pyc is still defeated when it checks "
                  "timestamps (the mutated file gets a different mtime), but a hash-based .pyc (unchecked-hash) "
                  "would still be read: %s" % cmd, file=sys.stderr)

    results: list[Result] = []
    originals: dict[str, str] = {}
    foreign_paths: set = set()
    try:
        preflight_writable(mut.path for mut in muts)
        # Stage 0: the unmutated tests must be green AND must have run (once per distinct command).
        bases: dict = {}
        for mut in muts:
            originals.setdefault(mut.path, sha256(read_bytes(mut.path)))
            key = baseline_key(mut)
            if key not in bases:
                verdict, outcome, why = run_baseline(mut, cwd)
                bases[key] = (verdict, why)
                show("%-16s exit=%-4s %s%s" % ("baseline-" + ("ok" if verdict == "OK" else verdict.lower()),
                                                "-" if outcome.rc is None else outcome.rc, mut.cmd,
                                                "  (unverified parser)" if mut.runner in UNVERIFIED_PARSERS else ""))
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
            if res.verdict in ("NOT_RUN", "RED_NONTEST") or args.verbose:
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
    except (WriteFailure, OSError) as exc:          # not a verdict and not a usage error: its own exit code
        label = "mutate: " + str(exc) if isinstance(exc, WriteFailure) else "mutate: unexpected I/O error: %s" % exc
        bad = unrestored(originals, foreign_paths)
        if bad:
            print(label + "\nmutate: AND these files do not match their pre-run bytes:\n  %s\n"
                  "  look for the backup under %s (mutate-backup-*) before trusting them"
                  % ("\n  ".join(bad), tempfile.gettempdir()), file=sys.stderr)
            return EXIT_RESTORE
        print(label, file=sys.stderr)
        return EXIT_IO

    bad = unrestored(originals, foreign_paths)
    if bad:
        print("mutate: RESTORE FAILED: differs from its pre-run bytes after all mutations:\n  %s"
              % "\n  ".join(bad), file=sys.stderr)
        return EXIT_RESTORE
    for path, digest in originals.items():
        if path in foreign_paths:
            try:
                now = sha256(read_bytes(path))
            except OSError as exc:
                now = "unreadable (%s)" % exc
            show("not comparable %s (edited by someone else during the run) sha256=%s" % (os.path.relpath(path, cwd), now))
        else:
            show("restored %s sha256=%s" % (os.path.relpath(path, cwd), digest))
    counts: dict = {}
    for r in results:
        counts[r.verdict] = counts.get(r.verdict, 0) + 1
    show("summary: " + " ".join("%s=%d" % kv for kv in sorted(counts.items())))
    return EXIT_OK if results and all(r.verdict == "RED" for r in results) else EXIT_NOT_PROVEN


if __name__ == "__main__":
    install_signal_handlers()
    sys.exit(main(sys.argv[1:]))
