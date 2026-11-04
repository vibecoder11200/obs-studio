/* vcamctl: elevated helper for the virtual camera runtime identity.
 *
 * The identity lives under HKLM\VIRTUALCAM_IDENTITY_KEY_W (admin-writable
 * only) and is applied by DllRegisterServer. `set`/`reset` re-register the
 * module DLLs so the change takes effect without a rebuild. The DLLs are
 * always resolved next to this executable (the install dir is
 * admin-protected); paths from the command line or the current directory
 * are never used. */

#include <windows.h>
#include <shellapi.h>
#include <strsafe.h>
#include <wctype.h>

#include <io.h>
#include <fcntl.h>
#include <stdio.h>

#include "virtualcam-brand.h"
#include "virtualcam-device.h"

/* ========================================================================= */

static const wchar_t *module_entries[] = {
	L"lvc920x64.dll",
	L"lvc920x86.dll",
	L"lvc920arm64.dll",
};

static void PrintUsage()
{
	wprintf(L"usage: vcamctl get\n"
		L"       vcamctl set --name NAME [--vid HHHH --pid HHHH] [--serial SERIAL]\n"
		L"       vcamctl reset\n"
		L"       vcamctl register | unregister\n"
		L"\n"
		L"get        print the identity the next registration will apply\n"
		L"set        write identity values, then re-register (omit values to keep them)\n"
		L"reset      remove all identity values, then re-register\n"
		L"register   re-register the module DLLs next to vcamctl\n"
		L"unregister unregister the module DLLs next to vcamctl\n");
}

/* ------------------------------------------------------------------------ */
/* registry                                                                  */

static bool RegReadIdentityValue(const wchar_t *value, wchar_t *out, size_t out_chars)
{
	DWORD size = (DWORD)(out_chars * sizeof(wchar_t));

	out[0] = L'\0';
	return RegGetValueW(HKEY_LOCAL_MACHINE, VIRTUALCAM_IDENTITY_KEY_W, value, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
			    nullptr, out, &size) == ERROR_SUCCESS &&
	       out[0] != L'\0';
}

static bool RegWriteIdentityValue(const wchar_t *name, const wchar_t *value)
{
	HKEY key = nullptr;
	LSTATUS status;

	status = RegCreateKeyExW(HKEY_LOCAL_MACHINE, VIRTUALCAM_IDENTITY_KEY_W, 0, nullptr, REG_OPTION_NON_VOLATILE,
				 KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &key, nullptr);
	if (status != ERROR_SUCCESS) {
		return false;
	}

	status = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value, (DWORD)(wcslen(value) + 1) * sizeof(wchar_t));
	RegCloseKey(key);

	return status == ERROR_SUCCESS;
}

/* ------------------------------------------------------------------------ */
/* validation                                                                */

static bool ValidHex4(const wchar_t *str)
{
	if (wcslen(str) != 4) {
		return false;
	}

	for (const wchar_t *p = str; *p; ++p) {
		if (!iswxdigit(*p)) {
			return false;
		}
	}

	return true;
}

static bool ValidSerial(const wchar_t *str)
{
	size_t len = wcslen(str);

	if (len == 0 || len > 15) {
		return false;
	}

	/* DevicePath is composed as usb#vid..#SERIAL#...: keep the charset
	 * free of the separators and path characters. */
	for (const wchar_t *p = str; *p; ++p) {
		if (!iswalnum(*p) && !wcschr(L"-_.& ", *p)) {
			return false;
		}
	}

	return true;
}

static bool ValidName(const wchar_t *str)
{
	size_t len = wcslen(str);

	return len > 0 && len <= 127;
}

/* ------------------------------------------------------------------------ */
/* (re-)registration                                                         */

