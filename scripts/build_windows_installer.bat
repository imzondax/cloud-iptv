@echo off
setlocal
pushd "%~dp0.."

call flutter pub get || goto :fail
call dart run build_runner build --delete-conflicting-outputs || goto :fail
call flutter build windows --release || goto :fail

rem Flutter does not bundle the VC++ runtime, and a clean Windows may lack it.
for %%f in (msvcp140.dll vcruntime140.dll vcruntime140_1.dll) do (
  copy /y "%SystemRoot%\System32\%%f" "build\windows\x64\runner\Release\" >nul || goto :fail
)

for /f "tokens=2 delims=: " %%v in ('findstr /b "version:" pubspec.yaml') do set "VERSION=%%v"
for /f "delims=+" %%v in ("%VERSION%") do set "VERSION=%%v"

if not defined ISCC for /f "delims=" %%i in ('where iscc 2^>nul') do set "ISCC=%%i"
if not defined ISCC if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not defined ISCC if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if not defined ISCC if exist "%LocalAppData%\Programs\Inno Setup 6\ISCC.exe" set "ISCC=%LocalAppData%\Programs\Inno Setup 6\ISCC.exe"
if not defined ISCC (
  echo Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup
  goto :fail
)

"%ISCC%" /DAppVersion=%VERSION% windows\installer.iss || goto :fail

echo.
echo Installer ready: build\installer\CloudIPTV_Setup.exe
popd
exit /b 0

:fail
echo Build failed.
popd
exit /b 1
