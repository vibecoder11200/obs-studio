#include "virtualcam-filter.hpp"
#include "virtualcam-guid.h"
#include "virtualcam-brand.h"
#include "virtualcam-device.h"

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
	inline VCamFactory(CLSID cls_) : cls(cls_) {}

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

static bool RegServers(bool reg)
{
	wchar_t file[MAX_PATH];

	if (!GetModuleFileNameW(dll_inst, file, MAX_PATH)) {
		return false;
	}

	if (reg) {
		return RegServer(CLSID_OBS_VirtualVideo, VIRTUALCAM_BRAND_NAME_W, file);
	} else {
		return UnregServer(CLSID_OBS_VirtualVideo);
	}
}

/* Writes the USB-style DevicePath value under the filter's category Instance
   key, where apps (Skype/Unity-era checkers) read it for physical cameras.
   UnregisterFilter removes the whole Instance tree, so no extra cleanup is
   needed beyond the defensive delete in DllUnregisterServer. */
static bool RegFilterDevicePath(const CLSID &clsid)
{
	wchar_t serial[16] = L"";

	if (VIRTUALCAM_DEVICE_SERIAL_W[0] != L'\0') {
		StringCbCopyW(serial, sizeof(serial), VIRTUALCAM_DEVICE_SERIAL_W);
	} else {
		/* Derive a stable per-machine serial: FNV-1a over MachineGuid. */
		wchar_t machine_guid[64] = L"";
		DWORD size = sizeof(machine_guid);

		LSTATUS status = RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Cryptography",
					      L"MachineGuid", RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr,
					      machine_guid, &size);
		if (status != ERROR_SUCCESS) {
			return false;
		}

		uint32_t hash = 2166136261u;
		for (const wchar_t *p = machine_guid; *p; ++p) {
			hash ^= (uint32_t)(uint16_t)*p;
			hash *= 16777619u;
		}

		StringCbPrintfW(serial, sizeof(serial), L"%08X", hash);
	}

	wchar_t cls_str[CHARS_IN_GUID];
	wchar_t category_str[CHARS_IN_GUID];
	wchar_t key_path[MAX_PATH];
	wchar_t device_path[MAX_PATH];

	StringFromGUID2(clsid, cls_str, CHARS_IN_GUID);
	StringFromGUID2(CLSID_VideoInputDeviceCategory, category_str, CHARS_IN_GUID);

	if (FAILED(StringCbPrintfW(key_path, sizeof(key_path), L"CLSID\\%s\\Instance\\%s", category_str, cls_str))) {
		return false;
	}
	if (FAILED(StringCbPrintfW(device_path, sizeof(device_path), L"\\\\?\\usb#%s#%s#%s",
				   VIRTUALCAM_DEVICE_VIDPID_W, serial, VIRTUALCAM_DEVICE_INTERFACE_W))) {
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

static bool RegFilters(bool reg)
{
	ComPtr<IFilterMapper2> fm;
	HRESULT hr;

	hr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER, IID_IFilterMapper2, (void **)&fm);
	if (FAILED(hr)) {
		return false;
	}

	if (reg) {
		ComPtr<IMoniker> moniker;
		REGFILTER2 rf2;
		rf2.dwVersion = 1;
		rf2.dwMerit = MERIT_DO_NOT_USE;
		rf2.cPins = 1;
		rf2.rgPins = &AMSPinVideo;

		hr = fm->RegisterFilter(CLSID_OBS_VirtualVideo, VIRTUALCAM_BRAND_NAME_W, &moniker,
					&CLSID_VideoInputDeviceCategory, nullptr, &rf2);
		if (FAILED(hr)) {
			return false;
		}
	} else {
		hr = fm->UnregisterFilter(&CLSID_VideoInputDeviceCategory, 0, CLSID_OBS_VirtualVideo);
		if (FAILED(hr)) {
			return false;
		}
	}

	return true;
}

/* ========================================================================= */

STDAPI DllRegisterServer()
{
	if (!RegServers(true)) {
		RegServers(false);
		return E_FAIL;
	}

	CoInitialize(0);

	if (!RegFilters(true)) {
		RegFilters(false);
		RegServers(false);
		CoUninitialize();
		return E_FAIL;
	}

	/* Best effort: a missing DevicePath degrades to a detectable device,
	   not to a broken one. */
	RegFilterDevicePath(CLSID_OBS_VirtualVideo);

	CoUninitialize();
	return S_OK;
}

STDAPI DllUnregisterServer()
{
	CoInitialize(0);
	RegFilters(false);

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

	RegServers(false);
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
