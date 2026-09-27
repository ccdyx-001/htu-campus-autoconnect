@echo off
chcp 936 >nul
title 卸载 校园网自动连接
cd /d "%~dp0程序文件"

if not exist "卸载程序.py" (
    echo   [X] 找不到卸载程序.py，请确认「程序文件」文件夹完整
    pause
    exit /b 1
)

set "PY=%~dp0程序文件\runtime\python.exe"
if exist "%PY%" goto run
where python >nul 2>nul
if errorlevel 1 goto nopython
set "PY=python"
echo   [i] 未找到内置运行库，改用系统 Python

:run
"%PY%" "卸载程序.py"
pause
exit /b 0

:nopython
echo   [X] 找不到 Python，无法运行卸载程序
echo   （也可以手动删除计划任务「HTU Campus AutoConnect」）
pause
exit /b 1
