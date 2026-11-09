// Form validators, photo picker helpers and the delete account message.
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/account_controller.dart';
import 'package:netzero/domain/validators.dart';
import 'package:netzero/services/photo_picker.dart';

void main() {
  group('validators', () {
    test('a new password names what it is missing', () {
      expect(validateNewPassword('Short1a'), S.passwordTooShort);
      expect(validateNewPassword(null), S.passwordTooShort);
      expect(validateNewPassword('alllowercase1'), S.passwordNeeds([S.uppercaseLetter]));
      expect(validateNewPassword('ALLUPPERCASE1'), S.passwordNeeds([S.lowercaseLetter]));
      expect(validateNewPassword('NoDigitsHere'), S.passwordNeeds([S.aDigit]));
      expect(validateNewPassword('nouppernodigit'), S.passwordNeeds([S.uppercaseLetter, S.aDigit]));
      expect(validateNewPassword('Passw0rd12'), isNull);
    });

    test('email accepts surrounding spaces and rejects an address without a domain', () {
      expect(validateEmail(' a@b.mn '), isNull);
      expect(validateEmail('a@b'), S.enterValidEmail);
      expect(isValidEmail('bat@x.mn'), isTrue);
    });
  });

  group('photos', () {
    test('content type comes from the file name', () {
      expect(imageContentType('IMG_1.PNG'), 'image/png');
      expect(imageContentType('a.heic'), 'image/heic');
      expect(imageContentType('a.HEIF'), 'image/heic');
      expect(imageContentType('a.jpg'), 'image/jpeg');
      expect(imageContentType('scan'), 'image/jpeg');
    });

    test('picker errors become Mongolian text that points to Settings', () {
      expect(PhotoPicker.messageFor('camera_access_denied', ImageSource.camera), S.cameraPermissionDenied);
      expect(PhotoPicker.messageFor('photo_access_denied', ImageSource.gallery), S.photosPermissionDenied);
      expect(PhotoPicker.messageFor('no_available_camera', ImageSource.camera), S.noCamera);
      expect(PhotoPicker.messageFor('something_else', ImageSource.gallery), S.couldNotOpenPhoto);
      expect(S.cameraPermissionDenied, contains('Тохиргоо'));
    });
  });

  test('a blocked account deletion lists the groups from the error details', () {
    final details = [
      {'groupId': 'g1', 'name': 'Байр'},
      {'groupId': 'g2', 'name': 'Аялал'},
      'junk',
    ];

    final names = AccountController.groupNames(details);

    expect(names, ['Байр', 'Аялал']);
    expect(S.deleteAccountBlocked(['Байр', 'Аялал']), contains('Байр, Аялал'));
  });
}
