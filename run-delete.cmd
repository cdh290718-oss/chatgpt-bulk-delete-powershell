@echo off
setlocal
chcp 65001 >nul
set "CHAT_DELETE_LIST=%~1"
if not defined CHAT_DELETE_LIST set "CHAT_DELETE_LIST=%~dp0titles.txt"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0chatgpt-bulk-delete.ps1" -ListPath "%CHAT_DELETE_LIST%" -Execute
set "CHAT_DELETE_EXIT=%errorlevel%"
pause
exit /b %CHAT_DELETE_EXIT%
