@echo off
rem RXPIP cREXX client launcher. rxc, rxas, rxvm must be on the PATH (or set CREXX_HOME).
if not "%CREXX_HOME%"=="" set "PATH=%CREXX_HOME%\bin;%PATH%"
if "%RXPIP_HOME%"=="" (set "RH=%USERPROFILE%\.rxpip") else (set "RH=%RXPIP_HOME%")
if not exist "%RH%\crexx\bin" mkdir "%RH%\crexx\bin"
if not exist "%RH%\crexx\bin\rxpip.rxbin" (
  rxc -o "%RH%\crexx\bin\rxpip" "%~dp0rxpip.crexx" >nul && rxas "%RH%\crexx\bin\rxpip"
)
rxvm "%RH%\crexx\bin\rxpip.rxbin" -a %*
