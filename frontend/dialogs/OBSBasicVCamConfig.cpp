#include "OBSBasicVCamConfig.hpp"

#include <OBSApp.hpp>

#include <QRandomGenerator>
#include <QRegularExpression>

#include "virtualcam-serial.h"

#include "moc_OBSBasicVCamConfig.cpp"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>

#include <QCoreApplication>
#include <QFileInfo>
#include <QMessageBox>
#endif

#ifdef __linux__
#include <QMessageBox>

#include <util/config-file.h>
#endif

/* The 12 verified camera presets, in the locked order, as plain string
 * literals (check-preset-coherence.ps1 regex-parses these rows); "Custom"
 * is appended after the table. Mirrors the pair table in
 * virtualcam-serial.h and the serial_formats rows in
 * tools/vcam-audit/blocklist.json (CI cross-checks the three). */
#if defined(_WIN32) || defined(__linux__)
struct VCamPreset {
	const char *name;
	const char *vid;
	const char *pid;
	vcam_serial_format serial_kind;
};

static const VCamPreset presets[] = {
	{"Logitech HD Pro Webcam C920", "046D", "082D", VCAM_SERIAL_8HEX},
	{"Logitech C922 Pro Stream Webcam", "046D", "085C", VCAM_SERIAL_8HEX},
	{"Logitech Webcam C930e", "046D", "0843", VCAM_SERIAL_8HEX},
	{"Logitech BRIO Ultra HD Webcam", "046D", "085E", VCAM_SERIAL_8DIGIT},
	{"Logitech Brio 500", "046D", "0943", VCAM_SERIAL_12ALNUM},
	{"Elgato Facecam", "0FD9", "0078", VCAM_SERIAL_ELGATO},
	{"ACER HD User Facing", "04F2", "B76F", VCAM_SERIAL_LOCATION},
	{"HP TrueVision HD Camera", "0408", "5365", VCAM_SERIAL_LOCATION},
	{"Lenovo EasyCamera", "5986", "0652", VCAM_SERIAL_LOCATION},
	{"Integrated_Webcam_HD", "0C45", "6723", VCAM_SERIAL_LOCATION},
	{"USB2.0 HD UVC WebCam", "13D3", "56A2", VCAM_SERIAL_LOCATION},
	{"HD Camera", "0408", "1110", VCAM_SERIAL_LOCATION},
};
#endif /* _WIN32 || __linux__ */

#ifdef _WIN32
/* Non-elevated read of the stored identity under HKLM\...\Identity (the
 * key is world-readable). Mirrors VIRTUALCAM_IDENTITY_KEY_W, which the
 * frontend cannot include (it is generated for the module only). */
static bool ReadIdentityValue(const wchar_t *value, wchar_t *out, size_t out_chars)
{
	DWORD size = (DWORD)(out_chars * sizeof(wchar_t));

	out[0] = L'\0';
	return RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Logitech\\Identity", value, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
			    nullptr, out, &size) == ERROR_SUCCESS &&
	       out[0] != L'\0';
}

static bool RegValidHexText(const wchar_t *str)
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

/* Random serial in the format of the given vid/pid (QRandomGenerator is
 * CSPRNG-backed). */
static QString GenerateSerialFor(const wchar_t *vid, const wchar_t *pid)
{
	uint8_t entropy[16];
	wchar_t out[33];
	auto *rng = QRandomGenerator::system();

	for (int i = 0; i < 4; ++i) {
		quint32 v = rng->generate();
		entropy[4 * i + 0] = (uint8_t)(v >> 24);
		entropy[4 * i + 1] = (uint8_t)(v >> 16);
		entropy[4 * i + 2] = (uint8_t)(v >> 8);
		entropy[4 * i + 3] = (uint8_t)v;
	}

	vcam_format_serial(vcam_serial_format_for(vid, pid), entropy, out, _countof(out));
	return QString::fromWCharArray(out);
}
#endif

