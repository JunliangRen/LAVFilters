@echo off
setlocal
cd /d "%~dp0..\.."
if not defined VSCMD_ARG_TGT_ARCH exit /b 2
set "CUVID_ARCH=%~1"
if not defined CUVID_ARCH set "CUVID_ARCH=%VSCMD_ARG_TGT_ARCH%"
if /i "%CUVID_ARCH%"=="Win32" set "CUVID_ARCH=x86"
if /i not "%CUVID_ARCH%"=="x64" if /i not "%CUVID_ARCH%"=="x86" exit /b 2
if /i not "%VSCMD_ARG_TGT_ARCH%"=="%CUVID_ARCH%" exit /b 2
set "CUVID_LIB=bin_x64\lib"
set "CUVID_LINK="
if /i "%CUVID_ARCH%"=="x86" (
  set "CUVID_LIB=bin_Win32\lib"
  set "CUVID_LINK=/LARGEADDRESSAWARE"
)
set "CUVID_OUTPUT=%~2"
if not defined CUVID_OUTPUT set "CUVID_OUTPUT=bin_build\cuvid-ffmpeg-20261011\harness\%CUVID_ARCH%"
if not exist "%CUVID_OUTPUT%" mkdir "%CUVID_OUTPUT%"
cl.exe /nologo /EHsc /std:c++17 /MT /O2 /utf-8 /Iffmpeg tests\cuvid-ffmpeg\codec-edge-probe.cpp /Fe"%CUVID_OUTPUT%\codec-edge-probe-%CUVID_ARCH%.exe" /Fo"%CUVID_OUTPUT%\codec-edge-probe-%CUVID_ARCH%.obj" /link %CUVID_LINK% /LIBPATH:"%CUVID_LIB%" avformat-lav.lib avcodec-lav.lib avutil-lav.lib
exit /b %errorlevel%
