<#
================================================================
 河南师范大学  校园网自动连接 —— 图形界面（免费开源版）
================================================================
 说明：
   · 界面用 Windows 原生控件绘制，不需要额外安装任何库
   · 后台仍然调用同目录下的内置 Python 运行库执行认证
   · 免费开源：填好学号和密码就能用
   · 参数 -Check：只做自检（不开窗口），用于自动化测试
   · 参数 -LayoutCheck：只做布局自检（越界/重叠），用于自动化测试
================================================================
#>
param([switch]$Check, [switch]$LayoutCheck)

$ErrorActionPreference = 'Stop'

$root       = $PSScriptRoot
$pyExe      = Join-Path $root 'runtime\python.exe'
if (-not (Test-Path $pyExe)) { $pyExe = 'python' }
$mainPy     = Join-Path $root 'AutoConnect_htu.py'
$taskPs1    = Join-Path $root 'setup_task.ps1'
$credFile   = Join-Path $root 'credentials.env'   # v1.0.0 的明文账号文件（现在只用于兼容/清理）
$credDat    = Join-Path $root 'credentials.dat'   # v1.1.0 起：Windows DPAPI 加密的账号文件
$userFile   = Join-Path $root '.user'             # 只存学号（界面启动时立刻显示用，不含密码）
$logFile    = Join-Path $root 'autoconnect.log'
$installLog = Join-Path $root 'install_log.txt'
$TaskName   = 'HTU Campus AutoConnect'

# 安装模块（安装到本机 / 桌面快捷方式 / 卸载条目）
$installMod = Join-Path $root '安装模块.ps1'
if (Test-Path $installMod) { . $installMod }

# ---------------- 底层工具函数 ----------------

function Get-PyStartInfo {
    param([string[]]$PyArgs = @(), [hashtable]$EnvExtra = $null)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pyExe
    $psi.Arguments = (($PyArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    try { $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8' } catch { }
    # 额外环境变量：用于把"要保存的账号密码"传进去
    # （走环境变量而不是命令行参数，避免密码出现在任务管理器的进程命令行里）
    if ($EnvExtra) {
        foreach ($k in $EnvExtra.Keys) {
            try { $psi.EnvironmentVariables[[string]$k] = [string]$EnvExtra[$k] } catch { }
        }
    }
    return $psi
}

function Invoke-Py {
    param([string[]]$PyArgs = @(), [hashtable]$EnvExtra = $null)
    $p = [System.Diagnostics.Process]::Start((Get-PyStartInfo -PyArgs $PyArgs -EnvExtra $EnvExtra))
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $script:LastPyExit = $p.ExitCode
    return (($out + "`r`n" + $err).Trim())
}

# ---------------- 后台执行（联网操作放这里，界面不会卡死）----------------
# 关键：联网操作（探测认证服务器、登录重试）可能要几秒到几十秒，
# 如果直接在界面线程里跑，Windows 会把窗口标成"无响应"。
# 这里用"后台进程 + 定时器轮询"的方式：进程在后台跑，界面线程只负责刷新。

$script:PyJobs = @{}          # 可以同时跑多个后台任务（互不阻塞）
$script:BusyCount = 0
# 注意：$script:PyTimer 在 WinForms 载入之后再创建（见文件后面的"后台任务定时器"）

function Set-UiBusy {
    param([bool]$Busy, [string]$Text = '')
    if ($Busy) { $script:BusyCount++ } else { $script:BusyCount = [Math]::Max(0, $script:BusyCount - 1) }
    $isBusy = ($script:BusyCount -gt 0)
    foreach ($b in @($btnTest, $btnInstall, $btnStatus, $btnUninstall, $btnLog)) {
        if ($b) { $b.Enabled = -not $isBusy }
    }
    try { $form.UseWaitCursor = $isBusy } catch { }
    if ($Busy -and $Text) { Write-Log2 ('……' + $Text + '（界面可以正常操作，完成后自动显示结果）') }
    if (-not $isBusy) { End-Actions }      # 忙完了：按钮文字恢复原样
}

# ---------------- 点击反馈（点下去立刻有反应）----------------
# 以前：点了按钮要等后台进程返回才看到变化，容易让人以为"没反应"又点一次。
# 现在：点击瞬间按钮文字变成"正在…"并禁用，同时立刻重绘。
$script:BtnDefaults = @{}

function Begin-Action {
    param($Btn, [string]$Text)
    if (-not $Btn) { return }
    if (-not $script:BtnDefaults.ContainsKey($Btn)) { $script:BtnDefaults[$Btn] = $Btn.Text }
    if ($Text) { $Btn.Text = $Text }
    $Btn.Enabled = $false
    try { $form.UseWaitCursor = $true } catch { }
    try { $form.Refresh() } catch { }
}

function End-Actions {
    foreach ($b in @($script:BtnDefaults.Keys)) {
        try { $b.Text = $script:BtnDefaults[$b]; $b.Enabled = $true } catch { }
    }
    try { $form.UseWaitCursor = $false } catch { }
}

function Start-PyAsync {
    param(
        [string[]]$PyArgs = @(),
        [string]$BusyText = '处理中',
        [scriptblock]$OnDone = $null,
        [int]$TimeoutSec = 90,
        [hashtable]$EnvExtra = $null,
        [switch]$Silent          # 静默模式：不锁界面、不显示"忙"提示（用于后台刷新）
    )
    try {
        $p = [System.Diagnostics.Process]::Start((Get-PyStartInfo -PyArgs $PyArgs -EnvExtra $EnvExtra))
    } catch {
        Write-Log2 ('启动失败：' + $_.Exception.Message)
        return $false
    }
    $id = [guid]::NewGuid().ToString('N')
    $script:PyJobs[$id] = @{
        Proc       = $p
        OnDone     = $OnDone
        Started    = Get-Date
        TimeoutSec = $TimeoutSec
        Silent     = [bool]$Silent
        Id         = $id
        Args       = ($PyArgs -join ' ')
    }
    if (-not $Silent) { Set-UiBusy -Busy $true -Text $BusyText }
    $script:PyTimer.Start()
    return $true
}

# ---------------- 本机信息缓存（关键性能优化）----------------
# 以前每次刷新界面都要启动 Python（光 getmac 就 1.5 秒），所以点一下按钮要等半天。
# 现在：启动时后台跑一次 --summary（约 90ms）把全部信息取回来缓存住，
# 之后界面刷新只读缓存，点击按钮不再启动任何进程。

$script:Summary   = $null
$script:SumJob    = $false
$script:NetState  = $null
$script:NetJob    = $false
$script:TaskState = $null
$script:TaskTime  = [datetime]::MinValue
$script:TaskPs    = $null      # 后台计划任务查询的运行空间
$script:TaskPsHandle = $null

function Get-NetState {
    if ($script:NetState) { return $script:NetState }
    return @{ ok = $null; text = '检测中…' }
}

function Get-Fingerprint {
    if ($script:Summary -and $script:Summary.fingerprint) { return [string]$script:Summary.fingerprint }
    if ($script:Fingerprint) { return $script:Fingerprint }
    return '读取中…'
}

function Update-SummaryAsync {
    param([switch]$Force)
    if ($script:SumJob) { return }
    if ($script:Summary -and -not $Force) { return }
    $script:SumJob = $true
    [void](Start-PyAsync -PyArgs @($mainPy, '--info') -BusyText '' -TimeoutSec 25 -Silent -OnDone {
        param($out, $code)
        $script:SumJob = $false
        # 取输出里第一行以 { 开头的 JSON
        # （不能只看第一行：升级账号文件时前面会先打印"已升级为加密版"之类的提示行）
        $line = ($out -split "`r?`n" | Where-Object { $_.Trim() -match '^\{' } | Select-Object -First 1)
        if ($line) {
            try { $script:Summary = $line.Trim() | ConvertFrom-Json } catch { }
        }
        if ($script:Summary) {
            $s = $script:Summary
            if ($s.user -and -not $txtUser.Text) { $txtUser.Text = [string]$s.user }
            if ($s.pwd -and -not $txtPwd.Text) { $txtPwd.Text = [string]$s.pwd }
            if ($null -ne $s.online) {
                if ($s.online) { $script:NetState = @{ ok = $true; text = '已联网' } }
                else { $script:NetState = @{ ok = $false; text = '未认证' } }
            }
        }
        Update-State
    })
}

function Update-NetStateAsync {
    # 静默后台检测网络（不锁界面、不显示忙提示）
    if ($script:NetJob) { return }
    $script:NetJob = $true
    [void](Start-PyAsync -PyArgs @($mainPy, '--status') -TimeoutSec 20 -Silent -OnDone {
        param($out, $code)
        $last = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($last -match 'ONLINE') { $script:NetState = @{ ok = $true; text = '已联网' } }
        else { $script:NetState = @{ ok = $false; text = '未认证' } }
        $script:NetJob = $false
        Update-State
    })
}

function Get-TaskState {
    # 只读缓存 —— 真正查询在后台跑（见 Start-TaskStateAsync）
    if ($script:TaskState) { return $script:TaskState }
    return @{ ok = $null; text = '检测中…' }
}

function Start-TaskStateAsync {
    param([switch]$Force)
    # 为什么必须放后台：Get-ScheduledTask 第一次调用要载入 ScheduledTasks 模块，
    # 实测约 900 ms。以前它是在界面线程里同步查的，导致窗口出现后大约 1 秒点不动。
    # 这里用 PowerShell 运行空间在后台查，界面只负责取结果。
    if ($script:TaskPs) { return }                                  # 已经在查了
    if (-not $Force -and $script:TaskState -and ((Get-Date) - $script:TaskTime).TotalSeconds -lt 5) { return }
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($name)
            $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if (-not $t) { return 'NONE' }
            $i = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
            return ('OK|{0}|{1}' -f $t.State, $i.LastTaskResult)
        }).AddArgument($TaskName)
        $script:TaskPs = $ps
        $script:TaskPsHandle = $ps.BeginInvoke()
        $script:PyTimer.Start()
    } catch {
        $script:TaskPs = $null; $script:TaskPsHandle = $null
    }
}

