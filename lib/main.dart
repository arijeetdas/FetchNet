import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/app_prefs.dart';
import 'core/app_services.dart';
import 'core/platform/device_environment.dart';
import 'services/app_updater.dart';
import 'services/web_session.dart';
import 'services/windows_self_update.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final prefs = await AppPrefs.load();
  await DeviceEnvironment.initialize();
  await WebSession.initialize();
  final services = AppServices.create(prefs);
  runApp(FetchNetApp(services: services));
  // The app is up: an in-app update that just happened worked, so its old
  // files can go (Windows; see WindowsSelfUpdate). And downloads of updates
  // that are installed by now are no longer needed.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    WindowsSelfUpdate.confirmStartup();
    await AppUpdater.cleanOldDownloads((await services.updates.installedRelease())?.buildNumber);
  });
}
