@echo off
chcp 936 >nul
title 校园网自动连接 - 状态检查与手动测试
cd /d "%~dp0"

echo ============================================================
echo     校园网自动连接 - 状态检查 / 手动测试
echo ============================================================
echo.

set "PYEXE="
for /f "delims=" %%i in ('py -3 -c "import sys;print(sys.executable)" 2^>nul') do set "PYEXE=%%i"
if not defined PYEXE (
    for /f "delims=" %%i in ('python -c "import sys;print(sys.executable)" 2^>nul') do (
        echo %%i | findstr /i "WindowsApps" >nul || set "PYEXE=%%i"
    )
)
if not defined PYEXE (
    for %%p in (
        "%LOCALAPPDATA%\Programs\Python\Python313\python.exe"
        "%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
        "%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
        "%LOCALAPPDATA%\Programs\Python\Python310\python.exe"
        "%LOCALAPPDATA%\Programs\Python\Python39\python.exe"
        "C:\software\miniconda3\python.exe"
        "C:\ProgramData\anaconda3\python.exe"
        "%USERPROFILE%\anaconda3\python.exe"
        "%USERPROFILE%\miniconda3\python.exe"
    ) do (
        if not defined PYEXE if exist "%%~p" set "PYEXE=%%~p"
    )
)

echo   [1] 计划任务状态
echo   ------------------------------------------------------------
schtasks /query /tn "HTU Campus AutoConnect" /v /fo LIST 2>nul | findstr /i "任务名 状态 上次运行时间 上次结果 下次运行时间 要运行的任务"
if errorlevel 1 echo     [X] 没有找到计划任务（可能尚未安装，或安装失败）
echo.

echo   [2] 强制认证一次（立即测试能否连上校园网）
echo   ------------------------------------------------------------
if defined PYEXE (
    "%PYEXE%" "%~dp0AutoConnect_htu.py" --force
) else (
    echo     [X] 没有检测到 Python
)
echo.

echo   [3] 当前网络状态
echo   ------------------------------------------------------------
if defined PYEXE "%PYEXE%" "%~dp0AutoConnect_htu.py"
echo.

echo   [4] 最近日志（最后 12 行）
echo   ------------------------------------------------------------
if exist "%~dp0autoconnect.log" (
    powershell -NoProfile -Command "Get-Content -LiteralPath '%~dp0autoconnect.log' -Tail 12 -Encoding UTF8"
) else (
    echo     （还没有日志文件，说明程序尚未运行过）
)

echo.
echo ============================================================
echo   判断标准：
echo     [1] 任务"状态"= 就绪(Ready) 且"上次结果"= 0x0  → 任务正常
echo     [2] 出现 [OK] 认证成功 或 当前已联网，无需认证   → 功能正常
echo ============================================================
pause