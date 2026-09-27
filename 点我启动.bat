@echo off
chcp 936 >nul
title 河南师范大学 校园网自动连接
cd /d "%~dp0程序文件"

set "PYW=%~dp0程序文件\runtime\pythonw.exe"
if exist "%PYW%" goto run

rem ---- 没有内置运行库时，退回系统 Python ----
where pythonw >nul 2>nul
if errorlevel 1 goto nopython
set "PYW=pythonw"
echo   [i] 未找到内置运行库，改用系统 Python 启动

:run
start "" "%PYW%" "启动界面.py"
exit /b 0

:nopython
echo.
echo   [X] 没找到内置运行库 runtime\，也没找到系统 Python
echo.
echo   你可能是直接从 GitHub 下载的源码。解决办法任选一种：
echo     1^) 下载 Release 里的完整发布包（自带运行库，推荐）
echo     2^) 自己安装 Python 3.8 以上，安装时勾选 Add Python to PATH
echo.
pause
exit /b 1
