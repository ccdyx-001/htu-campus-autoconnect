# 河南师范大学 校园网自动连接工具

每次开机都要手动打开认证页面输账号密码太烦了，所以写了这个小工具：
**开机自动认证、断网自动重连、后台静默运行**。

> 📌 这是**最初的脚本版本**（v0.1）：需要电脑上已安装 Python 3.8 以上。
> 后续版本会加图形界面和内置运行库（免安装 Python），见下文「后续计划」。

> 🐛 **用着有问题、或者觉得哪里别扭，欢迎直接提 [Issue](../../issues) 告诉我** —— 我会尽快修。
> 这个项目最大的价值就是"大家帮我踩坑"，小问题也尽管提 ✓

---

## 功能

- **开机自动认证**：登录进桌面就自动连上校园网
- **断网自动重连**：计划任务每分钟检查一次，掉线自动补认证（一般 1 分钟内恢复）
- **后台静默运行**：没有任何窗口、弹窗打扰
- **兼容代理软件**：Clash / Watt Toolkit 等开着也能用（校园网请求强制直连）
- **纯标准库实现**：不需要 pip 安装任何第三方库

## 快速开始

1. 把文件夹解压到固定位置（建议 D 盘等固定目录，别在压缩包里直接运行）
2. 双击 **`install.bat`**
3. 按提示输入 **学号** 和 **上网密码**
   - 账号就是学号，不用自己加 `@htu`（程序会自动补上）
   - 初始密码规则一般是 `Myhtu` + 身份证第 12-17 位，以学校通知为准
   - 看到「✅ 认证成功」说明账号密码正确
4. 弹出管理员权限确认框时点 **【是】**（注册计划任务需要）
5. 看到「安装完成」就好了

## 前提条件

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 |
| Python | **3.8 或更高**（[官网下载](https://www.python.org/downloads/)，安装时务必勾选 **Add Python to PATH**） |
| 校园网 | Wi-Fi 已保存并勾选「自动连接」（设置 → 网络和 Internet → WLAN → 管理已知网络） |

## 命令行用法（进阶）

```bash
python AutoConnect_htu.py --setup        # 交互式配置账号密码
python AutoConnect_htu.py                # 检测网络，未联网才认证
python AutoConnect_htu.py --force        # 强制认证一次（测试用）
python AutoConnect_htu.py --logout       # 主动下线
python AutoConnect_htu.py 学号 密码       # 直接指定账号密码
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `AutoConnect_htu.py` | 主程序（认证核心） |
| `install.bat` | 安装：配置账号 + 验证 + 注册计划任务 |
| `uninstall.bat` | 卸载：删除计划任务与账号信息 |
| `setup_task.ps1` | 计划任务注册脚本（每 1 分钟检查一次） |
| `手动测试.bat` | 诊断工具：看状态、手动认证、翻日志 |
| `使用说明.txt` | 给同学看的简易说明 |
| `credentials.env` | 账号密码（**本机保存，已被 .gitignore 排除，不会上传**） |

## 工作原理

河师大用的是华为风格的 Portal 认证（`authByRas=false`，走明文提交）：

```
1. 探测认证服务器
   访问 http://www.msftconnecttest.com/redirect 等地址，被 AC 重定向后
   从 URL 里取出真实的 Portal 地址和 AC 名称（wlanacname）
2. 获取本机在校园网内的 IP
   优先问 Portal 的 /portal/getRemoteAddr.do，其次 UDP 路由探测，
   最后枚举本机网卡（避开 Clash 的 198.18.x 虚拟网卡）
3. 提交认证
   GET http://<portal>/quickauth.do?userid=<学号@htu>&passwd=<密码>
       &wlanuserip=<本机IP>&wlanacname=<AC>&...
   返回 JSON 里 code="0" 表示成功，"7" 表示账号或密码错误
4. 断线检测
   请求 generate_204 类地址，严格校验「HTTP 204 且未被 AC 劫持」
```

细节都在 `AutoConnect_htu.py` 的注释里，欢迎直接读源码。

## 常见问题

**Q：提示"没有检测到 Python"**
A：去官网安装 Python 3.8+，安装界面底部勾选 **Add Python to PATH**，装完重新运行 `install.bat`。

**Q：提示"账号或密码不正确"**
A：检查学号密码；初始密码是 `Myhtu` + 身份证第 12-17 位；改过密码就用新密码。

**Q：怎么卸载？**
A：双击 `uninstall.bat`（会删除计划任务和账号信息）。

**Q：开着代理（Clash / VPN）会失效吗？**
A：不会，程序对校园网请求做了强制直连。但不建议开 TUN 模式（那会接管所有流量）。

## 后续计划

- [ ] 图形界面（不用命令行，填学号密码点一下就好）
- [ ] 内置 Python 运行库，免安装 Python
- [ ] 一键生成桌面快捷方式、在「设置 → 应用」里可卸载

## 反馈与贡献 ⭐

**发现 bug、或者觉得哪里不好用，尽管提 Issue —— 我来修。**

| 我想… | 怎么做 |
|---|---|
| 🐛 报告一个问题 | [新建 Bug Issue](../../issues/new?template=bug_report.md)（有模板，照着填就行） |
| 💡 提个建议 / 想要新功能 | [新建 Issue](../../issues/new) 描述一下你的想法 |
| 🔧 直接改代码帮我修 | Fork → 改 → 提 Pull Request（Pull Request 就是"我改好了，你看看要不要合并"） |

**提 bug 时附上这些信息，我能快很多**（模板里已经列好了）：

- Windows 版本、用的哪个版本
- 是否在校园网内（是不是连着手机热点）
- 是否开着代理（Clash / VPN，TUN 模式开没开）
- `autoconnect.log` 最后几行（右键桌面图标 → 打开文件所在位置）

> 不用担心"这是不是很蠢的问题" —— **你自己用着别扭的地方，别人大概率也别扭** ✓
> 提出来就是在帮下一个用的人 ✓

## 免责声明

- 仅供学习和个人便利使用，请遵守学校网络管理规定
- 程序只向学校认证服务器发送登录请求，不采集、不上传任何个人信息
- 使用本程序产生的一切后果由使用者自行承担

## 致谢

Portal 认证流程的思路参考了开源项目
[YINGHAIDADA/School_Network_AutoConnecter](https://github.com/YINGHAIDADA/School_Network_AutoConnecter)（MIT License）。

## License

[MIT](LICENSE) —— 可以自由使用、修改、分发，包括商业用途，保留版权声明即可 ✓

**这个项目完全开源**：代码随便看、随便改、随便用。唯一的要求是保留上面那份版权声明 ✓
