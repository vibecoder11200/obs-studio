#include "virtualcam-filter.hpp"
#include "virtualcam-guid.h"
#include "virtualcam-brand.h"
#include "virtualcam-device.h"
#include "virtualcam-serial.h"

#include <bcrypt.h>
#include <stdlib.h>
#include <wctype.h>

/* ========================================================================= */

static const REGPINTYPES AMSMediaTypesV = {&MEDIATYPE_Video, &MEDIASUBTYPE_NV12};

static const REGFILTERPINS AMSPinVideo = {nullptr, false, true, false, false, &CLSID_NULL, nullptr, 1, &AMSMediaTypesV};

HINSTANCE dll_inst = nullptr;
volatile long locks = 0;

/* ========================================================================= */

class VCamFactory : public IClassFactory {
	volatile long refs = 1;
	CLSID cls;

public:
	inline VCamFactory(CLSID cls_) : cls(cls_) { os_atomic_inc_long(&locks); }
	inline ~VCamFactory() { os_atomic_dec_long(&locks); }

	// IUnknown
	STDMETHODIMP QueryInterface(REFIID riid, void **p_ptr);
	STDMETHODIMP_(ULONG) AddRef();
	STDMETHODIMP_(ULONG) Release();

	// IClassFactory
	STDMETHODIMP CreateInstance(LPUNKNOWN parent, REFIID riid, void **p_ptr);
	STDMETHODIMP LockServer(BOOL lock);
};

STDMETHODIMP VCamFactory::QueryInterface(REFIID riid, void **p_ptr)
{
	if (!p_ptr) {
		return E_POINTER;
	}

	if ((riid == IID_IUnknown) || (riid == IID_IClassFactory)) {
		AddRef();
		*p_ptr = (void *)this;
		return S_OK;
	} else {
		*p_ptr = nullptr;
		return E_NOINTERFACE;
	}
}

STDMETHODIMP_(ULONG) VCamFactory::AddRef()
{
	return os_atomic_inc_long(&refs);
}

STDMETHODIMP_(ULONG) VCamFactory::Release()
{
	long new_refs = os_atomic_dec_long(&refs);
	if (new_refs == 0) {
		delete this;
		return 0;
	}

	return (ULONG)new_refs;
}

STDMETHODIMP VCamFactory::CreateInstance(LPUNKNOWN parent, REFIID, void **p_ptr)
{
	if (!p_ptr) {
		return E_POINTER;
	}

	*p_ptr = nullptr;

	/* don't bother supporting the "parent" functionality */
	if (parent) {
		return E_NOINTERFACE;
	}

	if (IsEqualCLSID(cls, CLSID_OBS_VirtualVideo)) {
		*p_ptr = (void *)new VCamFilter();
		return S_OK;
	}

	return E_NOINTERFACE;
}

STDMETHODIMP VCamFactory::LockServer(BOOL lock)
{
	if (lock) {
		os_atomic_inc_long(&locks);
	} else {
		os_atomic_dec_long(&locks);
	}

	return S_OK;
}

/* ========================================================================= */

static inline DWORD string_size(const wchar_t *str)
{
	return (DWORD)(wcslen(str) + 1) * sizeof(wchar_t);
}

/* ------------------------------------------------------------------------ */
/* Runtime identity overrides                                               */
/*                                                                          */
/* vcamctl writes Name/Serial/Vid/Pid under HKLM\VIRTUALCAM_IDENTITY_KEY_W; */
/* registration applies them over the compiled identity. The key lives in   */
/* the 64-bit HKLM view (both module architectures read the same values)    */
/* and is writable by administrators only. Missing or invalid values fall   */
/* back to the compiled defaults.                                           */

static void LogIdentity(const wchar_t *msg)
{
	OutputDebugStringW(msg);
}

static bool RegReadIdentityValue(const wchar_t *value, wchar_t *out, size_t out_chars)
{
	DWORD size = (DWORD)(out_chars * sizeof(wchar_t));
	LSTATUS status;

	out[0] = L'\0';
	status = RegGetValueW(HKEY_LOCAL_MACHINE, VIRTUALCAM_IDENTITY_KEY_W, value, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
			      nullptr, out, &size);
	if (status == ERROR_MORE_DATA) {
		/* A too-small buffer reads as "value absent" unless it is
		   reported; the only value that can exceed a buffer today is
		   an over-long serial, which every reader sizes for. */
		LogIdentity(L"vcam-module: identity value longer than its buffer, ignored");
		return false;
	}
	return status == ERROR_SUCCESS && out[0] != L'\0';
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

	status = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value, string_size(value));
	RegCloseKey(key);

	return status == ERROR_SUCCESS;
}

