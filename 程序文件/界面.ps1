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
    # 计划任务查询有几十毫秒开销，缓存 5 秒，避免每次刷新都查
    if ($script:TaskState -and ((Get-Date) - $script:TaskTime).TotalSeconds -lt 5) {
        return $script:TaskState
    }
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { $script:TaskState = @{ ok = $false; text = '未安装' } }
    else {
        $i = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        $script:TaskState = @{ ok = $true; text = ('已安装（{0} / 上次结果 {1}）' -f $t.State, $i.LastTaskResult) }
    }
    $script:TaskTime = Get-Date
    return $script:TaskState
}

function Invoke-TaskScript {
    param([switch]$Uninstall)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                 '-File', "`"$taskPs1`"", '-PythonExe', "`"$pyExe`"")
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

$APP_VERSION = '1.1.0'
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
    $tsk = Get-TaskState
    Write-Host ("任务状态  : {0}" -f $tsk.text)
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
    if ($script:PyJobs.Count -eq 0) { $script:PyTimer.Stop(); return }
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

$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$fontNormal = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = '河南师范大学 校园网自动连接 v' + $APP_VERSION
$form.Size = New-Object System.Drawing.Size(580, 648)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $fontNormal

# ---- 窗口/任务栏图标（logo.ico 存在才设置，缺失不影响使用）----
$logoIco = Join-Path $root 'logo.ico'
$logoPng = Join-Path $root 'logo.png'
if (Test-Path $logoIco) {
    try { $form.Icon = New-Object System.Drawing.Icon($logoIco) } catch { }
}

# ---- 左上角个人 Logo ----
if (Test-Path $logoPng) {
    $picLogo = New-Object System.Windows.Forms.PictureBox
    $picLogo.Location = New-Object System.Drawing.Point(20, 12)
    $picLogo.Size = New-Object System.Drawing.Size(54, 54)
    $picLogo.SizeMode = 'Zoom'
    try { $picLogo.Image = [System.Drawing.Image]::FromFile($logoPng) } catch { }
    $form.Controls.Add($picLogo)
}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '校园网自动连接'
$lblTitle.Font = $fontTitle
$lblTitle.Location = New-Object System.Drawing.Point(88, 14)
$lblTitle.Size = New-Object System.Drawing.Size(300, 30)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '开机自动认证 · 断网自动重连 · 后台静默运行'
$lblSub.ForeColor = [System.Drawing.Color]::Gray
$lblSub.Location = New-Object System.Drawing.Point(90, 46)
$lblSub.Size = New-Object System.Drawing.Size(340, 20)
$form.Controls.Add($lblSub)

# ---- 右上角：作者卡片（头像 + 昵称 + 学号，点一下看关于）----
$tipAbout = New-Object System.Windows.Forms.ToolTip
$lblAuthor = New-Object System.Windows.Forms.Label
$lblAuthor.Text = $AUTHOR_NAME
$lblAuthor.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$lblAuthor.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$lblAuthor.Location = New-Object System.Drawing.Point(480, 16)
$lblAuthor.Size = New-Object System.Drawing.Size(80, 22)
$lblAuthor.Cursor = 'Hand'
$lblAuthor.Add_Click({ Show-About })
$tipAbout.SetToolTip($lblAuthor, '作者：梅川逸夫 —— 点一下看关于')
$form.Controls.Add($lblAuthor)

$lblAuthorId = New-Object System.Windows.Forms.Label
$lblAuthorId.Text = '免费开源'
$lblAuthorId.Font = New-Object System.Drawing.Font('Consolas', 9)
$lblAuthorId.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$lblAuthorId.Location = New-Object System.Drawing.Point(481, 38)
$lblAuthorId.Size = New-Object System.Drawing.Size(80, 18)
$lblAuthorId.Cursor = 'Hand'
$lblAuthorId.Add_Click({ Show-About })
$tipAbout.SetToolTip($lblAuthorId, '点一下看关于')
$form.Controls.Add($lblAuthorId)

if (Test-Path $logoPng) {
    $picFace = New-Object System.Windows.Forms.PictureBox
    $picFace.Location = New-Object System.Drawing.Point(430, 14)
    $picFace.Size = New-Object System.Drawing.Size(46, 46)
    $picFace.SizeMode = 'Zoom'
    $picFace.Cursor = 'Hand'
    try { $picFace.Image = [System.Drawing.Image]::FromFile($logoPng) } catch { }
    $picFace.Add_Click({ Show-About })
    $tipAbout.SetToolTip($picFace, '作者：梅川逸夫')
    $form.Controls.Add($picFace)
}

$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Text = '学号：'
$lblUser.Location = New-Object System.Drawing.Point(22, 78)
$lblUser.Size = New-Object System.Drawing.Size(60, 22)
$form.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(84, 75)
$txtUser.Size = New-Object System.Drawing.Size(300, 24)
$form.Controls.Add($txtUser)

$lblPwd = New-Object System.Windows.Forms.Label
$lblPwd.Text = '密码：'
$lblPwd.Location = New-Object System.Drawing.Point(22, 112)
$lblPwd.Size = New-Object System.Drawing.Size(60, 22)
$form.Controls.Add($lblPwd)

$txtPwd = New-Object System.Windows.Forms.TextBox
$txtPwd.Location = New-Object System.Drawing.Point(84, 109)
$txtPwd.Size = New-Object System.Drawing.Size(300, 24)
$txtPwd.UseSystemPasswordChar = $true
$form.Controls.Add($txtPwd)

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = '显示密码'
$chkShow.Location = New-Object System.Drawing.Point(394, 110)
$chkShow.Size = New-Object System.Drawing.Size(110, 24)
$chkShow.Add_Click({ $txtPwd.UseSystemPasswordChar = -not $chkShow.Checked })
$form.Controls.Add($chkShow)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = '保存并安装'
$btnInstall.Location = New-Object System.Drawing.Point(22, 150)
$btnInstall.Size = New-Object System.Drawing.Size(150, 34)
$form.Controls.Add($btnInstall)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = '立即连接测试'
$btnTest.Location = New-Object System.Drawing.Point(182, 182)
$btnTest.Size = New-Object System.Drawing.Size(150, 34)
$form.Controls.Add($btnTest)

$btnStatus = New-Object System.Windows.Forms.Button
$btnStatus.Text = '查看状态'
$btnStatus.Location = New-Object System.Drawing.Point(342, 182)
$btnStatus.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($btnStatus)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = '打开日志'
$btnLog.Location = New-Object System.Drawing.Point(452, 182)
$btnLog.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($btnLog)

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = '卸载'
$btnUninstall.Location = New-Object System.Drawing.Point(22, 224)
$btnUninstall.Size = New-Object System.Drawing.Size(118, 28)
$form.Controls.Add($btnUninstall)


$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(22, 262)
$txtOut.Size = New-Object System.Drawing.Size(530, 226)
$txtOut.Multiline = $true
$txtOut.ReadOnly = $true
$txtOut.ScrollBars = 'Vertical'
$txtOut.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtOut.Font = $fontMono
$form.Controls.Add($txtOut)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Text = '正在检测…'
$lblState.Location = New-Object System.Drawing.Point(22, 496)
$lblState.Size = New-Object System.Drawing.Size(530, 44)
$form.Controls.Add($lblState)
$lblState.BringToFront()

# ---- 底部：本机指纹 + 一键复制（按钮紧贴内容，方便操作）----
$lblFp = New-Object System.Windows.Forms.Label
$lblFp.Text = '免费开源版 · 学号密码只存本机'
$lblFp.Location = New-Object System.Drawing.Point(22, 548)
$lblFp.Size = New-Object System.Drawing.Size(326, 26)
$lblFp.Font = $fontNormal
$form.Controls.Add($lblFp)
$lblFp.BringToFront()

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

    $l1 = '网络：{0}      自动连接：{1}' -f $net.text, $tsk.text
    $l2 = '账号：{0}' -f $credText
    $lblState.Text = $l1 + "`r`n" + $l2

    if ($credState -eq 'undecryptable') { $lblState.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30) }
    elseif ($hasCred) { $lblState.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0) }
    elseif ($script:Summary) { $lblState.ForeColor = [System.Drawing.Color]::FromArgb(190, 60, 0) }
    else { $lblState.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60) }
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

    $tsk = Get-TaskState
    Write-Log2 ('计划任务：' + $tsk.text)
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
    $user = $txtUser.Text.Trim()
    $pwd = $txtPwd.Text
    if (-not $user) { [System.Windows.Forms.MessageBox]::Show('请输入学号', '提示'); return }
    if (-not $pwd) { [System.Windows.Forms.MessageBox]::Show('请输入上网密码', '提示'); return }

    if (-not (Save-Cred -User $user -Password $pwd)) {
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
})

$btnStatus.Add_Click({
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
})

$btnLog.Add_Click({
    if (Test-Path $logFile) { Start-Process notepad.exe $logFile }
    else { [System.Windows.Forms.MessageBox]::Show('还没有日志文件（程序尚未运行过）', '提示') }
})

$btnUninstall.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        '确定要卸载吗？将删除开机自启任务和保存的账号密码。', '确认卸载', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

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

[void]$form.ShowDialog()
