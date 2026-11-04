#include "OBSBasicVCamConfig.hpp"

#include <OBSApp.hpp>

#include "moc_OBSBasicVCamConfig.cpp"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>

#include <QCoreApplication>
#include <QFileInfo>
#include <QMessageBox>
#include <QRegularExpression>
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

#ifdef _WIN32
	/* Coherent name + VID/PID bundles; presets never set a serial, so the
	 * per-machine derived one keeps being used. */
	ui->identityPreset->addItem("Logitech HD Pro Webcam C920");
	ui->identityPreset->addItem("Logitech Brio 500");
	ui->identityPreset->addItem("Generic UVC Camera");
	ui->identityPreset->addItem(QTStr("Basic.VCam.Identity.Preset.Custom"));

	IdentityPresetChanged();
	connect(ui->identityPreset, &QComboBox::currentIndexChanged, this,
		&OBSBasicVCamConfig::IdentityPresetChanged);
	connect(ui->identityApply, &QPushButton::clicked, this, &OBSBasicVCamConfig::IdentityApply);
	connect(ui->identityReset, &QPushButton::clicked, this, &OBSBasicVCamConfig::IdentityReset);
#else
	/* Runtime identity is a Windows-only feature. */
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

#ifdef _WIN32
void OBSBasicVCamConfig::IdentityPresetChanged()
{
	/* "Custom" (last entry) keeps whatever is in the fields. */
	static const char *preset_vids[] = {"046D", "046D", "0C45"};
	static const char *preset_pids[] = {"0825", "085E", "6367"};

	int index = ui->identityPreset->currentIndex();
	int count = (int)(sizeof(preset_vids) / sizeof(preset_vids[0]));
	if (index < 0 || index >= count) {
		return;
	}

	ui->identityName->setText(ui->identityPreset->itemText(index));
	ui->identityVid->setText(preset_vids[index]);
	ui->identityPid->setText(preset_pids[index]);
	ui->identitySerial->clear();
}

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

void OBSBasicVCamConfig::IdentityApply()
{
	QString name = ui->identityName->text().trimmed();
	QString vid = ui->identityVid->text().trimmed();
	QString pid = ui->identityPid->text().trimmed();
	QString serial = ui->identitySerial->text().trimmed();

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

	QRegularExpression serialRe(QStringLiteral("^[\\w\\-.& ]{1,15}$"));
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
#endif
