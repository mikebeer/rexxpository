@echo off
rem RXPIP NetRexx client launcher. Set NETREXX_JAR to NetRexxC.jar if it is not in this folder.
if "%NETREXX_JAR%"=="" set NETREXX_JAR=%~dp0NetRexxC.jar
java -cp "%~dp0;%NETREXX_JAR%" Rxpip %*
