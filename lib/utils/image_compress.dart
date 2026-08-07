import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Teto seguro para o base64 de imagens que serão cifradas com NIP-44.
///
/// O NIP-44 v2 grava o tamanho do plaintext num campo de 2 bytes, então o
/// plaintext NÃO pode passar de 65535 bytes (0xFFFF). Se passar, o tamanho
/// "dá a volta" (mod 65536) e a decriptação devolve a imagem TRUNCADA →
/// "Could not decompress image" no lado de quem recebe.
///
/// Como o comprovante é cifrado como base64 (1 byte ASCII por char), usamos
/// 60000 como teto com folga.
const int kNip44MaxImageBase64 = 60000;

/// Recomprime [originalBytes] (uma imagem) para JPEG até que o base64 caiba
/// no limite do NIP-44 e retorna o base64 pronto para cifrar.
///
/// Mantém a criptografia NIP-44 intacta — apenas garante que a imagem cabe.
/// Se a imagem já couber, é devolvida como está. Se não for decodificável,
/// devolve o base64 original (o gate de tamanho a montante decide o resto).
String compressImageToBase64ForNip44(
  Uint8List originalBytes, {
  int maxBase64Len = kNip44MaxImageBase64,
}) {
  final asIs = base64Encode(originalBytes);
  if (asIs.length <= maxBase64Len) return asIs;

  final decoded = img.decodeImage(originalBytes);
  if (decoded == null) return asIs;

  // Tenta combinações de (dimensão máxima, qualidade), da maior para a menor,
  // sempre reamostrando a partir do ORIGINAL (qualidade não acumula perda).
  const dims = <int>[1000, 800, 640, 512, 400, 320, 256];
  const qualities = <int>[60, 45, 35, 25, 18];

  for (final dim in dims) {
    final needsResize = decoded.width > dim || decoded.height > dim;
    final resized = needsResize
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? dim : null,
            height: decoded.height > decoded.width ? dim : null,
          )
        : decoded;
    for (final q in qualities) {
      final b64 = base64Encode(img.encodeJpg(resized, quality: q));
      if (b64.length <= maxBase64Len) return b64;
    }
  }

  // Último recurso: menor possível (garante que sempre cabe).
  final tiny = img.copyResize(decoded, width: 200);
  return base64Encode(img.encodeJpg(tiny, quality: 15));
}
