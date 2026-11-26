#define _GNU_SOURCE

#include <obs-module.h>
#include <util/dstr.h>
#include <util/platform.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <string.h>

struct virtualcam_data {
	obs_output_t *output;
	int device;
	uint32_t frame_size;
	bool use_caps_workaround;
	char card_label[32];
};

static const char *virtualcam_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "Virtual Camera Output";
}

static void virtualcam_destroy(void *data)
{
	struct virtualcam_data *vcam = (struct virtualcam_data *)data;

	if (vcam->device >= 0)
		close(vcam->device);

	bfree(data);
}

#if defined(__linux__)
static bool is_flatpak_sandbox(void)
{
	static bool flatpak_info_exists = false;
	static bool initialized = false;

	if (!initialized) {
		flatpak_info_exists = access("/.flatpak-info", F_OK) == 0;
		initialized = true;
	}

	return flatpak_info_exists;
}

static int run_command(const char *command)
{
	struct dstr str;
	int result;

	dstr_init_copy(&str, "PATH=\"$PATH:/sbin\" ");

	if (is_flatpak_sandbox())
		dstr_cat(&str, "flatpak-spawn --host ");

	dstr_cat(&str, command);
	result = system(str.array);
	dstr_free(&str);
	return result;
}

/* Neutral module name and card label for the virtual camera. The forked
 * vcamuvc module (vendored v4l2loopback with the identity patch) reports a
 * real UVC identity; the stock v4l2loopback stays as a fallback with the
 * same label, but the audit tool flags its driver-name tell.
 * VIRTUALCAM_LINUX_CARD_LABEL is threaded from CMakePresets.json. */
#ifndef VIRTUALCAM_LINUX_CARD_LABEL
#define VIRTUALCAM_LINUX_CARD_LABEL "OBS Virtual Camera"
#endif

static bool loopback_module_loaded_name(const char *module)
{
	bool loaded = false;

	char temp[512];

	FILE *fp = fopen("/proc/modules", "r");

	if (!fp)
		return false;

	while (fgets(temp, sizeof(temp), fp)) {
		if (strstr(temp, module)) {
			loaded = true;
			break;
		}
	}

	fclose(fp);

	return loaded;
}

static bool loopback_module_loaded()
{
	/* the forked module first: if both are loaded, it owns the identity */
	return loopback_module_loaded_name("vcamuvc") ||
	       loopback_module_loaded_name("v4l2loopback");
}

bool loopback_module_available()
{
	if (loopback_module_loaded()) {
		return true;
	}

	if (run_command("modinfo vcamuvc >/dev/null 2>&1") == 0 ||
	    run_command("modinfo v4l2loopback >/dev/null 2>&1") == 0) {
		return true;
	}

	return false;
}

static int modprobe_with_label(const char *module, const char *label)
{
	struct dstr command = {0};
	struct dstr escaped = {0};
	int result;

	dstr_init_copy(&escaped, label);
	/* the label lands inside a single-quoted shell argument; escape any
	   single quote instead of letting it break out of the quoting */
	dstr_replace(&escaped, "'", "'\\''");

	dstr_init_copy(&command, "pkexec sh -c 'modprobe ");
	dstr_cat(&command, module);
	dstr_cat(&command, " exclusive_caps=1 card_label=\"$1\"' sh '");
	dstr_cat(&command, escaped.array);
	dstr_cat(&command, "' && sleep 0.5");
	result = run_command(command.array);

	dstr_free(&command);
	dstr_free(&escaped);
	return result;
}

/* ONE atomic pkexec: rmmod + re-modprobe in a single sh -c, so a denied
   second polkit prompt (or an EBUSY rmmod) can never leave the camera
   unloaded. On failure the caller re-modprobes with the OLD label before
   continuing. */
static int reload_module(const char *label)
{
	struct dstr command = {0};
	struct dstr escaped = {0};
	int result;

	dstr_init_copy(&escaped, label);
	dstr_replace(&escaped, "'", "'\\''");

	dstr_init_copy(&command, "pkexec sh -c 'modprobe -r vcamuvc && sleep 0.5 && modprobe vcamuvc exclusive_caps=1 card_label=\"$1\"' sh '");
	dstr_cat(&command, escaped.array);
	dstr_cat(&command, "' && sleep 0.5");
	result = run_command(command.array);

	dstr_free(&command);
	dstr_free(&escaped);
	return result;
}

static int loopback_module_load(const char *label)
{
	/* prefer the forked module (real UVC identity); fall back to the
	   stock module, whose `v4l2 loopback` compiled-in label is set by the
	   same card_label parameter */
	if (modprobe_with_label("vcamuvc", label) == 0)
		return 0;

	return modprobe_with_label("v4l2loopback", label);
}
#else
bool loopback_module_available()
{
	struct v4l2_capability capability;
	char new_device[16];
	int fd;
	int i;

	for (i = 0; i != 32; i++) {
		snprintf(new_device, 16, "/dev/video%d", i);
		fd = open(new_device, O_RDWR);
		if (fd < 0)
			continue;
		if (ioctl(fd, VIDIOC_QUERYCAP, &capability) < 0) {
			close(fd);
			continue;
		}
		if (capability.capabilities & V4L2_CAP_VIDEO_OUTPUT) {
			close(fd);
			return true;
		}
		close(fd);
	}
	return false;
}
#endif