function Complete-TaskStateAsync {
    # 由后台任务定时器调用：查完了就把结果收进缓存，并刷新状态栏
    if (-not $script:TaskPs -or -not $script:TaskPsHandle) { return }
    if (-not $script:TaskPsHandle.IsCompleted) { return }
    try {
        $res = @($script:TaskPs.EndInvoke($script:TaskPsHandle))
        $line = ''
        foreach ($r in $res) { if ("$r".Trim()) { $line = "$r".Trim() } }
        if ($line -eq 'NONE') {
            $script:TaskState = @{ ok = $false; text = '未安装' }
        } elseif ($line -like 'OK|*') {
            $p = $line -split '\|'
            $script:TaskState = @{ ok = $true; text = ('已安装（{0} / 上次结果 {1}）' -f $p[1], $p[2]) }
        } else {
            $script:TaskState = @{ ok = $null; text = '检测中…' }
        }
        $script:TaskTime = Get-Date
    } catch {
        $script:TaskState = @{ ok = $null; text = '检测失败（可点【查看状态】重试）' }
    } finally {
        try { $script:TaskPs.Dispose() } catch { }
        $script:TaskPs = $null; $script:TaskPsHandle = $null
        Update-State
    }
}

function Invoke-TaskScript {
    param([switch]$Uninstall)
    # 注意：这里刻意不带执行策略参数、也不带窗口样式参数 ——
    # 这两样叠在一起是杀毒软件的高危特征。本机自己的 .ps1 在默认
    # RemoteSigned 策略下本来就能执行，所以策略参数是多余的；
    # 提权（-Verb RunAs）必须保留，否则删/建计划任务会失败。
    $argList = @('-NoProfile', '-File', "`"$taskPs1`"", '-PythonExe', "`"$pyExe`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait
    if (Test-Path $installLog) { return (Get-Content $installLog -Encoding UTF8 | Select-Object -Last 6) -join "`r`n" }
    return '（没有拿到安装日志）'
}

function Read-CredUser {
    # v1.1.0 起：学号单独记在 .user 里（密码在加密文件里，界面读不到、也不需要读）
    if (Test-Path $userFile) {
        $u = (Get-Content $userFile -Raw -Encoding UTF8).Trim()
        if ($u) { return $u }
    }
    # 兼容 v1.0.0 的明文文件（升级后这个文件会自动消失）
    if (Test-Path $credFile) {
        foreach ($line in Get-Content $credFile -Encoding UTF8) {
            if ($line -match '^\s*CAMPUS_USER\s*=\s*(.+)$') { return $Matches[1].Trim() }
        }
    }
    return ''
}

function Save-Cred {
    # 保存账号：交给 Python 用 Windows DPAPI 加密写文件
    # （界面自己不再写明文文件，避免密码留在硬盘上）
    param([string]$User, [string]$Password)
    $out = Invoke-Py -PyArgs @($mainPy, '--save-cred') -EnvExtra @{
        HTU_NEW_USER = $User
        HTU_NEW_PWD  = $Password
    }
    if ($out -match 'SAVE_CRED=OK') {
        $tail = (($out -split "`r?`n" | Where-Object { $_ -match 'SAVE_CRED=OK' }) | Select-Object -First 1)
        Write-Log2 ('账号已保存：' + $User + '（Windows 加密，只有本机当前用户能解开）')
        $script:Summary = $null          # 让状态栏下次刷新时重新取
        return $true
    }
    $why = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    Write-Log2 ('账号保存失败：' + $why)
    return $false
}

# ---------------- 作者信息 ----------------

$APP_VERSION = '1.3.0'
$AUTHOR_NAME = '梅川逸夫'
$AUTHOR_ID   = ''

function Show-About {
    $msg = @(
        '河南师范大学  校园网自动连接',
        '',
        ('作者：{0}' -f $AUTHOR_NAME),
        '版本：v' + $APP_VERSION + '（免费开源版）',
        '',
        '版本 v' + $APP_VERSION + '（免费开源，MIT 许可）',
        '直接填学号和密码就能用，不需要注册码。',
        '',
        '账号密码用 Windows DPAPI 加密保存在本机，',
        '只有这台电脑上的当前 Windows 用户能解开；',
        '复制到别的电脑或别的账户都解不开，也不会上传到任何服务器。'
    ) -join "`r`n"
    [void][System.Windows.Forms.MessageBox]::Show($msg, '关于本工具', 'OK', 'Information')
}

if ($Check) {
    Write-Host "python    : $pyExe"
    Write-Host "主脚本    : $(Test-Path $mainPy)"
    Write-Host "任务脚本  : $(Test-Path $taskPs1)"
    # 自检模式直接查（不走界面缓存），这样能反映真实状态
    $sum = Invoke-Py @($mainPy, '--info')
    $sj = ($sum -split "`r?`n" | Where-Object { $_.Trim() -match '^\{' } | Select-Object -First 1)
    if ($sj) {
        $sj = $sj.Trim()
        $o = $sj | ConvertFrom-Json
        Write-Host ("程序版本  : v{0}" -f $o.version)
        Write-Host ("账号状态  : {0}" -f $(if ($o.has_cred) { '已保存学号密码' } else { '未保存' }))
        $csMap = @{
            'dpapi'         = '已加密（Windows DPAPI，只有本机当前用户能解开）'
            'plain'         = '明文保存（旧格式，下次运行会自动加密）'
            'none'          = '还没有账号文件'
            'undecryptable' = '解不开（换了电脑/账户或文件被改过，需要重新填写）'
        }
        $cs = [string]$o.cred_state
        Write-Host ("账号文件  : {0}" -f $(if ($csMap.ContainsKey($cs)) { $csMap[$cs] } else { $cs }))
        Write-Host ("网络状态  : {0}" -f $(if ($o.online) { '已联网' } else { '未认证' }))
    } else {
        Write-Host "账号状态  : （--info 读取失败）" -ForegroundColor Yellow
    }
    # 自检模式直接同步查（这里不在乎那几百毫秒，但要拿到真实结果）
    $tObj = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $tObj) {
        Write-Host "任务状态  : 未安装"
    } else {
        $tInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host ("任务状态  : 已安装（{0} / 上次结果 {1}）" -f $tObj.State, $tInfo.LastTaskResult)
    }
    Write-Host "界面自检完成"
    exit 0
}

