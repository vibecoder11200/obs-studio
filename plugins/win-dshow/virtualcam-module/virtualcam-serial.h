#pragma once

/* Shared serial-format library for the virtual camera identity.
 *
 * Plain C, no platform dependencies: included unconditionally by the Windows
 * module (virtualcam-module.cpp), the helper CLI (vcamctl.cpp), and the
 * frontend config dialog (all platforms, where it feeds the preset table and
 * the serial generator).
 *
 * The formats mirror verified real hardware (linuxhw/LsUSB dataset,
 * libuvc/USBTree/lkml descriptor dumps); tools/vcam-audit/blocklist.json
 * carries the same table for the audit's V3 coherence check, and CI
 * cross-checks the two (tools/vcam-audit/check-preset-coherence.ps1).
 *
 * Real USB serials are ASCII 0x20-0x7F with no comma (Microsoft USB FAQ and
 * hub driver validation); generated serials stay inside that range. */

#include <stddef.h>
#include <stdint.h>
#include <wchar.h>
#include <wctype.h>

#ifdef __cplusplus
extern "C" {
#endif

enum vcam_serial_format {
	VCAM_SERIAL_8HEX,     /* E1CA2A7F           (old Logitech webcams)   */
	VCAM_SERIAL_8DIGIT,   /* 93004248           (Logitech BRIO 4K)       */
	VCAM_SERIAL_12ALNUM,  /* 2419LZ50AFL8       (Logitech Brio 500)      */
	VCAM_SERIAL_ELGATO,   /* FW15K1A12513       (Elgato Facecam)         */
	VCAM_SERIAL_LOCATION, /* 6&330c68f9&0&0000  (Windows location ID for */
			      /*  cameras with no real serial)                */
};

/* C's enum tags are not bare type names; keep the header usable as C. */
typedef enum vcam_serial_format vcam_serial_format;

/* Verified VID/PID pairs; lookup is case-insensitive and falls back on the
 * vendor prefix (046d Logitech by PID, 0fd9 Elgato), then 8HEX. */
typedef struct {
	const wchar_t *vid;
	const wchar_t *pid;
	vcam_serial_format format;
} vcam_serial_pair;

static inline const vcam_serial_pair *vcam_serial_pairs(void)
{
	static const vcam_serial_pair pairs[] = {
		{L"046d", L"082d", VCAM_SERIAL_8HEX},     /* Logitech HD Pro Webcam C920  */
		{L"046d", L"085c", VCAM_SERIAL_8HEX},     /* Logitech C922 Pro Stream     */
		{L"046d", L"0843", VCAM_SERIAL_8HEX},     /* Logitech Webcam C930e        */
		{L"046d", L"085e", VCAM_SERIAL_8DIGIT},   /* Logitech BRIO Ultra HD       */
		{L"046d", L"0943", VCAM_SERIAL_12ALNUM},  /* Logitech Brio 500            */
		{L"0fd9", L"0078", VCAM_SERIAL_ELGATO},   /* Elgato Facecam               */
		{L"04f2", L"b76f", VCAM_SERIAL_LOCATION}, /* ACER HD User Facing          */
		{L"0408", L"5365", VCAM_SERIAL_LOCATION}, /* HP TrueVision HD Camera      */
		{L"5986", L"0652", VCAM_SERIAL_LOCATION}, /* Lenovo EasyCamera            */
		{L"0c45", L"6723", VCAM_SERIAL_LOCATION}, /* Integrated_Webcam_HD (Dell)  */
		{L"13d3", L"56a2", VCAM_SERIAL_LOCATION}, /* USB2.0 HD UVC WebCam (IMC)   */
		{L"0408", L"1110", VCAM_SERIAL_LOCATION}, /* HD Camera (Quanta)           */
	};
	return pairs;
}

static inline int vcam_hex4_eq(const wchar_t *a, const wchar_t *b)
{
	for (int i = 0; i < 4; ++i) {
		if (towlower(a[i]) != towlower(b[i])) {
			return 0;
		}
	}
	return 1;
}

static inline vcam_serial_format vcam_serial_format_for(const wchar_t *vid, const wchar_t *pid)
{
	const vcam_serial_pair *pairs = vcam_serial_pairs();

	for (int i = 0; i < 12; ++i) {
		if (vcam_hex4_eq(vid, pairs[i].vid) && vcam_hex4_eq(pid, pairs[i].pid)) {
			return pairs[i].format;
		}
	}

	/* Vendor fallbacks for pairs outside the preset table. */
	if (vcam_hex4_eq(vid, L"046d")) {
		if (vcam_hex4_eq(pid, L"085e")) {
			return VCAM_SERIAL_8DIGIT;
		}
		if (vcam_hex4_eq(pid, L"0943")) {
			return VCAM_SERIAL_12ALNUM;
		}
		return VCAM_SERIAL_8HEX;
	}
	if (vcam_hex4_eq(vid, L"0fd9")) {
		return VCAM_SERIAL_ELGATO;
	}

	return VCAM_SERIAL_8HEX;
}

/* LOCATION-format identities composite their DevicePath as
 * usb#vid_X&pid_Y&mi_00#... — the structure real laptop built-ins (composite
 * UVC devices) report; direct serial-carrying cameras use usb#vid#pid#... */
static inline int vcam_serial_needs_mi00(vcam_serial_format fmt)
{
	return fmt == VCAM_SERIAL_LOCATION;
}

static inline int vcam_is_digit(wchar_t c)
{
	return c >= L'0' && c <= L'9';
}

static inline int vcam_is_upper_hex(wchar_t c)
{
	return vcam_is_digit(c) || (c >= L'A' && c <= L'F');
}

static inline int vcam_is_lower_hex(wchar_t c)
{
	return vcam_is_digit(c) || (c >= L'a' && c <= L'f');
}

static inline int vcam_is_upper_alnum(wchar_t c)
{
	return vcam_is_digit(c) || (c >= L'A' && c <= L'Z');
}

static inline int vcam_serial_matches(const wchar_t *s, vcam_serial_format fmt)
{
	size_t n = wcslen(s);

	switch (fmt) {
	case VCAM_SERIAL_8HEX:
		if (n != 8) {
			return 0;
		}
		for (const wchar_t *p = s; *p; ++p) {
			if (!vcam_is_upper_hex(*p)) {
				return 0;
			}
		}
		return 1;

	case VCAM_SERIAL_8DIGIT:
		if (n != 8) {
			return 0;
		}
		for (const wchar_t *p = s; *p; ++p) {
			if (!vcam_is_digit(*p)) {
				return 0;
			}
		}
		return 1;

	case VCAM_SERIAL_12ALNUM:
		if (n != 12) {
			return 0;
		}
		for (int i = 0; i < 4; ++i) {
			if (!vcam_is_digit(s[i])) {
				return 0;
			}
		}
		for (int i = 4; i < 12; ++i) {
			if (!vcam_is_upper_alnum(s[i])) {
				return 0;
			}
		}
		return 1;

	case VCAM_SERIAL_ELGATO:
		return n == 12 && s[0] == L'F' && s[1] == L'W' && vcam_is_digit(s[2]) && vcam_is_digit(s[3]) &&
		       s[4] == L'K' && s[5] == L'1' && s[6] == L'A' && vcam_is_digit(s[7]) && vcam_is_digit(s[8]) &&
		       vcam_is_digit(s[9]) && vcam_is_digit(s[10]) && vcam_is_digit(s[11]);

	case VCAM_SERIAL_LOCATION:
		/* 6&hhhhhhhh&0&dddd — mirrors the audit's pattern. */
		if (n != 17 || s[0] != L'6' || s[1] != L'&' || s[10] != L'&' || s[11] != L'0' || s[12] != L'&') {
			return 0;
		}
		for (int i = 2; i < 10; ++i) {
			if (!vcam_is_lower_hex(s[i])) {
				return 0;
			}
		}
		for (int i = 13; i < 17; ++i) {
			if (!vcam_is_digit(s[i])) {
				return 0;
			}
		}
		return 1;
	}

	return 0;
}

static inline int vcam_serial_matches_format(const wchar_t *serial, const wchar_t *vid, const wchar_t *pid)
{
	return vcam_serial_matches(serial, vcam_serial_format_for(vid, pid));
}

/* Deterministic formatting from 16 bytes of entropy. Writes at most 17
 * characters plus the terminator. Entropy consumption: 8HEX/8DIGIT/LOCATION
 * render one 32-bit word from entropy[0..3]; 12ALNUM uses entropy[0..11]
 * (word for the 4 digits, one byte per [A-Z0-9] char — the % 36 selection is
 * negligibly biased); ELGATO uses entropy[0..7]. */
static inline void vcam_format_serial(vcam_serial_format fmt, const uint8_t entropy[16], wchar_t *out,
				      size_t out_chars)
{
	uint32_t w = ((uint32_t)entropy[0] << 24) | ((uint32_t)entropy[1] << 16) | ((uint32_t)entropy[2] << 8) |
		     (uint32_t)entropy[3];

	switch (fmt) {
	case VCAM_SERIAL_8HEX:
		swprintf(out, out_chars, L"%08X", (unsigned)w);
		break;

	case VCAM_SERIAL_8DIGIT:
		swprintf(out, out_chars, L"%08u", (unsigned)(w % 100000000u));
		break;

	case VCAM_SERIAL_12ALNUM: {
		static const wchar_t alphabet[] = L"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

		swprintf(out, out_chars, L"%04u", (unsigned)(w % 10000u));
		for (int i = 0; i < 8; ++i) {
			out[4 + i] = alphabet[entropy[4 + i] % 36];
		}
		out[12] = L'\0';
		break;
	}

	case VCAM_SERIAL_ELGATO: {
		uint32_t a = ((uint32_t)entropy[0] << 8) | (uint32_t)entropy[1];
		uint32_t b = ((uint32_t)entropy[2] << 24) | ((uint32_t)entropy[3] << 16) | ((uint32_t)entropy[4] << 8) |
			     (uint32_t)entropy[5];

		swprintf(out, out_chars, L"FW%02uK1A%05u", (unsigned)(a % 100u), (unsigned)(b % 100000u));
		break;
	}

	case VCAM_SERIAL_LOCATION:
		swprintf(out, out_chars, L"6&%08x&0&0000", (unsigned)w);
		break;
	}
}

/* FNV-chain expansion: renders 16 entropy bytes from a 32-bit seed by
 * re-hashing the state, so the deterministic FNV-1a(MachineGuid) fallback can
 * fill formats that need more than 32 bits. */
static inline void vcam_entropy_from_seed(uint32_t seed, uint8_t entropy[16])
{
	uint32_t h = seed;

	for (int i = 0; i < 4; ++i) {
		for (int b = 0; b < 4; ++b) {
			h ^= (h >> (8 * b)) & 0xFFu;
			h *= 16777619u;
		}
		entropy[4 * i + 0] = (uint8_t)(h >> 24);
		entropy[4 * i + 1] = (uint8_t)(h >> 16);
		entropy[4 * i + 2] = (uint8_t)(h >> 8);
		entropy[4 * i + 3] = (uint8_t)h;
	}
}

#ifdef __cplusplus
}
#endif
