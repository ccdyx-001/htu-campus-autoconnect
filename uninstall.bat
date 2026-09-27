@echo off
chcp 936 >nul
title 卸载 校园网自动连接
cd /d "%~dp0"
set "LOGSTATUS=已保留"

echo ============================================================
echo     卸载 校园网自动连接
echo ============================================================
echo.
echo  将要执行：
echo     1) 删除开机自启的计划任务
echo     2) 删除保存的账号密码文件 credentials.env
echo     3) 断开校园网认证（可选，方便你测试重新连接）
echo     4) 询问是否删除运行日志（默认保留）
echo.
echo  即将弹出管理员权限确认框，请点 [是]
echo.
pause

rem ---------- 查找 Python（断开认证需要） ----------
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

echo.
echo   [1/4] 删除计划任务 ......
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_task.ps1" -Uninstall

echo.
echo   [2/4] 删除账号密码文件 ......
if exist "%~dp0credentials.env" (
    del /q "%~dp0credentials.env" 2>nul
    if exist "%~dp0credentials.env" (
        echo       [X] 删除失败（文件可能正被占用）
    ) else (
        echo       [OK] 已删除 credentials.env（你的密码不再保存在本机）
    )
) else (
    echo       没有找到 credentials.env（可能已经删过了）
)

echo.
echo   [3/4] 断开校园网认证
echo.
echo       注意：选择“断开”后，这台电脑会立即掉线，
echo             需要你手动打开浏览器重新登录才能上网。
echo             10 秒内不选择则默认“断开”。
echo.
choice /c yn /t 10 /d y /m "       是否立即断开校园网认证"
if errorlevel 2 goto skip_logout

if not defined PYEXE (
    echo       [X] 没有检测到 Python，无法自动断开
    echo           请手动打开浏览器访问任意网页，点击认证页上的“注销/退出登录”
    goto after_logout
)
echo       正在断开 ......
"%PYEXE%" "%~dp0AutoConnect_htu.py" --logout
if errorlevel 1 (
    echo       [!] 断开请求未成功（可能本来就没有登录）
) else (
    echo       [OK] 已请求断开，这台电脑现在处于未认证状态
)
goto after_logout

:skip_logout
echo       已跳过断开操作，当前认证状态保持不变

:after_logout
echo.
echo   [4/4] 运行日志处理
echo.
echo       日志记录了每次认证的时间与结果（含学号），可用于排查问题。
echo       默认【保留】日志；10 秒内不选择则保留。
echo.
choice /c yn /t 10 /d n /m "       是否删除运行日志"
if errorlevel 2 goto keep_logs

for %%f in ("%~dp0autoconnect.log" "%~dp0autoconnect.log.1" "%~dp0.last_heartbeat" "%~dp0install_log.txt") do (
    if exist "%%~f" (
        del /q "%%~f" 2>nul
        echo       已删除 %%~nxf
    )
)
set "LOGSTATUS=已删除"
goto after_logs

:keep_logs
echo       已保留日志文件（autoconnect.log）

:after_logs
echo.
echo ============================================================
echo   卸载完成
echo     · 计划任务       —— 已删除，不会再自动连接校园网
echo     · 账号密码文件    —— 已删除，本机不再保存你的密码
echo     · 运行日志       —— %LOGSTATUS%
echo ============================================================
echo.
echo   想重新启用自动连接：再次双击 install.bat 即可
echo   想手动上网：打开浏览器访问任意网页，会跳到认证页
echo.
pause