# ---------------- 图形界面 ----------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------- 后台任务定时器（WinForms 载入后才能建）----------------
$script:PyTimer = New-Object System.Windows.Forms.Timer
$script:PyTimer.Interval = 200
$script:PyTimer.Add_Tick({
    # 顺便收后台的"计划任务查询"结果（它不占界面线程）
    if ($script:TaskPs) { Complete-TaskStateAsync }

    if ($script:PyJobs.Count -eq 0) {
        if (-not $script:TaskPs) { $script:PyTimer.Stop() }
        return
    }
    foreach ($id in @($script:PyJobs.Keys)) {
        $job = $script:PyJobs[$id]
        if (-not $job) { continue }
        $p = $job.Proc

        if (-not $p.HasExited) {
            # 超时保护：到期还没返回就中止
            if (((Get-Date) - $job.Started).TotalSeconds -gt $job.TimeoutSec) {
                try { $p.Kill() } catch { }
                $script:PyJobs.Remove($id)
                if (-not $job.Silent) { Set-UiBusy -Busy $false }
                Write-Log2 ('操作超时（超过 {0} 秒），已中止。' -f $job.TimeoutSec)
                if (-not $job.Silent) {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        ("操作超过 {0} 秒还没返回，已中止。`r`n`r`n大多数情况是当前不在校园网`r`n（比如连着手机热点），连上 HTU_Student 再试即可。" -f $job.TimeoutSec),
                        '操作超时', 'OK', 'Warning')
                }
            }
            continue
        }

        $out = ''
        try { $out = ($p.StandardOutput.ReadToEnd() + "`r`n" + $p.StandardError.ReadToEnd()).Trim() } catch { }
        $code = $p.ExitCode
        $script:PyJobs.Remove($id)
        if (-not $job.Silent) { Set-UiBusy -Busy $false }
        if ($job.OnDone) {
            try { & $job.OnDone $out $code } catch { Write-Log2 ('回调出错：' + $_.Exception.Message) }
        }
    }
})

$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$fontNormal = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.25)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)
$fontCard = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)

# ---- 统一配色（改这里就等于换整套皮肤）----
$clrBg     = [System.Drawing.Color]::FromArgb(245, 246, 248)   # 窗体底色：浅灰
$clrCard   = [System.Drawing.Color]::White                     # 卡片底色
$clrBorder = [System.Drawing.Color]::FromArgb(216, 220, 226)   # 卡片描边
$clrText   = [System.Drawing.Color]::FromArgb(32, 36, 42)      # 主文字
$clrMuted  = [System.Drawing.Color]::FromArgb(122, 128, 138)   # 次要文字
$clrAccent = [System.Drawing.Color]::FromArgb(37, 99, 235)     # 主按钮：蓝
$clrAccentHover = [System.Drawing.Color]::FromArgb(29, 78, 216)
$clrBtnHover = [System.Drawing.Color]::FromArgb(238, 242, 248)
$clrOk     = [System.Drawing.Color]::FromArgb(22, 140, 74)     # 绿：正常
$clrWarn   = [System.Drawing.Color]::FromArgb(200, 90, 10)     # 橙：待处理
$clrBad    = [System.Drawing.Color]::FromArgb(190, 40, 40)     # 红：异常/警告

$form = New-Object System.Windows.Forms.Form
$form.Text = '河南师范大学 校园网自动连接 v' + $APP_VERSION
$form.Size = New-Object System.Drawing.Size(580, 660)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $fontNormal
$form.BackColor = $clrBg

# ---- 窗口/任务栏图标（logo.ico 存在才设置，缺失不影响使用）----
$logoIco = Join-Path $root 'logo.ico'
$logoPng = Join-Path $root 'logo.png'
if (Test-Path $logoIco) {
    try { $form.Icon = New-Object System.Drawing.Icon($logoIco) } catch { }
}

