import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

class Huami2021Payload {
  const Huami2021Payload(this.endpoint, this.payload);

  final int endpoint;
  final Uint8List payload;
}

class Huami2021Crypto {
  Huami2021Crypto({
    required List<int> authKey,
    Random? random,
  })  : _authKey = Uint8List.fromList(authKey),
        _random = random ?? Random.secure();

  final Uint8List _authKey;
  final Random _random;
  final HuamiB163 _ecdh = HuamiB163();

  late Uint8List _privateKey;
  late Uint8List publicKey;
  Uint8List? sessionKey;
  int encryptedSequence = 0;
  int _writeHandle = 0;

  bool get isReady => sessionKey != null;

  void start() {
    _privateKey = _randomBytes(24);
    while (!_ecdh.isAcceptablePrivateKey(_privateKey)) {
      _privateKey = _randomBytes(24);
    }
    publicKey = _ecdh.generatePublicKey(_privateKey);
    sessionKey = null;
    encryptedSequence = 0;
    _writeHandle = 0;
  }

  Uint8List buildAuthHello() {
    if (publicKey.length != 48) {
      throw StateError('Huami2021 public key has not been generated.');
    }
    return Uint8List.fromList(<int>[
      0x04,
      0x02,
      0x00,
      0x02,
      ...publicKey,
    ]);
  }

  Uint8List handleRemoteKey(Uint8List payload) {
    if (payload.length < 67 ||
        payload[0] != 0x10 ||
        payload[1] != 0x04 ||
        payload[2] != 0x01) {
      throw StateError('Unexpected Huami2021 auth key response: $payload');
    }

    final remoteRandom = Uint8List.fromList(payload.sublist(3, 19));
    final remotePublicKey = Uint8List.fromList(payload.sublist(19, 67));
    final shared = _ecdh.generateSharedSecret(_privateKey, remotePublicKey);
    if (shared == null) {
      throw StateError('Huami2021 remote public key failed validation.');
    }

    encryptedSequence = _le32(shared, 0);
    final aes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      aes[i] = shared[i + 8] ^ _authKey[i];
    }
    sessionKey = aes;

    final encryptedRandomWithAuthKey = _aesEcb(remoteRandom, _authKey);
    final encryptedRandomWithSessionKey = _aesEcb(remoteRandom, aes);
    return Uint8List.fromList(<int>[
      0x05,
      ...encryptedRandomWithAuthKey,
      ...encryptedRandomWithSessionKey,
    ]);
  }

  List<Uint8List> encode({
    required int endpoint,
    required List<int> payload,
    required bool encrypted,
    bool extendedFlags = true,
    int mtu = 247,
  }) {
    if (encrypted && sessionKey == null) {
      throw StateError('Huami2021 encrypted packet requested before auth.');
    }

    _writeHandle = (_writeHandle + 1) & 0xff;
    final handle = _writeHandle;
    final originalLength = payload.length;
    final headerSizeFirst = extendedFlags ? 11 : 10;
    var remainingPayload = Uint8List.fromList(payload);

    if (encrypted) {
      final key = _messageKey(handle);
      var encryptedLength = originalLength + 8;
      final overflow = encryptedLength % 16;
      if (overflow > 0) encryptedLength += 16 - overflow;
      final plain = Uint8List(encryptedLength);
      plain.setAll(0, payload);
      _putLe32(plain, originalLength, encryptedSequence);
      encryptedSequence = (encryptedSequence + 1) & 0xffffffff;
      _putLe32(plain, originalLength + 4, _crc32(plain, 0, originalLength + 4));
      remainingPayload = _aesEcb(plain, key);
    }

    final chunks = <Uint8List>[];
    var offset = 0;
    var count = 0;
    var headerSize = headerSizeFirst;
    while (offset < remainingPayload.length || count == 0) {
      final maxPayload = max(1, (mtu - 3) - headerSize);
      final copyBytes = min(remainingPayload.length - offset, maxPayload);
      var flags = 0;
      if (encrypted) flags |= 0x08;
      if (count == 0) flags |= 0x01;
      if (offset + copyBytes >= remainingPayload.length) {
        flags |= 0x02;
        flags |= 0x04;
      }
      final chunk = Uint8List(headerSize + copyBytes);
      var i = 0;
      chunk[i++] = 0x03;
      chunk[i++] = flags;
      if (extendedFlags) chunk[i++] = 0x00;
      chunk[i++] = handle;
      chunk[i++] = count & 0xff;
      if (count == 0) {
        _putLe32(chunk, i, originalLength);
        i += 4;
        chunk[i++] = endpoint & 0xff;
        chunk[i++] = (endpoint >> 8) & 0xff;
      }
      chunk.setRange(i, i + copyBytes, remainingPayload, offset);
      chunks.add(chunk);
      offset += copyBytes;
      count++;
      headerSize = extendedFlags ? 5 : 4;
      if (remainingPayload.isEmpty) break;
    }
    return chunks;
  }

  Uint8List? decryptPayload({
    required int handle,
    required int originalLength,
    required Uint8List encryptedPayload,
  }) {
    final key = _messageKey(handle);
    final decoded = _aesEcbDecrypt(encryptedPayload, key);
    if (decoded.length < originalLength + 8) return null;
    final crcExpected = _le32(decoded, originalLength + 4);
    final crcActual = _crc32(decoded, 0, originalLength + 4);
    if (crcExpected != crcActual) return null;
    return Uint8List.fromList(decoded.sublist(0, originalLength));
  }

  Uint8List _messageKey(int handle) {
    final sk = sessionKey;
    if (sk == null) throw StateError('No Huami2021 session key.');
    final key = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      key[i] = sk[i] ^ handle;
    }
    return key;
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  static Uint8List _aesEcb(List<int> data, List<int> key) {
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(Uint8List.fromList(key)),
          mode: enc.AESMode.ecb, padding: null),
    );
    return Uint8List.fromList(encrypter.encryptBytes(data).bytes);
  }

  static Uint8List _aesEcbDecrypt(List<int> data, List<int> key) {
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(Uint8List.fromList(key)),
          mode: enc.AESMode.ecb, padding: null),
    );
    return Uint8List.fromList(encrypter.decryptBytes(
      enc.Encrypted(Uint8List.fromList(data)),
    ));
  }
}

