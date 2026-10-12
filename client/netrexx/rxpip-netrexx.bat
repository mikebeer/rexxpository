@echo off
rem RXPIP NetRexx client launcher. Set NETREXX_JAR to NetRexxC.jar if it is not in this folder.
if "%NETREXX_JAR%"=="" set "NETREXX_JAR=%~dp0NetRexxC.jar"
if "%RXPIP_HOME%"=="" (set "RH=%USERPROFILE%\.rxpip") else (set "RH=%RXPIP_HOME%")
set "OUT=%RH%\netrexx\bin"
if not exist "%OUT%" mkdir "%OUT%"
if not exist "%OUT%\Rxpip.class" (
  copy /y "%~dp0Rxpip.nrx" "%OUT%\" >nul
  pushd "%OUT%"
  java -cp "%NETREXX_JAR%" COM.ibm.netrexx.process.NetRexxC Rxpip -nologo -nocrossref -noconsole >nul
  popd
)
java -cp "%OUT%;%NETREXX_JAR%" Rxpip %*
