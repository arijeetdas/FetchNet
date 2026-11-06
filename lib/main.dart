import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_prefs.dart';
import 'core/app_services.dart';
import 'core/platform/device_environment.dart';
import 'services/web_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await AppPrefs.load();
  await DeviceEnvironment.initialize();
  await WebSession.initialize();
  final services = AppServices.create(prefs);
  runApp(FetchNetApp(services: services));
}
