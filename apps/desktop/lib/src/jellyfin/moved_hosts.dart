// Servers that moved to another domain: addresses saved under the old one
// are put on the new one ([movedAddress]), the same names under it.

/// Old domain -> new domain. pol's server: example.org -> example.org.
const movedDomains = {'example.org': 'example.org'};

final _authority = RegExp(r'^([a-z][a-z0-9+.\-]*://(?:[^@/?#]*@)?)([^:/?#]+)(.*)$', caseSensitive: false);

/// [url] with its host moved when it is a moved domain or a name under
/// one (`https://media.example.org:8920/x` ->
/// `https://media.example.org:8920/x`); scheme, port, path and the rest
/// kept as written. Anything else comes back unchanged.
String movedAddress(String url) {
  final m = _authority.firstMatch(url);
  if (m == null) return url;
  final host = m.group(2)!.toLowerCase();
  for (final MapEntry(key: old, value: now) in movedDomains.entries) {
    if (host == old || host.endsWith('.$old')) {
      return '${m.group(1)}${host.substring(0, host.length - old.length)}$now${m.group(3)}';
    }
  }
  return url;
}

/// [domain] and the names it moved from or to ([movedDomains]): one
/// server under either name.
Set<String> sameServerDomains(String domain) => {
      domain,
      for (final MapEntry(key: old, value: now) in movedDomains.entries)
        if (domain == old || domain == now) ...[old, now],
    };