static bool RegValidHex(const wchar_t *str)
{
	size_t len = wcslen(str);

	if (len != 4) {
		return false;
	}

	for (const wchar_t *p = str; *p; ++p) {
		if (!iswxdigit(*p)) {
			return false;
		}
	}

	return true;
}

static void RegLowercase(wchar_t *str)
{
	for (; *str; ++str) {
		*str = (wchar_t)towlower(*str);
	}
}

/* OS CSPRNG entropy for serial generation: BCryptGenRandom, with the rand_s
   fallback (also OS-seeded; needs _CRT_RAND_S before <stdlib.h>). */
static bool GetRandomEntropy(uint8_t entropy[16])
{
	/* NTSTATUS >= 0 is success (NT_SUCCESS is absent in MinGW headers). */
	if (BCryptGenRandom(nullptr, (PUCHAR)entropy, 16, BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0) {
		return true;
	}

	for (int i = 0; i < 4; ++i) {
		unsigned int value;

		if (rand_s(&value) != 0) {
			return false;
		}
		entropy[4 * i + 0] = (uint8_t)(value >> 24);
		entropy[4 * i + 1] = (uint8_t)(value >> 16);
		entropy[4 * i + 2] = (uint8_t)(value >> 8);
		entropy[4 * i + 3] = (uint8_t)value;
	}

	return true;
}

/* Deterministic degraded-mode serial: FNV-1a over MachineGuid and the
   identity itself, FNV-chain expanded to the format's required length (used
   when the CSPRNG or the HKLM persist write fails, e.g. a non-elevated
   regsvr32). Logged by the caller; never silent. */
static void BuildDeterministicSerial(const wchar_t *vid, const wchar_t *pid, wchar_t *out, size_t out_chars)
{
	wchar_t machine_guid[64] = L"";
	DWORD size = sizeof(machine_guid);
	uint32_t hash = 2166136261u;
	uint8_t entropy[16];

	RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Cryptography", L"MachineGuid",
		     RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, machine_guid, &size);

	for (const wchar_t *p = machine_guid; *p; ++p) {
		hash ^= (uint32_t)(uint16_t)*p;
		hash *= 16777619u;
	}
	for (const wchar_t *p = vid; *p; ++p) {
		hash ^= (uint32_t)(uint16_t)*p;
		hash *= 16777619u;
	}
	for (const wchar_t *p = pid; *p; ++p) {
		hash ^= (uint32_t)(uint16_t)*p;
		hash *= 16777619u;
	}

	vcam_entropy_from_seed(hash, entropy);
	vcam_format_serial(vcam_serial_format_for(vid, pid), entropy, out, out_chars);
}

/* Loads the effective identity for this registration: name and vidpid are
 * always filled (override or compiled default), serial receives the stored
 * serial or an empty string, vid/pid the lowercase 4-hex halves of vidpid. */
static void LoadIdentityOverrides(wchar_t *name, size_t name_chars, wchar_t *vidpid, size_t vidpid_chars,
				  wchar_t *serial, size_t serial_chars, wchar_t *vid, wchar_t *pid)
{
	wchar_t override_name[128];
	wchar_t vid_buf[16];
	wchar_t pid_buf[16];

	StringCbCopyW(name, name_chars * sizeof(wchar_t), VIRTUALCAM_BRAND_NAME_W);
	StringCbCopyW(vidpid, vidpid_chars * sizeof(wchar_t), VIRTUALCAM_DEVICE_VIDPID_W);
	serial[0] = L'\0';
	vid[0] = L'\0';
	pid[0] = L'\0';

	if (RegReadIdentityValue(L"Name", override_name, _countof(override_name))) {
		StringCbCopyW(name, name_chars * sizeof(wchar_t), override_name);
	}

	/* Result ignored: an absent Serial keeps the compiled/generated one. */
	RegReadIdentityValue(L"Serial", serial, serial_chars);

	if (RegReadIdentityValue(L"Vid", vid_buf, _countof(vid_buf)) && RegReadIdentityValue(L"Pid", pid_buf, _countof(pid_buf)) &&
	    RegValidHex(vid_buf) && RegValidHex(pid_buf)) {
		RegLowercase(vid_buf);
		RegLowercase(pid_buf);
		StringCbPrintfW(vidpid, vidpid_chars * sizeof(wchar_t), L"vid_%s&pid_%s", vid_buf, pid_buf);
	}

	/* vidpid is always "vid_HHHH&pid_HHHH" (override or compiled default). */
	const wchar_t *pid_at = wcsstr(vidpid, L"&pid_");
	if (wcsncmp(vidpid, L"vid_", 4) == 0 && pid_at != nullptr) {
		for (int i = 0; i < 4; ++i) {
			vid[i] = (wchar_t)towlower(vidpid[4 + i]);
			pid[i] = (wchar_t)towlower(pid_at[5 + i]);
		}
		vid[4] = L'\0';
		pid[4] = L'\0';
	}
}

