"""Fresh interpreter used by posix_spawn; never imports scientific libraries."""
import os
import subprocess
import sys

if __name__ == '__main__':
    directory, descriptor, *command = sys.argv[1:]
    os.chdir(directory)
    descriptor = int(descriptor)
    if descriptor < 0:
        os.execvpe(command[0], command, os.environ)
    # Keep a launcher alive until the model exits. Some programs close inherited
    # descriptors; their surviving launcher still protects the cache on a crash.
    process = subprocess.Popen(command, pass_fds=(descriptor,))
    code = process.wait()
    if code < 0:
        os.kill(os.getpid(), -code)
    sys.exit(code)
