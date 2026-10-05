"""Gated Windows launcher. EOF before authorization must never start a model.

Invoked as a script to avoid importing the runtime or heavy dependencies before
reading the parent's pipe. The parent assigns this process to its Windows Job
Object before sending the command. All descendants inherit that job.
"""
import json
import subprocess
import sys


def main():
    request = sys.stdin.readline()
    if not request:
        return 0
    command = json.loads(request)['command']
    return subprocess.call(command)


if __name__ == '__main__':
    sys.exit(main())
