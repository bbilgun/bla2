import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../app/strings.dart';

/// A photo picked for upload.
class PickedPhoto {
  const PickedPhoto({required this.bytes, required this.contentType});

  final List<int> bytes;
  final String contentType;
}

/// The person can't pick a photo right now (permission denied, no camera). [message] says what to do.
class PhotoPickException implements Exception {
  const PhotoPickException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// "receipt.PNG" -> "image/png". Phones hand us JPEG, PNG or HEIC; anything else is sent as JPEG.
String imageContentType(String filename) {
  final name = filename.toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.heic') || name.endsWith('.heif')) return 'image/heic';
  return 'image/jpeg';
}

/// Wraps image_picker: returns bytes and content type, and turns its PlatformExceptions
/// (permission denied, no camera) into a Mongolian message instead of a crash.
class PhotoPicker {
  PhotoPicker([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Null when the person backs out without choosing.
  Future<PickedPhoto?> pick(ImageSource source, {double maxWidth = 2000, int imageQuality = 80}) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(source: source, maxWidth: maxWidth, imageQuality: imageQuality);
    } on PlatformException catch (e) {
      throw PhotoPickException(messageFor(e.code, source));
    }
    if (file == null) return null;
    return PickedPhoto(bytes: await file.readAsBytes(), contentType: imageContentType(file.name));
  }

  static String messageFor(String code, ImageSource source) => switch (code) {
    'camera_access_denied' || 'camera_access_restricted' => S.cameraPermissionDenied,
    'photo_access_denied' => S.photosPermissionDenied,
    'no_available_camera' => S.noCamera,
    _ => source == ImageSource.camera ? S.couldNotOpenCamera : S.couldNotOpenPhoto,
  };
}
