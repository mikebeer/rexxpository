@echo off
rem Publish the four rxpip client kinds from this checkout (Windows).
rem
rem   tools\publish-clients.cmd <version> [min-version]
rem
rem Run it from the checkout, logged in as an rxpip administrator
rem (rxpip login). Every file is signed with minisign first (one password
rem prompt per kind); set NOSIGN=1 to publish unsigned. RXPIP overrides the
rem command that runs the client (default: rxpip). MINISIGN_KEY overrides
rem the secret key file (default: minisign's own default).
setlocal EnableDelayedExpansion
if "%~1"=="" (
  echo usage: tools\publish-clients.cmd ^<version^> [min-version]
  exit /b 1
)
set "V=%~1"
set "MIN=%~2"
if "%MIN%"=="" set "MIN=1.0.0"
set "ROOT=%~dp0.."
set "STAGE=%TEMP%\rxpip_rel"
if "%RXPIP%"=="" set "RXPIP=rxpip"
set "KEYARG="
if not "%MINISIGN_KEY%"=="" set KEYARG=-s "%MINISIGN_KEY%"
if "%NOSIGN%"=="" (
  where minisign >nul 2>nul
  if errorlevel 1 (
    echo minisign not found on the PATH. Install it, or set NOSIGN=1 to publish unsigned.
    exit /b 1
  )
)

call :pub regina  "%ROOT%\client\rxpip.rexx" "%ROOT%\client\rxpip.bat"
if errorlevel 1 exit /b 1
call :pub oorexx  "%ROOT%\client\rxpip.rexx" "%ROOT%\client\oorexx\rxpip-oorexx" "%ROOT%\client\oorexx\rxpip-oorexx.bat"
if errorlevel 1 exit /b 1
call :pub netrexx "%ROOT%\client\netrexx\Rxpip.nrx" "%ROOT%\client\netrexx\rxpip-netrexx" "%ROOT%\client\netrexx\rxpip-netrexx.bat"
if errorlevel 1 exit /b 1
call :pub crexx   "%ROOT%\client\crexx\rxpip.crexx" "%ROOT%\client\crexx\rxpip-crexx" "%ROOT%\client\crexx\rxpip-crexx.bat"
if errorlevel 1 exit /b 1
echo.
echo All four client kinds published as %V%.
exit /b 0

:pub
set "K=%~1"
echo.
echo == %K% %V%
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%"
shift
:copyloop
if "%~1"=="" goto copied
copy /y "%~1" "%STAGE%\" >nul
if errorlevel 1 (
  echo cannot copy %~1
  exit /b 1
)
shift
goto copyloop
:copied
pushd "%STAGE%"
if "%NOSIGN%"=="" (
  set "LIST="
  for %%F in (*) do set "LIST=!LIST! "%%F""
  minisign -S %KEYARG% -m !LIST!
  if errorlevel 1 (
    echo signing failed
    popd
    exit /b 1
  )
)
set "PUB="
for %%F in (*) do set "PUB=!PUB! "%%F""
%RXPIP% admin client-publish %K% --version=%V% --min=%MIN% !PUB!
set "RC=!errorlevel!"
popd
exit /b !RC!
