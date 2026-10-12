import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'core/app_state.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'data/database.dart';
import 'data/repositories.dart';
import 'ui/screens/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // تسجيل الأخطاء في ملف سجل حتى نتمكّن من تشخيص أي فشل بدء تشغيل على ويندوز
  // (كان التطبيق يفشل في الصمت دون أي رسالة).
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _logCrash('FlutterError', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _logCrash('UncaughtAsync', error, stack);
    return true;
  };

  runApp(const SchoolApp());
}

/// يكتب خطأ بدء التشغيل إلى school_crash.log في مجلد دعم التطبيق.
Future<void> _logCrash(String kind, Object error, StackTrace? stack) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final f = File(p.join(dir.path, 'school_crash.log'));
    await f.writeAsString(
      '[${DateTime.now().toIso8601String()}] $kind: $error\n${stack ?? ''}\n\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // لا يمكن التسجيل — لا شيء نفعله.
  }
}

class SchoolApp extends StatelessWidget {
  const SchoolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _Boot(),
      ),
    );
  }
}

/// شاشة الإقلاع: تهيئة قاعدة البيانات + التحقق من وجود حساب.
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  String _status = 'جارٍ تهيئة النظام...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      final state = context.read<AppState>();
      await AppDatabase.instance.database;
      final hasUser = await AuthRepository().hasAnyUser();
      state.ensureDeviceId();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => LoginScreen(firstRun: !hasUser)),
      );
    } catch (e) {
      if (mounted) setState(() => _status = 'تعذّر تهيئة النظام: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.school, size: 72, color: AppTheme.primary),
            const SizedBox(height: 16),
            const Text(AppConfig.appName, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_status, style: const TextStyle(color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }
}
