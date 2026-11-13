@echo off
REM Build the project.
:: A label-style comment
setlocal enabledelayedexpansion
set "ROOT=%~dp0"
set /a COUNT=0
set NAME=gitbello %VERSION%

if not exist "%ROOT%build" mkdir "%ROOT%build"
if "%1"=="" (
    echo Usage: %~nx0 ^<target^>
    goto :eof
) else if /i "%1" equ "clean" (
    rd /s /q "%ROOT%build" 2>nul
)

for %%f in (*.txt) do (
    set /a COUNT+=1
    echo Found %%~nxf, count !COUNT!
)

call :build %*
if errorlevel 1 exit /b 1
title Done.
echo.
endlocal
goto :eof

:build
echo Building %NAME:~0,8% in "%CD%" & rem trailing comment
exit /b 0
