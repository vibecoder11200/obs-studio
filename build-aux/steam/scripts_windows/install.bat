@echo off
@cd /d "%~dp0"

goto checkAdmin


:checkAdmin
	net session >nul 2>&1
	if %errorLevel% == 0 (
		echo.
	) else (
		echo Administrative rights are required. Please re-run this script as Administrator.
		goto end
	)

:writeRegistry
	reg add "HKLM\SOFTWARE\OBS Studio" /f /t REG_SZ /d %1 /reg:32
	reg add "HKLM\SOFTWARE\OBS Studio" /f /t REG_SZ /d %1 /reg:64

:setupProgramData
	:: Required for UWP applications
	mkdir "%PROGRAMDATA%\obs-studio-hook"
	icacls "%PROGRAMDATA%\obs-studio-hook" /grant "ALL APPLICATION PACKAGES":(OI)(CI)(GR,GE)

:install32DLL
	echo Installing 32-bit Virtual Cam...
	regsvr32.exe /i /s %1\core\win-dshow\data\lvc920x86.dll
	reg query "HKLM\SOFTWARE\Classes\CLSID\{76692E1E-F28F-4DD6-9024-C3A999D30EFB}" >nul 2>&1 /reg:32
	if %errorLevel% == 0 (
		echo 32-bit Virtual Cam successfully installed
		echo.
	) else (
		echo 32-bit Virtual Cam installation failed
		echo.
		goto endFail
	)

:install64DLL
	echo Installing 64-bit Virtual Cam...
	regsvr32.exe /i /s %1\core\win-dshow\data\lvc920x64.dll
	reg query "HKLM\SOFTWARE\Classes\CLSID\{76692E1E-F28F-4DD6-9024-C3A999D30EFB}" >nul 2>&1 /reg:64
	if %errorLevel% == 0 (
		echo 64-bit Virtual Cam successfully installed
		echo.
		goto endSuccess
	) else (
		echo 64-bit Virtual Cam installation failed
		echo.
		goto endFail
	)

:endFail
	echo Something failed, please report this on the OBS Discord or Forums!
	goto end

:endSuccess
	echo Virtual Cam installed!
	echo.

:end
	exit
