#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
============================================================
 河南师范大学  校园网自动连接工具
 作者：梅川逸夫
============================================================
 功能：
   · 开机自动认证，断网自动重连（配合计划任务，每分钟检查一次）
   · 完全后台运行，无窗口、无弹窗打扰
   · 兼容代理软件（Clash / Watt Toolkit 等）：校园网请求强制直连
   · 纯 Python 标准库实现，无需 pip 安装任何第三方库

 使用方法（普通用户看这里）：
   双击上一层的【点我启动.bat】，在窗口里填学号和密码，
   点【保存并安装】即可（程序会自动安装到本机并注册开机自启）。

 命令行用法（进阶）：
   python AutoConnect_htu.py --setup            交互式配置账号密码
   python AutoConnect_htu.py                    检测网络，未联网才认证
   python AutoConnect_htu.py --force            强制认证一次（测试用）
   python AutoConnect_htu.py --logout           主动下线
   python AutoConnect_htu.py --status           只报告当前是否已联网
   python AutoConnect_htu.py --save-cred        保存账号（图形界面调用，账号通过环境变量传入）
   python AutoConnect_htu.py --check-cred       检查账号文件状态（加密 / 明文 / 解不开）
   python AutoConnect_htu.py --seal             把旧版明文账号文件升级成加密文件
   python AutoConnect_htu.py 学号 密码           直接指定账号密码

 账号密码保存在同目录的 credentials.dat：
   · v1.1.0 起用 Windows DPAPI 加密保存，密钥由 Windows 掌管，
     绑定"这台电脑 + 当前 Windows 用户"；复制到别的电脑、别的用户，或被改动过，都解不开
   · 从 v1.0.0 升级：第一次运行时自动把旧的明文 credentials.env
     加密成 credentials.dat，并删掉明文文件（升级失败会保留明文，保证能用）
   · 无论哪种方式，账号都只存在本机，不会上传到任何服务器