class Huami2021Decoder {
  int? _currentHandle;
  int _currentEndpoint = 0;
  int _currentLength = 0;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  int lastHandle = 0;
  int lastCount = 0;

  Huami2021Payload? decode(
    List<int> data, {
    required Huami2021Crypto crypto,
    bool extendedFlags = true,
  }) {
    if (data.isEmpty || data[0] != 0x03) return null;
    var i = 1;
    final flags = data[i++];
    final encrypted = (flags & 0x08) != 0;
    final first = (flags & 0x01) != 0;
    final last = (flags & 0x02) != 0;
    if (extendedFlags) i++;
    final handle = data[i++];
    final count = data[i++];
    lastHandle = handle;
    lastCount = count;
    if (_currentHandle != null && _currentHandle != handle) {
      reset();
      return null;
    }
    if (first) {
      _buffer.clear();
      _currentHandle = handle;
      _currentLength = _le32(data, i);
      i += 4;
      _currentEndpoint = data[i++] | (data[i++] << 8);
    }
    if (i < data.length) {
      _buffer.add(data.sublist(i));
    }
    if (!last) return null;

    var payload = _buffer.toBytes();
    if (encrypted) {
      final decrypted = crypto.decryptPayload(
        handle: handle,
        originalLength: _currentLength,
        encryptedPayload: payload,
      );
      if (decrypted == null) {
        reset();
        return null;
      }
      payload = decrypted;
    }
    final out = Huami2021Payload(_currentEndpoint, payload);
    reset();
    return out;
  }

  bool needsAck(List<int> data) =>
      data.length > 1 && data[0] == 0x03 && (data[1] & 0x04) != 0;

  void reset() {
    _currentHandle = null;
    _currentEndpoint = 0;
    _currentLength = 0;
    _buffer.clear();
  }
}

class HuamiB163 {
  static const int _m = 163;
  static final BigInt _one = BigInt.one;
  static final BigInt _poly =
      (BigInt.one << 163) | BigInt.from(0x000000c9);
  static final BigInt _b = _fromWords(
      const [0x4a3205fd, 0x512f7874, 0x1481eb10, 0xb8c953ca, 0x0a601907, 0x00000002]);
  static final _Point _g = _Point(
    _fromWords(const [0xe8343e36, 0xd4994637, 0xa0991168, 0x86a2d57e, 0xf0eba162, 0x00000003]),
    _fromWords(const [0x797324f1, 0xb11c5c0c, 0xa2cdd545, 0x71a0094f, 0xd51fbc6c, 0x00000000]),
  );
  static final BigInt _order =
      _fromWords(const [0xa4234c33, 0x77e70c12, 0x000292fe, 0x00000000, 0x00000000, 0x00000004]);

  bool isAcceptablePrivateKey(List<int> privateKey) {
    final scalar = _clampScalar(_fromLe(privateKey));
    return scalar.bitLength >= (_m ~/ 2);
  }

  Uint8List generatePublicKey(List<int> privateKey) {
    final p = _mul(_g, _clampScalar(_fromLe(privateKey)));
    return _pointToBytes(p);
  }

  Uint8List? generateSharedSecret(List<int> privateKey, List<int> remotePublicKey) {
    final p = _pointFromBytes(remotePublicKey);
    if (p == null || !_onCurve(p)) return null;
    final shared = _mul(p, _clampScalar(_fromLe(privateKey)));
    return _pointToBytes(shared);
  }

  static BigInt _clampScalar(BigInt scalar) {
    final limitBits = _order.bitLength - 1;
    final mask = (BigInt.one << limitBits) - BigInt.one;
    return scalar & mask;
  }

