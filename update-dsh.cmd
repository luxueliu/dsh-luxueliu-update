@echo off
rem dsh-luxueliu-update 双击入口。等价命令：
rem   powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-luxueliu-update.ps1" %*
rem 常用：-CheckOnly（只看不更）、-Force（同版本也重装）、-StartOnly（只拉起主台）
rem ASCII only: cmd 按系统代码页解码 .bat/.cmd，混中文容易炸
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-luxueliu-update.ps1" %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
