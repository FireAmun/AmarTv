// Generates assets/icon/icon.png (1024x1024): a simple TV with a play symbol.
// Run: dart run tool/make_icon.dart
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  const size = 1024;
  final bg = img.ColorRgba8(0x0E, 0x11, 0x16, 255);
  final accent = img.ColorRgba8(0x3D, 0x8B, 0xFF, 255);
  final screen = img.ColorRgba8(0x12, 0x18, 0x22, 255);
  final white = img.ColorRgba8(0xFF, 0xFF, 0xFF, 255);

  final icon = img.Image(width: size, height: size, numChannels: 4);
  img.fill(icon, color: bg);

  // Antennas.
  // Solid quads (thick antialiased lines render striped).
  img.fillPolygon(icon,
      vertices: [img.Point(358, 162), img.Point(386, 138), img.Point(530, 268), img.Point(494, 268)], color: accent);
  img.fillPolygon(icon,
      vertices: [img.Point(638, 138), img.Point(666, 162), img.Point(530, 268), img.Point(494, 268)], color: accent);
  for (final x in [372, 652]) {
    img.fillCircle(icon, x: x, y: 150, radius: 30, color: accent, antialias: true);
  }
  // TV body and screen.
  img.fillRect(icon, x1: 142, y1: 260, x2: 882, y2: 800, color: accent, radius: 96);
  img.fillRect(icon, x1: 204, y1: 322, x2: 820, y2: 738, color: screen, radius: 52);
  // Play triangle.
  img.fillPolygon(icon, vertices: [img.Point(452, 420), img.Point(452, 640), img.Point(642, 530)], color: white);
  // Stand.
  img.fillRect(icon, x1: 412, y1: 828, x2: 612, y2: 872, color: accent, radius: 22);

  final out = File('assets/icon/icon.png')..createSync(recursive: true);
  out.writeAsBytesSync(img.encodePng(icon));

  // Splash logo: same artwork, transparent background.
  final splash = img.Image(width: size, height: size, numChannels: 4);
  img.compositeImage(splash, icon);
  for (final p in splash) {
    if (p.r == bg.r && p.g == bg.g && p.b == bg.b) p.a = 0;
  }
  File('assets/icon/splash.png').writeAsBytesSync(img.encodePng(splash));

  // Android adaptive-icon foreground: artwork shrunk into the safe zone.
  final fg = img.Image(width: size, height: size, numChannels: 4);
  final small = img.copyResize(splash, width: 600, height: 600, interpolation: img.Interpolation.average);
  img.compositeImage(fg, small, dstX: 212, dstY: 212);
  File('assets/icon/icon_foreground.png').writeAsBytesSync(img.encodePng(fg));
  stdout.writeln('Wrote assets/icon/icon.png, splash.png, icon_foreground.png');
}