# ---- 左上角个人 Logo ----
if (Test-Path $logoPng) {
    $picLogo = New-Object System.Windows.Forms.PictureBox
    $picLogo.Location = New-Object System.Drawing.Point(22, 18)
    $picLogo.Size = New-Object System.Drawing.Size(44, 44)
    $picLogo.SizeMode = 'Zoom'
    $picLogo.BackColor = [System.Drawing.Color]::Transparent
    try { $picLogo.Image = [System.Drawing.Image]::FromFile($logoPng) } catch { }
    $form.Controls.Add($picLogo)
}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '校园网自动连接'
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $clrText
$lblTitle.Location = New-Object System.Drawing.Point(78, 20)
$lblTitle.Size = New-Object System.Drawing.Size(280, 30)
$lblTitle.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '开机自动认证 · 断网自动重连 · 后台静默运行'
$lblSub.Font = $fontSmall
$lblSub.ForeColor = $clrMuted
$lblSub.Location = New-Object System.Drawing.Point(80, 50)
$lblSub.Size = New-Object System.Drawing.Size(300, 18)
$lblSub.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($lblSub)

# ---- 右上角：作者（头像 + 昵称，点一下看关于）----
$tipAbout = New-Object System.Windows.Forms.ToolTip
$lblAuthor = New-Object System.Windows.Forms.Label
$lblAuthor.Text = $AUTHOR_NAME
$lblAuthor.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
$lblAuthor.ForeColor = $clrText
$lblAuthor.Location = New-Object System.Drawing.Point(392, 22)
$lblAuthor.Size = New-Object System.Drawing.Size(100, 18)
$lblAuthor.TextAlign = 'MiddleRight'
$lblAuthor.BackColor = [System.Drawing.Color]::Transparent
$lblAuthor.Cursor = 'Hand'
$lblAuthor.Add_Click({ Show-About })
$tipAbout.SetToolTip($lblAuthor, '作者：梅川逸夫 —— 点一下看关于')
$form.Controls.Add($lblAuthor)

$lblAuthorId = New-Object System.Windows.Forms.Label
$lblAuthorId.Text = '免费开源'
$lblAuthorId.Font = $fontSmall
$lblAuthorId.ForeColor = $clrMuted
$lblAuthorId.Location = New-Object System.Drawing.Point(392, 42)
$lblAuthorId.Size = New-Object System.Drawing.Size(100, 16)
$lblAuthorId.TextAlign = 'MiddleRight'
$lblAuthorId.BackColor = [System.Drawing.Color]::Transparent
$lblAuthorId.Cursor = 'Hand'
$lblAuthorId.Add_Click({ Show-About })
$tipAbout.SetToolTip($lblAuthorId, '点一下看关于')
$form.Controls.Add($lblAuthorId)

if (Test-Path $logoPng) {
    $picFace = New-Object System.Windows.Forms.PictureBox
    $picFace.Location = New-Object System.Drawing.Point(502, 18)
    $picFace.Size = New-Object System.Drawing.Size(40, 40)
    $picFace.SizeMode = 'Zoom'
    $picFace.BackColor = [System.Drawing.Color]::Transparent
    $picFace.Cursor = 'Hand'
    try { $picFace.Image = [System.Drawing.Image]::FromFile($logoPng) } catch { }
    $picFace.Add_Click({ Show-About })
    $tipAbout.SetToolTip($picFace, '作者：梅川逸夫')
    $form.Controls.Add($picFace)
}

# ---- 输入区（白卡片，两行：学号 / 密码）----
$cardInput = New-Object System.Windows.Forms.Panel
$cardInput.Location = New-Object System.Drawing.Point(20, 84)
$cardInput.Size = New-Object System.Drawing.Size(524, 112)
$cardInput.BackColor = $clrCard
$cardInput.BorderStyle = 'FixedSingle'
$form.Controls.Add($cardInput)

$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Text = '学号'
$lblUser.Font = $fontCard
$lblUser.ForeColor = $clrMuted
$lblUser.Location = New-Object System.Drawing.Point(16, 18)
$lblUser.Size = New-Object System.Drawing.Size(52, 22)
$cardInput.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(72, 15)
$txtUser.Size = New-Object System.Drawing.Size(336, 26)
$txtUser.Font = $fontCard
$cardInput.Controls.Add($txtUser)

$lblPwd = New-Object System.Windows.Forms.Label
$lblPwd.Text = '密码'
$lblPwd.Font = $fontCard
$lblPwd.ForeColor = $clrMuted
$lblPwd.Location = New-Object System.Drawing.Point(16, 56)
$lblPwd.Size = New-Object System.Drawing.Size(52, 22)
$cardInput.Controls.Add($lblPwd)

$txtPwd = New-Object System.Windows.Forms.TextBox
$txtPwd.Location = New-Object System.Drawing.Point(72, 53)
$txtPwd.Size = New-Object System.Drawing.Size(336, 26)
$txtPwd.Font = $fontCard
$txtPwd.UseSystemPasswordChar = $true
$cardInput.Controls.Add($txtPwd)

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = '显示密码'
$chkShow.ForeColor = $clrMuted
$chkShow.Location = New-Object System.Drawing.Point(418, 54)
$chkShow.Size = New-Object System.Drawing.Size(96, 24)
$chkShow.Cursor = 'Hand'
$chkShow.Add_Click({ $txtPwd.UseSystemPasswordChar = -not $chkShow.Checked })
$cardInput.Controls.Add($chkShow)

# ---- 主操作：一个大按钮（一眼看到该点哪）----
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = '保存并安装'
$btnInstall.Location = New-Object System.Drawing.Point(20, 208)
$btnInstall.Size = New-Object System.Drawing.Size(524, 40)
$btnInstall.FlatStyle = 'Flat'
$btnInstall.FlatAppearance.BorderSize = 0
$btnInstall.FlatAppearance.MouseOverBackColor = $clrAccentHover
$btnInstall.BackColor = $clrAccent
$btnInstall.ForeColor = [System.Drawing.Color]::White
$btnInstall.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$btnInstall.Cursor = 'Hand'
$form.Controls.Add($btnInstall)

# ---- 次要操作：一行四个等宽按钮 ----
function New-SubButton {
    param([string]$Text, [int]$X, [int]$W)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, 258)
    $b.Size = New-Object System.Drawing.Size($W, 34)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $clrBorder
    $b.FlatAppearance.MouseOverBackColor = $clrBtnHover
    $b.BackColor = $clrCard
    $b.ForeColor = $clrText
    $b.Cursor = 'Hand'
    $form.Controls.Add($b)
    return $b
}
$btnTest      = New-SubButton '立即连接测试' 20 170
$btnStatus    = New-SubButton '查看状态'     198 112
$btnLog       = New-SubButton '打开日志'     318 112
$btnUninstall = New-SubButton '卸载'         438 106


