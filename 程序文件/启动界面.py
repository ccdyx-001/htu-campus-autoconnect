# -*- coding: utf-8 -*-
"""启动图形界面。

说明：批处理里如果直接写 powershell + 隐藏窗口 + 绕过执行策略，
      很容易被杀毒软件当成木马（HEUR:TrojanDownloader 之类）。
      所以这里由内置 Python 来启动 PowerShell，批处理只调用 pythonw。
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PS1 = os.path.join(HERE, "界面.ps1")
CREATE_NO_WINDOW = 0x08000000


def main():
    if not os.path.exists(PS1):
        return 1
    subprocess.Popen(
        ["powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", PS1],
        creationflags=CREATE_NO_WINDOW,
        close_fds=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())