  static _Point _mul(_Point p, BigInt k) {
    var r = _Point.zero;
    for (var i = k.bitLength - 1; i >= 0; i--) {
      r = _double(r);
      if (((k >> i) & _one) == _one) {
        r = _add(r, p);
      }
    }
    return r;
  }

  static _Point _double(_Point p) {
    if (p.isZero || p.x == BigInt.zero) return _Point.zero;
    final lambda = _addField(p.x, _mulField(p.y, _invField(p.x)));
    final x3 = _addField(_addField(_mulField(lambda, lambda), lambda), _one);
    final y3 = _addField(_mulField(_addField(lambda, _one), x3), _mulField(p.x, p.x));
    return _Point(x3, y3);
  }

  static _Point _add(_Point p, _Point q) {
    if (p.isZero) return q;
    if (q.isZero) return p;
    if (p.x == q.x) {
      if (p.y == q.y) return _double(p);
      return _Point.zero;
    }
    final lambda =
        _mulField(_addField(p.y, q.y), _invField(_addField(p.x, q.x)));
    final x3 = _addField(
      _addField(_addField(_mulField(lambda, lambda), lambda), p.x),
      _addField(q.x, _one),
    );
    final y3 = _addField(
      _mulField(lambda, _addField(p.x, x3)),
      _addField(x3, p.y),
    );
    return _Point(x3, y3);
  }

  static bool _onCurve(_Point p) {
    if (p.isZero) return false;
    final left = _addField(_mulField(p.y, p.y), _mulField(p.x, p.y));
    final x2 = _mulField(p.x, p.x);
    final right = _addField(_addField(_mulField(x2, p.x), x2), _b);
    return left == right;
  }

  static BigInt _addField(BigInt a, BigInt b) => a ^ b;

  static BigInt _mulField(BigInt a, BigInt b) {
    var z = BigInt.zero;
    var aa = a;
    var bb = b;
    while (bb > BigInt.zero) {
      if ((bb & _one) == _one) z ^= aa;
      bb >>= 1;
      aa <<= 1;
      if (((aa >> _m) & _one) == _one) aa ^= _poly;
    }
    return _reduce(z);
  }

  static BigInt _invField(BigInt a) {
    if (a == BigInt.zero) throw StateError('Cannot invert zero in GF(2^163).');
    var u = a;
    var v = _poly;
    var g1 = BigInt.one;
    var g2 = BigInt.zero;
    while (u != BigInt.one) {
      var j = u.bitLength - v.bitLength;
      if (j < 0) {
        final tu = u;
        u = v;
        v = tu;
        final tg = g1;
        g1 = g2;
        g2 = tg;
        j = -j;
      }
      u ^= v << j;
      g1 ^= g2 << j;
    }
    return _reduce(g1);
  }

  static BigInt _reduce(BigInt x) {
    var r = x;
    while (r.bitLength > _m) {
      final shift = r.bitLength - _m - 1;
      r ^= _poly << shift;
    }
    return r;
  }

  static _Point? _pointFromBytes(List<int> bytes) {
    if (bytes.length < 48) return null;
    return _Point(_fromLe(bytes.sublist(0, 24)), _fromLe(bytes.sublist(24, 48)));
  }

  static Uint8List _pointToBytes(_Point p) {
    final out = Uint8List(48);
    out.setAll(0, _toLe(p.x, 24));
    out.setAll(24, _toLe(p.y, 24));
    return out;
  }

  static BigInt _fromWords(List<int> words) {
    var out = BigInt.zero;
    for (var i = 0; i < words.length; i++) {
      out |= BigInt.from(words[i] & 0xffffffff) << (32 * i);
    }
    return out;
  }

  static BigInt _fromLe(List<int> bytes) {
    var out = BigInt.zero;
    for (var i = 0; i < bytes.length; i++) {
      out |= BigInt.from(bytes[i] & 0xff) << (8 * i);
    }
    return out;
  }

  static Uint8List _toLe(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = 0; i < length; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}

class _Point {
  const _Point(this.x, this.y);

  static final zero = _Point(BigInt.zero, BigInt.zero);

  final BigInt x;
  final BigInt y;

  bool get isZero => x == BigInt.zero && y == BigInt.zero;
}

int _le32(List<int> data, int offset) =>
    (data[offset] & 0xff) |
    ((data[offset + 1] & 0xff) << 8) |
    ((data[offset + 2] & 0xff) << 16) |
    ((data[offset + 3] & 0xff) << 24);

void _putLe32(Uint8List data, int offset, int value) {
  data[offset] = value & 0xff;
  data[offset + 1] = (value >> 8) & 0xff;
  data[offset + 2] = (value >> 16) & 0xff;
  data[offset + 3] = (value >> 24) & 0xff;
}

int _crc32(List<int> data, int offset, int length) {
  var crc = 0xffffffff;
  for (var i = offset; i < offset + length; i++) {
    crc ^= data[i] & 0xff;
    for (var j = 0; j < 8; j++) {
      final mask = -(crc & 1);
      crc = (crc >> 1) ^ (0xedb88320 & mask);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
