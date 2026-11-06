@echo off
setlocal EnableExtensions
rem Village Pact Host installer. Run it from the extracted zip.
rem   Install.bat                  install or update
rem   Install.bat /check           find the game and say what would happen, change nothing
rem   Install.bat /uninstall       remove it (Uninstall.bat runs this)
rem A Bellwright folder can follow, in quotes, when Steam doesn't know where the game is.
rem Paths are only used outside ( ) blocks: Steam's default folder contains "(x86)".
title Village Pact Host
set "HERE=%~dp0"
set "EXE=BellwrightGame-Win64-Shipping.exe"
set "SUB=Bellwright\Binaries\Win64"
set "APPKEY=Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1812450"
set "MODE=install"
set "ARG=%~1"
if /i "%~1"=="/uninstall" set "MODE=uninstall"
if /i "%~1"=="/check" set "MODE=check"
if not "%MODE%"=="install" set "ARG=%~2"
echo Village Pact Host: %MODE%
echo.

if "%MODE%"=="uninstall" goto :find
if exist "%HERE%files\ue4ss\UE4SS.dll" goto :find
echo The installer can't find its files.
echo Extract the whole zip first: right-click it, choose Extract All, then run Install.bat from the new folder.
goto :fail

:find
set "GAME="
if defined ARG call :try "%ARG%"
if defined ARG if not defined GAME echo That folder doesn't hold Bellwright: %ARG%
if not defined GAME call :fromreg "HKLM\SOFTWARE\%APPKEY%"
if not defined GAME call :fromreg "HKLM\SOFTWARE\WOW6432Node\%APPKEY%"
if not defined GAME call :fromsteam
if not defined GAME call :ask
if not defined GAME goto :fail
echo Bellwright: %GAME%

tasklist /fi "imagename eq %EXE%" /fo csv /nh 2>nul | findstr /i /c:"%EXE%" >nul
if errorlevel 1 goto :notrunning
echo Bellwright is running. Close the game, then run this again.
goto :fail
:notrunning

set "MARK=%GAME%\ue4ss\VillagePact.txt"
if "%MODE%"=="uninstall" goto :uninstall
if "%MODE%"=="check" goto :check

rem ---- install or update ----
if exist "%MARK%" goto :copy
if exist "%GAME%\dwmapi.dll" goto :backup
if exist "%GAME%\ue4ss" goto :backup
goto :copy
:backup
call :freename BK "%GAME%\VillagePact-backup"
echo Moving the UE4SS already in the game folder to:
echo %BK%
mkdir "%BK%" || goto :fail
if exist "%GAME%\dwmapi.dll" move "%GAME%\dwmapi.dll" "%BK%\" >nul || goto :fail
if exist "%GAME%\ue4ss" move "%GAME%\ue4ss" "%BK%\" >nul || goto :fail
:copy
echo Copying Village Pact Host into the game folder...
robocopy "%HERE%files" "%GAME%" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto :copyfailed
if not exist "%GAME%\ue4ss\Mods\BWCoop\data" mkdir "%GAME%\ue4ss\Mods\BWCoop\data"
echo.
type "%MARK%"
echo.
echo Installed. Start Bellwright and host as usual; the first start takes up to a minute longer.
echo In the game, Ctrl+O opens the host admin window.
goto :done
:copyfailed
echo Copying failed. Check that the game folder isn't read-only, then run this again.
goto :fail

rem ---- check: say what would happen ----
:check
if exist "%MARK%" goto :check_update
if exist "%GAME%\dwmapi.dll" goto :check_backup
if exist "%GAME%\ue4ss" goto :check_backup
echo Install would copy Village Pact Host into this folder.
goto :done
:check_update
echo Village Pact Host is installed; Install would update it and keep your world settings.
goto :done
:check_backup
echo UE4SS is already in this folder; Install would move it to a VillagePact-backup folder first.
goto :done

rem ---- uninstall ----
:uninstall
if exist "%MARK%" goto :uninstall_go
echo Village Pact Host isn't installed in that folder.
goto :fail
:uninstall_go
call :freename OUT "%GAME%\VillagePact-removed"
mkdir "%OUT%" || goto :fail
if exist "%GAME%\dwmapi.dll" move "%GAME%\dwmapi.dll" "%OUT%\" >nul || goto :fail
move "%GAME%\ue4ss" "%OUT%\" >nul || goto :fail
echo Moved Village Pact Host to:
echo %OUT%
echo Your world settings stay there, in ue4ss\Mods\BWCoop\data.
if not exist "%GAME%\VillagePact-backup" goto :uninstall_done
if exist "%GAME%\VillagePact-backup\dwmapi.dll" move "%GAME%\VillagePact-backup\dwmapi.dll" "%GAME%\" >nul
if exist "%GAME%\VillagePact-backup\ue4ss" move "%GAME%\VillagePact-backup\ue4ss" "%GAME%\" >nul
rmdir "%GAME%\VillagePact-backup" 2>nul
echo Put back the UE4SS you had before Village Pact Host.
:uninstall_done
echo Delete that folder once you no longer need those settings.
goto :done

rem ---- helpers ----
:try
rem Accepts the Bellwright folder, its Bellwright subfolder or Binaries\Win64; sets GAME to Binaries\Win64.
set "C=%~1"
if not defined C exit /b 0
if "%C:~-1%"=="\" set "C=%C:~0,-1%"
if exist "%C%\%EXE%" set "GAME=%C%"
if not defined GAME if exist "%C%\%SUB%\%EXE%" set "GAME=%C%\%SUB%"
if not defined GAME if exist "%C%\Binaries\Win64\%EXE%" set "GAME=%C%\Binaries\Win64"
exit /b 0

:fromreg
for /f "tokens=2,*" %%A in ('reg query "%~1" /v InstallLocation 2^>nul ^| findstr /i /c:"InstallLocation"') do call :try "%%B"
exit /b 0

:fromsteam
set "STEAM="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| findstr /i /c:"SteamPath"') do set "STEAM=%%B"
if not defined STEAM exit /b 0
set "STEAM=%STEAM:/=\%"
call :try "%STEAM%\steamapps\common\Bellwright"
if defined GAME exit /b 0
if not exist "%STEAM%\steamapps\libraryfolders.vdf" exit /b 0
for /f usebackq^ tokens^=4^ delims^=^" %%L in (`findstr /l /c:"path" "%STEAM%\steamapps\libraryfolders.vdf"`) do if not defined GAME call :trylib "%%L"
exit /b 0

:trylib
set "LIB=%~1"
set "LIB=%LIB:\\=\%"
call :try "%LIB%\steamapps\common\Bellwright"
exit /b 0

:ask
echo Bellwright wasn't found through Steam.
echo In Steam, right-click Bellwright, choose Manage, then Browse local files.
echo Copy that folder's address from the address bar and paste it here.
echo.
set "ASK="
set /p "ASK=Bellwright folder: "
if not defined ASK exit /b 0
set "ASK=%ASK:"=%"
call :try "%ASK%"
if not defined GAME echo That folder doesn't hold Bellwright.
exit /b 0

:freename
rem Sets variable %1 to folder %2, or %2-2, %2-3 ... whichever doesn't exist yet.
set "FN=%~2"
set "N=1"
:freename_next
if not exist "%FN%" goto :freename_ok
set /a N+=1
set "FN=%~2-%N%"
goto :freename_next
:freename_ok
set "%~1=%FN%"
exit /b 0

:done
echo.
pause
exit /b 0

:fail
echo.
pause
exit /b 1
