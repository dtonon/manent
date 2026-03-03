import 'package:flutter/foundation.dart';

class AppFlavor {
  static String get storagePrefix => kDebugMode ? 'dev_' : '';
  static String get dbName => kDebugMode ? 'dev_manent.db' : 'manent.db';
  static String get appName => kDebugMode ? 'Manent Dev' : 'Manent';
}
