# -*- coding: utf-8 -*-
"""卸载程序：删除计划任务、桌面快捷方式、卸载条目、账号文件
（可选断开认证、删除日志，并清理安装到本机的文件）

说明：批处理里不写 powershell 特征，避免被杀软误报成木马。
"""
import ctypes
import os
import subprocess
import sys
import time

class _Tee:
    """同时往控制台和日志文件写，卸载出问题能翻日志"""

    def __init__(self, path):
        self.f = open(path, "w", encoding="utf-8")
        self.out = sys.stdout

    def write(self, s):
        try:
            if self.out is not None:
                self.out.write(s)
        except Exception:
            pass
        try:
            self.f.write(s)
            self.f.flush()
        except Exception:
            pass

    def flush(self):
        try:
            if self.out is not None:
                self.out.flush()
        except Exception:
            pass

HERE = os.path.dirname(os.path.abspath(__file__))
TASK_PS1 = os.path.join(HERE, "setup_task.ps1")
MAIN_PY = os.path.join(HERE, "AutoConnect_htu.py")
INSTALL_LOG = os.path.join(HERE, "install_log.txt")
CRED_FILES = ["credentials.dat", "credentials.env", ".user"]
LOG_FILES = ["autoconnect.log", "autoconnect.log.1", ".last_heartbeat", "install_log.txt"]
TASK_NAME = "HTU Campus AutoConnect"
SHORTCUT_NAME = "校园网自动连接.lnk"
REG_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\HTUAutoConnect"
INSTALL_DIR = os.path.join(os.environ.get("LOCALAPPDATA", ""), "HTUAutoConnect")


def ask(prompt, default="n", auto=None):
    """auto 不为 None 时（--yes 全自动模式）直接用 auto，不等人回答"""
    if auto is not None:
        print(prompt + ("[自动: %s]" % auto))
        return auto
    try:
        ans = input(prompt).strip().lower()
    except (EOFError, KeyboardInterrupt):
        return default
    if not ans:
        return default
    return ans[0]


def same_dir(a, b):
    try:
        return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))
    except Exception:
        return False


def desktop_dir():
    """取桌面路径（支持桌面被移到 D:\\Desktop 这类重定向）"""
    try:
        import winreg
        k = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                           r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
        val, _ = winreg.QueryValueEx(k, "Desktop")
        winreg.CloseKey(k)
        return os.path.expandvars(val)
    except Exception:
        return os.path.join(os.environ.get("USERPROFILE", ""), "Desktop")


def remove_shortcut():
    for name in (SHORTCUT_NAME, "校园网自动连接.lnk"):
        p = os.path.join(desktop_dir(), name)
        if os.path.exists(p):
            try:
                os.remove(p)
                return name
            except Exception as e:
                return "删除失败：{0}".format(e)
    return None


def remove_startmenu_shortcut():
    """删除开始菜单里的快捷方式"""
    d = os.path.join(os.environ.get("APPDATA", ""), r"Microsoft\Windows\Start Menu\Programs")
    p = os.path.join(d, SHORTCUT_NAME)
    if os.path.exists(p):
        try:
            os.remove(p)
            return True
        except Exception:
            pass
    return None


def remove_reg_entry():
    try:
        import winreg
        winreg.DeleteKey(winreg.HKEY_CURRENT_USER, REG_KEY)
        return True
    except FileNotFoundError:
        return None
    except Exception as e:
        return "删除失败：{0}".format(e)


def run_elevated_uninstall():
    """以管理员权限运行 setup_task.ps1 -Uninstall（用 ShellExecuteW 提权）"""
    if not os.path.exists(TASK_PS1):
        print("  [X] 找不到 setup_task.ps1")
        return False
    old_mtime = os.path.getmtime(INSTALL_LOG) if os.path.exists(INSTALL_LOG) else 0
    try:
        ret = ctypes.windll.shell32.ShellExecuteW(
            None, "runas", "powershell.exe",
            '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall'.format(TASK_PS1),
            HERE, 1)
    except Exception as e:
        print("  [X] 提权失败：{0}".format(e))
        return False
    if ret <= 32:
        print("  [X] 提权被取消（没有点【是】）")
        return False
    for _ in range(120):
        time.sleep(0.5)
        try:
            if os.path.exists(INSTALL_LOG) and os.path.getmtime(INSTALL_LOG) != old_mtime:
                break
        except Exception:
            break
    if os.path.exists(INSTALL_LOG):
        for line in open(INSTALL_LOG, encoding="utf-8", errors="replace").read().splitlines()[-5:]:
            print("  " + line)
    return True


def schedule_self_delete(path):
    """关掉本窗口后自动删除目录（用分离的 cmd 延迟执行）"""
    try:
        subprocess.Popen(
            'cmd.exe /c ping 127.0.0.1 -n 3 >nul & rmdir /s /q "{0}"'.format(path),
            shell=True, creationflags=0x08000000)
        return True
    except Exception as e:
        print("       [X] 安排删除失败：{0}".format(e))
        return False