============================================================
"""
import base64
import ctypes
import datetime
import email.utils
import json
import os
import socket
import sys
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request


# ---- 河师大默认认证服务器（未认证时脚本会自动探测真实地址）----
DEFAULT_PORTAL = "http://10.101.2.194:6060"
DEFAULT_AC_NAME = "HSD-BRAS-2"
DEFAULT_PAGE_ID = "82"
DEFAULT_SUFFIX = "@htu"                    # 学生账号后缀；教职工为 @htu.edu.cn
ONLINE_CHECK_URL = "http://connect.rom.miui.com/generate_204"
PORTAL_PROBES = [
    "http://www.msftconnecttest.com/redirect",
    "http://1.1.1.1",
    "http://connect.rom.miui.com/generate_204",
]

# ---- 版本号（改程序时记得同步更新 CHANGELOG.md）----
VERSION = "1.1.1"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CRED_FILE = os.path.join(SCRIPT_DIR, "credentials.env")        # v1.0.0 的明文文件（现在只用于自动升级）
CRED_FILE_DAT = os.path.join(SCRIPT_DIR, "credentials.dat")    # v1.1.0 起的加密文件（Windows DPAPI）
USER_FILE = os.path.join(SCRIPT_DIR, ".user")                  # 只存学号，供界面显示（不含密码）
LOG_FILE = os.path.join(SCRIPT_DIR, "autoconnect.log")
HEARTBEAT_FILE = os.path.join(SCRIPT_DIR, ".last_heartbeat")
HEARTBEAT_INTERVAL = 1800   # 正常联网时，日志最多每 30 分钟记一条，避免刷屏

PORTAL = DEFAULT_PORTAL
AC_NAME = DEFAULT_AC_NAME

try:
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass

# 强制直连：忽略系统代理（Clash / Watt Toolkit / Windows 系统代理）
# 原因：认证服务器是校园网内网地址(10.x)，一旦请求被塞进代理隧道就会超时
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _direct_open(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    return _DIRECT_OPENER.open(req, timeout=timeout)


def campus_reachable(timeout=2):
    """快速判断"现在是不是在校园网里"（连得上认证服务器）

    为什么需要它：在校外用手机热点时，认证服务器(10.x)完全不可达，
    如果照常往下走（探测 3 个地址 × 8 秒 + 3 次登录重试 × 15 秒），
    要干等近 100 秒，界面就会显示"无响应"。
    这里先花最多 2 秒探一下，不在校园网就立刻收工。
    """
    host = urllib.parse.urlparse(PORTAL).hostname
    port = urllib.parse.urlparse(PORTAL).port or 80
    if not host:
        return True          # 解析不出来就别拦着
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except Exception:
        return False


def log(msg):
    """输出到控制台 + 写入日志（超过 512KB 自动轮转）"""
    line = "[{0}] {1}".format(time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 512 * 1024:
            os.replace(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def log_heartbeat(msg):
    """心跳日志：控制台每次都打印，日志文件每 30 分钟最多一条"""
    line = "[{0}] {1}".format(time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        last = os.path.getmtime(HEARTBEAT_FILE) if os.path.exists(HEARTBEAT_FILE) else 0
        if time.time() - last >= HEARTBEAT_INTERVAL:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
            with open(HEARTBEAT_FILE, "w", encoding="utf-8") as f:
                f.write(line)
    except Exception:
        pass


# ============================================================
#  账号文件：Windows DPAPI 加密（v1.1.0 起）
# ============================================================
#  为什么改：v1.0.0 把学号密码明文写在 credentials.env 里，
#  任何能打开这台电脑的人（或者不小心把文件夹/压缩包发给别人）
#  都能直接用记事本看到密码。
#
#  现在改成调用 Windows 自带的 DPAPI 加密：
#    · 密钥由 Windows 自己掌管，绑定"这台电脑 + 当前 Windows 用户"
#    · 文件被复制到别的电脑、别的 Windows 账户，或者被改动过一个字节 → 都解不开
#    · 不需要用户自己记密码，程序运行时自动解密（开机自动连不受影响）
#    · 纯标准库实现（ctypes 调 crypt32.dll），不依赖任何第三方库
#
#  文件格式（credentials.dat，文本文件，方便排查）：
#    FORMAT=HTUDPAPI1
#    DATA=<DPAPI 密文的 base64>

CRED_FORMAT = "HTUDPAPI1"
_CRED_MODE = "none"       # dpapi / plain / none / undecryptable
_CRED_LOADED = False      # 账号文件是否已经读过（避免同一进程里重复读、重复报警告）

# CRYPTPROTECT_UI_FORBIDDEN：禁止弹任何窗口。
# 必须带上：计划任务是隐藏运行的，万一系统想弹窗确认就会卡死在那里。
_CRYPTPROTECT_UI_FORBIDDEN = 0x1


class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_uint32),
                ("pbData", ctypes.POINTER(ctypes.c_char))]


def _dpapi_call(func_name, data):
    """调用 crypt32.dll 的 CryptProtectData / CryptUnprotectData（纯标准库）"""
    if os.name != "nt":
        raise RuntimeError("当前系统不是 Windows，DPAPI 不可用")
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    fn = getattr(crypt32, func_name)
    # 必须显式声明参数类型：否则 64 位下指针会被截断成 32 位，直接崩
    fn.argtypes = [ctypes.POINTER(_DATA_BLOB), ctypes.c_wchar_p,
                   ctypes.POINTER(_DATA_BLOB), ctypes.c_void_p,
                   ctypes.c_void_p, ctypes.c_uint32,
                   ctypes.POINTER(_DATA_BLOB)]
    fn.restype = ctypes.c_int
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p

    buf = ctypes.create_string_buffer(bytes(data), max(1, len(data)))
    blob_in = _DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = _DATA_BLOB()
    ok = fn(ctypes.byref(blob_in), None, None, None, None,
            _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out))
    if not ok:
        raise OSError(ctypes.get_last_error(),
                      "{0} 调用失败".format(func_name))
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


def dpapi_encrypt(data):
    """加密（只能被当前 Windows 用户解开）"""
    return _dpapi_call("CryptProtectData", data)


def dpapi_decrypt(blob):
    """解密（不是本机本用户加密的，就会失败）"""
    return _dpapi_call("CryptUnprotectData", blob)


def _write_user_file(user):
    """单独记一份学号（不含密码），供界面启动时立刻显示"""
    try:
        with open(USER_FILE, "w", encoding="utf-8", newline="\n") as f:
            f.write(user)
    except Exception:
        pass


def _write_plain_env(user, password):
    """明文保存（只在 DPAPI 不可用时兜底，例如把本工具移植到 Linux 跑）"""
    with open(CRED_FILE, "w", encoding="utf-8") as f:
        f.write("# 校园网上网账号（此文件只在本机保存，请勿外传）\n")
        f.write("CAMPUS_USER={0}\n".format(user))
        f.write("CAMPUS_PASSWORD={0}\n".format(password))


def _read_cred_dat():
    """读加密账号文件，返回 (状态, 学号, 密码)

    状态：ok / empty（文件不存在）/ broken（格式不对）/ undecryptable（解不开）
    """
    if not os.path.exists(CRED_FILE_DAT):
        return "empty", "", ""
    fmt, b64 = "", ""
    try:
        with open(CRED_FILE_DAT, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k, v = k.strip().upper(), v.strip()
                if k == "FORMAT":
                    fmt = v
                elif k == "DATA":
                    b64 = v
    except Exception as e:
        log("读取 credentials.dat 失败：{0}".format(e))
        return "broken", "", ""
    if fmt != CRED_FORMAT or not b64:
        return "broken", "", ""
    try:
        text = dpapi_decrypt(base64.b64decode(b64)).decode("utf-8", "replace")
    except Exception as e:
        log("解密 credentials.dat 失败：{0}".format(e))
        return "undecryptable", "", ""
    user, _, pwd = text.partition("\n")
    user, pwd = user.strip(), pwd.strip()
    if not (user and pwd):
        return "broken", "", ""
    return "ok", user, pwd


def save_credentials_file(user, password):
    """保存账号密码（加密），返回 'dpapi' 或 'plain'

    加密后会立刻回读校验一次：确保"存进去的一定解得开"，
    避免出现"文件写坏了、下次开机解不开"这种最难查的问题。
    """
    payload = "{0}\n{1}".format(user, password).encode("utf-8")
    try:
        blob = dpapi_encrypt(payload)
    except Exception as e:
        log("[WARN] 系统加密不可用（{0}），退回明文保存".format(e))
        _write_plain_env(user, password)
        _write_user_file(user)
        return "plain"

    text = "\n".join([
        "# 河南师范大学 校园网自动连接 —— 账号文件",
        "# 已用 Windows DPAPI 加密：只有本机 + 当前 Windows 用户能解开，不用自己记密码。",
        "# 复制到别的电脑 / 别的 Windows 账户 / 被改动过：都会解不开，需要重新填写账号。",
        "# 想清除账号：删除本文件即可（密码不会留在任何地方）。",
        "FORMAT=" + CRED_FORMAT,
        "DATA=" + base64.b64encode(blob).decode("ascii"),
        "",
    ])
    tmp = CRED_FILE_DAT + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, CRED_FILE_DAT)
    _write_user_file(user)

    state, u2, p2 = _read_cred_dat()
    if not (state == "ok" and u2 == user and p2 == password):
        raise RuntimeError("加密文件回读校验失败（状态={0}）".format(state))

    os.environ["CAMPUS_USER"] = user
    os.environ["CAMPUS_PASSWORD"] = password
    return "dpapi"


def _load_plain_env():
    """读 v1.0.0 的明文 credentials.env（只用于自动升级）"""
    if not os.path.exists(CRED_FILE):
        return False
    got = False
    try:
        with open(CRED_FILE, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip().strip('"').strip("'")
                if k and k not in os.environ:
                    os.environ[k] = v
                    got = True
    except Exception as e:
        log("读取 credentials.env 失败：{0}".format(e))
    return got


def migrate_plain_credentials():
    """把 v1.0.0 的明文账号升级成加密文件，成功则删除明文"""
    user = os.environ.get("CAMPUS_USER", "")
    pwd = os.environ.get("CAMPUS_PASSWORD", "")
    if not (user and pwd):
        return False
    try:
        mode = save_credentials_file(user, pwd)          # 内部已做回读校验
    except Exception as e:
        log("[WARN] 明文账号升级加密失败（继续用明文，功能不受影响）：{0}".format(e))
        return False
    if mode != "dpapi":
        return False
    try:
        os.remove(CRED_FILE)
        log("[OK] 账号文件已升级为 Windows 加密版（credentials.dat），明文文件已删除")
    except Exception as e:
        log("[WARN] 明文文件删除失败：{0}（可手动删除 credentials.env）".format(e))
    return True


# ---- 账号配置文件 ----


def _load_credentials_impl():
    """读取账号密码（优先级：加密文件 → v1.0.0 明文文件 → 无）

    读到明文会自动升级成加密文件；升级失败则继续用明文，保证程序照常能用。
    返回读到的状态：dpapi / plain / none / undecryptable
    """
    global _CRED_MODE

    if os.path.exists(CRED_FILE_DAT):
        state, user, pwd = _read_cred_dat()
        if state == "ok":
            if "CAMPUS_USER" not in os.environ:
                os.environ["CAMPUS_USER"] = user
            if "CAMPUS_PASSWORD" not in os.environ:
                os.environ["CAMPUS_PASSWORD"] = pwd
            if not os.path.exists(USER_FILE):
                _write_user_file(user)
            _CRED_MODE = "dpapi"
            return _CRED_MODE
        if state == "undecryptable":
            _CRED_MODE = "undecryptable"
            log("[WARN] 账号文件解不开（credentials.dat）")
            log("       常见原因：① 换了电脑 ② 换了 Windows 用户 ③ 文件被改过 / 被别的程序动过")
            log("       处理办法：打开界面重新填一次学号密码并保存，或删掉 credentials.dat 重新配置")
            return _CRED_MODE
        log("[WARN] 账号文件格式不对（credentials.dat），请重新填写一次账号")

    if _load_plain_env():
        _CRED_MODE = "plain"
        if migrate_plain_credentials():
            _CRED_MODE = "dpapi"
        return _CRED_MODE

    if _CRED_MODE != "undecryptable":
        _CRED_MODE = "none"
    return _CRED_MODE


def load_credentials_file(force=False):
    """读账号（带缓存）：同一个进程里只真正读一次

    为什么加缓存：--info / --check-cred 这类命令会调用两次（main 一次、命令自己一次），
    不加缓存的话同一句"账号文件解不开"的警告会在界面日志里打印两遍。
    """
    global _CRED_LOADED
    if _CRED_LOADED and not force:
        return _CRED_MODE
    mode = _load_credentials_impl()
    _CRED_LOADED = True
    return mode


def get_credentials():
    """读取账号密码，返回 (user, password, mode)

    mode: dpapi=加密文件读到 / plain=明文（旧格式）/ none=没配置
          undecryptable=文件在但解不开（需要用户重新填写）
    """
    mode = load_credentials_file()
    u = os.environ.get("CAMPUS_USER", "")
    p = os.environ.get("CAMPUS_PASSWORD", "")
    if u and p:
        return u, p, mode
    return "", "", ("undecryptable" if mode == "undecryptable" else "none")


# ---- 账号相关的命令行入口（图形界面调用）----


def save_cred_cmd(argv):
    """保存账号（--save-cred）

    账号密码通过环境变量 HTU_NEW_USER / HTU_NEW_PWD 传进来，
    不走命令行参数 —— 避免密码出现在任务管理器的进程命令行里。
    """
    user = os.environ.get("HTU_NEW_USER", "").strip()
    pwd = os.environ.get("HTU_NEW_PWD", "")
    if not user or not pwd:
        print("SAVE_CRED=FAIL 缺少账号或密码")
        return 2
    if "@" in user:
        user = user.split("@")[0]
    try:
        mode = save_credentials_file(user, pwd)
    except Exception as e:
        print("SAVE_CRED=FAIL {0}".format(e))
        return 1
    print("SAVE_CRED=OK mode={0} user={1}".format(mode, user))
    return 0


def check_cred_cmd():
    """检查账号文件状态（--check-cred）"""
    mode = load_credentials_file()
    u = os.environ.get("CAMPUS_USER", "")
    hint = {
        "dpapi": "已用 Windows 加密保存（只有本机当前用户能解开）",
        "plain": "明文保存（旧版本格式，重新保存一次即可加密）",
        "none": "还没有保存账号",
        "undecryptable": "解不开：换了电脑 / 换了 Windows 用户 / 文件被改动过，请重新填写",
    }.get(mode, mode)
    print("CRED={0} user={1} 说明：{2}".format(mode, u or "-", hint))
    if mode == "undecryptable":
        return 3
    return 0 if (u and mode in ("dpapi", "plain")) else 2


def seal_cmd():
    """把明文账号文件升级成加密文件（--seal），不需要联网"""
    if not os.path.exists(CRED_FILE):
        if os.path.exists(CRED_FILE_DAT):
            print("SEAL=SKIP 账号已经是加密保存的（credentials.dat）")
            return 0
        print("SEAL=FAIL 没有找到账号文件，请先用界面或 --setup 保存账号")
        return 2
    _load_plain_env()
    if migrate_plain_credentials():
        print("SEAL=OK 已加密保存为 credentials.dat，明文文件已删除")
        return 0
    print("SEAL=FAIL 加密失败，明文文件已保留（功能不受影响）")
    return 1


# ---------------- 网络探测 ----------------

def discover_portal(timeout=3):
    """未认证时，通过 AC 重定向自动识别认证服务器地址与 AC 名称。

    已认证状态下不会发生重定向，此时保持默认值即可。
    """
    global PORTAL, AC_NAME
    for url in PORTAL_PROBES:
        try:
            with _direct_open(url, timeout=timeout) as r:
                final = r.geturl() or ""
        except Exception:
            continue
        if not final or final == url:
            continue
        if ("portal" not in final and "eportal" not in final
                and "wlanuserip" not in final and "wlanacname" not in final):
            continue
        try:
            p = urllib.parse.urlparse(final)
            q = urllib.parse.parse_qs(p.query)
            host = "{0}://{1}".format(p.scheme, p.netloc)
            ac = (q.get("wlanacname") or [""])[0]
            if host and "://" in host and p.netloc:
                PORTAL = host
                if ac:
                    AC_NAME = ac
                log("自动识别认证服务器：{0}   AC={1}".format(PORTAL, AC_NAME))
            return True
        except Exception:
            continue
    return False


def get_local_ip():
    """获取本机在校园网内的 IP（AC 靠它识别设备）

    三重保障，避免代理虚拟网卡(TUN, 198.18.x)污染：
      1) 直接问 Portal 服务器"你看到的我是谁"
      2) UDP 路由探测（不实际发包）
      3) 枚举本机网卡，挑一个 10.x 内网地址
    """
    ip = None
    try:
        data = http_get_json("{0}/portal/getRemoteAddr.do?rand={1}".format(
            PORTAL, int(time.time() * 1000)))
        addr = (data or {}).get("remoteAddr") or (data or {}).get("remoteAddr6")
        if addr and not str(addr).startswith("127."):
            ip = str(addr)
    except Exception:
        pass

    if not ip:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("10.101.2.194", 6060))
            ip = s.getsockname()[0]
        finally:
            s.close()

    if not ip or not str(ip).startswith("10."):
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                cand = info[4][0]
                if cand.startswith("10."):
                    ip = cand
                    break
        except Exception:
            pass

    if not str(ip).startswith("10."):
        log("[WARN] 本机IP={0} 不是校园网地址(10.x)，可能被代理软件 TUN/全局模式接管了流量".format(ip))
    return ip


def get_mac():
    n = uuid.getnode()
    return ":".join("{0:02x}".format((n >> shift) & 0xff) for shift in range(40, -1, -8))


def is_online(timeout=3):
    """严格联网检测：必须 HTTP 204 且未被重定向

    未认证时校园网 AC 会把请求劫持到认证页（返回 200/302），不能算联网成功。
    """
    try:
        with _direct_open(ONLINE_CHECK_URL, timeout=timeout) as r:
            final_url = r.geturl() or ""
            status = r.status
        if final_url and final_url != ONLINE_CHECK_URL:
            log("检测到 HTTP 被重定向（认证页劫持）→ 判定为未认证")
            return False
        if status != 204:
            log("联网检测返回 {0}（非 204）→ 判定为未认证".format(status))
            return False
        return True
    except Exception as e:
        log("联网检测异常（按未认证处理）：{0}: {1}".format(type(e).__name__, e))
        return False


def http_get_text(url, timeout=6):
    with _direct_open(url, timeout=timeout) as r:
        raw = r.read()
        return r.status, raw.decode("utf-8", "ignore"), r.geturl()


def http_get_json(url, timeout=6):
    status, text, final = http_get_text(url, timeout=timeout)
    if final and final != url:
        log("请求被重定向到：{0}".format(final[:120]))
    return json.loads(text)


def fetch_portal_info(ip):
    """获取 portalpageid / 版本号等参数"""
    info = {"ac_name": AC_NAME, "page_id": DEFAULT_PAGE_ID, "portal_ver": 0}
    try:
        qs = urllib.parse.urlencode({
            "wlanuserip": ip,
            "wlanacname": AC_NAME,
            "viewStatus": "1",
        })
        data = http_get_json("{0}/PortalJsonAction.do?{1}".format(PORTAL, qs))
        info["ac_name"] = (data.get("portalForm") or {}).get("wlanacname") or AC_NAME
        info["page_id"] = str((data.get("portalconfig") or {}).get("id") or DEFAULT_PAGE_ID)
        info["portal_ver"] = (data.get("serverForm") or {}).get("portalVer", 0)
    except Exception as e:
        log("获取 portal 配置失败（改用默认值）：{0}".format(e))
    return info


def build_params(user, password, force_suffix=True):
    ip = get_local_ip()
    info = fetch_portal_info(ip)
    if force_suffix and "@" not in user:
        user = user + DEFAULT_SUFFIX
    return {
        "userid": user,
        "passwd": password,
        "wlanuserip": ip,
        "wlanuseripv6": "",
        "wlanacname": info["ac_name"],
        "wlanacIp": "",
        "ssid": "",
        "vlan": "",
        "mac": get_mac(),
        "version": info["portal_ver"],
        "portalpageid": info["page_id"],
        "validateCode": "",
        "timestamp": "",
        "uuid": "",
        "portaltype": "0",
        "hostname": socket.gethostname(),
        "bindCtrlId": "",
    }, ip, info


def notify(title, message):
    """桌面通知（未安装 plyer 时静默跳过）"""
    try:
        from plyer import notification
        notification.notify(title=title, message=message, timeout=5)
    except Exception:
        pass


def do_login(user, password, attempts=2):
    """执行一次认证，返回 (是否成功, 提示信息, 错误码)"""
    params, ip, info = build_params(user, password)
    url = "{0}/quickauth.do?".format(PORTAL) + urllib.parse.urlencode(params)

    last_err = None
    for n in range(1, attempts + 1):
        log("提交认证（第 {0}/{1} 次）：账号={2}  本机IP={3}  AC={4}".format(
            n, attempts, params["userid"], ip, info["ac_name"]))
        try:
            data = http_get_json(url)
        except Exception as e:
            last_err = "{0}: {1}".format(type(e).__name__, e)
            log("请求失败：{0}".format(last_err))
            if n < attempts:
                time.sleep(2)
            continue

        code = str(data.get("code"))
        message = data.get("message") or ""
        if code == "0":
            log("[OK] 认证成功！{0}".format(message))
            return True, message or "认证成功", code
        if code == "7":
            log("[FAIL] 账号或密码不正确")
            return False, "账号或密码不正确", code
        log("[FAIL] 认证失败 code={0} message={1}".format(code, message))
        log("原始响应：" + json.dumps(data, ensure_ascii=False))
        return False, message or ("错误码 " + code), code

    return False, "网络请求超时：" + str(last_err), "-1"


def fetch_server_date():
    """从校园网认证服务器读取权威时间（HTTP 响应头里的 Date 字段）。

    用途：判断用户是否把系统时间调错了。服务器时间比本地时间可信得多，
    而且不增加额外负担（本来就要访问认证服务器，且是内网直连）。
    """
    try:
        url = "{0}/portal/getRemoteAddr.do?rand={1}".format(PORTAL, int(time.time() * 1000))
        with _direct_open(url, timeout=6) as r:
            dt = r.headers.get("Date")
        if not dt:
            return None
        return email.utils.parsedate_to_datetime(dt).date()
    except Exception:
        return None


def login(user, password, force=False):
    t_start = time.time()

    # ---- 先花最多 2 秒确认"在不在校园网"，不在就立刻收工（避免界面卡死）----
    if not campus_reachable():
        if is_online(timeout=2):
            log_heartbeat("当前已联网（不在校园网，可能是热点/家里网）[OK]")
            return 0
        # 用 log_heartbeat：每分钟跑一次任务也不会把日志刷爆（最多每 30 分钟记一条）
        log_heartbeat("当前不在校园网（连不上认证服务器 {0}），已跳过认证".format(PORTAL))
        return 4

    # ---- 顺带看一下系统时间准不准（服务器时间比本地可信）----
    sd = fetch_server_date()
    if sd is not None:
        gap = abs((sd - datetime.date.today()).days)
        if gap >= 2:
            log_heartbeat("提示：系统时间与校园网服务器相差 {0} 天（服务器 {1}），建议校准".format(gap, sd.isoformat()))

    if not force and is_online():
        log_heartbeat("当前已联网，无需认证 [OK]")
        return 0
    if not force:
        discover_portal()
    ok, msg, code = do_login(user, password)
    notify("校园网连接", msg)
    log("本次耗时 {0:.1f} 秒".format(time.time() - t_start))
    return 0 if ok else 1



def print_info():
    """给图形界面用：一次性输出账号/网络状态（JSON）"""
    mode = load_credentials_file()
    u = os.environ.get("CAMPUS_USER", "")
    p = os.environ.get("CAMPUS_PASSWORD", "")
    try:
        import socket as _sock
        _s = _sock.create_connection(("connect.rom.miui.com", 80), timeout=2)
        _s.close()
        online = True
    except Exception:
        online = False
    print(json.dumps({"version": VERSION, "user": u, "pwd": p, "online": online,
                      "has_cred": bool(u and p), "cred_state": mode},
                     ensure_ascii=False))


def logout():
    if not campus_reachable():
        log("当前不在校园网（连不上认证服务器），无需下线")
        return 0
    params, ip, _ = build_params("", "", force_suffix=False)
    params.pop("userid", None)
    params.pop("passwd", None)
    url = "{0}/quickauthdisconn.do?".format(PORTAL) + urllib.parse.urlencode(params)
    log("请求下线 ...")
    try:
        data = http_get_json(url)
        log("响应：" + json.dumps(data, ensure_ascii=False))
        return 0
    except Exception as e:
        log("下线请求失败：{0}".format(e))
        return 2


# ---------------- 交互式配置 ----------------


def setup():
    """交互式配置入口：用户按 Ctrl+C 或提前关闭窗口时优雅退出，不报错栈"""
    try:
        return _setup_interactive()
    except (EOFError, KeyboardInterrupt):
        print("\n\n  已取消账号配置。")
        return 1


def _setup_interactive():
    """交互式输入账号密码，校验通过后保存"""
    print("=" * 52)
    print("  河南师范大学 校园网自动连接 - 账号配置")
    print("=" * 52)
    print("  提示：账号为学号；密码默认为 Myhtu+身份证第12-17位")
    print("  账号密码只保存在本机（Windows 加密的 credentials.dat），不会上传任何服务器")
    print()

    discover_portal()

    for attempt in range(1, 6):
        user = ""
        while not user:
            user = input("请输入你的学号（上网账号）：").strip()
            if "@" in user:
                user = user.split("@")[0]

        # 密码采用明文输入，方便当场核对是否输错（只显示在本机屏幕上，不保存到任何地方）
        password = input("请输入上网密码（会显示出来，方便你核对）：").strip()

        if not password:
            print("  ✗ 密码不能为空，请重新输入\n")
            continue

        print("\n正在验证账号密码（连接认证服务器）...")
        ok, msg, code = do_login(user, password, attempts=1)
        if ok:
            print("\n  ✅ 认证成功！账号密码正确")
            save_credentials_file(user, password)
            print("\n  全部配置完成，可以开始使用了！")
            return 0
        if code == "7":
            print("\n  ✗ 账号或密码不正确，请重新输入\n")
            continue
        print("\n  ⚠️ 认证未成功：{0}".format(msg))
        print("     可能原因：① 没连校园网 ② 校园网欠费 ③ 认证服务器暂时不可用")
        ans = input("     仍然保存这组账号密码吗？(y=保存 / n=重新输入) ").strip().lower()
        if ans == "y":
            print("\n  ✅ 已保存（当前环境无法验证，回学校后会自动生效）")
            save_credentials_file(user, password)
            return 0
    print("\n  ✗ 尝试次数过多，安装中止")
    return 1


def main():
    argv = sys.argv[1:]
    force = "--force" in argv

    # 这两个命令自己负责读写账号文件，必须放在最前面：
    # 否则 main 开头的 load_credentials_file() 会先把明文自动升级掉，
    # 轮到 --seal 时就"没活可干"，明明干了事却报 SKIP
    if "--save-cred" in argv:
        return save_cred_cmd(argv)
    if "--seal" in argv:
        return seal_cmd()

    load_credentials_file()

    if "--setup" in argv:
        return setup()
    if "--logout" in argv:
        return logout()
    if "--info" in argv:
        print_info()
        return 0
    if "--check-cred" in argv:
        return check_cred_cmd()
    if "--status" in argv:
        # 供图形界面调用：只报告当前是否已认证（严格判定：204 且未被 AC 劫持）
        print("ONLINE" if is_online() else "OFFLINE")
        return 0

    rest = [a for a in argv if not a.startswith("--")]
    user, password, mode = get_credentials()
    if len(rest) >= 2:                      # 命令行直接给了账号密码
        user, password, mode = rest[0], rest[1], "argv"

    if mode == "undecryptable":
        log("[FAIL] 账号文件解不开（credentials.dat）：换了电脑 / 换了 Windows 用户 / 文件被改动过")
        log("       请在界面里重新填写学号密码并保存；或删掉该文件后重新配置")
        return 3
    if not user or not password:
        log("缺少账号/密码：请先运行  python AutoConnect_htu.py --setup  完成配置")
        return 2

    rc = login(user, password, force=force)

    return rc


if __name__ == "__main__":
    sys.exit(main())
