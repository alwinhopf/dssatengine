"""POSIX launcher lifetime independent of any cropmodel front end."""
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest


@pytest.mark.skipif(os.name == 'nt', reason='POSIX lock transfer')
def test_launcher_keeps_lock_after_scheduler_death_and_model_fd_cleanup(tmp_path):
    import fcntl
    model = tmp_path/'model.py'
    model.write_text("import os,time\nfrom pathlib import Path\nos.closerange(3,256)\nPath('ready').touch()\ntime.sleep(1)\nPath('finished').touch()\n")
    lock = tmp_path/'lock'
    code = ('import fcntl,sys; from dssatengine.process import execute\n'
            'with open(sys.argv[1],"a+b") as stream:\n'
            ' fcntl.flock(stream.fileno(),fcntl.LOCK_EX)\n'
            ' execute([sys.executable,sys.argv[2]],sys.argv[3],15,lock_stream=stream)\n')
    scheduler = subprocess.Popen([sys.executable,'-c',code,str(lock),str(model),str(tmp_path)])
    try:
        deadline = time.monotonic()+5
        while not (tmp_path/'ready').exists() and scheduler.poll() is None and time.monotonic()<deadline:
            time.sleep(.02)
        assert (tmp_path/'ready').exists()
        scheduler.kill();scheduler.wait(timeout=5)
        with lock.open('a+b') as stream:
            with pytest.raises(BlockingIOError):
                fcntl.flock(stream.fileno(),fcntl.LOCK_EX | fcntl.LOCK_NB)
            deadline = time.monotonic()+5
            while True:
                try:
                    fcntl.flock(stream.fileno(),fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    assert time.monotonic()<deadline
                    time.sleep(.02)
            assert (tmp_path/'finished').exists()
    finally:
        if scheduler.poll() is None:scheduler.kill()
        scheduler.wait()