OBSBasicVCamConfig::OBSBasicVCamConfig(const VCamConfig &_config, bool _vcamActive, QWidget *parent)
	: config(_config),
	  vcamActive(_vcamActive),
	  activeType(_config.type),
	  QDialog(parent),
	  ui(new Ui::OBSBasicVCamConfig)
{
	setWindowFlags(windowFlags() & ~Qt::WindowContextHelpButtonHint);

	ui->setupUi(this);

	ui->outputType->addItem(QTStr("Basic.VCam.OutputType.Program"), (int)VCamOutputType::ProgramView);
	ui->outputType->addItem(QTStr("StudioMode.Preview"), (int)VCamOutputType::PreviewOutput);
	ui->outputType->addItem(QTStr("Basic.Scene"), (int)VCamOutputType::SceneOutput);
	ui->outputType->addItem(QTStr("Basic.Main.Source"), (int)VCamOutputType::SourceOutput);

	ui->outputType->setCurrentIndex(ui->outputType->findData((int)config.type));
	OutputTypeChanged();
	connect(ui->outputType, &QComboBox::currentIndexChanged, this, &OBSBasicVCamConfig::OutputTypeChanged);

	connect(ui->buttonBox, &QDialogButtonBox::accepted, this, &OBSBasicVCamConfig::UpdateConfig);

#if defined(_WIN32) || defined(__linux__)
	/* The 12 verified presets + Custom. Dialog open only displays the
	 * stored identity; fresh serials are generated ONLY on an explicit
	 * preset selection or Generate click, so an open-and-Apply cannot
	 * rotate the identity (red-team finding 9). */
	for (const VCamPreset &preset : presets) {
		ui->identityPreset->addItem(preset.name);
	}
	ui->identityPreset->addItem(QTStr("Basic.VCam.Identity.Preset.Custom"));

#ifdef __linux__
	/* Runtime identity on Linux is the card label the plugin applies at
	 * modprobe (consumed by StartVirtualCam): preset + name + Apply are
	 * enough; VID/PID/serial/reset are Windows-only (vcamctl + UAC) and
	 * the hint text describes that flow. Apply stays visible — it is the
	 * commit path. */
	ui->identityName->setMaxLength(31); /* kernel card_label[32] */
	ui->identityVidLabel->setVisible(false);
	ui->identityVid->setVisible(false);
	ui->identityPidLabel->setVisible(false);
	ui->identityPid->setVisible(false);
	ui->identitySerialLabel->setVisible(false);
	ui->identitySerial->setVisible(false);
	ui->identityGenerate->setVisible(false);
	ui->identityReset->setVisible(false);
	ui->identityHint->setVisible(false);
#endif

	/* Display the stored identity at open, then select the matching
	 * preset with signals blocked so no generation path fires. */
	QString storedName;
#ifdef _WIN32
	wchar_t sName[128];
	wchar_t sVid[16];
	wchar_t sPid[16];
	wchar_t sSerial[33];

	if (ReadIdentityValue(L"Name", sName, _countof(sName))) {
		storedName = QString::fromWCharArray(sName);
		ui->identityName->setText(storedName);
	}
	if (ReadIdentityValue(L"Vid", sVid, _countof(sVid)) && ReadIdentityValue(L"Pid", sPid, _countof(sPid)) &&
	    RegValidHexText(sVid) && RegValidHexText(sPid)) {
		ui->identityVid->setText(QString::fromWCharArray(sVid).toUpper());
		ui->identityPid->setText(QString::fromWCharArray(sPid).toUpper());
	}
	if (ReadIdentityValue(L"Serial", sSerial, _countof(sSerial))) {
		ui->identitySerial->setText(QString::fromWCharArray(sSerial));
	}

	QString storedVid = ui->identityVid->text();
	QString storedPid = ui->identityPid->text();
	int match = -1;
	if (storedVid.size() == 4 && storedPid.size() == 4) {
		for (int i = 0; i < (int)(sizeof(presets) / sizeof(presets[0])); ++i) {
			if (storedVid.compare(QLatin1String(presets[i].vid), Qt::CaseInsensitive) == 0 &&
			    storedPid.compare(QLatin1String(presets[i].pid), Qt::CaseInsensitive) == 0) {
				match = i;
				break;
			}
		}
	}
#elif defined(__linux__)
	/* The stored label is the config value written by this dialog. */
	const char *storedLabel = config_get_string(App()->GetUserConfig(), "VirtualCamera", "CardLabel");
	if (storedLabel && *storedLabel) {
		storedName = QString::fromUtf8(storedLabel).left(31);
		ui->identityName->setText(storedName);
	}
	int match = -1;
	if (!storedName.isEmpty()) {
		for (int i = 0; i < (int)(sizeof(presets) / sizeof(presets[0])); ++i) {
			if (storedName.compare(QLatin1String(presets[i].name)) == 0) {
				match = i;
				break;
			}
		}
	}
#endif

	/* Select the matching preset (vid/pid on Windows, name on Linux),
	 * Custom otherwise — without firing the generate path. */
	const int count = (int)(sizeof(presets) / sizeof(presets[0]));
	ui->identityPreset->blockSignals(true);
	ui->identityPreset->setCurrentIndex(match >= 0 ? match : count);
	ui->identityPreset->blockSignals(false);

	connect(ui->identityPreset, &QComboBox::currentIndexChanged, this,
		&OBSBasicVCamConfig::IdentityPresetChanged);
	connect(ui->identityApply, &QPushButton::clicked, this, &OBSBasicVCamConfig::IdentityApply);
#ifdef _WIN32
	connect(ui->identityGenerate, &QPushButton::clicked, this, &OBSBasicVCamConfig::IdentityGenerate);
	connect(ui->identityReset, &QPushButton::clicked, this, &OBSBasicVCamConfig::IdentityReset);
#endif
#endif /* _WIN32 || __linux__ */

#if !defined(_WIN32) && !defined(__linux__)
	/* Runtime identity is a Windows/Linux feature; the macOS identity is
	 * compile-time (name changes need camera-extension re-signing). */
	ui->identityGroup->setVisible(false);
#endif
}

