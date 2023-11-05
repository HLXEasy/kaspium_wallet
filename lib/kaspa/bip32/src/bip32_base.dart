import 'dart:convert';
import 'dart:typed_data';

import '../../bs58check/bs58check.dart' as bs58check;
import 'models/networks.dart' as networks;
import 'models/networks.dart' show NetworkType;
import 'utils/crypto.dart';
import 'utils/ecurve.dart' as ecc;

const highestBit = 0x80000000;
const uInt31Max = 2147483647; // 2^31 - 1
const uInt32Max = 4294967295; // 2^32 - 1

/// Checks if you are awesome. Spoiler: you are.
class BIP32 {
  Uint8List? _d;
  Uint8List? _q;
  Uint8List chainCode;
  int depth = 0;
  int index = 0;
  NetworkType network;
  int parentFingerprint = 0x00000000;
  BIP32(this._d, this._q, this.chainCode, this.network);

  Uint8List get publicKey {
    _q ??= ecc.pointFromScalar(_d!, true)!;
    return _q!;
  }

  Uint8List? get privateKey => _d;
  Uint8List get identifier => hash160(publicKey);
  Uint8List get fingerprint => identifier.sublist(0, 4);

  bool isNeutered() {
    return _d == null;
  }

  BIP32 neutered() {
    final neutered = BIP32.fromPublicKey(publicKey, chainCode, network);
    neutered.depth = depth;
    neutered.index = index;
    neutered.parentFingerprint = parentFingerprint;
    return neutered;
  }

  String toBase58() {
    final version =
        (!isNeutered()) ? network.bip32.private : network.bip32.public;
    Uint8List buffer = Uint8List(78);
    ByteData bytes = buffer.buffer.asByteData();
    bytes.setUint32(0, version);
    bytes.setUint8(4, depth);
    bytes.setUint32(5, parentFingerprint);
    bytes.setUint32(9, index);
    buffer.setRange(13, 45, chainCode);
    if (!isNeutered()) {
      bytes.setUint8(45, 0);
      buffer.setRange(46, 78, privateKey!);
    } else {
      buffer.setRange(45, 78, publicKey);
    }
    return bs58check.encode(buffer);
  }

  BIP32 derive(int index) {
    if (index > uInt32Max || index < 0) throw ArgumentError("Expected UInt32");
    final isHardened = index >= highestBit;
    Uint8List data = Uint8List(37);
    if (isHardened) {
      if (isNeutered()) {
        throw ArgumentError("Missing private key for hardened child key");
      }
      data[0] = 0x00;
      data.setRange(1, 33, privateKey!);
      data.buffer.asByteData().setUint32(33, index);
    } else {
      data.setRange(0, 33, publicKey);
      data.buffer.asByteData().setUint32(33, index);
    }
    final i = hmacSHA512(chainCode, data);
    final il = i.sublist(0, 32);
    final ir = i.sublist(32);
    if (!ecc.isPrivate(il)) {
      return derive(index + 1);
    }
    BIP32 hd;
    if (!isNeutered()) {
      final ki = ecc.privateAdd(privateKey!, il);
      if (ki == null) return derive(index + 1);
      hd = BIP32.fromPrivateKey(ki, ir, network);
    } else {
      final ki = ecc.pointAddScalar(publicKey, il, true);
      if (ki == null) return derive(index + 1);
      hd = BIP32.fromPublicKey(ki, ir, network);
    }
    hd.depth = depth + 1;
    hd.index = index;
    hd.parentFingerprint = fingerprint.buffer.asByteData().getUint32(0);
    return hd;
  }

  BIP32 deriveHardened(int index) {
    if (index > uInt31Max || index < 0) throw ArgumentError("Expected UInt31");
    return derive(index + highestBit);
  }

