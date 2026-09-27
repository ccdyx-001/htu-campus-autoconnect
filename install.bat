@echo off
chcp 936 >nul
setlocal
title 河南师范大学 校园网自动连接 - 安装程序
cd /d "%~dp0"

echo ============================================================
echo     河南师范大学  校园网自动连接  -  安装程序
echo ============================================================
echo.
echo  功能：开机自动认证 + 断网自动重连（后台运行，无窗口）
echo  账号密码只保存在本机，不会上传任何服务器
echo.
echo ------------------------------------------------------------
echo  [1/3] 检查 Python 环境
echo ------------------------------------------------------------

set "PYEXE="

rem 方式1：Python 启动器（py -3）
for /f "delims=" %%i in ('py -3 -c "import sys;print(sys.executable)" 2^>nul') do set "PYEXE=%%i"

rem 方式2：PATH 里的 python（排除微软商店的占位程序）
if not defined PYEXE (
    for /f "delims=" %%i in ('python -c "import sys;print(sys.executable)" 2^>nul') do (
        echo %%i | findstr /i "WindowsApps" >nul || set "PYEXE=%%i"
    )
)

rem 方式3：常见安装位置
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

if not defined PYEXE (
    echo.
    echo   [X] 没有检测到 Python，无法继续。
    echo.
    echo       请先安装 Python 3.8 或更高版本：
    echo         https://www.python.org/downloads/
    echo.
    echo       ^(安装时务必勾选 "Add Python to PATH"^)
    echo.
    pause
    exit /b 1
)

"%PYEXE%" -c "print(1)" >nul 2>nul
if errorlevel 1 (
    echo   [X] 检测到的 Python 无法运行：%PYEXE%
    pause
    exit /b 1
)

echo   [OK] Python：%PYEXE%
echo.

echo ------------------------------------------------------------
echo  [2/3] 配置校园网账号
echo ------------------------------------------------------------
echo.

"%PYEXE%" "%~dp0AutoConnect_htu.py" --setup
if errorlevel 1 (
    echo.
    echo   [X] 账号配置未完成，安装中止。
    echo.
    pause
    exit /b 1
)

echo.
echo ------------------------------------------------------------
echo  [3/3] 注册开机自启任务
echo ------------------------------------------------------------
echo.
echo   即将弹出管理员权限确认框，请点击 [是]
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_task.ps1" -PythonExe "%PYEXE%"

echo.
echo ============================================================
echo     安装完成！
echo ============================================================
echo.
echo   · 以后开机自动认证、断网自动重连，你不需要做任何操作
echo   · 日志文件：autoconnect.log（出问题时看这个）
echo   · 重新配置账号：再次运行 install.bat
echo   · 卸载：运行 uninstall.bat
echo.
pause