# ---- 状态卡片（三行，各带颜色圆点：网络 / 自动连接 / 账号）----
$cardState = New-Object System.Windows.Forms.Panel
$cardState.Location = New-Object System.Drawing.Point(20, 306)
$cardState.Size = New-Object System.Drawing.Size(524, 92)
$cardState.BackColor = $clrCard
$cardState.BorderStyle = 'FixedSingle'
$form.Controls.Add($cardState)

$lblNet = New-Object System.Windows.Forms.Label
$lblNet.Text = '● 网络：检测中…'
$lblNet.Font = $fontCard
$lblNet.ForeColor = $clrMuted
$lblNet.Location = New-Object System.Drawing.Point(18, 14)
$lblNet.Size = New-Object System.Drawing.Size(488, 22)
$cardState.Controls.Add($lblNet)

$lblTask = New-Object System.Windows.Forms.Label
$lblTask.Text = '● 自动连接：检测中…'
$lblTask.Font = $fontCard
$lblTask.ForeColor = $clrMuted
$lblTask.Location = New-Object System.Drawing.Point(18, 40)
$lblTask.Size = New-Object System.Drawing.Size(488, 22)
$cardState.Controls.Add($lblTask)

$lblCred = New-Object System.Windows.Forms.Label
$lblCred.Text = '● 账号：检测中…'
$lblCred.Font = $fontCard
$lblCred.ForeColor = $clrMuted
$lblCred.Location = New-Object System.Drawing.Point(18, 66)
$lblCred.Size = New-Object System.Drawing.Size(488, 22)
$cardState.Controls.Add($lblCred)

# ---- 运行日志 ----
$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = '运行日志'
$lblLogTitle.Font = $fontNormal
$lblLogTitle.ForeColor = $clrMuted
$lblLogTitle.Location = New-Object System.Drawing.Point(20, 408)
$lblLogTitle.Size = New-Object System.Drawing.Size(200, 18)
$form.Controls.Add($lblLogTitle)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(20, 428)
$txtOut.Size = New-Object System.Drawing.Size(524, 152)
$txtOut.Multiline = $true
$txtOut.ReadOnly = $true
$txtOut.ScrollBars = 'Vertical'
$txtOut.BackColor = $clrCard
$txtOut.ForeColor = $clrText
$txtOut.BorderStyle = 'FixedSingle'
$txtOut.Font = $fontMono
$form.Controls.Add($txtOut)

# ---- 页脚 ----
$lblFp = New-Object System.Windows.Forms.Label
$lblFp.Text = '免费开源版 · 学号密码只存本机（Windows 加密）'
$lblFp.Location = New-Object System.Drawing.Point(20, 590)
$lblFp.Size = New-Object System.Drawing.Size(400, 18)
$lblFp.Font = $fontSmall
$lblFp.ForeColor = $clrMuted
$form.Controls.Add($lblFp)

$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = 'v' + $APP_VERSION
$lblVer.Location = New-Object System.Drawing.Point(420, 590)
$lblVer.Size = New-Object System.Drawing.Size(124, 18)
$lblVer.Font = $fontSmall
$lblVer.ForeColor = $clrMuted
$lblVer.TextAlign = 'MiddleRight'
$form.Controls.Add($lblVer)

function Write-Log2 {
    param([string]$Msg)
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $txtOut.AppendText("[$stamp] $Msg`r`n")
    # 日志框限长：超过 400 行就砍掉前面一半，避免越用越卡
    if ($txtOut.Lines.Count -gt 400) {
        $keep = $txtOut.Lines[($txtOut.Lines.Count - 200)..($txtOut.Lines.Count - 1)]
        $txtOut.Text = ($keep -join "`r`n")
    }
    $txtOut.SelectionStart = $txtOut.TextLength
    $txtOut.ScrollToCaret()
}

function Update-State {
    # 只读缓存，不启动任何进程 —— 所以点按钮、切换状态都是"瞬间"的
    $net = Get-NetState
    Start-TaskStateAsync          # 需要时在后台刷新（已缓存则立刻返回）
    $tsk = Get-TaskState
    $hasCred = [bool]($script:Summary -and $script:Summary.has_cred)
    $credState = [string]$(if ($script:Summary) { $script:Summary.cred_state } else { '' })

    $credText = '未保存'
    if ($hasCred) {
        if ($credState -eq 'dpapi') { $credText = '已保存（Windows 加密，开机自动连）' }
        else { $credText = '已保存（明文旧格式，重新保存一次即可加密）' }
    } elseif ($credState -eq 'undecryptable') {
        $credText = '账号文件解不开，请重新填写学号密码并保存'
    }

    $lblNet.Text  = '● 网络：' + $net.text
    $lblTask.Text = '● 自动连接：' + $tsk.text
    $lblCred.Text = '● 账号：' + $credText

    # 每行单独上色：绿=正常 / 橙=要注意 / 红=有问题 / 灰=还在检测
    $lblNet.ForeColor  = if ($net.ok -eq $true) { $clrOk } elseif ($net.ok -eq $false) { $clrWarn } else { $clrMuted }
    $lblTask.ForeColor = if ($tsk.ok -eq $true) { $clrOk } elseif ($tsk.ok -eq $false) { $clrWarn } else { $clrMuted }
    if ($credState -eq 'undecryptable') { $lblCred.ForeColor = $clrBad }
    elseif ($hasCred) { $lblCred.ForeColor = $clrOk }
    elseif ($script:Summary) { $lblCred.ForeColor = $clrWarn }
    else { $lblCred.ForeColor = $clrMuted }

    # 托盘图标的悬停提示跟着一起刷新（用户就是靠它判断状态的）
    if (Get-Command Update-TrayTip -ErrorAction SilentlyContinue) { Update-TrayTip }
}

# ---- 事件 ----

