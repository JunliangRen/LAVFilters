@echo off
setlocal
cd /d "%~dp0..\.."
if not defined VSCMD_ARG_TGT_ARCH (
  echo Run from the matching Visual Studio x64 or x86 Native Tools Command Prompt.
  exit /b 2
)
set "AVS_ARCH=%~1"
if not defined AVS_ARCH set "AVS_ARCH=%VSCMD_ARG_TGT_ARCH%"
if /i "%AVS_ARCH%"=="Win32" set "AVS_ARCH=x86"
if /i not "%AVS_ARCH%"=="x64" if /i not "%AVS_ARCH%"=="x86" (
  echo Usage: build.cmd [x64^|x86^|Win32] [output-directory]
  exit /b 2
)
if /i not "%VSCMD_ARG_TGT_ARCH%"=="%AVS_ARCH%" (
  echo Requested architecture does not match the Native Tools environment.
  exit /b 2
)
set "AVS_LIB=bin_x64\lib"
set "AVS_LINK="
if /i "%AVS_ARCH%"=="x86" (
  set "AVS_LIB=bin_Win32\lib"
  set "AVS_LINK=/LARGEADDRESSAWARE"
)
if not exist "%AVS_LIB%\strmbase.lib" (
  echo Build Release DirectShow base classes for %AVS_ARCH% first.
  exit /b 2
)
set "AVS_OUTPUT=%~2"
if not defined AVS_OUTPUT set "AVS_OUTPUT=bin_build\avs-first\dualarch-validation\harness\%AVS_ARCH%"
if not exist "%AVS_OUTPUT%" mkdir "%AVS_OUTPUT%"
cl.exe /nologo /EHsc /std:c++17 /MT /O2 /utf-8 /DUNICODE /D_UNICODE /D_WIN32_WINNT=0x0602 /Icommon\baseclasses /Iinclude tests\avs-decode\graph-regression.cpp /Fe"%AVS_OUTPUT%\graph-regression-%AVS_ARCH%.exe" /Fo"%AVS_OUTPUT%\graph-regression-%AVS_ARCH%.obj" /link %AVS_LINK% /LIBPATH:"%AVS_LIB%" strmbase.lib ole32.lib oleaut32.lib strmiids.lib winmm.lib uuid.lib advapi32.lib user32.lib bcrypt.lib
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /EHsc /std:c++17 /MT /O2 /utf-8 /D_WIN32_WINNT=0x0602 /Iffmpeg tests\avs-decode\frame-pts-probe.cpp /Fe"%AVS_OUTPUT%\frame-pts-probe-%AVS_ARCH%.exe" /Fo"%AVS_OUTPUT%\frame-pts-probe-%AVS_ARCH%.obj" /link %AVS_LINK%
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /EHsc /std:c++17 /MT /O2 /utf-8 /D_WIN32_WINNT=0x0602 tests\avs-decode\smoke-load.cpp /Fe"%AVS_OUTPUT%\smoke-load-%AVS_ARCH%.exe" /Fo"%AVS_OUTPUT%\smoke-load-%AVS_ARCH%.obj" /link %AVS_LINK% ole32.lib strmiids.lib uuid.lib
exit /b %errorlevel%
