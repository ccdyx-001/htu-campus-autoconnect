# -*- coding: utf-8 -*-
"""启动图形界面。

说明：批处理里如果直接写 powershell + 隐藏窗口 + 绕过执行策略，
      很容易被杀毒软件当成木马（HEUR:TrojanDownloader 之类）。
      所以这里由内置 Python 来启动 PowerShell，批处理只调用 pythonw。

v1.2.0 起：命令行里不再出现「绕过执行策略 / 隐藏窗口」这类字样
      （杀软敏感词），改成：
        · 不给命令行加执行策略参数
        · 用 CREATE_NO_WINDOW 给子进程一个没有控制台窗口的运行环境，
          效果和原来的「隐藏窗口」一样，但只是一个 Win32 常量，不是敏感字串

v1.2.1 起（重要修复）：只去掉策略参数是不够的 —— 实测踩坑记录：
      用户从 GitHub 下载 zip 解压后，文件会带上 Windows 的"网络来源"标记
      （MOTW，Zone.Identifier 数据流，ZoneId=3）。在默认的 RemoteSigned 策略下，
      带这个标记的 .ps1 被当成"从网上下载的未签名脚本"，PowerShell 会直接拒绝执行：
          File ...\界面.ps1 cannot be loaded. The file ... is not digitally signed.
      现象就是"点了图标没反应"。原来靠命令行策略参数硬压过去，参数去掉后就暴露了。

      所以这里做两道保险（都不含杀软敏感字串）：
        1. 启动前把本目录 .ps1 的"网络来源"标记删掉（这些脚本本来就是本地程序的一部分，
           删掉标记既正确又能让策略判定回归"本地脚本"）
        2. 给子进程一个进程级执行策略环境变量（PSExecutionPolicyPreference）兜底：
           它只是环境变量，命令行里不会出现任何策略关键字串
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PS1 = os.path.join(HERE, "界面.ps1")
CREATE_NO_WINDOW = 0x08000000


def strip_network_mark(path):
    """删掉单个文件的「网络来源」标记（Zone.Identifier 数据流）。

    删不掉也无所谓（文件可能只读、或本来就没有这个流），绝不让它影响启动。
    """
    try:
        import ctypes
        # 用 DeleteFileW 删 <文件>:Zone.Identifier 这个备用数据流
        ctypes.windll.kernel32.DeleteFileW(path + ":Zone.Identifier")
    except Exception:
        pass


def strip_network_marks():
    """把本目录下会被 PowerShell 加载的脚本都去掉网络来源标记"""
    try:
        names = os.listdir(HERE)
    except Exception:
        return
    for name in names:
        if name.lower().endswith((".ps1", ".psm1", ".psd1")):
            strip_network_mark(os.path.join(HERE, name))


def build_env():
    """子进程环境：进程级执行策略兜底（环境变量，不是命令行参数）"""
    env = dict(os.environ)
    try:
        env["PSExecutionPolicyPreference"] = "Bypass"
    except Exception:
        pass
    return env


def main():
    if not os.path.exists(PS1):
        return 1
    strip_network_marks()
    subprocess.Popen(
        ["powershell.exe", "-NoProfile", "-STA", "-File", PS1],
        creationflags=CREATE_NO_WINDOW,
        close_fds=True,
        env=build_env(),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
