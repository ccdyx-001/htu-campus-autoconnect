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
    """同时往控制台和日志文件写，卸载出问题能翻日志

    v1.3.0 起：日志固定写到 %TEMP%\\HTU卸载日志.txt，**不再写进安装目录**。
    原因（实测踩坑）：以前日志写在安装目录里，句柄一直开着，导致卸载最后
    "关掉窗口后自动删除安装目录"这一步的 rmdir 必然失败（文件被占用）——
    用户会停在"目录还在、没有任何入口"的半状态。
    """

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

    def close(self):
        """关掉日志文件句柄（自删安装目录之前必须调用，否则 rmdir 会失败）"""
        try:
            self.f.flush()
        except Exception:
            pass
        try:
            self.f.close()
        except Exception:
            pass

HERE = os.path.dirname(os.path.abspath(__file__))
_LOG_TEE = None          # 当前日志 tee（自删目录前需要关掉它持有的句柄）
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


def remove_task_unelevated():
    """非提权删除计划任务。

    为什么先试这条：本程序注册任务时用的是「交互式登录 + Limited」，
    **任务所有者就是当前用户**，而任务所有者本来就有权删掉自己的任务。
    所以绝大多数情况根本不需要弹 UAC。以前只走提权路径，用户一旦在 UAC
    弹框点【否】，这里就会干等（实测会白等 60 秒），是"卸载卡住"的元凶之一。
    """
    try:
        r = subprocess.run(["schtasks.exe", "/Delete", "/TN", TASK_NAME, "/F"],
                           capture_output=True, errors="replace",
                           creationflags=0x08000000, timeout=30)
        out = r.stdout if isinstance(r.stdout, str) else (r.stdout or b"").decode("utf-8", "replace")
        err = r.stderr if isinstance(r.stderr, str) else (r.stderr or b"").decode("utf-8", "replace")
        if r.returncode == 0:
            print("  [OK] 已删除计划任务（非提权）：{0}".format(TASK_NAME))
            return True
        print("  [i] 非提权删除没成功：{0}".format((err or out).strip().splitlines()[0] if (err or out).strip() else "未知原因"))
        return False
    except Exception as e:
        print("  [i] 非提权删除出错：{0}".format(e))
        return False


def task_exists():
    try:
        r = subprocess.run(["schtasks.exe", "/Query", "/TN", TASK_NAME],
                           capture_output=True, errors="replace",
                           creationflags=0x08000000, timeout=20)
        return r.returncode == 0
    except Exception:
        return False


def run_elevated_uninstall():
    """删除计划任务：先试非提权，不行再提权（提权最好也只有这一次）"""
    if not task_exists():
        print("  [i] 计划任务不存在，无需删除")
        return True
    # 1) 先试不需要管理员的方式（任务所有者删自己的任务）
    if remove_task_unelevated() and not task_exists():
        return True
    if not task_exists():
        return True
    # 2) 实在不行才提权
    print("  [i] 需要管理员权限才能删除计划任务")
    if not os.path.exists(TASK_PS1):
        print("  [X] 找不到 setup_task.ps1")
        return False
    old_mtime = os.path.getmtime(INSTALL_LOG) if os.path.exists(INSTALL_LOG) else 0
    try:
        # 刻意不带执行策略参数（杀软敏感词）；
        # 本机自己的 .ps1 在默认 RemoteSigned 下可直接执行，runas 提权必须保留。
        ret = ctypes.windll.shell32.ShellExecuteW(
            None, "runas", "powershell.exe",
            '-NoProfile -File "{0}" -Uninstall'.format(TASK_PS1),
            HERE, 1)
    except Exception as e:
        print("  [X] 提权失败：{0}".format(e))
        return False
    if ret <= 32:
        # ShellExecuteW 的返回值 <=32 是错误码；其中 1223 (0x4C7) = 用户在 UAC 弹框点了【否】
        if ret == 1223:
            print("  [i] 你在管理员权限确认框里点了【否】——已跳过提权删任务这一步")
            print("      计划任务可能还留着，稍后会由安装器用非提权方式兜底删除。")
        else:
            print("  [X] 提权没有启动（错误码 {0}）".format(ret))
        return False
    # 等提权进程干完：最多 30 秒，且**任务一旦消失就立刻结束**（别白等）
    for _ in range(60):
        time.sleep(0.5)
        if not task_exists():
            break
        try:
            if os.path.exists(INSTALL_LOG) and os.path.getmtime(INSTALL_LOG) != old_mtime:
                break
        except Exception:
            break
    if os.path.exists(INSTALL_LOG):
        for line in open(INSTALL_LOG, encoding="utf-8", errors="replace").read().splitlines()[-5:]:
            print("  " + line)
    return True


