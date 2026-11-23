import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/core/app_services.dart';
import 'package:fetchnet/ui_kit/glass_kit.dart';
import 'package:fetchnet/ui_kit/glass_tuning.dart';
import 'package:fetchnet/widgets/page_parts.dart';
import 'package:fetchnet/widgets/sub_page.dart';
import 'package:fetchnet/ui_kit/kit.dart';
import 'package:fetchnet/widgets/app_dialog.dart';
import 'package:fetchnet/widgets/app_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(UiLook look, Widget child) => UiLookScope(
      look: look,
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );

void main() {
  group('the look picks the widgets', () {
    for (final look in UiLook.values) {
      final glass = look == UiLook.liquidGlass;
      testWidgets('${look.name}: switches, sliders and segmented controls', (tester) async {
        await tester.pumpWidget(_app(
          look,
          Column(
            children: [
              KitSwitch(value: true, onChanged: (_) {}),
              SizedBox(width: 300, child: KitSlider(value: 0.5, onChanged: (_) {})),
              KitSegmented<int>(
                segments: const [ButtonSegment(value: 1, label: Text('One')), ButtonSegment(value: 2, label: Text('Two'))],
                selected: const {2},
                onSelectionChanged: (_) {},
              ),
            ],
          ),
        ));
        await tester.pump();
        expect(find.byType(GlassSwitch), glass ? findsOneWidget : findsNothing);
        expect(find.byType(Switch), glass ? findsNothing : findsOneWidget);
        expect(find.byType(GlassSlider), glass ? findsOneWidget : findsNothing);
        expect(find.byType(Slider), glass ? findsNothing : findsOneWidget);
        expect(find.byType(GlassSegmentedControl), glass ? findsOneWidget : findsNothing);
        expect(find.byType(SegmentedButton<int>), glass ? findsNothing : findsOneWidget);
      });
    }

    testWidgets('a switch row toggles with a tap on the row (glass)', (tester) async {
      var value = false;
      await tester.pumpWidget(_app(
        UiLook.liquidGlass,
        StatefulBuilder(
          builder: (context, setState) => KitSwitchListTile(
            value: value,
            onChanged: (v) => setState(() => value = v),
            title: const Text('Autoplay'),
          ),
        ),
      ));
      await tester.tap(find.text('Autoplay'));
      await tester.pump();
      expect(value, isTrue);
    });

    testWidgets('alerts with FetchNet buttons are iOS alerts; others keep their layout', (tester) async {
      await tester.pumpWidget(_app(
        UiLook.liquidGlass,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showFetchNetDialog<void>(
              context: context,
              builder: (_) => KitAlertDialog(
                title: const Text('Delete?'),
                content: const Text('It goes for good.'),
                actions: [
                  DialogButton(label: 'Cancel', icon: Icons.close, onPressed: () {}),
                  DialogButton(label: 'Delete', icon: Icons.delete, destructive: true, primary: true, onPressed: () {}),
                ],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GlassDialog), findsOneWidget);
      expect(find.text('It goes for good.'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('sheets: on glass in Liquid Glass, Material otherwise', (tester) async {
      for (final look in UiLook.values) {
        await tester.pumpWidget(_app(
          look,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showKitSheet<void>(context: context, showDragHandle: true, builder: (_) => const Text('In the sheet')),
              child: const Text('open'),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('In the sheet'), findsOneWidget);
        expect(find.ancestor(of: find.text('In the sheet'), matching: find.byType(GlassContainer)), look == UiLook.liquidGlass ? findsOneWidget : findsNothing);
        await tester.tapAt(const Offset(10, 10)); // the barrier
        await tester.pump(const Duration(milliseconds: 500));
      }
    });
  });

  group('the glass tab bar', () {
    testWidgets('changes the page once the lens has landed, also when asked elsewhere', (tester) async {
      var target = 0;
      final settled = <int>[];
      late StateSetter rebuild;
      await tester.pumpWidget(_app(
        UiLook.liquidGlass,
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return FloatingNavBar(
              target: target,
              onTargetChanged: (i) => setState(() => target = i),
              onSettled: settled.add,
              items: const [
                LiquidNavItem(icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Home'),
                LiquidNavItem(icon: Icons.download_outlined, selectedIcon: Icons.download, label: 'Downloads'),
                LiquidNavItem(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: 'Settings'),
              ],
            );
          },
        ),
      ));
      expect(find.byType(GlassTabBar), findsOneWidget);

      // Asked for elsewhere (a button on another page).
      rebuild(() => target = 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(settled, isEmpty, reason: 'the lens is still moving');
      await tester.pump(const Duration(milliseconds: 200));
      expect(settled, [2]);

      // Two quick changes: only the last one changes the page.
      rebuild(() => target = 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      rebuild(() => target = 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(settled, [2, 0]);
    });
  });

  testWidgets('switching the look keeps the app where it is', (tester) async {
    final glass = ValueNotifier(false);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ValueListenableBuilder<bool>(
      valueListenable: glass,
      builder: (context, on, _) => UiLookScope(
        look: on ? UiLook.liquidGlass : UiLook.material,
        child: GlassKit.wrap(on: on, MaterialApp(navigatorKey: navigator, home: const Text('Home'))),
      ),
    ));
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Settings'))));
    await tester.pumpAndSettle();
    glass.value = true;
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(GlassAdaptiveScope), findsOneWidget);
    // Never down to the plain-blur tier (no refraction or reflection there).
    expect(tester.widget<GlassAdaptiveScope>(find.byType(GlassAdaptiveScope)).minQuality, GlassQuality.standard);
    glass.value = false;
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(GlassAdaptiveScope), findsNothing);
    expect(navigator.currentState!.canPop(), isTrue);
  });

  group('header buttons', () {
    for (final look in UiLook.values) {
      final glass = look == UiLook.liquidGlass;
      testWidgets('${look.name}: back, header and pill buttons', (tester) async {
        await tester.pumpWidget(_app(
          look,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const KitBackButton(halo: true),
              KitHeaderButton(icon: Icons.arrow_forward, onPressed: () {}, tooltip: 'Forward'),
              PillButton(label: 'Clear', icon: Icons.delete_sweep_rounded, onPressed: () {}),
            ],
          ),
        ));
        expect(find.byType(GlassIconButton), glass ? findsNWidgets(2) : findsNothing);
        expect(find.ancestor(of: find.text('Clear'), matching: find.byType(GlassButton)), glass ? findsOneWidget : findsNothing);
        expect(find.text('Clear'), findsOneWidget);
        // Round, never stretched.
        final back = tester.getSize(find.byType(KitBackButton));
        expect(back.width, back.height);
      });
    }

    testWidgets('a sub-page: the title gives way once it scrolls; the back button stays', (tester) async {
      await tester.pumpWidget(UiLookScope(
        look: UiLook.material,
        child: MaterialApp(
          home: SubPageScaffold(
            title: 'Engines',
            background: false,
            body: Builder(
              builder: (context) => ListView(
                padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
                children: [for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('Row $i'))],
              ),
            ),
          ),
        ),
      ));
      double titleOpacity() => tester.widget<AnimatedOpacity>(find.ancestor(of: find.text('Engines'), matching: find.byType(AnimatedOpacity))).opacity;
      expect(titleOpacity(), 1);
      // The list starts under the header, not behind it.
      expect(tester.getTopLeft(find.text('Row 0')).dy, greaterThanOrEqualTo(SubPageScaffold.headerHeight));
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(titleOpacity(), 0);
      expect(find.byType(KitBackButton), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(titleOpacity(), 1);
    });
  });

  group('glass tuning', () {
    test('reflection and refraction start off; opacity in the middle', () {
      const t = GlassTuning();
      expect((t.opacity, t.reflection, t.refraction), (0.5, 0.0, 0.0));
      final theme = GlassKit.themeFor(t);
      for (final v in [theme.light, theme.dark]) {
        expect(v.settings!.refractiveIndex, 1.0, reason: 'no bending');
        expect(v.settings!.chromaticAberration, 0);
        expect(v.settings!.lightIntensity, 0, reason: 'no highlights');
        expect(v.settings!.fresnelStrength, 0);
      }
    });

    test('turned up, the glass bends and reflects light', () {
      final off = GlassKit.themeFor(const GlassTuning());
      final theme = GlassKit.themeFor(const GlassTuning(opacity: 1, reflection: 1, refraction: 1));
      expect(theme.light.settings!.refractiveIndex, greaterThan(1.24));
      // What bends on every shader: a deep curved edge (the Standard shader
      // bends by thickness alone) and a real lens.
      expect(theme.light.settings!.thickness, greaterThan(off.light.settings!.thickness! * 5));
      expect(theme.light.settings!.lensModel, GlassLensModel.spherical);
      // Refraction bends; it doesn't clear the glass (that's Opacity).
      expect(theme.light.settings!.frost, off.light.settings!.frost);
      expect(theme.light.settings!.blur, off.light.settings!.blur);
      expect(theme.light.settings!.lightIntensity, greaterThan(0));
      expect(theme.light.settings!.fresnelStrength, greaterThan(0));
      final clear = GlassKit.themeFor(const GlassTuning(opacity: 0));
      expect(clear.dark.settings!.glassColor!.a, lessThan(theme.dark.settings!.glassColor!.a));
    });

    test('is remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final services = AppServices.create(await AppPrefs.load());
      expect(services.glassTuning.value, const GlassTuning());
      await services.setGlassTuning(const GlassTuning(opacity: 0.8, reflection: 0.3, refraction: 0.6));
      expect(AppServices.create(await AppPrefs.load()).glassTuning.value, const GlassTuning(opacity: 0.8, reflection: 0.3, refraction: 0.6));
      // While a slider moves: shown, not saved.
      await services.setGlassTuning(const GlassTuning(opacity: 0.1), save: false);
      expect(AppServices.create(await AppPrefs.load()).glassTuning.value.opacity, 0.8);
    });
  });

  test('the setting is off until turned on, and remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final services = AppServices.create(await AppPrefs.load());
    expect(services.liquidGlass.value, isFalse);
    await services.prefs.setLiquidGlass(true);
    expect(AppServices.create(await AppPrefs.load()).liquidGlass.value, isTrue);
  });
}