# ---- 验证之后的安装步骤（抽成函数，供后台回调调用）----
function Complete-Install {
    param([string]$user, [bool]$verified)
    # ---- 1) 复制到本机（程序文件 → %LOCALAPPDATA%\HTUAutoConnect）----
    $target = $null
    if (Get-Command Install-ToLocal -ErrorAction SilentlyContinue) {
        Write-Log2 '正在安装到本机…'
        try {
            $target = Install-ToLocal -SourceDir $root
            if ($root.TrimEnd('\') -ieq $target.TrimEnd('\')) {
                Write-Log2 ('当前就是安装目录：' + $target)
            } else {
                Write-Log2 ('已复制到：' + $target)
            }
        } catch {
            Write-Log2 ('复制失败：' + $_.Exception.Message)
            $target = $root
        }
    } else {
        $target = $root
    }

    # ---- 2) 注册开机自启任务（指向安装目录）----
    Write-Log2 '正在注册开机自启任务（会弹出管理员权限确认框，请点【是】）…'
    if ($target -and $target.TrimEnd('\') -ine $root.TrimEnd('\')) {
        $log = Register-ScheduledTaskElevated -AppDir $target
    } else {
        $log = Invoke-TaskScript
    }
    foreach ($line in ($log -split "`r?`n")) { if ($line.Trim()) { Write-Log2 $line } }

    # ---- 3) 桌面快捷方式 + 卸载条目 ----
    $lnkPath = $null
    if ($target -and (Get-Command New-DesktopShortcut -ErrorAction SilentlyContinue)) {
        try {
            $lnkPath = New-DesktopShortcut -TargetDir $target
            Write-Log2 ('已创建桌面快捷方式：' + $lnkPath)
        } catch { Write-Log2 ('创建快捷方式失败：' + $_.Exception.Message) }
        try {
            [void](Register-UninstallEntry -TargetDir $target)
            Write-Log2 ('已登记到「设置 → 应用」和「控制面板 → 程序和功能」（版本 v' + (Get-AppVersion) + '）')
        } catch { }
        try {
            $sm = New-StartMenuShortcut -TargetDir $target
            if ($sm) { Write-Log2 '已创建开始菜单快捷方式' }
        } catch { }
    }

    Start-TaskStateAsync -Force
    Write-Log2 '计划任务状态正在后台刷新…'
    Write-Log2 '安装完成 ✅'
    Update-State

    $msg = "安装完成！`r`n`r`n· 以后开机自动连校园网`r`n· 桌面出现【校园网自动连接】，双击可打开这个界面"
    if ($lnkPath -and $target -and $target.TrimEnd('\') -ine $root.TrimEnd('\')) {
        $msg += "`r`n`r`n程序已经复制到本机：`r`n$target`r`n`r`n所以现在这个文件夹（包括压缩包）都可以删掉了，不影响使用。"
    } elseif ($verified) {
        $msg += "`r`n`r`n（当前就在安装目录内运行，无需复制）"
    }
    [System.Windows.Forms.MessageBox]::Show($msg, '安装成功')
}

$btnInstall.Add_Click({
    Begin-Action $btnInstall '正在保存…'
    $user = $txtUser.Text.Trim()
    $pwd = $txtPwd.Text
    if (-not $user) { End-Actions; [System.Windows.Forms.MessageBox]::Show('请输入学号', '提示'); return }
    if (-not $pwd) { End-Actions; [System.Windows.Forms.MessageBox]::Show('请输入上网密码', '提示'); return }

    if (-not (Save-Cred -User $user -Password $pwd)) {
        End-Actions
        [System.Windows.Forms.MessageBox]::Show(
            "账号没能保存到本机，请看日志窗口里的原因。`r`n`r`n" +
            "常见原因：磁盘只读 / 杀毒软件拦截写入 / 程序目录被系统保护。",
            '保存失败', 'OK', 'Warning')
        return
    }
    Write-Log2 '正在验证账号密码…'
    # 这一步要联网（在校外会稍慢），放到后台跑，界面不卡；跑完自动继续安装
    $ok = Start-PyAsync -PyArgs @($mainPy, '--force') -BusyText '正在验证账号密码' -TimeoutSec 60 -OnDone {
        param($out, $code)
        foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { Write-Log2 $line } }
        $verified = ($out -match '认证成功' -or $out -match '已联网')
        if (-not $verified) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "认证没有成功。`r`n`r`n仍然要安装吗？（回到学校连上 WiFi 后会自动生效）",
                '认证未通过', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { Write-Log2 '已取消安装'; Update-State; return }
        }
        Complete-Install -user $user -verified $verified
    }
    if (-not $ok) { Write-Log2 '（已有操作在进行中）' }
})

$btnTest.Add_Click({
    Begin-Action $btnTest '正在测试…'
    Invoke-ConnectionTest
})

# ---- 下面两个抽成函数：主界面按钮和托盘菜单共用同一套逻辑 ----
function Invoke-ConnectionTest {
    Write-Log2 '开始连接测试…'
    [void](Start-PyAsync -PyArgs @($mainPy, '--force') -BusyText '正在测试连接' -TimeoutSec 60 -OnDone {
        param($out, $code)
        foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { Write-Log2 $line } }
        if ($code -eq 4) {
            Write-Log2 '提示：当前不在校园网（连不上认证服务器）。连着手机热点/家里网时这是正常的。'
        } elseif ($code -eq 3) {
            Write-Log2 '⚠ 账号文件解不开，请重新填写学号密码后点【保存并安装】'
            Update-SummaryAsync -Force
        }
        $script:NetState = $null      # 让状态栏重新检测
        Update-NetStateAsync
        Update-State
    })
}

function Invoke-StatusCheck {
    Start-TaskStateAsync           # 计划任务改后台查，界面不卡
    Write-Log2 '---- 状态检查 ----'
    $user = $txtUser.Text.Trim()
    if (-not $user) { $user = Read-CredUser }
    $tsk = Get-TaskState
    Write-Log2 ('计划任务：' + $tsk.text)
    Write-Log2 ('网络状态：' + (Get-NetState).text + '（后台检测中，几秒后自动刷新）')
    if (Test-Path $logFile) {
        Write-Log2 '最近日志：'
        foreach ($line in (Get-Content $logFile -Encoding UTF8 -Tail 8)) { Write-Log2 ('   ' + $line) }
    } else {
        Write-Log2 '（还没有日志文件）'
    }
    $script:NetState = $null
    Update-NetStateAsync
    Update-State
}

function Show-MainWindow {
    # 从托盘把主窗口叫回来（双击图标 / 菜单【打开界面】都走这里）
    try {
        $form.ShowInTaskbar = $true
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Show()
        $form.Activate()
        $form.BringToFront()
    } catch { }
}

function Hide-ToTray {
    # 最小化 -> 缩到托盘（窗口缩掉、任务栏不显示，托盘图标留着，用户能看出进程还活着）
    # ⚠ 踩坑：主窗口是用 ShowDialog() 显示的，对它调用 Hide() 会让模态消息循环直接退出
    #   —— 结果就是"一最小化整个程序就没了、托盘图标也没了"（实测复现过）。
    #   所以这里只能"缩到最小 + 从任务栏隐藏"，绝不能 Hide()。
    try {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        $form.ShowInTaskbar = $false
        if ($script:Tray -and -not $script:TrayExiting) {
            $script:Tray.Visible = $true
            $script:Tray.ShowBalloonTip(2500, '校园网自动连接',
                '已缩到托盘（右下角），双击图标可以打开界面。', [System.Windows.Forms.ToolTipIcon]::Info)
        }
        Write-Log2 '已缩到系统托盘（右下角图标还在）。双击图标可以重新打开界面。'
    } catch { }
}

