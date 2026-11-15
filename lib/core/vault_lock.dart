import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Palette-agnostic colors (works with both _P and AppPalette).
class LockColors {
  const LockColors({
    required this.surface, required this.text, required this.sub,
    required this.accent, required this.border,
  });
  final Color surface, text, sub, accent, border;
}

class VaultLock {
  VaultLock._();
  static final VaultLock instance = VaultLock._();

  static const _kHash = 'vault_pw_hash';
  static const _kSalt = 'vault_pw_salt';
  static const _kBio = 'vault_biometric';
  static const _kLegacy = 'vault_secret_key'; // old plain-text key
  static const minLen = 6;

  final LocalAuthentication _auth = LocalAuthentication();

  // ─── hashing ───
  String _hash(String pw, String salt) =>
      sha256.convert(utf8.encode('$salt:$pw')).toString();

  String _newSalt() {
    final r = Random.secure();
    return base64UrlEncode(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  // ─── password ───
  Future<bool> hasPassword() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kHash) != null || sp.getString(_kLegacy) != null;
  }

  Future<void> setPassword(String pw) async {
    final sp = await SharedPreferences.getInstance();
    final salt = _newSalt();
    await sp.setString(_kSalt, salt);
    await sp.setString(_kHash, _hash(pw, salt));
    await sp.remove(_kLegacy);
  }

  Future<bool> verify(String pw) async {
    final sp = await SharedPreferences.getInstance();
    final hash = sp.getString(_kHash);
    final salt = sp.getString(_kSalt);
    if (hash != null && salt != null) return _hash(pw, salt) == hash;

    // migrate old plain-text key
    final legacy = sp.getString(_kLegacy);
    if (legacy != null && legacy == pw) {
      await setPassword(pw);
      return true;
    }
    return false;
  }

  // ─── biometric ───
  Future<bool> biometricAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final types = await _auth.getAvailableBiometrics();
      return types.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> biometricEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kBio) ?? false;
  }

  Future<void> setBiometric(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kBio, v);
  }

  Future<bool> authenticateBio({String reason = 'Unlock your vault'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } on PlatformException {
      return false;
    }
  }

  /// Turn biometric ON only after the user proves it works once.
  Future<bool> enableBiometric() async {
    if (!await biometricAvailable()) return false;
    final ok = await authenticateBio(reason: 'Confirm to enable biometric unlock');
    if (ok) await setBiometric(true);
    return ok;
  }

  // ─── public flows ───
  /// Returns true if vault should open.
  Future<bool> unlock(BuildContext context, LockColors c) async {
    if (!await hasPassword()) {
      if (!context.mounted) return false;
      return _show(context, _Mode.setup, c);
    }
    if (await biometricEnabled() && await biometricAvailable()) {
      if (await authenticateBio()) return true;
    }
    if (!context.mounted) return false;
    return _show(context, _Mode.enter, c);
  }

  Future<bool> changePassword(BuildContext context, LockColors c) =>
      _show(context, _Mode.change, c);

  Future<bool> _show(BuildContext context, _Mode mode, LockColors c) async {
    final bioAvail = await biometricAvailable();
    final bioOn = await biometricEnabled();
    if (!context.mounted) return false;
    final res = await showDialog<bool>(
      context: context,
      builder: (_) => _LockDialog(mode: mode, c: c, bioAvailable: bioAvail, bioEnabled: bioOn),
    );
    return res ?? false;
  }
}

// ════════════════════════════════════════════════════════════════════
//  PASSWORD FIELD (with eye icon)
// ════════════════════════════════════════════════════════════════════
class VaultPwField extends StatefulWidget {
  const VaultPwField({
    super.key, required this.controller, required this.hint, required this.c,
    this.autofocus = false, this.onChanged, this.onSubmitted,
  });
  final TextEditingController controller;
  final String hint;
  final LockColors c;
  final bool autofocus;
  final ValueChanged<String>? onChanged, onSubmitted;

  @override
  State<VaultPwField> createState() => _VaultPwFieldState();
}

