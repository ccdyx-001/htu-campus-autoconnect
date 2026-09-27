<#
================================================================
 安装模块：把软件安装到本机（%LOCALAPPDATA%\HTUAutoConnect）
================================================================
 供 界面.ps1 调用，也可以单独调用做测试。

 安装后：
   · 运行文件在 %LOCALAPPDATA%\HTUAutoConnect\
   · 计划任务指向该目录
   · 桌面出现"校园网自动连接"快捷方式
   · 在 设置 → 应用 里出现可卸载条目
   · 原来下载的文件夹可以随时删除
================================================================
#>

function Get-InstallTarget {
    return (Join-Path $env:LOCALAPPDATA 'HTUAutoConnect')
}

function Install-ToLocal {
    param([string]$SourceDir)
    $target = Get-InstallTarget
    if ($SourceDir.TrimEnd('\') -ieq $target.TrimEnd('\')) {
        return $target            # 已经在安装目录里运行
    }
    $skip = @('autoconnect.log', 'autoconnect.log.1', 'install_log.txt', '.last_heartbeat', '__pycache__')
    # 本机的账号文件必须保留，否则"同步程序文件"会把已保存的学号密码冲掉
    $userData = @('credentials.dat', 'credentials.env', '.user', 'license.key', '.license_state')
    $keep = @{}
    if (Test-Path $target) {
        foreach ($f in $userData) {
            $p = Join-Path $target $f
            if (Test-Path $p) {
                try { $keep[$f] = [System.IO.File]::ReadAllBytes($p) } catch { }
            }
        }
        Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Get-ChildItem $SourceDir -Force | Where-Object { $skip -notcontains $_.Name } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name) -Recurse -Force
    }
    foreach ($f in $keep.Keys) {
        try { [System.IO.File]::WriteAllBytes((Join-Path $target $f), $keep[$f]) } catch { }
    }
    return $target
}

function New-DesktopShortcut {
    param([string]$TargetDir)
    $ws = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop '校园网自动连接.lnk'
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $TargetDir 'runtime\pythonw.exe'
    $lnk.Arguments = '"' + (Join-Path $TargetDir '启动界面.py') + '"'
    $lnk.WorkingDirectory = $TargetDir
    if (Test-Path (Join-Path $TargetDir 'logo.ico')) {
        $lnk.IconLocation = (Join-Path $TargetDir 'logo.ico')
    }
    $lnk.Description = '河南师范大学 校园网自动连接'
    $lnk.Save()
    return $lnkPath
}

function Remove-DesktopShortcut {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop '校园网自动连接.lnk'
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Register-UninstallEntry {
    param([string]$TargetDir)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HTUAutoConnect'
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name DisplayName -Value '河南师范大学 校园网自动连接'
    Set-ItemProperty -Path $key -Name DisplayVersion -Value '1.0'
    Set-ItemProperty -Path $key -Name Publisher -Value 'CWC'
    Set-ItemProperty -Path $key -Name InstallLocation -Value $TargetDir
    if (Test-Path (Join-Path $TargetDir 'logo.ico')) {
        Set-ItemProperty -Path $key -Name DisplayIcon -Value (Join-Path $TargetDir 'logo.ico')
    }
    $py = Join-Path $TargetDir 'runtime\python.exe'
    $un = Join-Path $TargetDir '卸载程序.py'
    Set-ItemProperty -Path $key -Name UninstallString -Value ('"' + $py + '" "' + $un + '"')
    Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord
    return $key
}

function Remove-UninstallEntry {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HTUAutoConnect'
    if (Test-Path $key) {
        Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Register-ScheduledTaskElevated {
    param([string]$AppDir)
    $ps1 = Join-Path $AppDir 'setup_task.ps1'
    $py = Join-Path $AppDir 'runtime\python.exe'
    if (-not (Test-Path $ps1)) { return '找不到 setup_task.ps1' }
    $log = Join-Path $AppDir 'install_log.txt'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$ps1`"", '-PythonExe', "`"$py`""
    ) -Wait
    if (Test-Path $log) {
        return (Get-Content $log -Encoding UTF8 | Select-Object -Last 6) -join "`r`n"
    }
    return '（没有拿到安装日志）'
}
