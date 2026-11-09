// Picking a photo from the camera or gallery for receipts and bank QR codes.
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../app/strings.dart';

/// A photo ready to upload.
class PickedPhoto {
  const PickedPhoto({required this.bytes, required this.contentType});

  /// The encoded image file.
  final List<int> bytes;

  /// MIME type, such as `image/jpeg`.
  final String contentType;
}

/// The user can't pick a photo right now, for example because permission was denied.
/// [message] tells them what to do about it.
class PhotoPickException implements Exception {
  const PhotoPickException(this.message);

  /// Mongolian text for the user.
  final String message;

  @override
  String toString() => message;
}

/// Guesses the MIME type from a file name, so "receipt.PNG" gives "image/png". Phones give us JPEG,
/// PNG or HEIC, and anything else is sent as JPEG.
String imageContentType(String filename) {
  final name = filename.toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.heic') || name.endsWith('.heif')) return 'image/heic';
  return 'image/jpeg';
}

/// A small wrapper around image_picker that returns bytes and a content type, and turns platform
/// errors into a [PhotoPickException] with a Mongolian message.
class PhotoPicker {
  PhotoPicker([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Opens the camera or gallery. Returns null if the user backs out without choosing.
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

  /// The message for an image_picker error [code].
  static String messageFor(String code, ImageSource source) => switch (code) {
    'camera_access_denied' || 'camera_access_restricted' => S.cameraPermissionDenied,
    'photo_access_denied' => S.photosPermissionDenied,
    'no_available_camera' => S.noCamera,
    _ => source == ImageSource.camera ? S.couldNotOpenCamera : S.couldNotOpenPhoto,
  };
}