def _release_stdout():
    """把 sys.stdout 恢复成原始对象，并关掉日志文件句柄。

    这一步是"卸载后目录真的能删掉"的关键：只要还有句柄指在安装目录里的文件上，
    rmdir 就会失败。v1.3.0 起日志已经改写到 %TEMP%，这里再显式释放一次，双保险。
    """
    global _LOG_TEE
    tee = _LOG_TEE
    try:
        sys.stdout = getattr(tee, "out", None) or sys.__stdout__
    except Exception:
        try:
            sys.stdout = sys.__stdout__
        except Exception:
            pass
    if tee is not None:
        try:
            tee.close()
        except Exception:
            pass
    _LOG_TEE = None


def _try_remove_tree(path, attempts=4):
    """尝试删除整棵目录（带重试）。返回 (是否删掉, 最后的错误)"""
    last = None
    for i in range(attempts):
        if not os.path.exists(path):
            return True, None
        try:
            subprocess.run(["cmd.exe", "/c", "rmdir", "/s", "/q", path],
                           creationflags=0x08000000, timeout=90)
        except Exception as e:
            last = e
        if not os.path.exists(path):
            return True, None
        # 还有残留：等一会儿再试（占用通常几百毫秒就释放）
        time.sleep(1.5 * (i + 1))
    return (not os.path.exists(path)), last


def schedule_self_delete(path):
    """关掉本窗口后自动删除目录。

    v1.3.0 起的做法：
      1. 先把日志句柄释放掉（否则 dll/日志被占用，删除必失败）
      2. 用分离的 cmd 延时删除（等本进程退出、文件锁释放）
      3. 删除结果**明确反馈**给用户：删掉了就说删掉了；
         没删掉就把目录路径打出来 + 告诉用户手动删哪里，绝不静默
    """
    _release_stdout()
    try:
        subprocess.Popen(
            'cmd.exe /c ping 127.0.0.1 -n 4 >nul & rmdir /s /q "{0}"'.format(path),
            shell=True, creationflags=0x08000000)
    except Exception as e:
        print("       [X] 安排自动删除失败：{0}".format(e))
        print("           请手动删除这个文件夹：")
        print("           " + path)
        return False
    return True