static void *virtualcam_create(obs_data_t *settings, obs_output_t *output)
{
	struct virtualcam_data *vcam = (struct virtualcam_data *)bzalloc(sizeof(*vcam));
	vcam->output = output;
	vcam->device = -1;

	UNUSED_PARAMETER(settings);
	return vcam;
}

static bool try_connect(void *data, const char *device, bool forked_only)
{
	static bool use_caps_workaround = false;
	struct virtualcam_data *vcam = (struct virtualcam_data *)data;
	struct v4l2_capability capability;
	struct v4l2_format format;
	struct v4l2_streamparm parm;

	uint32_t width = obs_output_get_width(vcam->output);
	uint32_t height = obs_output_get_height(vcam->output);

	vcam->frame_size = width * height * 2;

	vcam->device = open(device, O_RDWR);

	if (vcam->device < 0)
		return false;

	if (ioctl(vcam->device, VIDIOC_QUERYCAP, &capability) < 0)
		goto fail_close_device;

	/* prefer devices backed by the forked module (they report the real
	   UVC identity); stock v4l2loopback stays a fallback in the second pass */
	if (forked_only && strcmp((const char *)capability.driver, "uvcvideo") != 0)
		goto fail_close_device;

	if (!(capability.device_caps & V4L2_CAP_VIDEO_OUTPUT))
		goto fail_close_device;

	format.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;

	if (ioctl(vcam->device, VIDIOC_G_FMT, &format) < 0)
		goto fail_close_device;

	struct obs_video_info ovi;
	obs_get_video_info(&ovi);

	memset(&parm, 0, sizeof(parm));
	parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;

	parm.parm.output.capability = V4L2_CAP_TIMEPERFRAME;
	parm.parm.output.timeperframe.numerator = ovi.fps_den;
	parm.parm.output.timeperframe.denominator = ovi.fps_num;

	if (ioctl(vcam->device, VIDIOC_S_PARM, &parm) < 0)
		goto fail_close_device;

	format.fmt.pix.width = width;
	format.fmt.pix.height = height;
	format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	format.fmt.pix.sizeimage = vcam->frame_size;

	if (ioctl(vcam->device, VIDIOC_S_FMT, &format) < 0)
		goto fail_close_device;

	if (!use_caps_workaround && ioctl(vcam->device, VIDIOC_STREAMON, &format.type) == 0) {
		/* STREAMON should error on all devices except v4l2loopback 0.12.x-0.13.x */
		use_caps_workaround = true;
	}
	vcam->use_caps_workaround = use_caps_workaround;

	struct video_scale_info vsi = {0};
	vsi.format = VIDEO_FORMAT_YUY2;
	vsi.width = width;
	vsi.height = height;
	obs_output_set_video_conversion(vcam->output, &vsi);

	memset(&parm, 0, sizeof(parm));
	parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;

	if (vcam->use_caps_workaround && ioctl(vcam->device, VIDIOC_STREAMON, &format.type) < 0) {
		blog(LOG_ERROR, "Failed to start streaming on '%s' (%s)", device, strerror(errno));
		goto fail_close_device;
	}

	blog(LOG_INFO, "Virtual camera started");
	obs_output_begin_data_capture(vcam->output, 0);

	return true;

fail_close_device:
	close(vcam->device);
	vcam->device = -1;
	return false;
}

static int scanfilter(const struct dirent *entry)
{
	return !astrcmp_n(entry->d_name, "video", 5);
}

/* Card label of the module's device, found by capability (OUTPUT cap +
   "uvcvideo" driver), never by name: vdev->name is the label itself, so a
   name scan would false-match the user's real webcams carrying preset
   product strings. */
static bool active_card_label(char *label, size_t size)
{
	struct dirent **list = NULL;
	struct v4l2_capability cap;
	bool found = false;
	int n;

	n = scandir("/dev", &list, scanfilter,
#if defined(__linux__)
		    versionsort
#else
		    alphasort
#endif
	);
	if (n == -1)
		return false;

	for (int i = 0; i < n; ++i) {
		char device[32] = {0};
		int fd;

		/* check the return: -Wformat-truncation fires on the 256-byte
		   d_name otherwise (CI builds with -Werror) */
		int written = snprintf(device, sizeof(device), "/dev/%s", list[i]->d_name);
		if (written < 0 || written >= (int)sizeof(device)) {
			free(list[i]);
			continue;
		}
		fd = open(device, O_RDWR);
		if (fd < 0) {
			free(list[i]);
			continue;
		}
		if (ioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
			close(fd);
			free(list[i]);
			continue;
		}
		if ((cap.device_caps & V4L2_CAP_VIDEO_OUTPUT) &&
		    strcmp((const char *)cap.driver, "uvcvideo") == 0) {
			snprintf(label, size, "%s", (const char *)cap.card);
			found = true;
		}
		close(fd);
		free(list[i]);
		if (found)
			break;
	}

	while (n--)
		free(list[n]);
	free(list);

	return found;
}

