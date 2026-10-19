import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Phone-OTP login (the Indian norm). Supabase Auth sends the OTP via the configured SMS provider.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController(text: '+91 ');
  final _otp = TextEditingController();
  bool _sent = false, _busy = false; String? _error;

  Future<void> _sendOtp() async {
    setState(() { _busy = true; _error = null; });
    try { await Supabase.instance.client.auth.signInWithOtp(phone: _phone.text.replaceAll(' ', '')); setState(() => _sent = true); }
    on AuthException catch (e) { setState(() => _error = e.message); }
    finally { setState(() => _busy = false); }
  }

  Future<void> _verify() async {
    setState(() { _busy = true; _error = null; });
    try { await Supabase.instance.client.auth.verifyOTP(phone: _phone.text.replaceAll(' ', ''), token: _otp.text.trim(), type: OtpType.sms); }
    on AuthException catch (e) { setState(() => _error = e.message); }
    finally { setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(
      mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('PoultryOS', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4), const Text('కోళ్ల ఫారం నిర్వహణ · Farm management'),
      const SizedBox(height: 32),
      TextField(controller: _phone, keyboardType: TextInputType.phone, enabled: !_sent,
          decoration: const InputDecoration(labelText: 'Mobile number', prefixIcon: Icon(Icons.phone))),
      if (_sent) ...[const SizedBox(height: 12),
        TextField(controller: _otp, keyboardType: TextInputType.number, maxLength: 6, autofocus: true,
            decoration: const InputDecoration(labelText: 'OTP', prefixIcon: Icon(Icons.sms_outlined)))],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      const SizedBox(height: 16),
      FilledButton(onPressed: _busy ? null : (_sent ? _verify : _sendOtp), child: Text(_busy ? 'Please wait…' : (_sent ? 'Verify & sign in' : 'Send OTP'))),
      if (_sent) TextButton(onPressed: () => setState(() => _sent = false), child: const Text('Change number')),
    ]))));
  }
}