  BIP32 derivePath(String path) {
    final regex = RegExp(r"^(m\/)?(\d+'?\/)*\d+'?$");
    if (!regex.hasMatch(path)) throw ArgumentError("Expected BIP32 Path");
    List<String> splitPath = path.split("/");
    if (splitPath[0] == "m") {
      if (parentFingerprint != 0) {
        throw ArgumentError("Expected master, got child");
      }
      splitPath = splitPath.sublist(1);
    }
    return splitPath.fold(this, (BIP32 prevHd, String indexStr) {
      int index;
      if (indexStr.substring(indexStr.length - 1) == "'") {
        index = int.parse(indexStr.substring(0, indexStr.length - 1));
        return prevHd.deriveHardened(index);
      } else {
        index = int.parse(indexStr);
        return prevHd.derive(index);
      }
    });
  }

  factory BIP32.fromBase58(String string, [NetworkType? nw]) {
    Uint8List buffer = bs58check.decode(string);
    if (buffer.length != 78) throw ArgumentError("Invalid buffer length");
    NetworkType network = nw ?? networks.bitcoin;
    ByteData bytes = buffer.buffer.asByteData();
    // 4 bytes: version bytes
    var version = bytes.getUint32(0);
    if (version != network.bip32.private && version != network.bip32.public) {
      throw ArgumentError("Invalid network version");
    }
    // 1 byte: depth: 0x00 for master nodes, 0x01 for level-1 descendants, ...
    var depth = buffer[4];

    // 4 bytes: the fingerprint of the parent's key (0x00000000 if master key)
    var parentFingerprint = bytes.getUint32(5);
    if (depth == 0) {
      if (parentFingerprint != 0x00000000) {
        throw ArgumentError("Invalid parent fingerprint");
      }
    }

    // 4 bytes: child number. This is the number i in xi = xpar/i, with xi the key being serialized.
    // This is encoded in MSB order. (0x00000000 if master key)
    var index = bytes.getUint32(9);
    if (depth == 0 && index != 0) throw ArgumentError("Invalid index");

    // 32 bytes: the chain code
    Uint8List chainCode = buffer.sublist(13, 45);
    BIP32 hd;

    // 33 bytes: private key data (0x00 + k)
    if (version == network.bip32.private) {
      if (bytes.getUint8(45) != 0x00) {
        throw ArgumentError("Invalid private key");
      }
      Uint8List k = buffer.sublist(46, 78);
      hd = BIP32.fromPrivateKey(k, chainCode, network);
    } else {
      // 33 bytes: public key data (0x02 + X or 0x03 + X)
      Uint8List X = buffer.sublist(45, 78);
      hd = BIP32.fromPublicKey(X, chainCode, network);
    }
    hd.depth = depth;
    hd.index = index;
    hd.parentFingerprint = parentFingerprint;
    return hd;
  }

  factory BIP32.fromPublicKey(
    Uint8List publicKey,
    Uint8List chainCode, [
    NetworkType? nw,
  ]) {
    NetworkType network = nw ?? networks.bitcoin;
    if (!ecc.isPoint(publicKey)) {
      throw ArgumentError("Point is not on the curve");
    }
    return BIP32(null, publicKey, chainCode, network);
  }

  factory BIP32.fromPrivateKey(
    Uint8List privateKey,
    Uint8List chainCode, [
    NetworkType? nw,
  ]) {
    NetworkType network = nw ?? networks.bitcoin;
    if (privateKey.length != 32) {
      throw ArgumentError(
        "Expected property privateKey of type Buffer(Length: 32)",
      );
    }
    if (!ecc.isPrivate(privateKey)) {
      throw ArgumentError("Private key not in range [1, n]");
    }
    return BIP32(privateKey, null, chainCode, network);
  }

  factory BIP32.fromSeed(Uint8List seed, [NetworkType? nw]) {
    if (seed.length < 16) {
      throw ArgumentError("Seed should be at least 128 bits");
    }
    if (seed.length > 64) {
      throw ArgumentError("Seed should be at most 512 bits");
    }
    NetworkType network = nw ?? networks.bitcoin;
    final i = hmacSHA512(utf8.encode("Bitcoin seed") as Uint8List, seed);
    final il = i.sublist(0, 32);
    final ir = i.sublist(32);
    return BIP32.fromPrivateKey(il, ir, network);
  }
}