class _VaultPwFieldState extends State<VaultPwField> {
  bool _hide = true;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return TextField(
      controller: widget.controller,
      obscureText: _hide,
      autofocus: widget.autofocus,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      cursorColor: c.accent,
      style: TextStyle(color: c.accent, fontSize: 20, letterSpacing: _hide ? 3 : 1, fontWeight: FontWeight.bold),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: TextStyle(color: c.sub.withValues(alpha: 0.6), fontSize: 14, letterSpacing: 0, fontWeight: FontWeight.normal),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.border)),
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.accent, width: 2)),
        suffixIcon: IconButton(
          tooltip: _hide ? 'Show' : 'Hide',
          icon: Icon(_hide ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: c.sub, size: 22),
          onPressed: () => setState(() => _hide = !_hide),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  DIALOG (setup / enter / change)
// ════════════════════════════════════════════════════════════════════
enum _Mode { setup, enter, change }

class _LockDialog extends StatefulWidget {
  const _LockDialog({required this.mode, required this.c, required this.bioAvailable, required this.bioEnabled});
  final _Mode mode;
  final LockColors c;
  final bool bioAvailable, bioEnabled;

  @override
  State<_LockDialog> createState() => _LockDialogState();
}

class _LockDialogState extends State<_LockDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String _error = '';
  bool _enableBio = true;
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String get _title => switch (widget.mode) {
        _Mode.setup => 'Set Secret Key',
        _Mode.enter => 'Enter Secret Key',
        _Mode.change => 'Change Secret Key',
      };

  String get _action => switch (widget.mode) {
        _Mode.setup => 'Set Key',
        _Mode.enter => 'Unlock',
        _Mode.change => 'Change',
      };

  void _err(String m) {
    if (mounted) setState(() { _error = m; _busy = false; });
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() { _busy = true; _error = ''; });
    final lock = VaultLock.instance;

    switch (widget.mode) {
      case _Mode.enter:
        final ok = await lock.verify(_old.text.trim());
        if (!mounted) return;
        if (!ok) return _err('Incorrect Key ❌');
        Navigator.pop(context, true);
        return;

      case _Mode.setup:
        final n = _new.text.trim();
        if (n.length < VaultLock.minLen) return _err('Minimum ${VaultLock.minLen} characters required');
        if (n != _confirm.text.trim()) return _err('Keys do not match');
        await lock.setPassword(n);
        if (_enableBio && widget.bioAvailable) {
          await lock.enableBiometric();
        }
        if (!mounted) return;
        Navigator.pop(context, true);
        return;

      case _Mode.change:
        final o = _old.text.trim(), n = _new.text.trim();
        if (!await lock.verify(o)) return _err('Current key is incorrect ❌');
        if (n.length < VaultLock.minLen) return _err('Minimum ${VaultLock.minLen} characters required');
        if (n == o) return _err('New key must be different');
        if (n != _confirm.text.trim()) return _err('Keys do not match');
        await lock.setPassword(n);
        if (!mounted) return;
        Navigator.pop(context, true);
        return;
    }
  }

  Future<void> _bioUnlock() async {
    final ok = await VaultLock.instance.authenticateBio();
    if (ok && mounted) Navigator.pop(context, true);
  }

  void _clearErr(String _) {
    if (_error.isNotEmpty) setState(() => _error = '');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final m = widget.mode;

    final fields = <Widget>[
      if (m == _Mode.enter)
        VaultPwField(controller: _old, hint: 'Secret key', c: c, autofocus: true, onChanged: _clearErr, onSubmitted: (_) => _submit()),
      if (m == _Mode.change) ...[
        VaultPwField(controller: _old, hint: 'Current key', c: c, autofocus: true, onChanged: _clearErr),
        const SizedBox(height: 12),
      ],
      if (m != _Mode.enter) ...[
        VaultPwField(controller: _new, hint: 'New key (min ${VaultLock.minLen})', c: c, autofocus: m == _Mode.setup, onChanged: _clearErr),
        const SizedBox(height: 12),
        VaultPwField(controller: _confirm, hint: 'Confirm key', c: c, onChanged: _clearErr, onSubmitted: (_) => _submit()),
      ],
    ];

    return AlertDialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(_title, textAlign: TextAlign.center, style: TextStyle(color: c.text, fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ...fields,
          if (m == _Mode.setup && widget.bioAvailable) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _enableBio,
              activeColor: c.accent,
              onChanged: (v) => setState(() => _enableBio = v),
              title: Text('Use fingerprint / face', style: TextStyle(color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ],
          if (m == _Mode.enter && widget.bioEnabled && widget.bioAvailable) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _bioUnlock,
              icon: Icon(Icons.fingerprint_rounded, color: c.accent, size: 26),
              label: Text('Use biometric', style: TextStyle(color: c.accent, fontWeight: FontWeight.w700)),
            ),
          ],
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ]),
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: c.sub))),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: Text(_action, style: TextStyle(color: c.accent, fontWeight: FontWeight.bold, fontSize: 16)),
        ),
      ],
    );
  }
}