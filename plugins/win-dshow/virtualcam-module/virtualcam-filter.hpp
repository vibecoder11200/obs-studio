#pragma once

#include <windows.h>
#include <cstdint>
#include <thread>

#ifdef OBS_LEGACY
#include "../shared-memory-queue.h"
#include "../tiny-nv12-scale.h"
#include "../../../deps/libdshowcapture/src/source/output-filter.hpp"
#include "../../../deps/libdshowcapture/src/source/dshow-formats.hpp"
#include "../../../libobs/util/windows/WinHandle.hpp"
#include "../../../libobs/util/threading-windows.h"
#else
#include <shared-memory-queue.h>
#include <tiny-nv12-scale.h>
#include <source/output-filter.hpp>
#include <source/dshow-formats.hpp>
#include <util/windows/WinHandle.hpp>
#include <util/threading-windows.h>
#endif

typedef struct {
	int cx;
	int cy;
	nv12_scale_t scaler;
	const uint8_t *source_data;
	uint8_t *scaled_data;
} placeholder_t;

/* ---------------------------------------------------------------- */
/* camera-control tear-offs (detection vector V7)                   */

class VCamFilter;

enum {
	VCAM_CAMERA_CONTROL_COUNT = 3,
	VCAM_VIDEO_PROC_AMP_COUNT = 6,
};

/* IAMCameraControl / IAMVideoProcAmp handlers. Real webcams answer these,
 * pure software filters usually do not; the ranges mimic a C920 (table in
 * virtualcam-filter.cpp), Get/Set work on stored values and never touch the
 * stream. Lifetime is delegated to the owning filter. */
class VCamCameraControl : public IAMCameraControl {
	VCamFilter *filter;
	long values[VCAM_CAMERA_CONTROL_COUNT];

public:
	explicit VCamCameraControl(VCamFilter *filter_);

	STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override;
	STDMETHODIMP_(ULONG) AddRef() override;
	STDMETHODIMP_(ULONG) Release() override;

	STDMETHODIMP GetRange(long Property, long *pMin, long *pMax, long *pSteppingDelta, long *pDefault,
			      long *pCapsFlags) override;
	STDMETHODIMP Set(long Property, long lValue, long Flags) override;
	STDMETHODIMP Get(long Property, long *lValue, long *lFlags) override;
};

class VCamVideoProcAmp : public IAMVideoProcAmp {
	VCamFilter *filter;
	long values[VCAM_VIDEO_PROC_AMP_COUNT];

public:
	explicit VCamVideoProcAmp(VCamFilter *filter_);

	STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override;
	STDMETHODIMP_(ULONG) AddRef() override;
	STDMETHODIMP_(ULONG) Release() override;

	STDMETHODIMP GetRange(long Property, long *pMin, long *pMax, long *pSteppingDelta, long *pDefault,
			      long *pCapsFlags) override;
	STDMETHODIMP Set(long Property, long lValue, long Flags) override;
	STDMETHODIMP Get(long Property, long *lValue, long *lFlags) override;
};

class VCamFilter : public DShow::OutputFilter {
	std::thread th;

	video_queue_t *vq = nullptr;
	int queue_mode = 0;
	bool in_obs = false;
	enum queue_state prev_state = SHARED_QUEUE_STATE_INVALID;
	placeholder_t placeholder;
	uint32_t obs_cx = 0;
	uint32_t obs_cy = 0;
	uint64_t obs_interval = 0;
	uint32_t filter_cx = 0;
	uint32_t filter_cy = 0;
	DShow::VideoFormat format;
	WinHandle thread_start;
	WinHandle thread_stop;
	volatile bool active = false;

	/* camera-control tear-offs (vector V7), lifetime-bound to the filter */
	VCamCameraControl camera_control;
	VCamVideoProcAmp video_proc_amp;

	nv12_scale_t scaler = {};

	inline bool stopped() const { return WaitForSingleObject(thread_stop, 0) != WAIT_TIMEOUT; }

	inline uint64_t GetTime();

	void Thread();
	void Frame(uint64_t ts);
	void ShowOBSFrame(uint8_t *ptr);
	void ShowDefaultFrame(uint8_t *ptr);
	void UpdatePlaceholder(void);
	const int GetOutputBufferSize(void);

protected:
	const wchar_t *FilterName() const override;

public:
	VCamFilter();
	~VCamFilter() override;

	STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override;
	STDMETHODIMP Pause() override;
	STDMETHODIMP Run(REFERENCE_TIME tStart) override;
	STDMETHODIMP Stop() override;
};
