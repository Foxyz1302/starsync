import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// What a friend needs to join your server: where ([host], [port]), what
/// it is called ([name]), whether it asks a password ([password]; the
/// password itself is never in it) and which Starsync runs it
/// ([version]). [fp]: reserved for a pinned certificate fingerprint
/// (`wss://` with a self-signed certificate); always null for now.
class Invite {
  final String host;
  final int port;
  final String name;
  final bool password;
  final String version;
  final String? fp;
  const Invite({
    required this.host,
    required this.port,
    this.name = '',
    this.password = false,
    this.version = '',
    this.fp,
  });

  /// What goes in the Join card's address and port.
  String get address => '${host.contains(':') ? '[$host]' : host}:$port';

  /// The text Invite copies: the address, whether to ask for the password,
  /// the version to match.
  String get text => [
        'Join me on Starsync: $address',
        if (password) '(ask me for the password)',
        if (version.isNotEmpty) '· Starsync $version',
      ].join(' ');

  @override
  bool operator ==(Object other) =>
      other is Invite &&
      other.host == host &&
      other.port == port &&
      other.name == name &&
      other.password == password &&
      other.version == version &&
      other.fp == fp;

  @override
  int get hashCode => Object.hash(host, port, name, password, version, fp);

  @override
  String toString() => 'Invite($address${password ? ', password' : ''})';
}

/// The `host:port` in a pasted invite (or a bare address); null when
/// there is none.
({String host, String port})? addressIn(String text) {
  final m = RegExp(r'(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+):(\d{1,5})\b').firstMatch(text);
  if (m == null) return null;
  final host = m.group(1)!;
  return (host: host.startsWith('[') ? host.substring(1, host.length - 1) : host, port: m.group(2)!);
}

/// Interface names of container and VM bridges, never a way in for a
/// friend (Docker, Podman, libvirt, LXC, VirtualBox, VMware, WSL/Hyper-V).
final _virtualName = RegExp(
    r'^(docker|br-|veth|virbr|vmnet|vboxnet|cni|flannel|podman|lxcbr|lxdbr|vEthernet|VirtualBox|VMware)',
    caseSensitive: false);

/// The proxy fake-IP range (198.18.0.0/15, benchmarking space that TUN
/// proxies like Clash hand out): this machine's address on it is useless
/// to anyone else.
bool isFakeIp(List<int> b) => b[0] == 198 && (b[1] == 18 || b[1] == 19);

bool _isPrivate(List<int> b) =>
    b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] < 32);

/// Shared address space (100.64.0.0/10): mesh VPNs like Tailscale.
bool _isShared(List<int> b) => b[0] == 100 && b[1] >= 64 && b[1] < 128;

/// The addresses of [interfaces] a friend could dial, best first: IPv4,
/// no loopback, link-local or fake-IP address, no container or VM bridge;
/// home networks (192.168, then 10, then 172.16/12) first, then a mesh
/// VPN's, then anything else (a public address). No repeats.
List<String> inviteAddresses(Iterable<({String name, InternetAddress address})> interfaces) {
  int rank(List<int> b) => b[0] == 192 && b[1] == 168
      ? 0
      : _isPrivate(b)
          ? 1
          : _isShared(b)
              ? 2
              : 3;
  final usable = [
    for (final i in interfaces)
      if (i.address.type == InternetAddressType.IPv4 &&
          !i.address.isLoopback &&
          !i.address.isLinkLocal &&
          !(i.address.rawAddress[0] == 169 && i.address.rawAddress[1] == 254) &&
          !isFakeIp(i.address.rawAddress) &&
          !_virtualName.hasMatch(i.name))
        i.address,
  ];
  final indexed = [for (var n = 0; n < usable.length; n++) (n, usable[n])];
  indexed.sort((a, b) {
    final r = rank(a.$2.rawAddress).compareTo(rank(b.$2.rawAddress));
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return {for (final (_, a) in indexed) a.address}.toList();
}

/// This machine's interfaces as [inviteAddresses] takes them (empty when
/// they can't be listed).
Future<List<({String name, InternetAddress address})>> machineInterfaces() async {
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in list)
        for (final a in i.addresses) (name: i.name, address: a),
    ];
  } catch (e) {
    debugPrint('list network interfaces failed: $e');
    return const [];
  }
}