static bool RunRegsvr32(const wchar_t *regsvr32, const wchar_t *flags, const wchar_t *dll)
{
	wchar_t cmdline[2 * MAX_PATH + 64];
	STARTUPINFOW si = {};
	PROCESS_INFORMATION pi = {};
	bool success = false;

	if (FAILED(StringCbPrintfW(cmdline, sizeof(cmdline), L"\"%s\" %s \"%s\"", regsvr32, flags, dll))) {
		return false;
	}

	if (!CreateProcessW(nullptr, cmdline, nullptr, nullptr, false, 0, nullptr, nullptr, &si, &pi)) {
		return false;
	}

	WaitForSingleObject(pi.hProcess, INFINITE);

	DWORD exit_code = 1;
	GetExitCodeProcess(pi.hProcess, &exit_code);
	success = exit_code == 0;

	CloseHandle(pi.hThread);
	CloseHandle(pi.hProcess);

	return success;
}

/* Unregisters then registers the module DLLs next to this executable, so
 * PnP re-creates the device with the updated identity. The 32-bit module
 * runs under the 32-bit regsvr32. Returns false only when nothing could be
 * (re-)registered. */
static bool ReRegisterModules(bool reg)
{
	wchar_t dir[MAX_PATH];
	wchar_t *slash;
	bool any = false;
	bool ok = true;

	if (!GetModuleFileNameW(nullptr, dir, MAX_PATH)) {
		wprintf(L"vcamctl: cannot resolve the executable path\n");
		return false;
	}

	slash = wcsrchr(dir, L'\\');
	if (!slash) {
		return false;
	}
	*slash = L'\0';

	for (const wchar_t *entry : module_entries) {
		wchar_t dll[MAX_PATH];
		wchar_t regsvr32[MAX_PATH];

		if (FAILED(StringCbPrintfW(dll, sizeof(dll), L"%s\\%s", dir, entry))) {
			continue;
		}
		if (GetFileAttributesW(dll) == INVALID_FILE_ATTRIBUTES) {
			continue;
		}

		/* %SystemRoot%\SysWOW64\regsvr32.exe hosts the 32-bit module. */
		const wchar_t *regsvr32_template = L"%SystemRoot%\\System32\\regsvr32.exe";
		if (wcscmp(entry, L"lvc920x86.dll") == 0) {
			regsvr32_template = L"%SystemRoot%\\SysWOW64\\regsvr32.exe";
		}

		if (ExpandEnvironmentStringsW(regsvr32_template, regsvr32, MAX_PATH) == 0) {
			ok = false;
			continue;
		}

		any = true;

		if (reg) {
			/* Ignore the unregister result: an unregistered module
			   fails /u but the following /s is what matters. */
			RunRegsvr32(regsvr32, L"/u /s", dll);
			if (RunRegsvr32(regsvr32, L"/s", dll)) {
				wprintf(L"registered %s\n", entry);
			} else {
				wprintf(L"FAILED to register %s\n", entry);
				ok = false;
			}
		} else {
			if (RunRegsvr32(regsvr32, L"/u /s", dll)) {
				wprintf(L"unregistered %s\n", entry);
			} else {
				wprintf(L"FAILED to unregister %s\n", entry);
				ok = false;
			}
		}
	}

	if (!any) {
		wprintf(L"vcamctl: no virtual camera module DLL found next to this executable\n");
		return false;
	}

	return ok;
}

/* ------------------------------------------------------------------------ */
/* commands                                                                  */

static int CommandGet()
{
	wchar_t name[128];
	wchar_t vid[16];
	wchar_t pid[16];
	wchar_t serial[16];

	bool has_name = RegReadIdentityValue(L"Name", name, _countof(name));
	bool has_vid = RegReadIdentityValue(L"Vid", vid, _countof(vid));
	bool has_pid = RegReadIdentityValue(L"Pid", pid, _countof(pid));
	bool has_serial = RegReadIdentityValue(L"Serial", serial, _countof(serial));

	if (has_name) {
		wprintf(L"name:    %s\n", name);
	} else {
		wprintf(L"name:    %s [default]\n", VIRTUALCAM_BRAND_NAME_W);
	}

	if (has_vid && has_pid) {
		wprintf(L"vid/pid: vid_%s&pid_%s\n", vid, pid);
	} else {
		wprintf(L"vid/pid: %s [default]\n", VIRTUALCAM_DEVICE_VIDPID_W);
	}

	if (has_serial) {
		wprintf(L"serial:  %s\n", serial);
	} else if (VIRTUALCAM_DEVICE_SERIAL_W[0] != L'\0') {
		wprintf(L"serial:  %s [default]\n", VIRTUALCAM_DEVICE_SERIAL_W);
	} else {
		wprintf(L"serial:  (derived per machine) [default]\n");
	}

	return 0;
}

