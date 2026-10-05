"""Windows process-tree ownership using a kill-on-close Job Object.

The helper waits on a pipe until assigned to the job, eliminating the interval
in which an unowned model could be started. If the scheduler dies before that
assignment, EOF stops the helper. Afterwards the OS kills the owned tree.
See https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
"""
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import subprocess
import sys


class _IOCounters(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in
                ('read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]


class _BasicLimits(ctypes.Structure):
    _fields_ = [('process_time', ctypes.c_longlong), ('job_time', ctypes.c_longlong),
                ('flags', wintypes.DWORD), ('minimum_working_set', ctypes.c_size_t),
                ('maximum_working_set', ctypes.c_size_t), ('active_processes', wintypes.DWORD),
                ('affinity', ctypes.c_size_t), ('priority', wintypes.DWORD),
                ('scheduling', wintypes.DWORD)]


class _ExtendedLimits(ctypes.Structure):
    _fields_ = [('basic', _BasicLimits), ('io', _IOCounters),
                ('process_memory', ctypes.c_size_t), ('job_memory', ctypes.c_size_t),
                ('peak_process_memory', ctypes.c_size_t), ('peak_job_memory', ctypes.c_size_t)]


class WindowsJob:
    def __init__(self):
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        signatures = {
            'CreateJobObjectW': ([ctypes.c_void_p, wintypes.LPCWSTR], wintypes.HANDLE),
            'SetInformationJobObject': ([wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD], wintypes.BOOL),
            'AssignProcessToJobObject': ([wintypes.HANDLE, wintypes.HANDLE], wintypes.BOOL),
            'CloseHandle': ([wintypes.HANDLE], wintypes.BOOL),
        }
        for name, (args, result) in signatures.items():
            fn = getattr(self.kernel, name)
            fn.argtypes, fn.restype = args, result
        # No inheritable security attributes: the scheduler owns the only job handle.
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = _ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def assign(self, process):
        # Popen retains its Windows process handle until it has been reaped.
        if not self.kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def execute_windows(command, directory, timeout, stream, env=None):
    job = WindowsJob()
    process = None
    try:
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name('_windows_worker.py'))],
            stdin=subprocess.PIPE, stdout=stream, stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', cwd=directory, env=env)
        job.assign(process)
        process.stdin.write(json.dumps({'command': command}) + '\n')
        process.stdin.close()
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            job.close()
            process.wait(timeout=10)
            raise TimeoutError(f'Model timeout after {timeout}s; see {Path(directory) / "execution.log"}')
    finally:
        job.close()
        if process is not None:
            if not process.stdin.closed:
                try:
                    process.stdin.close()
                except OSError:
                    pass  # The helper may have exited before accepting a command.
            if process.poll() is None:
                # Also cleans up a helper whose job assignment failed before authorization.
                process.kill()
            process.wait()
