@echo off
chcp 936 >nul
title 校园网自动连接 - 手动测试与诊断
cd /d "%~dp0"
set "PY=%~dp0runtime\python.exe"
if not exist "%PY%" set "PY=python"

echo ============================================================
echo     校园网自动连接 - 手动测试 / 诊断
echo ============================================================
echo.
echo   [1] 当前网络状态
echo   ------------------------------------------------------------
"%PY%" "AutoConnect_htu.py" --status
echo.
echo   [2] 账号状态
echo   ------------------------------------------------------------
"%PY%" "AutoConnect_htu.py" --info
echo.
echo   [3] 开机自启任务
echo   ------------------------------------------------------------
schtasks /query /tn "HTU Campus AutoConnect" /fo LIST 2>nul | findstr /i "任务名 状态 下次 上次 要运行"
if errorlevel 1 echo    （没有找到计划任务：还没安装过，或者已经被卸载）
echo.
echo   [4] 强制认证一次（测试用）
echo   ------------------------------------------------------------
choice /c yn /t 10 /d n /m "   现在强制认证一次吗？(y/N) "
if errorlevel 2 goto skipauth
"%PY%" "AutoConnect_htu.py" --force
goto afterauth
:skipauth
echo    已跳过
:afterauth
echo.
echo   [5] 最近日志
echo   ------------------------------------------------------------
if exist "autoconnect.log" (
    "%PY%" -c "import io;print(''.join(io.open('autoconnect.log',encoding='utf-8',errors='replace').readlines()[-15:]))"
) else (
    echo    （还没有日志文件，程序可能还没运行过）
)
echo.
echo ============================================================
pause
