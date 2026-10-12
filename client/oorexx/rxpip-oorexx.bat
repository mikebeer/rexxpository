@echo off
rem RXPIP launcher for ooRexx (Windows). Arguments stay double-quoted; rxpip.rexx splits them again.
set RXPIP_QUOTED=2
if "%RXPIP_INTERPRETER%"=="" set RXPIP_INTERPRETER=rexx
rexx "%~dp0..\rxpip.rexx" %*