void OBSBasicVCamConfig::OutputTypeChanged()
{
	VCamOutputType type = (VCamOutputType)ui->outputType->currentData().toInt();
	ui->outputSelection->setDisabled(false);

	auto list = ui->outputSelection;
	list->clear();

	switch (type) {
	case VCamOutputType::Invalid:
	case VCamOutputType::ProgramView:
	case VCamOutputType::PreviewOutput:
		ui->outputSelection->setDisabled(true);
		list->addItem(QTStr("Basic.VCam.OutputSelection.NoSelection"));
		break;
	case VCamOutputType::SceneOutput: {
		// Scenes in default order
		BPtr<char *> scenes = obs_frontend_get_scene_names();
		for (char **temp = scenes; *temp; temp++) {
			list->addItem(*temp);

			if (config.scene.compare(*temp) == 0) {
				list->setCurrentIndex(list->count() - 1);
			}
		}
		break;
	}
	case VCamOutputType::SourceOutput: {
		// Sources in alphabetical order
		std::vector<std::string> sources;
		auto AddSource = [&](obs_source_t *source) {
			auto name = obs_source_get_name(source);

			if (!(obs_source_get_output_flags(source) & OBS_SOURCE_VIDEO)) {
				return;
			}

			sources.push_back(name);
		};
		using AddSource_t = decltype(AddSource);

		obs_enum_sources(
			[](void *data, obs_source_t *source) {
				auto &AddSource = *static_cast<AddSource_t *>(data);
				if (!obs_source_removed(source)) {
					AddSource(source);
				}
				return true;
			},
			static_cast<void *>(&AddSource));

		// Sort and select current item
		sort(sources.begin(), sources.end());
		for (auto &&source : sources) {
			list->addItem(source.c_str());

			if (config.source == source) {
				list->setCurrentIndex(list->count() - 1);
			}
		}
		break;
	}
	}

	if (!vcamActive) {
		return;
	}

	requireRestart = (activeType == VCamOutputType::ProgramView && type != VCamOutputType::ProgramView) ||
			 (activeType != VCamOutputType::ProgramView && type == VCamOutputType::ProgramView);

	ui->warningLabel->setVisible(requireRestart);
}