function Exit-App {
    # 点 X / 托盘菜单【退出】：真正结束进程，并且保证托盘图标一起消失
    $script:TrayExiting = $true
    try {
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.ShowBalloonTip(3000, '校园网自动连接',
                '程序已退出，右下角图标会消失。' + "`r`n" +
                '开机自动连由计划任务负责，不受影响。', [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } catch { }
    try { if ($script:Tray) { $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
    try { $form.Close() } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}

$btnStatus.Add_Click({
    Begin-Action $btnStatus '检查中…'
    Invoke-StatusCheck
})

$btnLog.Add_Click({
    Begin-Action $btnLog '正在打开…'
    if (Test-Path $logFile) { Start-Process notepad.exe $logFile }
    else { [System.Windows.Forms.MessageBox]::Show('还没有日志文件（程序尚未运行过）', '提示') }
    End-Actions
})

$btnUninstall.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        '确定要卸载吗？将删除开机自启任务和保存的账号密码。', '确认卸载', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    Begin-Action $btnUninstall '正在卸载…'
    Write-Log2 '正在删除计划任务…'
    $log = Invoke-TaskScript -Uninstall
    foreach ($line in ($log -split "`r?`n")) { if ($line.Trim()) { Write-Log2 $line } }

    $removedCred = @()
    foreach ($cf in @($credFile, (Join-Path $root 'credentials.dat'), (Join-Path $root '.user'))) {
        if (Test-Path $cf) {
            Remove-Item $cf -Force -ErrorAction SilentlyContinue
            $removedCred += (Split-Path $cf -Leaf)
        }
    }
    if ($removedCred.Count -gt 0) {
        Write-Log2 ('已删除账号相关文件：' + ($removedCred -join '、') + '（账号密码不再保存在本机）')
        $txtUser.Clear(); $txtPwd.Clear()
    }

    $ans2 = [System.Windows.Forms.MessageBox]::Show('要顺便断开当前校园网认证吗？（便于测试重新连接）', '断开认证', 'YesNo', 'Question')
    if ($ans2 -eq 'Yes') {
        $r = Invoke-Py @($mainPy, '--logout')
        foreach ($line in ($r -split "`r?`n")) { if ($line.Trim()) { Write-Log2 $line } }
        Write-Log2 '已请求断开，本机现在处于未认证状态'
    }

    $ans3 = [System.Windows.Forms.MessageBox]::Show('要删除运行日志吗？（默认保留，便于排查问题）', '运行日志', 'YesNo', 'Question')
    if ($ans3 -eq 'Yes') {
        foreach ($f in @($logFile, "$logFile.1", (Join-Path $root '.last_heartbeat'), $installLog)) {
            if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
        Write-Log2 '已删除运行日志'
    } else {
        Write-Log2 '已保留运行日志'
    }

    # 如果之前装到了本机，一并清掉（桌面快捷方式 / 卸载条目 / 程序文件）
    if (Get-Command Get-InstallTarget -ErrorAction SilentlyContinue) {
        $target = Get-InstallTarget
        if ($target -and (Test-Path $target)) {
            if ($root.TrimEnd('\') -ieq $target.TrimEnd('\')) {
                Write-Log2 '当前正在运行安装版：程序文件夹需要手动删除'
                Write-Log2 ('   ' + $target)
            } else {
                $ans4 = [System.Windows.Forms.MessageBox]::Show(
                    "要一并删除安装到本机的程序文件吗？`r`n`r`n$target", '安装目录', 'YesNo', 'Question')
                if ($ans4 -eq 'Yes') {
                    try {
                        Remove-Item $target -Recurse -Force -ErrorAction Stop
                        Write-Log2 ('已删除安装目录：' + $target)
                    } catch {
                        Write-Log2 ('删除安装目录失败（可能有文件正在使用）：' + $_.Exception.Message)
                    }
                } else {
                    Write-Log2 '已保留安装目录'
                }
            }
        }
        if (Remove-DesktopShortcut) { Write-Log2 '已删除桌面快捷方式' }
        if (Remove-UninstallEntry) { Write-Log2 '已从「设置 → 应用」列表中移除' }
    }

    Write-Log2 '卸载完成。如需彻底清除，直接删除本文件夹即可。'
    Start-TaskStateAsync -Force          # 卸载后计划任务没了，后台重新查一次
    End-Actions
    Update-State
})

$form.Add_Shown({
    $u = Read-CredUser
    if ($u) {
        $txtUser.Text = $u
        Write-Log2 ("已检测到已保存的账号：{0}" -f $u)
    } else {
        Write-Log2 ('河南师范大学 校园网自动连接  v' + $APP_VERSION + '  by ' + $AUTHOR_NAME + '（免费开源）')
        Write-Log2 '欢迎使用！请填写：学号 → 上网密码，然后点【保存并安装】。'
        Write-Log2 '（密码默认隐藏，可勾选“显示密码”核对；账号密码只保存在本机）'
    }

    if (Get-Command Get-InstallTarget -ErrorAction SilentlyContinue) {
        $t = Get-InstallTarget
        if ($t -and (Test-Path $t)) {
            if ($root.TrimEnd('\') -ieq $t.TrimEnd('\')) {
                Write-Log2 '（当前运行的是安装到本机的版本）'
            } else {
                Write-Log2 ('（本机已安装一份：' + $t + '，点【保存并安装】可更新它）')
            }
        }
    }

    # 界面先显示出来，信息后台去取
    Write-Log2 '正在读取本机信息…'
    Start-TaskStateAsync            # 计划任务状态放后台查（不卡界面）
    Update-State
    Update-SummaryAsync -Force      # 一次后台调用取回：学号/密码/网络
})

# summary 取回来之后的收尾提示（回填 + 体检结论）
$script:SummaryReported = $false
function Report-Summary {
    if ($script:SummaryReported -or -not $script:Summary) { return }
    $script:SummaryReported = $true
    $s = $script:Summary
    if ($s.pwd) { Write-Log2 '已回填本机保存的密码（打码显示，勾"显示密码"可以核对）' }

    switch ([string]$s.cred_state) {
        'dpapi' {
            Write-Log2 '账号文件：已用 Windows 加密保存（只有本机当前 Windows 用户能解开）'
        }
        'plain' {
            Write-Log2 '账号文件：检测到 v1.0.0 的明文格式，已自动升级为加密保存'
        }
        'undecryptable' {
            Write-Log2 '⚠ 账号文件解不开（credentials.dat）：换了电脑 / 换了 Windows 用户 / 文件被改动过'
            Write-Log2 '   请重新输入学号和上网密码，点【保存并安装】即可恢复（坏文件会被覆盖）'
            [void][System.Windows.Forms.MessageBox]::Show(
                "本机保存的账号文件解不开了。`r`n`r`n" +
                "常见原因：`r`n" +
                "· 把程序文件夹从别的电脑复制过来的`r`n" +
                "· 换了 Windows 登录账户`r`n" +
                "· 文件被工具软件改动过`r`n`r`n" +
                "解决办法：重新输入一次学号和上网密码，点【保存并安装】。`r`n`r`n" +
                "（这是加密的正常表现：账号只在这台电脑的这个 Windows 账户里能解开）",
                '账号需要重新填写', 'OK', 'Warning')
        }
        default {
            Write-Log2 '（本机还没保存账号密码，首次使用请填学号和密码）'
        }
    }
}

# ---------------- 布局自检（自动化测试用）----------------
if ($LayoutCheck) {
    $cs = $form.ClientSize
    Write-Host ("窗口客户区 : {0} x {1}" -f $cs.Width, $cs.Height)
    $ctl = @($form.Controls)
    Write-Host ("控件数量   : {0}" -f $ctl.Count)
    $bad = 0
    foreach ($c in $ctl) {
        $r = $c.Bounds
        if ($r.Left -lt 0 -or $r.Top -lt 0 -or $r.Right -gt $cs.Width -or $r.Bottom -gt $cs.Height) {
            $txt = if ($c.PSObject.Properties['Text']) { $c.Text } else { '' }
            Write-Host ("  [越界] {0,-12} {1,-28} x={2} y={3} w={4} h={5}" -f `
                $c.GetType().Name, $txt, $r.X, $r.Y, $r.Width, $r.Height) -ForegroundColor Yellow
            $bad++
        }
    }
    for ($i = 0; $i -lt $ctl.Count; $i++) {
        for ($j = $i + 1; $j -lt $ctl.Count; $j++) {
            $a = $ctl[$i]; $b = $ctl[$j]
            $ra = $a.Bounds; $rb = $b.Bounds
            $ix = [Math]::Min($ra.Right, $rb.Right) - [Math]::Max($ra.Left, $rb.Left)
            $iy = [Math]::Min($ra.Bottom, $rb.Bottom) - [Math]::Max($ra.Top, $rb.Top)
            if ($ix -gt 0 -and $iy -gt 0) {
                $ta = if ($a.PSObject.Properties['Text']) { $a.Text } else { '' }
                $tb = if ($b.PSObject.Properties['Text']) { $b.Text } else { '' }
                Write-Host ("  [重叠] {0}({1}) <-> {2}({3})  重叠 {4}x{5}px" -f `
                    $a.GetType().Name, $ta, $b.GetType().Name, $tb, $ix, $iy) -ForegroundColor Yellow
                $bad++
            }
        }
    }
    if ($bad -eq 0) { Write-Host "布局自检通过：没有越界、没有重叠" -ForegroundColor Green }
    else { Write-Host ("布局自检发现问题：{0} 处" -f $bad) -ForegroundColor Red }
    Write-Host "布局自检完成"
    exit 0
}

# ================= 系统托盘图标（v1.3.0 新增）=================
# 用户需求："希望右下角有个状态栏图标，看我到底关了进程没有"
#   · 进程活着就有图标；进程一退出图标立刻消失 —— 这就是"关没关"的判据
#   · 双击图标 = 打开并激活主窗口
#   · 右键菜单：打开界面 / 立即连接测试 / 查看状态 / 退出
#   · 悬停提示跟随 Update-State 实时刷新
#   · 关闭行为明确：点 X = 真正退出（并给一次气泡说明）；最小化 = 缩到托盘
$script:Tray = $null
$script:TrayExiting = $false
$script:TrayTip = '校园网自动连接'

function Get-TrayTipText {
    $net = ''
    $tsk = ''
    try { $net = (Get-NetState).text } catch { }
    try { $tsk = (Get-TaskState).text } catch { }
    if (-not $net) { $net = '检测中' }
    if (-not $tsk) { $tsk = '检测中' }
    $tip = '校园网自动连接 v' + $APP_VERSION + ' ｜ 网络：' + $net + ' ｜ 自动连接：' + $tsk
    # 托盘提示有长度上限（约 127 字符），超了会显示异常，这里截断
    if ($tip.Length -gt 120) { $tip = $tip.Substring(0, 120) }
    return $tip
}

function Update-TrayTip {
    if (-not $script:Tray) { return }
    try {
        $tip = Get-TrayTipText
        $script:TrayTip = $tip
        $script:Tray.Text = $tip
    } catch { }
}

try {
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $trayIconPath = Join-Path $root 'logo.ico'
    if (Test-Path $trayIconPath) {
        $script:Tray.Icon = New-Object System.Drawing.Icon($trayIconPath)
    } else {
        $script:Tray.Icon = [System.Drawing.SystemIcons]::Application
    }
    $script:Tray.Text = '校园网自动连接 v' + $APP_VERSION
    $script:Tray.Visible = $true          # 进程活着 → 图标就在

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $trayMenu.Items.Add('打开界面')
    $miOpen.Add_Click({ Show-MainWindow })
    $miTest = $trayMenu.Items.Add('立即连接测试')
    $miTest.Add_Click({ Invoke-ConnectionTest })
    $miStatus = $trayMenu.Items.Add('查看状态')
    $miStatus.Add_Click({ Invoke-StatusCheck })
    [void]$trayMenu.Items.Add('-')
    $miExit = $trayMenu.Items.Add('退出')
    $miExit.Add_Click({ Exit-App })
    $script:Tray.ContextMenuStrip = $trayMenu

    # 双击图标 = 显示并激活主窗口
    $script:Tray.Add_DoubleClick({ Show-MainWindow })
    # 单击也把窗口叫回来（很多人习惯单击；右键仍是菜单）
    $script:Tray.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-MainWindow }
    })
} catch {
    # 托盘建不起来也不能让界面挂掉
    Write-Log2 ('托盘图标创建失败（不影响其它功能）：' + $_.Exception.Message)
    $script:Tray = $null
}

# 最小化 = 缩到托盘（窗口隐藏、图标保留）
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        Hide-ToTray
    }
})

# 点右上角 X = 真正退出进程（退出后托盘图标消失），并给一次说明
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:TrayExiting) { return }
    $script:TrayExiting = $true
    try {
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.ShowBalloonTip(3000, '校园网自动连接',
                '程序已退出，右下角图标会消失。' + "`r`n" +
                '开机自动连由计划任务负责，不受影响（想连上网不受影响）。',
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } catch { }
    try { if ($script:Tray) { $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
    Write-Log2 '已退出（托盘图标已移除）。开机自动连由计划任务负责，不受影响。'
})

try {
    # ⚠ 这里从 ShowDialog() 改成 Application::Run()：
    #   ShowDialog 是"模态对话框"循环，对它调 Hide() 或者缩到最小 + 隐藏任务栏按钮，
    #   模态循环会直接退出 —— 表现为"一最小化整个程序就没了"（实测复现过）。
    #   Application::Run 是标准消息循环，托盘程序必须用它，缩到托盘后进程能继续活着。
    #   界面本身没有任何"对话框语义"的用法，换成 Run 对其它功能没有影响。
    [System.Windows.Forms.Application]::Run($form)
} finally {
    # 兜底：无论怎么退出，都不留"幽灵托盘图标"
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
}
