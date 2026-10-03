@echo off
REM RXPIP client wrapper for Windows.
REM Put this .bat alongside rxpip.rexx (or on PATH with rxpip.rexx in
REM the same directory) so `rxpip install foo` works the way it does
REM on Linux/macOS via the shebang + chmod +x convention there.
REM
REM -a (--args) is required: it makes each command-line argument
REM arrive as its own ARG(n) element instead of REXX's default of
REM joining the whole command line into one string, which would
REM silently break multi-word values like --summary="a description
REM with spaces". See ARCHITECTURE.md for details.
regina -a "%~dp0rxpip.rexx" %*
