@echo off
rem RXPIP launcher for ooRexx (Windows). Arguments stay double-quoted; rxpip.rexx splits them again.
rem rxpip.rexx is next to this file (downloaded from the website) or one folder up (repository layout).
set "RXPIP_CLIENT_DIR=%~dp0"
if not exist "%~dp0rxpip.rexx" set "RXPIP_CLIENT_DIR=%~dp0.."
set RXPIP_QUOTED=2
if "%RXPIP_INTERPRETER%"=="" set RXPIP_INTERPRETER=rexx
rexx "%RXPIP_CLIENT_DIR%\rxpip.rexx" %*
