import 'dart:io';

import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'features/home/desktop_home.dart';
import 'features/home/phone_home.dart';

class AmarApp extends StatelessWidget {
  const AmarApp({super.key, this.openSettingsOnStart = false});
  final bool openSettingsOnStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AmarTv',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: Builder(builder: (context) {
        // Phones get the bottom-navigation layout; Windows and tablets the
        // sidebar layout.
        final phone = Platform.isAndroid && MediaQuery.sizeOf(context).shortestSide < 600;
        return phone
            ? PhoneHome(openSettingsOnStart: openSettingsOnStart)
            : DesktopHome(openSettingsOnStart: openSettingsOnStart);
      }),
    );
  }
}
