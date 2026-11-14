import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';
import 'database.dart';
import 'xtream_client.dart' show loginPlaceholder, withLogin;

/// Source passwords in the system keychain (Windows Credential Manager,
/// Android Keystore, Apple Keychain, libsecret on Linux), not the database.
class Secrets {
  const Secrets([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static String _key(int sourceId) => 'source_${sourceId}_password';

  /// The database only holds a password the keychain could not take, so that
  /// copy is the newer one.
  Future<String?> password(Source source) async {
    if (source.password case final password?) return password;
    try {
      return await _storage.read(key: _key(source.id));
    } catch (_) {
      return null; // No keychain, or one restored from another device.
    }
  }

  /// False when the keychain is unavailable, such as Linux without a keyring.
  Future<bool> savePassword(int sourceId, String? password) async {
    try {
      if (password == null) {
        await _storage.delete(key: _key(sourceId));
      } else {
        await _storage.write(key: _key(sourceId), value: password);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// [urls] ready for the player: stored Xtream URLs hold [loginPlaceholder]
/// instead of the login.
Future<List<String>> playableUrls(
    AppDatabase db, Secrets secrets, int sourceId, List<String> urls) async {
  if (!urls.any((u) => u.contains(loginPlaceholder))) return urls;
  final source = await db.source(sourceId);
  final password = await secrets.password(source) ?? '';
  return [for (final u in urls) withLogin(u, source.username ?? '', password)];
}

/// Moves passwords out of the database, with the logins inside stored stream
/// URLs: those older versions saved, and any saved while the keychain was
/// unavailable. Runs at each start, and does nothing once they are moved.
Future<void> moveLoginsToKeychain(AppDatabase db, Secrets secrets) async {
  for (final source in await db.allSources()) {
    final password = source.password;
    if (password == null) continue;
    if (!await secrets.savePassword(source.id, password)) return;
    await db.forgetLogin(source, password);
  }
}
