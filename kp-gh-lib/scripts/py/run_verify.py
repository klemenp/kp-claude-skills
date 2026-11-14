import errno
import math
import os
import re
import signal
import subprocess
import sys
import time

USAGE = ("usage: run-verify.sh --log <path> [--tail <n>] [--timeout-sec <s>]"
         " -- <command> [args…]")
DEFAULT_TAIL = 80
DEFAULT_TIMEOUT_SEC = 540
# One foreground Bash call is capped at 10 minutes; 540 s leaves room for the
# TERM→KILL grace and the script's own start-up.
MAX_TIMEOUT_SEC = 540
KILL_GRACE_SEC = 5
EXIT_TIMEOUT = 124
EXIT_NOT_EXECUTABLE = 126
EXIT_NOT_FOUND = 127
EXIT_LOG_FAILURE = 1
EXIT_USAGE = 2
INTEGER = re.compile(r"[0-9]+")


class UsageError(Exception):
    pass


def parse_int(option, value, low, high=None):
    if not INTEGER.fullmatch(value):
        raise UsageError(f"{option} needs an integer, got '{value}'")
    number = int(value)
    if number < low or (high is not None and number > high):
        bound = f"{low}–{high}" if high is not None else f"≥ {low}"
        raise UsageError(f"{option} must be {bound}, got {number}")
    return number


def parse_args(argv):
    if "--" not in argv:
        raise UsageError("missing the -- separator before the command")
    separator = argv.index("--")
    options, command = argv[:separator], argv[separator + 1:]
    log_path, tail, timeout_sec = None, DEFAULT_TAIL, DEFAULT_TIMEOUT_SEC
    index = 0
    while index < len(options):
        option = options[index]
        if option not in ("--log", "--tail", "--timeout-sec"):
            raise UsageError(f"unknown argument '{option}'")
        if index + 1 >= len(options):
            raise UsageError(f"{option} needs a value")
        value = options[index + 1]
        if option == "--log":
            if not value:
                raise UsageError("--log needs a non-empty path")
            log_path = value
        elif option == "--tail":
            tail = parse_int(option, value, 1)
        else:
            timeout_sec = parse_int(option, value, 1, MAX_TIMEOUT_SEC)
        index += 2
    if log_path is None:
        raise UsageError("--log is required")
    if not command:
        raise UsageError("no command after --")
    return log_path, tail, timeout_sec, command


def kill_group(process):
    """TERM the command's process group, then KILL whatever is left after the grace."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=KILL_GRACE_SEC)
    except subprocess.TimeoutExpired:
        pass
    # The leader may have exited on TERM while a child that ignores TERM lives on.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(command, log_file, timeout_sec):
    """Return (result, exit code) for one run of the command."""
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log_file,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as error:
        code = EXIT_NOT_FOUND if error.errno == errno.ENOENT else EXIT_NOT_EXECUTABLE
        return "fail", code
    try:
        returncode = process.wait(timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        kill_group(process)
        return "timeout", EXIT_TIMEOUT
    if returncode < 0:
        return "fail", 128 - returncode
    return ("pass" if returncode == 0 else "fail"), returncode


def main(argv):
    try:
        log_path, tail, timeout_sec, command = parse_args(argv)
    except UsageError as error:
        print(f"run-verify.sh: {error}\n{USAGE}", file=sys.stderr)
        return EXIT_USAGE

    try:
        parent = os.path.dirname(log_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        log_file = open(log_path, "wb")
    except OSError as error:
        print(f"run-verify.sh: cannot create log '{log_path}': {error}", file=sys.stderr)
        return EXIT_LOG_FAILURE

    started = time.monotonic()
    with log_file:
        result, code = run(command, log_file, timeout_sec)
    seconds = math.floor(time.monotonic() - started)

    with open(log_path, "rb") as handle:
        text = handle.read().decode("utf-8", "surrogateescape")
    lines = text.splitlines(keepends=True)

    out = sys.stdout.buffer
    out.write((f"result={result} exit={code} seconds={seconds} lines={len(lines)}"
               f" log={log_path}\n").encode("utf-8", "surrogateescape"))
    if result != "pass":
        shown = lines[len(lines) - min(tail, len(lines)):]
        out.write(f"--- last {len(shown)} of {len(lines)} lines ---\n".encode())
        body = "".join(shown)
        if body and not body.endswith("\n"):
            body += "\n"
        out.write(body.encode("utf-8", "surrogateescape"))
    out.flush()
    return 0


sys.exit(main(sys.argv[1:]))
