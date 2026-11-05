import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_prefs.dart';
import 'core/app_services.dart';
import 'core/platform/device_environment.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await AppPrefs.load();
  await DeviceEnvironment.initialize();
  final services = AppServices.create(prefs);
  runApp(FetchNetApp(services: services));
}
