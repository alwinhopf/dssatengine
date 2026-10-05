"""Isolated model execution shared by DSSAT and APSIM Python adapters.

POSIX uses posix_spawn plus a fresh interpreter to avoid forking a process after
BLAS or macOS frameworks have created threads. The worker retains the cache lock
and its own session, so timeout cleanup includes descendants even when a model
closes inherited descriptors. Windows uses a Job.
"""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def execute(command, directory, timeout, env=None, lock_stream=None):
    log = Path(directory) / 'execution.log'
    with log.open('w', encoding='utf-8') as stream:
        if os.name == 'nt':
            from ._windows import execute_windows
            code = execute_windows(command, directory, timeout, stream, env)
        else:
            actions = [(os.POSIX_SPAWN_DUP2, stream.fileno(), 1),
                       (os.POSIX_SPAWN_DUP2, stream.fileno(), 2)]
            descriptor = None
            if lock_stream is not None:
                # Darwin may retain CLOEXEC for dup2(fd, fd). Use a distinct
                # descriptor so the fresh worker really inherits the lock.
                descriptor = os.dup(lock_stream.fileno())
                actions.append((os.POSIX_SPAWN_DUP2, lock_stream.fileno(), descriptor))
            worker = Path(__file__).with_name('_posix_worker.py')
            argv = [sys.executable, str(worker), str(Path(directory).resolve()),
                    str(descriptor if descriptor is not None else -1), *map(str, command)]
            try:
                pid = os.posix_spawn(sys.executable, argv, dict(os.environ) if env is None else env,
                                     file_actions=actions, setsid=True)
            finally:
                if descriptor is not None:
                    os.close(descriptor)
            deadline = time.monotonic() + timeout
            while True:
                finished, status = os.waitpid(pid, os.WNOHANG)
                if finished:
                    code = os.waitstatus_to_exitcode(status)
                    break
                if time.monotonic() >= deadline:
                    try: os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    os.waitpid(pid, 0)
                    raise TimeoutError(f'Model timeout after {timeout}s; see {log}')
                time.sleep(0.01)
    if code:
        raise RuntimeError(f'Model exited with status {code}; see {log}')