static bool virtualcam_start(void *data)
{
	struct virtualcam_data *vcam = (struct virtualcam_data *)data;
	struct dirent **list;
	bool success = false;
	int n;

#if defined(__linux__)
	/* The label applies at modprobe time only: read it from the output
	   settings (pushed by StartVirtualCam at start, never a ctor-time
	   snapshot) with the compiled macro as fallback. */
	char requested[32] = {0};
	obs_data_t *settings = obs_output_get_settings(vcam->output);
	const char *label = obs_data_get_string(settings, "card_label");
	if (label && *label)
		snprintf(requested, sizeof(requested), "%s", label);
	obs_data_release(settings);

	if (!*requested) {
		snprintf(requested, sizeof(requested), "%s", VIRTUALCAM_LINUX_CARD_LABEL);
	}
	snprintf(vcam->card_label, sizeof(vcam->card_label), "%s", requested);

	/* only the forked module counts as "already loaded": with the stock
	   module alone, still load the forked one so the identity holds */
	if (!loopback_module_loaded_name("vcamuvc")) {
		if (loopback_module_load(requested) != 0)
			return false;
	} else {
		char active[32] = {0};
		if (active_card_label(active, sizeof(active)) && strcmp(active, requested) != 0) {
			blog(LOG_INFO, "virtual camera card label change '%s' -> '%s' (atomic module reload)",
			     active, requested);
			if (reload_module(requested) != 0) {
				blog(LOG_WARNING, "label reload failed; restoring the previous card label '%s'",
				     active);
				if (reload_module(active) != 0) {
					blog(LOG_ERROR, "module reload recovery failed; virtual camera unavailable");
					return false;
				}
			}
		}
	}
#endif

	n = scandir("/dev", &list, scanfilter,
#if defined(__linux__)
		    versionsort
#else
		    alphasort
#endif
	);

	if (n == -1)
		return false;

	for (int pass = 0; pass < 2 && !success; pass++) {
		/* the first pass prefers forked-module devices (real UVC identity),
		   the second pass accepts any loopback device as a fallback */
		bool forked_only = pass == 0;

		for (int i = 0; i < n; i++) {
			char device[32] = {0};

#if !defined(__linux__)
			if (strstr(list[i]->d_name, "video") != list[i]->d_name)
				continue;
#endif

			// Use the return value of snprintf to prevent truncation warning.
			int written = snprintf(device, 32, "/dev/%s", list[i]->d_name);
			if (written >= 32)
				blog(LOG_DEBUG, "v4l2-output: A format truncation may have occurred."
						" This can be ignored since it is quite improbable.");

			if (try_connect(vcam, device, forked_only)) {
				success = true;
				break;
			}
		}
	}

	while (n--)
		free(list[n]);
	free(list);

	if (!success)
		blog(LOG_WARNING, "Failed to start virtual camera");

	return success;
}

static void virtualcam_stop(void *data, uint64_t ts)
{
	struct virtualcam_data *vcam = (struct virtualcam_data *)data;
	obs_output_end_data_capture(vcam->output);

	uint32_t buf_type = V4L2_BUF_TYPE_VIDEO_OUTPUT;

	if (vcam->use_caps_workaround && ioctl(vcam->device, VIDIOC_STREAMOFF, &buf_type) < 0) {
		blog(LOG_WARNING, "Failed to stop streaming on video device %d (%s)", vcam->device, strerror(errno));
	}

	close(vcam->device);
	vcam->device = -1;
	blog(LOG_INFO, "Virtual camera stopped");

	UNUSED_PARAMETER(ts);
}

static void virtual_video(void *param, struct video_data *frame)
{
	struct virtualcam_data *vcam = (struct virtualcam_data *)param;
	uint32_t frame_size = vcam->frame_size;
	while (frame_size > 0) {
		ssize_t written = write(vcam->device, frame->data[0], vcam->frame_size);
		if (written == -1)
			break;
		frame_size -= written;
	}
}

struct obs_output_info virtualcam_info = {
	.id = "virtualcam_output",
	.flags = OBS_OUTPUT_VIDEO,
	.get_name = virtualcam_name,
	.create = virtualcam_create,
	.destroy = virtualcam_destroy,
	.start = virtualcam_start,
	.stop = virtualcam_stop,
	.raw_video = virtual_video,
};