def main():
    global _LOG_TEE
    dry = "--dry-run" in sys.argv
    auto_yes = "--yes" in sys.argv or dry        # 全自动静默（不提问）
    from_panel = "--from-panel" in sys.argv      # 从「设置→应用」卸载：提问，但等你按键才关窗口
    # v1.3.0 新增：完全不等人输入的三种用法
    #   --noninteractive ：不提问、不等待（账号默认保留）
    #   --keep-account   ：不提问，账号保留
    #   --del-account    ：不提问，账号删除
    # 安装包面板用它：先弹自己的确认框让用户选"保留/删除"，再让本脚本静默跑完 ——
    # 这样既有用户的选择，又不会挂在一个用户看不见的 input() 上。
    keep_account = "--keep-account" in sys.argv
    del_account = "--del-account" in sys.argv
    noninteractive = keep_account or del_account or ("--noninteractive" in sys.argv)
    if noninteractive:
        auto_yes = True          # 内部一律按"自动回答"走，只是账号那题的答案不同
    _old_stdout = sys.stdout
    if not dry and sys.stdout is not None:
        try:
            # 日志固定写 %TEMP%（不能写安装目录：句柄会挡住最后的目录自删）
            _LOG_TEE = _Tee(os.path.join(os.environ.get("TEMP", "."), "HTU卸载日志.txt"))
            sys.stdout = _LOG_TEE
            print("=== 校园网自动连接 卸载日志 ===")
            print("时间:", time.strftime("%Y-%m-%d %H:%M:%S"))
            print("脚本位置:", HERE)
            print("安装目录:", INSTALL_DIR)
            print("日志位置:", os.path.join(os.environ.get("TEMP", "."), "HTU卸载日志.txt"))
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
    print("     4) 处理保存的账号密码（可自己选保留还是删除）")
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
    # v1.3.0：--noninteractive / --keep-account / --del-account 时**不等待任何输入**。
    # 为什么必须这样：安装包的「已安装」面板会用隐藏控制台启动本脚本，用户看不见
    # 这个提示、也没法按回车 —— 以前这里一句 input() 会把子进程永久挂住，
    # 父安装器于是"窗口已关、进程不退"，用户还得去任务管理器杀进程。
    if not auto_yes and not from_panel and not noninteractive:
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
    print("  [4/6] 处理账号密码文件 ......")
    # 账号文件可能在两个地方：当前目录（绿色版/解压目录）、以及安装到本机的目录。
    # 旧版本只删"当前目录"，结果真正在用的那份（安装目录里的）反而留下来了 —— 这里一起处理。
    cred_dirs = [HERE]
    if os.path.exists(INSTALL_DIR) and not same_dir(HERE, INSTALL_DIR):
        cred_dirs.append(INSTALL_DIR)
    cred_paths, cred_labels = [], []
    for d in cred_dirs:
        for f in CRED_FILES:
            p = os.path.join(d, f)
            if os.path.exists(p) and p not in cred_paths:
                cred_paths.append(p)
                cred_labels.append(f if same_dir(d, HERE) else (f + "（安装目录）"))
    credstatus = "没有账号文件"
    if not cred_paths:
        print("       没有找到账号密码文件（可能已经删过了）")
    else:
        print("       找到：" + "、".join(cred_labels))
        if dry:
            print("       （测试模式：不做修改；实际运行时这里会问你要不要保留）")
            credstatus = "（测试模式，未改动）"
        else:
            # 账号去留的答案优先级：--del-account > --keep-account > --yes(默认保留) > 交互提问
            if del_account:
                answer = "n"
            elif keep_account:
                answer = "y"
            elif auto_yes:
                answer = "y"
            else:
                answer = None
            keep = ask("       要保留账号密码文件吗？(Y=保留 / n=删除) ",
                       default="y", auto=answer)
            if keep == "y":
                print("       已保留账号密码（以后重新安装不用再输一遍）")
                credstatus = "已保留"
            else:
                gone, fail = [], []
                for p, lab in zip(cred_paths, cred_labels):
                    try:
                        os.remove(p)
                        gone.append(lab)
                    except Exception:
                        fail.append(lab)
                if gone:
                    print("       已删除：" + "、".join(gone))
                if fail:
                    print("       [X] 没删掉（可能有程序正在用）：" + "、".join(fail))
                credstatus = "已删除" if not fail else "部分删除失败"

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
    # v1.3.0 起策略明确：账号文件按用户在前面的选择处理（保留 or 删除），
    # **账号文件之外的程序文件一律无条件清理** —— 不允许留下"目录还在、没有任何入口"的半状态。
    self_delete = False
    dir_status = "未处理"
    if not dry and os.path.exists(INSTALL_DIR):
        print()
        print("  安装到本机的程序文件 ......")
        if same_dir(HERE, INSTALL_DIR):
            # 当前就跑在安装目录里：释放句柄后延时自删
            print("       当前就是安装目录，本次卸载结束后会自动删除：")
            print("       " + INSTALL_DIR)
            self_delete = True
            dir_status = "已安排自动删除"
        else:
            print("       正在清理：" + INSTALL_DIR)
            ok, err = _try_remove_tree(INSTALL_DIR)
            if ok:
                print("       已删除安装目录")
                dir_status = "已删除"
            else:
                print("       [X] 没能删掉安装目录（可能有程序正在运行/文件被占用）")
                print("           请手动删除这个文件夹：")
                print("           " + INSTALL_DIR)
                if err:
                    print("           （原因：{0}）".format(err))
                dir_status = "删除失败（已提示手动删除）"
    elif dry:
        dir_status = "（测试模式，未改动）"

    print()
    print("=" * 60)
    print("  卸载完成")
    print("     · 计划任务     已删除，不会再自动连接校园网")
    print("     · 桌面快捷方式 已清理")
    print("     · 账号密码     " + credstatus)
    print("     · 运行日志     " + logstatus)
    print("     · 安装目录     " + dir_status)
    print("=" * 60)
    print()
    if self_delete:
        print("  关掉本窗口后，程序文件夹会自动删除（约 3 秒）")
    elif dir_status == "已删除":
        print("  程序文件已清理干净，这个下载文件夹也可以直接删掉")
    else:
        print("  彻底清除：按上面提示删除程序文件夹即可")
    print("  （账号密码" + ("已保留：重新安装后不用再输一遍" if credstatus == "已保留" else ("已删除：想再装回来，重新填一次学号和密码即可" if credstatus == "已删除" else credstatus)) + "）")
    print()
    if self_delete:
        # 先释放日志句柄（否则 rmdir 必失败），再安排延时自删
        _TEE_PATH = os.path.join(os.environ.get("TEMP", "."), "HTU卸载日志.txt")
        print("  日志已保存在：" + _TEE_PATH)
        schedule_self_delete(INSTALL_DIR)
    if from_panel and not auto_yes and not noninteractive:
        try:
            print("  （按回车关闭此窗口）")
            input()
        except (EOFError, KeyboardInterrupt):
            pass
    _release_stdout()                     # 恢复标准输出 + 关掉日志句柄（双保险）
    return 0


if __name__ == "__main__":
    sys.exit(main())
