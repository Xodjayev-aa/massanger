import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/data/voice_service.dart';

void main() {
  test('browser/native PCM is wrapped in a valid 16 kHz mono WAV container', () {
    final pcm = Uint8List.fromList(<int>[0, 0, 255, 127, 0, 128, 255, 255]);
    final wav = VoiceService.wavFromPcm(pcm);
    final bytes = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(bytes.getUint32(4, Endian.little), wav.length - 8);
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(bytes.getUint16(20, Endian.little), 1); // PCM
    expect(bytes.getUint16(22, Endian.little), 1); // mono
    expect(bytes.getUint32(24, Endian.little), 16000);
    expect(bytes.getUint16(34, Endian.little), 16);
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(bytes.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);
  });
}
