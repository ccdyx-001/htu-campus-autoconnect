<#
============================================================
 校园网自动连接 - 计划任务注册/卸载脚本
 由 install.bat 自动调用；脚本会自行请求管理员权限

 参数：
   -PythonExe <路径>   指定 Python 解释器（install.bat 自动传入）
   -TaskName  <名称>   计划任务名称（默认 HTU Campus AutoConnect）
   -Uninstall          卸载：删除计划任务

 说明：文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1
       读取中文会乱码（安装包里已处理）。
============================================================
#>
param(
    [string]$PythonExe = "",
    [string]$TaskName = "HTU Campus AutoConnect",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$logPath = Join-Path $scriptDir "install_log.txt"

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 自提权 ----------
if (-not (Test-Admin)) {
    Write-Host "需要管理员权限，正在请求提权（请在弹窗中点击 [是]）..." -ForegroundColor Yellow
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"",
                 "-TaskName", "`"$TaskName`"")
    if ($PythonExe) { $argList += @("-PythonExe", "`"$PythonExe`"") }
    if ($Uninstall) { $argList += "-Uninstall" }
    Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
    if (Test-Path $logPath) { Get-Content $logPath -Encoding UTF8 | Select-Object -Last 15 }
    exit
}

if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }

# ---------- 卸载 ----------
if ($Uninstall) {
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log "[OK] 已删除计划任务：$TaskName"
        } else {
            Write-Log "[i] 计划任务不存在，无需删除"
        }
    } catch {
        Write-Log "[X] 删除失败：$($_.Exception.Message)"
        exit 1
    }
    exit 0
}

# ---------- 安装 ----------
try {
    if (-not $PythonExe -or -not (Test-Path $PythonExe)) { throw "未指定有效的 Python 解释器：$PythonExe" }

    $pythonw = Join-Path (Split-Path $PythonExe -Parent) "pythonw.exe"
    $exe = if (Test-Path $pythonw) { $pythonw } else { $PythonExe }

    $mainScript = Join-Path $scriptDir "AutoConnect_htu.py"
    if (-not (Test-Path $mainScript)) { throw "找不到主脚本：$mainScript" }
    if (-not (Test-Path (Join-Path $scriptDir "credentials.env"))) { throw "还没有配置账号密码，请先运行 install.bat" }

    $action = New-ScheduledTaskAction -Execute $exe -Argument "`"$mainScript`"" -WorkingDirectory $scriptDir

    # 触发器1：登录进桌面时立刻认证
    $t1 = New-ScheduledTaskTrigger -AtLogOn
    # 触发器2：每 1 分钟检查一次，断网自动重连
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 1) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $t1, $t2 -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log "[OK] 计划任务已注册：$TaskName"
    Write-Log "     执行程序：$exe"
    Write-Log "     脚本路径：$mainScript"
    Write-Log "     触发条件：登录时 + 每 1 分钟检查"

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 6
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Log ("[OK] 试运行结果：LastTaskResult={0}  (0 = 成功)" -f $info.LastTaskResult)
} catch {
    Write-Log "[X] 安装失败：$($_.Exception.Message)"
    exit 1
}