static bool RegServer(const CLSID &cls, const wchar_t *desc, const wchar_t *file, const wchar_t *model = L"Both",
		      const wchar_t *type = L"InprocServer32")
{
	wchar_t cls_str[CHARS_IN_GUID];
	wchar_t temp[MAX_PATH];
	HKEY key = nullptr;
	HKEY subkey = nullptr;
	bool success = false;

	StringFromGUID2(cls, cls_str, CHARS_IN_GUID);

	StringCbPrintf(temp, sizeof(temp), L"CLSID\\%s", cls_str);

	if (RegCreateKey(HKEY_CLASSES_ROOT, temp, &key) != ERROR_SUCCESS) {
		goto fail;
	}

	RegSetValueW(key, nullptr, REG_SZ, desc, string_size(desc));

	if (RegCreateKey(key, type, &subkey) != ERROR_SUCCESS) {
		goto fail;
	}

	RegSetValueW(subkey, nullptr, REG_SZ, file, string_size(file));
	RegSetValueExW(subkey, L"ThreadingModel", 0, REG_SZ, (const BYTE *)model, string_size(model));

	success = true;

fail:
	if (key) {
		RegCloseKey(key);
	}
	if (subkey) {
		RegCloseKey(subkey);
	}

	return success;
}

static bool UnregServer(const CLSID &cls)
{
	wchar_t cls_str[CHARS_IN_GUID];
	wchar_t temp[MAX_PATH];

	StringFromGUID2(cls, cls_str, CHARS_IN_GUID);
	StringCbPrintf(temp, sizeof(temp), L"CLSID\\%s", cls_str);

	return RegDeleteTreeW(HKEY_CLASSES_ROOT, temp) == ERROR_SUCCESS;
}

static bool RegServers(const wchar_t *name)
{
	wchar_t file[MAX_PATH];

	if (!GetModuleFileNameW(dll_inst, file, MAX_PATH)) {
		return false;
	}

	return RegServer(CLSID_OBS_VirtualVideo, name, file);
}

/* Writes the USB-style DevicePath value under the filter's category Instance
   key, where apps (Skype/Unity-era checkers) read it for physical cameras.
   UnregisterFilter removes the whole Instance tree, so no extra cleanup is
   needed beyond the defensive delete in DllUnregisterServer. */
static bool RegFilterDevicePath(const CLSID &clsid, const wchar_t *vidpid, const wchar_t *serial,
				vcam_serial_format fmt)
{
	wchar_t cls_str[CHARS_IN_GUID];
	wchar_t category_str[CHARS_IN_GUID];
	wchar_t key_path[MAX_PATH];
	wchar_t device_path[MAX_PATH];

	StringFromGUID2(clsid, cls_str, CHARS_IN_GUID);
	StringFromGUID2(CLSID_VideoInputDeviceCategory, category_str, CHARS_IN_GUID);

	if (FAILED(StringCbPrintfW(key_path, sizeof(key_path), L"CLSID\\%s\\Instance\\%s", category_str, cls_str))) {
		return false;
	}

	/* LOCATION-format identities composite like real laptop built-ins
	   (composite UVC devices): usb#vid..&pid..&mi_00#serial#interface. */
	if (vcam_serial_needs_mi00(fmt)) {
		if (FAILED(StringCbPrintfW(device_path, sizeof(device_path), L"\\\\?\\usb#%s&mi_00#%s#%s", vidpid,
					   serial, VIRTUALCAM_DEVICE_INTERFACE_W))) {
			return false;
		}
	} else if (FAILED(StringCbPrintfW(device_path, sizeof(device_path), L"\\\\?\\usb#%s#%s#%s", vidpid, serial,
					  VIRTUALCAM_DEVICE_INTERFACE_W))) {
		return false;
	}

	HKEY key = nullptr;
	LSTATUS status = RegOpenKeyExW(HKEY_CLASSES_ROOT, key_path, 0, KEY_SET_VALUE, &key);
	if (status != ERROR_SUCCESS) {
		return false;
	}

	status = RegSetValueExW(key, L"DevicePath", 0, REG_SZ, (const BYTE *)device_path,
				string_size(device_path));
	RegCloseKey(key);

	return status == ERROR_SUCCESS;
}

