import 'package:fetchnet/features/settings/about_dialog.dart';
import 'package:fetchnet/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Same shape as D:\FetchNet\src\config\releases.json (served at /releases.json).
  const manifest = '''
{
  "android": {
    "latest": { "versionName": "1.2.0", "buildNo": 5 },
    "older": [{ "versionName": "1.1.0", "buildNo": 3 }, { "versionName": "1.0.0", "buildNo": 1 }]
  },
  "windows": { "latest": null, "older": [] },
  "macos": { "latest": null, "older": [] },
  "linux": { "latest": null, "older": [] }
}''';

  test('parseManifest reads the platform\'s latest release, not an older one', () {
    final r = UpdateService.parseManifest(manifest, 'android')!;
    expect(r.versionName, '1.2.0');
    expect(r.buildNumber, 5);
  });

  test('platforms without a release (or unknown ones) have no update', () {
    expect(UpdateService.parseManifest(manifest, 'windows'), isNull);
    expect(UpdateService.parseManifest(manifest, 'ios'), isNull);
    expect(UpdateService.parseManifest(manifest, null), isNull);
  });

  test('a malformed manifest is a failed check, not "up to date"', () {
    expect(() => UpdateService.parseManifest('[]', 'android'), throwsFormatException);
    expect(() => UpdateService.parseManifest('{"android": 3}', 'android'), throwsFormatException);
    expect(
      () => UpdateService.parseManifest('{"android": {"latest": {"buildNo": "x"}, "older": []}}', 'android'),
      throwsFormatException,
    );
  });

  test('Android update links always carry the recommended ABI', () {
    const v = AppRelease(versionName: '1.0.0', buildNumber: 1);
    expect(
      UpdateService.buildUpdateLink('android', v, androidInstallType: 'arm64-v8a'),
      'https://fetchnet.arijeet.in/updates/android/1.0.0+1-arm64-v8a',
    );
    expect(UpdateService.buildUpdateLink('android', v), 'https://fetchnet.arijeet.in/updates/android/1.0.0+1-universal');
    expect(UpdateService.buildUpdateLink('windows', v), 'https://fetchnet.arijeet.in/updates/windows/1.0.0+1');
  });

  test('recommended ABI follows the device, like DropNet', () {
    expect(UpdateService.recommendedInstallTypeFor(['arm64-v8a', 'armeabi-v7a', 'armeabi']), 'arm64-v8a');
    expect(UpdateService.recommendedInstallTypeFor(['armeabi-v7a', 'armeabi']), 'armeabi-v7a');
    expect(UpdateService.recommendedInstallTypeFor(['x86_64', 'arm64-v8a']), 'x86_64');
    expect(UpdateService.recommendedInstallTypeFor(['x86']), 'universal');
    expect(UpdateService.recommendedInstallTypeFor(const []), 'universal');
  });

  test('the About popup recommends the same build as the update link', () {
    const devices = [
      ['arm64-v8a', 'armeabi-v7a', 'armeabi'], // most phones
      ['arm64-v8a'], // 64-bit-only phones (Pixel 7 and later)
      ['armeabi-v7a', 'armeabi'], // older 32-bit phones
      ['x86_64', 'x86', 'arm64-v8a', 'armeabi-v7a'], // Chromebooks, emulators
      ['x86'], // 32-bit x86: no build is published for it
      <String>[], // unknown
    ];
    for (final abis in devices) {
      final link = UpdateService.recommendedInstallTypeFor(abis);
      expect(recommendedAndroidBuildFor(abis), link == 'universal' ? 'Universal' : link, reason: '$abis');
    }
    expect(recommendedAndroidBuildFor(['x86']), 'Universal', reason: 'x86 is never published');
  });

  test('the installed build is named like the published ones', () {
    expect(installedAndroidBuildFor('arm64-v8a'), 'arm64-v8a');
    expect(installedAndroidBuildFor(' ARM64-V8A '), 'arm64-v8a');
    expect(installedAndroidBuildFor('armeabi-v7a'), 'armeabi-v7a');
    expect(installedAndroidBuildFor('x86_64'), 'x86_64');
    expect(installedAndroidBuildFor('universal'), 'Universal');
    expect(installedAndroidBuildFor(''), 'Universal');
  });
}
