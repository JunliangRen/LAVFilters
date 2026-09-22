@echo off
setlocal
cd /d "%~dp0..\.."
if not defined VSCMD_ARG_TGT_ARCH (
  echo Run from a Visual Studio x64 or x86 Native Tools Command Prompt.
  exit /b 2
)
set "PLATFORM_DIR=x64"
if /i "%VSCMD_ARG_TGT_ARCH%"=="x86" set "PLATFORM_DIR=Win32"
if not exist bin_build\aac-config-switch mkdir bin_build\aac-config-switch
cl.exe /nologo /EHsc /std:c++17 /MT /O2 /utf-8 /DUNICODE /D_UNICODE /D_WIN32_WINNT=0x0602 /Icommon\baseclasses /Iinclude tests\aac-config-switch\graph-regression.cpp /Febin_build\aac-config-switch\graph-regression-%VSCMD_ARG_TGT_ARCH%.exe /Fobin_build\aac-config-switch\graph-regression-%VSCMD_ARG_TGT_ARCH%.obj /link /LIBPATH:bin_%PLATFORM_DIR%\lib strmbase.lib ole32.lib oleaut32.lib strmiids.lib winmm.lib uuid.lib advapi32.lib user32.lib
exit /b %errorlevel%
