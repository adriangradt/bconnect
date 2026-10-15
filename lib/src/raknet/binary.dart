import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Thrown when a packet is shorter or differently shaped than expected.
class PacketFormatException implements Exception {
  PacketFormatException(this.message);
  final String message;
  @override
  String toString() => 'PacketFormatException: $message';
}

/// Builds binary packets. RakNet uses big endian, the Bedrock game layer
/// mostly little endian and varints, so both are offered.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);
  final ByteData _tmp = ByteData(8);

  int get length => _b.length;

  void u8(int v) => _b.addByte(v & 0xff);
  void boolean(bool v) => u8(v ? 1 : 0);
  void bytes(List<int> v) => _b.add(v);

  void u16be(int v) => _put(2, () => _tmp.setUint16(0, v));
  void u16le(int v) => _put(2, () => _tmp.setUint16(0, v, Endian.little));
  void i32be(int v) => _put(4, () => _tmp.setInt32(0, v));
  void u32be(int v) => _put(4, () => _tmp.setUint32(0, v));
  void i64be(int v) => _put(8, () => _tmp.setInt64(0, v));
  void f32le(double v) => _put(4, () => _tmp.setFloat32(0, v, Endian.little));

  void u24le(int v) {
    u8(v);
    u8(v >> 8);
    u8(v >> 16);
  }

  void varuint(int v) {
    var x = v;
    while (x >= 0x80) {
      u8((x & 0x7f) | 0x80);
      x >>= 7;
    }
    u8(x);
  }

  /// Bedrock string: varuint length + UTF-8.
  void string(String s) {
    final b = utf8.encode(s);
    varuint(b.length);
    bytes(b);
  }

  /// RakNet system address.
  void address(InternetAddress a, int port) {
    if (a.type == InternetAddressType.IPv4) {
      u8(4);
      for (final b in a.rawAddress) {
        u8(~b & 0xff);
      }
      u16be(port);
    } else {
      u8(6);
      u16le(23); // AF_INET6 on Windows, which is what RakNet writes
      u16be(port);
      u32be(0); // flow info
      bytes(a.rawAddress);
      u32be(0); // scope id
    }
  }

  void _put(int n, void Function() set) {
    set();
    _b.add(Uint8List.fromList(_tmp.buffer.asUint8List(0, n)));
  }

  Uint8List take() => _b.takeBytes();
}

class ByteReader {
  ByteReader(this.data, [this.pos = 0]) : _view = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData _view;
  int pos;

  int get remaining => data.length - pos;
  bool get done => pos >= data.length;

  void _need(int n) {
    if (pos + n > data.length) throw PacketFormatException('need $n bytes at $pos, have ${data.length}');
  }

  int u8() {
    _need(1);
    return data[pos++];
  }

  bool boolean() => u8() != 0;

  int u16be() {
    _need(2);
    final v = _view.getUint16(pos);
    pos += 2;
    return v;
  }

  int u24le() {
    _need(3);
    final v = data[pos] | data[pos + 1] << 8 | data[pos + 2] << 16;
    pos += 3;
    return v;
  }

  int i32be() {
    _need(4);
    final v = _view.getInt32(pos);
    pos += 4;
    return v;
  }

  int u32be() {
    _need(4);
    final v = _view.getUint32(pos);
    pos += 4;
    return v;
  }

  int i64be() {
    _need(8);
    final v = _view.getInt64(pos);
    pos += 8;
    return v;
  }

  int varuint() {
    var result = 0;
    for (var shift = 0; shift < 35; shift += 7) {
      final b = u8();
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
    }
    throw PacketFormatException('varint too long');
  }

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return v;
  }

  Uint8List rest() => bytes(remaining);

  void skip(int n) {
    _need(n);
    pos += n;
  }

  /// RakNet system address; returns address and port.
  ({InternetAddress address, int port}) address() {
    final version = u8();
    if (version == 4) {
      final raw = Uint8List.fromList([for (final b in bytes(4)) ~b & 0xff]);
      return (address: InternetAddress.fromRawAddress(raw), port: u16be());
    }
    if (version == 6) {
      skip(2); // family
      final port = u16be();
      skip(4); // flow info
      final raw = Uint8List.fromList(bytes(16));
      skip(4); // scope id
      return (address: InternetAddress.fromRawAddress(raw, type: InternetAddressType.IPv6), port: port);
    }
    throw PacketFormatException('unknown address version $version');
  }
}
