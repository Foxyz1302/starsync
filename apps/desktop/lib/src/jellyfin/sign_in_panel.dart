import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/home/ui.dart';
import 'accounts.dart';
import 'sign_in.dart';

/// Add a Jellyfin server (or reconnect an expired one): address, then Quick
/// Connect (big code, approve it in Jellyfin) or username and password.
class JellyfinSignInPanel extends StatefulWidget {
  final JellyfinAccounts accounts;
  final JellyfinAccount? reconnect;
  final ValueChanged<JellyfinAccount>? onDone;
  final VoidCallback? onCancel;
  final Duration pollInterval;
  const JellyfinSignInPanel({
    super.key,
    required this.accounts,
    this.reconnect,
    this.onDone,
    this.onCancel,
    this.pollInterval = const Duration(seconds: 3),
  });

  @override
  State<JellyfinSignInPanel> createState() => _JellyfinSignInPanelState();
}

class _JellyfinSignInPanelState extends State<JellyfinSignInPanel> {
  late final JellyfinSignIn _flow =
      JellyfinSignIn(widget.accounts, pollInterval: widget.pollInterval, reconnect: widget.reconnect);
  late final _address = TextEditingController(text: widget.reconnect?.baseUrl ?? '');
  late final _user = TextEditingController(text: widget.reconnect?.userName ?? '');
  final _password = TextEditingController();
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _flow.addListener(_changed);
    if (widget.reconnect != null) _flow.probe(widget.reconnect!.baseUrl);
  }

  @override
  void dispose() {
    _flow.removeListener(_changed);
    _flow.dispose();
    _address.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final linked = _flow.linked;
    if (_flow.step == JellyfinSignInStep.done && linked != null && !_reported) {
      _reported = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone?.call(linked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = _flow;
    final body = switch (f.step) {
      JellyfinSignInStep.address || JellyfinSignInStep.probing => _addressStep(),
      JellyfinSignInStep.method => _methodStep(),
      JellyfinSignInStep.quickConnect => _quickConnectStep(),
      JellyfinSignInStep.password || JellyfinSignInStep.signingIn => _passwordStep(),
      JellyfinSignInStep.done => Row(children: [
          const Icon(Icons.check_circle, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
              child: Text('Linked as ${f.linked?.userName} on ${f.linked?.displayName}',
                  key: const ValueKey('jf-linked'))),
        ]),
    };
    return Column(
      key: const ValueKey('jf-sign-in'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.reconnect == null ? 'Add a Jellyfin server' : 'Reconnect ${widget.reconnect!.displayName}',
            style: t.titleMedium),
        const SizedBox(height: 12),
        if (f.server != null && f.step != JellyfinSignInStep.address && f.step != JellyfinSignInStep.done)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ServerLine(
              name: f.server!.name,
              version: f.server!.version,
              url: f.baseUrl ?? '',
              onChange: widget.reconnect == null ? f.changeAddress : null,
            ),
          ),
        body,
        if (f.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(f.error!,
                key: const ValueKey('jf-sign-in-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ],
    );
  }

  Widget _cancelButton() => widget.onCancel == null
      ? const SizedBox.shrink()
      : TextButton(onPressed: widget.onCancel, child: const Text('Cancel'));

  Widget _addressStep() {
    final probing = _flow.step == JellyfinSignInStep.probing;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('jf-address'),
            controller: _address,
            autofocus: true,
            enabled: !probing,
            decoration: fieldDecoration('Server address', hint: 'jellyfin.example.com'),
            keyboardType: TextInputType.url,
            onSubmitted: (v) => _flow.probe(v),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          key: const ValueKey('jf-connect'),
          onPressed: probing ? null : () => _flow.probe(_address.text),
          child: probing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect'),
        ),
        _cancelButton(),
      ],
    );
  }

  Widget _methodStep() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_flow.quickConnectAvailable)
          FilledButton.icon(
            key: const ValueKey('jf-quick-connect'),
            onPressed: _flow.startQuickConnect,
            icon: const Icon(Icons.qr_code_2, size: 18),
            label: const Text('Quick Connect'),
          ),
        if (_flow.quickConnectAvailable)
          OutlinedButton.icon(
            key: const ValueKey('jf-use-password'),
            onPressed: _flow.usePassword,
            icon: const Icon(Icons.password, size: 18),
            label: const Text('Username & password'),
          )
        else
          FilledButton.icon(
            key: const ValueKey('jf-use-password'),
            onPressed: _flow.usePassword,
            icon: const Icon(Icons.password, size: 18),
            label: const Text('Username & password'),
          ),
        _cancelButton(),
      ],
    );
  }

  Widget _quickConnectStep() {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final code = _flow.code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (code == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  code,
                  key: const ValueKey('jf-qc-code'),
                  style: t.displaySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Copy code',
                onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
        const SizedBox(height: 12),
        const Text('Approve it in Jellyfin: Profile → Quick Connect, then enter this code.'),
        const SizedBox(height: 12),
        Row(
          children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            const Text('Waiting for approval…', style: TextStyle(color: Colors.grey)),
            const SizedBox(width: 16),
            TextButton(
              key: const ValueKey('jf-qc-cancel'),
              onPressed: _flow.cancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _passwordStep() {
    final busy = _flow.step == JellyfinSignInStep.signingIn;
    void submit() => _flow.signIn(_user.text, _password.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('jf-username'),
          controller: _user,
          autofocus: true,
          enabled: !busy,
          decoration: fieldDecoration('Username'),
          onSubmitted: (_) => submit(),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('jf-password'),
          controller: _password,
          enabled: !busy,
          obscureText: true,
          decoration: fieldDecoration('Password'),
          onSubmitted: (_) => submit(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              key: const ValueKey('jf-sign-in-submit'),
              onPressed: busy ? null : submit,
              child: busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in'),
            ),
            const SizedBox(width: 8),
            if (_flow.quickConnectAvailable)
              TextButton(onPressed: _flow.cancel, child: const Text('Back')),
            _cancelButton(),
          ],
        ),
      ],
    );
  }
}

class _ServerLine extends StatelessWidget {
  final String name;
  final String version;
  final String url;
  final VoidCallback? onChange;
  const _ServerLine({required this.name, required this.version, required this.url, this.onChange});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(Icons.dns_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name.isEmpty ? 'Jellyfin server' : name,
                  key: const ValueKey('jf-server-name'), style: t.titleSmall),
              Text('Jellyfin $version · $url', style: t.bodySmall?.copyWith(color: Colors.grey)),
            ],
          ),
        ),
        if (onChange != null) TextButton(onPressed: onChange, child: const Text('Change')),
      ],
    );
  }
}