static bool RegFilters(const wchar_t *name)
{
	ComPtr<IFilterMapper2> fm;
	ComPtr<IMoniker> moniker;
	HRESULT hr;

	hr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER, IID_IFilterMapper2, (void **)&fm);
	if (FAILED(hr)) {
		return false;
	}

	REGFILTER2 rf2;
	rf2.dwVersion = 1;
	rf2.dwMerit = MERIT_DO_NOT_USE;
	rf2.cPins = 1;
	rf2.rgPins = &AMSPinVideo;

	return SUCCEEDED(fm->RegisterFilter(CLSID_OBS_VirtualVideo, name, &moniker, &CLSID_VideoInputDeviceCategory,
					    nullptr, &rf2));
}

static bool UnregFilters()
{
	ComPtr<IFilterMapper2> fm;
	HRESULT hr;

	hr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER, IID_IFilterMapper2, (void **)&fm);
	if (FAILED(hr)) {
		return false;
	}

	return SUCCEEDED(fm->UnregisterFilter(&CLSID_VideoInputDeviceCategory, 0, CLSID_OBS_VirtualVideo));
}

/* ========================================================================= */

/* Resolves the identity applied by this registration, in this order:
 *   1. stored Serial whose format check passes — kept;
 *   2. stored Serial with a mismatched format — regenerated + re-persisted
 *      (e.g. vcamctl set --vid/--pid without --serial, or a legacy install);
 *   3. compiled VIRTUALCAM_DEVICE_SERIAL — kept (deliberate build choice);
 *   4. random serial (OS CSPRNG) persisted to the identity key — a fresh
 *      install's serial; reset clears it and the next registration generates
 *      a fresh one (reset = replaced physical unit);
 *   5. entropy/persist failure — deterministic FNV-1a(MachineGuid + identity)
 *      serial (logged degraded mode, e.g. a non-elevated regsvr32 that
 *      cannot write HKLM). */
static void ResolveRegistrationIdentity(wchar_t *name, size_t name_chars, wchar_t *vidpid, size_t vidpid_chars,
					wchar_t *vid, wchar_t *pid, wchar_t *serial, size_t serial_chars)
{
	uint8_t entropy[16];
	wchar_t generated[33];

	LoadIdentityOverrides(name, name_chars, vidpid, vidpid_chars, serial, serial_chars, vid, pid);

	/* One-time migration: installs that stored the old dialog's C920
	   preset carry the C270 PID 0825 forever (stored overrides beat
	   compiled defaults); rewrite it once, logged. */
	if (_wcsicmp(pid, L"0825") == 0 && wcsstr(name, L"C920") != nullptr) {
		if (RegWriteIdentityValue(L"Pid", L"082D")) {
			LogIdentity(L"vcam-module: migrated legacy pid 0825 to the real C920 pid 082D");
			memcpy(pid, L"082d", 5 * sizeof(wchar_t));
			StringCbPrintfW(vidpid, vidpid_chars * sizeof(wchar_t), L"vid_%s&pid_%s", vid, pid);
		} else {
			LogIdentity(L"vcam-module: legacy pid 0825 detected but the migration write failed");
		}
	}

	/* Sticky-serial check: a stored serial incoherent with the identity's
	   format (vcamctl set --vid/--pid without --serial) regenerates so the
	   DevicePath never ships a detector-visible mismatch. */
	if (serial[0] != L'\0' && !vcam_serial_matches_format(serial, vid, pid)) {
		LogIdentity(L"vcam-module: stored serial does not match the identity's serial format, regenerating");
		serial[0] = L'\0';
	}

	if (serial[0] == L'\0' && VIRTUALCAM_DEVICE_SERIAL_W[0] != L'\0') {
		StringCbCopyW(serial, serial_chars * sizeof(wchar_t), VIRTUALCAM_DEVICE_SERIAL_W);
	}

	if (serial[0] == L'\0') {
		if (GetRandomEntropy(entropy)) {
			vcam_format_serial(vcam_serial_format_for(vid, pid), entropy, generated, _countof(generated));
		} else {
			LogIdentity(L"vcam-module: random entropy unavailable, using the deterministic serial");
			BuildDeterministicSerial(vid, pid, generated, _countof(generated));
		}

		if (RegWriteIdentityValue(L"Serial", generated)) {
			LogIdentity(L"vcam-module: generated a random serial and persisted it to the identity key");
			StringCbCopyW(serial, serial_chars * sizeof(wchar_t), generated);
		} else {
			LogIdentity(L"vcam-module: persisting the serial failed (admin rights required), "
				    "using a deterministic serial");
			BuildDeterministicSerial(vid, pid, serial, serial_chars);
		}
	}
}