static int CommandSet(int argc, wchar_t **argv)
{
	const wchar_t *name = nullptr;
	const wchar_t *vid = nullptr;
	const wchar_t *pid = nullptr;
	const wchar_t *serial = nullptr;

	for (int i = 2; i < argc; i++) {
		if (wcscmp(argv[i], L"--name") == 0 && i + 1 < argc) {
			name = argv[++i];
		} else if (wcscmp(argv[i], L"--vid") == 0 && i + 1 < argc) {
			vid = argv[++i];
		} else if (wcscmp(argv[i], L"--pid") == 0 && i + 1 < argc) {
			pid = argv[++i];
		} else if (wcscmp(argv[i], L"--serial") == 0 && i + 1 < argc) {
			serial = argv[++i];
		} else {
			wprintf(L"vcamctl: unknown or incomplete argument %s\n", argv[i]);
			PrintUsage();
			return 1;
		}
	}

	if (!name && !vid && !pid && !serial) {
		PrintUsage();
		return 1;
	}
	if (name && !ValidName(name)) {
		wprintf(L"vcamctl: invalid name (1-127 characters required)\n");
		return 1;
	}
	if (!vid != !pid) {
		wprintf(L"vcamctl: --vid and --pid must be provided together\n");
		return 1;
	}
	if (vid && !ValidHex4(vid)) {
		wprintf(L"vcamctl: invalid vid/pid (exactly 4 hex digits required)\n");
		return 1;
	}
	if (serial && !ValidSerial(serial)) {
		wprintf(L"vcamctl: invalid serial (1-15 characters: letters, digits, -_.& or space)\n");
		return 1;
	}

	if (name && !RegWriteIdentityValue(L"Name", name)) {
		wprintf(L"vcamctl: writing the identity failed (admin rights required)\n");
		return 2;
	}
	if (vid && !RegWriteIdentityValue(L"Vid", vid)) {
		wprintf(L"vcamctl: writing the identity failed (admin rights required)\n");
		return 2;
	}
	if (vid && !RegWriteIdentityValue(L"Pid", pid)) {
		wprintf(L"vcamctl: writing the identity failed (admin rights required)\n");
		return 2;
	}
	if (serial && !RegWriteIdentityValue(L"Serial", serial)) {
		wprintf(L"vcamctl: writing the identity failed (admin rights required)\n");
		return 2;
	}

	wprintf(L"identity written; re-registering...\n");

	return ReRegisterModules(true) ? 0 : 2;
}

static int CommandReset()
{
	LSTATUS status = RegDeleteTreeW(HKEY_LOCAL_MACHINE, VIRTUALCAM_IDENTITY_KEY_W);

	if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND && status != ERROR_PATH_NOT_FOUND) {
		wprintf(L"vcamctl: resetting the identity failed (admin rights required)\n");
		return 2;
	}

	wprintf(L"identity reset to build defaults; re-registering...\n");

	return ReRegisterModules(true) ? 0 : 2;
}

/* ========================================================================= */

int main(void)
{
	_setmode(_fileno(stdout), _O_U16TEXT);
	_setmode(_fileno(stderr), _O_U16TEXT);

	int argc = 0;
	wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);

	if (argc < 2) {
		PrintUsage();
		return 1;
	}

	if (wcscmp(argv[1], L"get") == 0) {
		return CommandGet();
	}
	if (wcscmp(argv[1], L"set") == 0) {
		return CommandSet(argc, argv);
	}
	if (wcscmp(argv[1], L"reset") == 0) {
		return CommandReset();
	}
	if (wcscmp(argv[1], L"register") == 0) {
		return ReRegisterModules(true) ? 0 : 2;
	}
	if (wcscmp(argv[1], L"unregister") == 0) {
		return ReRegisterModules(false) ? 0 : 2;
	}

	PrintUsage();
	return 1;
}