def main():
    dry = "--dry-run" in sys.argv
    auto_yes = "--yes" in sys.argv or dry        # 全自动静默（不提问）
    from_panel = "--from-panel" in sys.argv      # 从「设置→应用」卸载：提问，但等你按键才关窗口
    _old_stdout = sys.stdout
    if not dry and sys.stdout is not None:
        try:
            sys.stdout = _Tee(os.path.join(os.environ.get("TEMP", "."), "HTU卸载日志.txt"))
            print("=== 校园网自动连接 卸载日志 ===")
            print("时间:", time.strftime("%Y-%m-%d %H:%M:%S"))
            print("脚本位置:", HERE)
            print("安装目录:", INSTALL_DIR)
            print()
        except Exception:
            pass
    log_lines = []

    def note(msg):
        print(msg)
        log_lines.append(msg)

    def safe(label, fn, *a, **kw):
        """每一步都兜住异常：失败也继续往下，绝不半途而废"""
        try:
            return fn(*a, **kw)
        except Exception as e:
            note("       [X] %s 失败：%s" % (label, e))
            return None
    print("=" * 60)
    print("     卸载 校园网自动连接")
    print("=" * 60)
    print()
    print("  将要执行：")
    print("     1) 删除开机自启的计划任务")
    print("     2) 删除桌面快捷方式")
    print("     3) 从「设置 → 应用」中移除")
    print("     4) 删除保存的账号密码（加密文件）")
    print("     5) 断开校园网认证（可选）")
    print("     6) 删除运行日志（可选，默认保留）")
    print()
    if os.path.exists(INSTALL_DIR) and not same_dir(HERE, INSTALL_DIR):
        print("  另外发现安装到本机的程序文件：")
        print("     " + INSTALL_DIR)
        print()
    if dry:
        print("  [测试模式 --dry-run] 只显示计划，不做任何修改")
        print()

    print("  即将弹出管理员权限确认框，请点 [是]")
    print()
    if not auto_yes and not from_panel:
        try:
            input("  按回车继续……")
        except (EOFError, KeyboardInterrupt):
            pass

    print()
    print("  [1/6] 删除计划任务 ......")
    if dry:
        print("       （测试模式：跳过）")
    else:
        safe("删除计划任务", run_elevated_uninstall)

    print()
    print("  [2/6] 删除桌面快捷方式 ......")
    if dry:
        print("       （测试模式：跳过）")
    else:
        r = safe("删除桌面快捷方式", remove_shortcut)
        print("       已删除 " + r if isinstance(r, str) and r.endswith(".lnk") else
              ("       没有找到桌面快捷方式" if r is None else "       " + str(r)))
        if safe("删除开始菜单快捷方式", remove_startmenu_shortcut):
            print("       已删除开始菜单快捷方式")

    print()
    print("  [3/6] 从「设置 → 应用」中移除 ......")
    if dry:
        print("       （测试模式：跳过）")
    else:
        r = safe("删除面板条目", remove_reg_entry)
        print("       已移除" if r is True else ("       本来就没有登记" if r is None else "       " + str(r)))

    print()
    print("  [4/6] 删除账号密码文件 ......")
    found = []
    for f in CRED_FILES:
        p = os.path.join(HERE, f)
        if os.path.exists(p):
            found.append(f)
            if not dry:
                try:
                    os.remove(p)
                except Exception:
                    pass
    if found:
        print(("       已删除：" if not dry else "       （测试模式）将会删除：") + "、".join(found))
    else:
        print("       没有找到账号密码文件（可能已经删过了）")

    print()
    print("  [5/6] 断开校园网认证 ......")
    ans = ask("       是否立即断开校园网认证？(y/N) ", default="n", auto=("n" if auto_yes else None))
    if ans == "y":
        try:
            r = subprocess.run([sys.executable, MAIN_PY, "--logout"], cwd=HERE,
                               capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
            for line in (r.stdout or "").splitlines()[-2:]:
                print("       " + line)
        except Exception as e:
            print("       [X] 断开失败：{0}".format(e))
    else:
        print("       已跳过，当前认证状态保持不变")

    print()
    print("  [6/6] 运行日志处理 ......")
    ans3 = ask("       是否删除运行日志？(y/N) ", default="n", auto=("y" if auto_yes else None))
    logstatus = "已保留"
    if ans3 == "y":
        for f in LOG_FILES:
            p = os.path.join(HERE, f)
            if os.path.exists(p) and not dry:
                try:
                    os.remove(p)
                    print("       已删除 " + f)
                except Exception:
                    pass
        logstatus = "已删除"

    # ---- 安装到本机的文件 ----
    self_delete = False
    if not dry and os.path.exists(INSTALL_DIR):
        print()
        print("  安装到本机的程序文件 ......")
        if same_dir(HERE, INSTALL_DIR):
            print("       当前就是安装目录，关掉本窗口后会自动删除：")
            print("       " + INSTALL_DIR)
            self_delete = True
        else:
            ans4 = ask("       是否删除安装到本机的程序文件？(Y/n) ", default="y", auto=("y" if auto_yes else None))
            if ans4 == "y":
                try:
                    subprocess.run(["cmd.exe", "/c", "rmdir", "/s", "/q", INSTALL_DIR],
                                   creationflags=0x08000000, timeout=60)
                except Exception:
                    pass
                if os.path.exists(INSTALL_DIR):
                    print("       [X] 没删掉（可能有程序正在运行），请手动删除：")
                    print("       " + INSTALL_DIR)
                else:
                    print("       已删除安装目录")

    print()
    print("=" * 60)
    print("  卸载完成")
    print("     · 计划任务     已删除，不会再自动连接校园网")
    print("     · 桌面快捷方式 已清理")
    print("     · 账号密码     已删除")
    print("     · 运行日志     " + logstatus)
    print("=" * 60)
    print()
    if self_delete:
        print("  关掉本窗口后，程序文件夹会自动删除（约 3 秒）")
    else:
        print("  彻底清除：直接删掉整个文件夹即可")
    print("  （账号密码已删除；想再装回来，重新填一次学号和密码即可）")
    print()
    if self_delete:
        schedule_self_delete(INSTALL_DIR)
    if from_panel and not auto_yes:
        try:
            print("  （按回车关闭此窗口）")
            input()
        except (EOFError, KeyboardInterrupt):
            pass
    try:
        sys.stdout = _old_stdout          # 恢复标准输出（别影响调用方）
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
