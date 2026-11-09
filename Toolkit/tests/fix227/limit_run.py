"""Runs a command with a per-process file-size limit (Linux): a write past the limit fails (EFBIG) instead of killing the process.
   Usage: limit_run.py <bytes> <command...>. Used by the 2.2.7 tests to stop a file write half-way."""
import os, resource, signal, sys
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
n = int(sys.argv[1])
resource.setrlimit(resource.RLIMIT_FSIZE, (n, n))
os.execvp(sys.argv[2], sys.argv[2:])
