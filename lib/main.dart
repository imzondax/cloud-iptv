import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const ProviderScope(child: CloudIptvApp()));
}

/// Mouse drag scrolls too: a wheel cannot move the sideways category rows.
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices =>
      {...super.dragDevices, PointerDeviceKind.mouse};
}

class CloudIptvApp extends StatelessWidget {
  const CloudIptvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloud IPTV',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _DragScrollBehavior(),
      theme: onAirTheme(),
      home: const HomeScreen(),
    );
  }
}