void OBSBasicVCamConfig::UpdateConfig()
{
	VCamOutputType type = (VCamOutputType)ui->outputType->currentData().toInt();
	switch (type) {
	case VCamOutputType::ProgramView:
	case VCamOutputType::PreviewOutput:
		break;
	case VCamOutputType::SceneOutput:
		config.scene = ui->outputSelection->currentText().toStdString();
		break;
	case VCamOutputType::SourceOutput:
		config.source = ui->outputSelection->currentText().toStdString();
		break;
	default:
		// unknown value, don't save type
		return;
	}

	config.type = type;

	if (requireRestart) {
		emit AcceptedAndRestart(config);
	} else {
		emit Accepted(config);
	}
}

#if defined(_WIN32) || defined(__linux__)
void OBSBasicVCamConfig::IdentityPresetChanged()
{
	/* "Custom" (last entry) keeps whatever is in the fields. */
	const int count = (int)(sizeof(presets) / sizeof(presets[0]));
	int index = ui->identityPreset->currentIndex();
	if (index < 0 || index >= count) {
		return;
	}

	ui->identityName->setText(presets[index].name);

#ifdef _WIN32
	ui->identityVid->setText(presets[index].vid);
	ui->identityPid->setText(presets[index].pid);
	ui->identitySerial->setText(GenerateSerialFor(QString::fromLatin1(presets[index].vid).toStdWString().c_str(),
						      QString::fromLatin1(presets[index].pid).toStdWString().c_str()));
#endif
}

#ifdef _WIN32
static QString FindVcamctl();
static bool RunVcamctlElevated(QWidget *parent, const QString &vcamctl, const QStringList &args);
#endif

void OBSBasicVCamConfig::IdentityApply()
{
	QString name = ui->identityName->text().trimmed();
	QString vid = ui->identityVid->text().trimmed();
	QString pid = ui->identityPid->text().trimmed();
	QString serial = ui->identitySerial->text().trimmed();

#ifdef __linux__
	/* The Linux commit path: persist the card label to the user config so
	   the plugin applies it at the next virtual camera start. */
	if (name.isEmpty()) {
		QMessageBox::warning(this, QTStr("Basic.VCam.Identity.Title"), QTStr("Basic.VCam.Identity.InvalidName"));
		return;
	}

	config_set_string(App()->GetUserConfig(), "VirtualCamera", "CardLabel", name.toUtf8().constData());
	config_save_safe(App()->GetUserConfig(), "tmp", nullptr);

	QMessageBox::information(this, QTStr("Basic.VCam.Identity.Title"),
				 QTStr("Basic.VCam.Identity.ApplyLinuxNote"));
	UNUSED_PARAMETER(vid);
	UNUSED_PARAMETER(pid);
	UNUSED_PARAMETER(serial);
#else
	if (name.isEmpty()) {
		QMessageBox::warning(this, QTStr("Basic.VCam.Identity.Title"), QTStr("Basic.VCam.Identity.InvalidName"));
		return;
	}

	QRegularExpression hex(QStringLiteral("^[0-9A-Fa-f]{4}$"));
	if (vid.isEmpty() != pid.isEmpty() || (!vid.isEmpty() && !hex.match(vid).hasMatch()) ||
	    (!pid.isEmpty() && !hex.match(pid).hasMatch())) {
		QMessageBox::warning(this, QTStr("Basic.VCam.Identity.Title"),
				     QTStr("Basic.VCam.Identity.InvalidVidPid"));
		return;
	}

	/* ASCII-only (real USB serials are ASCII; Qt's \w is Unicode-aware —
	 * a non-ASCII serial would be a detector tell). */
	QRegularExpression serialRe(QStringLiteral("^[A-Za-z0-9-_.& ]{1,32}$"));
	if (!serial.isEmpty() && !serialRe.match(serial).hasMatch()) {
		QMessageBox::warning(this, QTStr("Basic.VCam.Identity.Title"),
				     QTStr("Basic.VCam.Identity.InvalidSerial"));
		return;
	}

	QString vcamctl = FindVcamctl();
	if (vcamctl.isEmpty()) {
		QMessageBox::warning(this, QTStr("Basic.VCam.Identity.Title"),
				     QTStr("Basic.VCam.Identity.NoHelper"));
		return;
	}

	QStringList args = {QStringLiteral("set"), QStringLiteral("--name"), name};
	if (!vid.isEmpty()) {
		args << QStringLiteral("--vid") << vid << QStringLiteral("--pid") << pid;
	}
	if (!serial.isEmpty()) {
		args << QStringLiteral("--serial") << serial;
	}

	if (!RunVcamctlElevated(this, vcamctl, args)) {
		return;
	}

	QMessageBox::information(this, QTStr("Basic.VCam.Identity.Title"),
				 QTStr("Basic.VCam.Identity.ApplyRequested"));
#endif /* __linux__ */
}

