import 'package:dart_mappable/dart_mappable.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

part 'android_channel.mapper.dart';

const _methodChannel = MethodChannel('org.linkisend.linkisend_app/localsend');
final _logger = Logger('AndroidSaf');

/// From Android 10 and above, we need to use the Storage Access Framework (SAF) to access files due to the scoped storage.
/// SAF itself is available from Android 4.4 (API level 19).
/// We implemented our own algorithm to build encode and decode content URIs.
/// Older versions might also work but the encoded content URI is not guaranteed to work with our algorithm.
const contentUriMinSdk = 27;

Future<PickDirectoryResult?> pickDirectoryAndroid() async {
  final result = await _methodChannel.invokeMethod<Map>('pickDirectory');
  if (result == null) {
    return null;
  }

  return PickDirectoryResultMapper.fromJson({
    'directoryUri': result['directoryUri'],
    'files': (result['files'] as List).map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList(),
  });
}

Future<String?> pickDirectoryPathAndroid() async {
  final result = await _methodChannel.invokeMethod<String>('pickDirectoryPath');
  return result;
}

Future<List<FileInfo>?> pickFilesAndroid() async {
  final result = await _methodChannel.invokeMethod<List>('pickFiles');
  if (result == null) {
    return null;
  }

  return result.map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList();
}

/// Returns the global "Download" directory, e.g. /storage/emulated/0/Download.
Future<String?> getDownloadsDirectoryAndroid() async {
  try {
    return await _methodChannel.invokeMethod<String>('getDownloadsDirectory');
  } catch (e) {
    _logger.warning('Could not get downloads directory', e);
    return null;
  }
}

Future<bool> getSystemAnimationsStatusAndroid() async {
  return await _methodChannel.invokeMethod('isAnimationsEnabled') ?? true;
}

/// Requests the "Nearby devices" permission gating local network access on Android 17+.
/// Returns true when granted or when running on an older Android version.
Future<bool> requestLocalNetworkPermissionAndroid() async {
  try {
    return await _methodChannel.invokeMethod<bool>('requestLocalNetworkPermission') ?? false;
  } catch (e) {
    _logger.warning('Could not request local network permission', e);
    return false;
  }
}

Future<Map<String, String>> startLocalHotspotAndroid() async {
  final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  final permission = sdk >= 33 ? Permission.nearbyWifiDevices : Permission.locationWhenInUse;
  if (!await permission.request().isGranted) {
    throw PlatformException(code: 'HOTSPOT_PERMISSION_DENIED', message: 'Nearby Wi-Fi permission is required to start a hotspot.');
  }
  final result = await _methodChannel.invokeMapMethod<String, dynamic>('startLocalHotspot');
  if (result == null) throw PlatformException(code: 'HOTSPOT_FAILED', message: 'Android did not return hotspot details.');
  return result.map((key, value) => MapEntry(key, value?.toString() ?? ''));
}

Future<void> stopLocalHotspotAndroid() => _methodChannel.invokeMethod('stopLocalHotspot');

Future<Map<String, String>> connectToHotspotAndroid({required String ssid, required String password}) async {
  final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  final permission = sdk >= 33 ? Permission.nearbyWifiDevices : Permission.locationWhenInUse;
  if (!await permission.request().isGranted) {
    throw PlatformException(code: 'WIFI_PERMISSION_DENIED', message: 'Разреши доступ к Wi-Fi устройствам для подключения.');
  }
  final result = await _methodChannel.invokeMapMethod<String, dynamic>('connectToHotspot', {'ssid': ssid, 'password': password});
  if (result == null) throw PlatformException(code: 'WIFI_JOIN_FAILED', message: 'Не удалось подключиться к точке доступа.');
  return result.map((key, value) => MapEntry(key, value?.toString() ?? ''));
}

Future<void> disconnectFromHotspotAndroid() => _methodChannel.invokeMethod('disconnectFromHotspot');

Future<List<String>> getNearbyHotspotsAndroid() async {
  final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  final permission = sdk >= 33 ? Permission.nearbyWifiDevices : Permission.locationWhenInUse;
  if (!await permission.request().isGranted) {
    throw PlatformException(code: 'WIFI_PERMISSION_DENIED', message: 'Разреши доступ к Wi-Fi устройствам.');
  }
  final result = await _methodChannel.invokeListMethod<String>('getNearbyHotspots');
  return result ?? const [];
}

Future<void> openContentUri({
  required String uri,
}) async {
  _logger.info('Opening content URI: $uri');
  await _methodChannel.invokeMethod('openContentUri', {
    'uri': uri,
  });
}

/// Tells MainActivity that the Dart side is now subscribed to the share_handler media stream,
/// so share intents that were held back during app start can be replayed.
Future<void> flushPendingShareIntentsAndroid() async {
  try {
    await _methodChannel.invokeMethod('shareIntentReady');
  } catch (e) {
    _logger.warning('Could not flush pending share intents', e);
  }
}

Future<void> openGallery() async {
  _logger.info('Opening gallery');
  await _methodChannel.invokeMethod('openGallery');
}

@MappableClass()
class PickDirectoryResult with PickDirectoryResultMappable {
  final String directoryUri;
  final List<FileInfo> files;

  PickDirectoryResult({
    required this.directoryUri,
    required this.files,
  });
}

@MappableClass()
class FileInfo with FileInfoMappable {
  final String name;
  final int size;
  final String uri;

  /// RFC 3339 in UTC. Null when the document provider does not know it.
  final String? lastModified;

  FileInfo({
    required this.name,
    required this.size,
    required this.uri,
    required this.lastModified,
  });
}