/* ========================================================================= */

STDAPI DllRegisterServer()
{
	wchar_t name[128];
	wchar_t vidpid[40];
	wchar_t vid[5];
	wchar_t pid[5];
	wchar_t serial[33];
	HRESULT hr = S_OK;

	/* Serialize the read → generate → persist → DevicePath sequence:
	   concurrent registrations (updater regsvr32, CI, elevated vcamctl)
	   would otherwise interleave and permanently desync the stored Serial
	   from the active DevicePath. */
	HANDLE mutex = CreateMutexW(nullptr, FALSE, L"Local\\OBSVcamRegister");
	bool locked = false;
	if (mutex != nullptr) {
		locked = WaitForSingleObject(mutex, 3000) == WAIT_OBJECT_0;
		if (!locked) {
			LogIdentity(L"vcam-module: register mutex wait failed, continuing unserialized");
		}
	}

	ResolveRegistrationIdentity(name, _countof(name), vidpid, _countof(vidpid), vid, pid, serial,
				    _countof(serial));

	if (!RegServers(name)) {
		UnregServer(CLSID_OBS_VirtualVideo);
		hr = E_FAIL;
	} else {
		CoInitialize(0);

		if (!RegFilters(name)) {
			UnregFilters();
			UnregServer(CLSID_OBS_VirtualVideo);
			hr = E_FAIL;
		} else {
			/* Best effort: a missing DevicePath degrades to a detectable
			   device, not to a broken one. */
			RegFilterDevicePath(CLSID_OBS_VirtualVideo, vidpid, serial, vcam_serial_format_for(vid, pid));
		}

		CoUninitialize();
	}

	if (mutex != nullptr) {
		if (locked) {
			ReleaseMutex(mutex);
		}
		CloseHandle(mutex);
	}

	return hr;
}

STDAPI DllUnregisterServer()
{
	CoInitialize(0);
	UnregFilters();

	/* Defensive: UnregisterFilter removes the Instance tree, but if a
	   previous registration left residue, clean only OUR Instance subtree -
	   never the category's Instance directory, which holds other devices. */
	wchar_t cls_str[CHARS_IN_GUID];
	wchar_t category_str[CHARS_IN_GUID];
	wchar_t key_path[MAX_PATH];
	StringFromGUID2(CLSID_OBS_VirtualVideo, cls_str, CHARS_IN_GUID);
	StringFromGUID2(CLSID_VideoInputDeviceCategory, category_str, CHARS_IN_GUID);
	if (SUCCEEDED(StringCbPrintfW(key_path, sizeof(key_path), L"CLSID\\%s\\Instance\\%s", category_str, cls_str))) {
		RegDeleteTreeW(HKEY_CLASSES_ROOT, key_path);
	}

	UnregServer(CLSID_OBS_VirtualVideo);
	CoUninitialize();
	return S_OK;
}

STDAPI DllInstall(BOOL install, LPCWSTR)
{
	if (!install) {
		return DllUnregisterServer();
	} else {
		return DllRegisterServer();
	}
}

STDAPI DllCanUnloadNow()
{
	return os_atomic_load_long(&locks) ? S_FALSE : S_OK;
}

STDAPI DllGetClassObject(REFCLSID cls, REFIID riid, void **p_ptr)
{
	if (!p_ptr) {
		return E_POINTER;
	}

	*p_ptr = nullptr;

	if (riid != IID_IClassFactory && riid != IID_IUnknown) {
		return E_NOINTERFACE;
	}
	if (!IsEqualCLSID(cls, CLSID_OBS_VirtualVideo)) {
		return E_INVALIDARG;
	}

	*p_ptr = (void *)new VCamFactory(cls);
	return S_OK;
}

//#define ENABLE_LOGGING

#ifdef ENABLE_LOGGING
void logcallback(DShow::LogType, const wchar_t *msg, void *)
{
	OutputDebugStringW(msg);
	OutputDebugStringW(L"\n");
}
#endif

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID)
{
	if (reason == DLL_PROCESS_ATTACH) {
#ifdef ENABLE_LOGGING
		DShow::SetLogCallback(logcallback, nullptr);
#endif
		dll_inst = inst;
	}

	return true;
}
