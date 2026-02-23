import 'package:flutter/material.dart';

import 'auth/auth_state.dart';
import 'screens/login_screen.dart';
import 'screens/notes_screen.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final user = await AuthService.loadUser();
  runApp(ManentApp(initialUser: user));
}

class ManentApp extends StatefulWidget {
  final AuthUser? initialUser;

  const ManentApp({super.key, this.initialUser});

  @override
  State<ManentApp> createState() => _ManentAppState();
}

class _ManentAppState extends State<ManentApp> {
  AuthUser? _user;

  @override
  void initState() {
    super.initState();
    _user = widget.initialUser;
  }

  Future<void> _onLogin(AuthUser user) async {
    await AuthService.save(user);
    setState(() => _user = user);
  }

  Future<void> _onLogout() async {
    await AuthService.clear();
    setState(() => _user = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
        ),
        useMaterial3: true,
      ),
      home: _user == null
          ? LoginScreen(onLogin: _onLogin)
          : NotesScreen(user: _user!, onLogout: _onLogout),
    );
  }
}