#ifdef _WIN32
/* The helper ships next to the module DLLs (bin/64bit/../core/win-dshow/data
 * in installed and portable layouts, next to obs64 in dev rundirs). */
static QString FindVcamctl()
{
	QString dir = QCoreApplication::applicationDirPath();
	QStringList candidates = {
		dir + QStringLiteral("/../core/win-dshow/data/vcamctl.exe"),
		dir + QStringLiteral("/vcamctl.exe"),
	};

	for (const QString &path : candidates) {
		if (QFileInfo::exists(path)) {
			return QFileInfo(path).absoluteFilePath();
		}
	}

	return QString();
}

/* Quotes one argument for a Windows command line per CommandLineToArgvW
 * rules: backslash runs preceding a quote (or the closing delimiter) are
 * doubled so an embedded quote can never split the argument. */
static QString QuoteWinArg(const QString &arg)
{
	QString out;
	int backslashes = 0;

	for (const QChar &c : arg) {
		if (c == QLatin1Char('\\')) {
			backslashes++;
			continue;
		}
		if (c == QLatin1Char('"')) {
			out += QString(backslashes * 2 + 1, QLatin1Char('\\'));
		} else if (backslashes > 0) {
			out += QString(backslashes, QLatin1Char('\\'));
		}
		backslashes = 0;
		out += c;
	}
	out += QString(backslashes * 2, QLatin1Char('\\'));

	return QLatin1Char('"') + out + QLatin1Char('"');
}

static bool RunVcamctlElevated(QWidget *parent, const QString &vcamctl, const QStringList &args)
{
	QString params;
	for (const QString &arg : args) {
		if (!params.isEmpty()) {
			params += QLatin1Char(' ');
		}
		params += QuoteWinArg(arg);
	}

	std::wstring file_w = vcamctl.toStdWString();
	std::wstring params_w = params.toStdWString();

	HINSTANCE inst = ShellExecuteW(nullptr, L"runas", file_w.c_str(), params_w.c_str(), nullptr, SW_HIDE);
	if ((intptr_t)inst > 32) {
		return true;
	}

	QMessageBox::warning(parent, QTStr("Basic.VCam.Identity.Title"), QTStr("Basic.VCam.Identity.ApplyFailed"));
	return false;
}

void OBSBasicVCamConfig::IdentityGenerate()
{
	QString vid = ui->identityVid->text().trimmed();
	QString pid = ui->identityPid->text().trimmed();

	/* VID-aware inference for Custom: invalid or empty fields fall
	   through to the 8HEX default (vcam_serial_format_for is NUL-safe). */
	ui->identitySerial->setText(GenerateSerialFor(vid.toStdWString().c_str(), pid.toStdWString().c_str()));
}

void OBSBasicVCamConfig::IdentityReset()
{
	QString vcamctl = FindVcamctl();
	if (vcamctl.isEmpty()) {
		QMessageBox::warning(this, QTStr("Basic.VCam.Identity.Title"),
				     QTStr("Basic.VCam.Identity.NoHelper"));
		return;
	}

	if (!RunVcamctlElevated(this, vcamctl, {QStringLiteral("reset")})) {
		return;
	}

	QMessageBox::information(this, QTStr("Basic.VCam.Identity.Title"),
				 QTStr("Basic.VCam.Identity.ApplyRequested"));
}
#endif /* _WIN32 */

#endif /* _WIN32 || __linux__ */
