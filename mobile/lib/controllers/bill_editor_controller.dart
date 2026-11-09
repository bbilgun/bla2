// The bill editor, for creating a QR bill or editing one.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../app/strings.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import '../services/photo_picker.dart';

/// One editable line of the bill.
class BillLineForm {
  BillLineForm({this.id, String name = '', String price = ''})
    : name = TextEditingController(text: name),
      price = TextEditingController(text: price),
      priceText = price.obs {
    this.price.addListener(() => priceText.value = this.price.text);
  }

  /// The server's id for a line that already exists. Sending it back keeps guests' ticks on the line.
  final String? id;

  /// The item name field.
  final TextEditingController name;

  /// The price field, as typed.
  final TextEditingController price;

  /// Follows [price] as the host types, so the running total can update.
  final RxString priceText;

  /// Whether both fields are empty. Blank lines are skipped when saving.
  bool get isBlank => name.text.trim().isEmpty && price.text.trim().isEmpty;

  /// Disposes the text fields.
  void dispose() {
    name.dispose();
    price.dispose();
  }
}

/// Collects what's on the receipt and where guests should pay, then creates or updates the bill.
/// The server works out every total. Pass [existing] to edit.
class BillEditorController extends GetxController {
  BillEditorController({this.existing, required this._bills, required this._users, Uuid? uuid, PhotoPicker? picker})
    : _uuid = uuid ?? const Uuid(),
      _picker = picker ?? PhotoPicker();

  /// The bill being edited, or null when creating.
  final Bill? existing;
  final BillsRepository _bills;
  final UserRepository _users;
  final Uuid _uuid;
  final PhotoPicker _picker;

  /// Whether the form edits an existing bill.
  bool get isEditing => existing != null;

  /// The bill title field.
  final title = TextEditingController();

  /// The bill's currency. Tugrik by default.
  final currency = 'MNT'.obs;

  /// The item lines. There is always at least one.
  final lines = <BillLineForm>[].obs;

  // Payment details guests transfer to.
  final bank = TextEditingController();
  final accountNumber = TextEditingController();
  final accountName = TextEditingController();

  /// Download URL of the host's bank QR screenshot, if they uploaded one.
  final payQrUrl = RxnString();

  /// True while the QR screenshot uploads.
  final uploadingQr = false.obs;

  /// True while the save request runs.
  final saving = false.obs;

  /// A failure to show above the Save button.
  final error = RxnString();

  /// Validation messages by field: `title`, `items` or `payment`.
  final fieldErrors = <String, String>{}.obs;

  // The Idempotency-Key for the create request being saved, and the body it was made for. Same rule
  // as for expenses: one key per distinct body, reused on retries.
  String? _pendingKey;
  String? _pendingBody;

  // Once Save is tapped, a late pre-fill must not change the form. A changed body gets a new
  // Idempotency-Key, so a retry could then create a second bill.
  bool _saveTapped = false;

  /// The Idempotency-Key a retry would reuse, or null when nothing is waiting.
  String? get pendingIdempotencyKey => _pendingKey;

  @override
  void onInit() {
    super.onInit();
    final bill = existing;
    if (bill != null) {
      title.text = bill.title;
      currency.value = bill.currency;
      lines.assignAll(
        bill.items.map(
          (item) => BillLineForm(
            id: item.id,
            name: item.name,
            price: centsToInput(item.priceCents, currency: bill.currency),
          ),
        ),
      );
      _fillPayment(bill.payment);
    } else {
      lines.assignAll([BillLineForm(), BillLineForm(), BillLineForm()]);
    }
    _savedSnapshot = _snapshot();
    unawaited(_loadProfile());
  }

  // Unsaved changes

  String _savedSnapshot = '';

  String _snapshot() => jsonEncode({
    'title': title.text,
    'currency': currency.value,
    'lines': [
      for (final line in lines) [line.name.text, line.price.text],
    ],
    'payment': [bank.text, accountNumber.text, accountName.text],
  });

  /// Whether anything changed since the form opened or last saved. Leaving then asks first.
  bool get isDirty => _snapshot() != _savedSnapshot;

  // Pre-fills the bank details saved from the last bill, and shows the QR image if there is one.
  Future<void> _loadProfile() async {
    try {
      final me = await _users.me();
      payQrUrl.value = me.payQrUrl;
      final paymentEmpty = bank.text.isEmpty && accountNumber.text.isEmpty;
      if (!isEditing && !_saveTapped && paymentEmpty) {
        // The pre-fill isn't the user's change, so a form they hadn't touched stays clean.
        final untouched = !isDirty;
        _fillPayment(me.payment);
        if (untouched) _savedSnapshot = _snapshot();
      }
    } on ApiException {
      // Pre-filling is a convenience. The form works without it.
    }
  }

  void _fillPayment(PaymentInfo? payment) {
    if (payment == null) return;
    bank.text = payment.bankName;
    accountNumber.text = payment.accountNumber;
    accountName.text = payment.accountName;
  }

  /// The sum of the prices typed so far, for display. The server works out the real total.
  int get totalCents {
    var sum = 0;
    for (final line in lines) {
      sum += tryParseCents(line.priceText.value, currency: currency.value) ?? 0;
    }
    return sum;
  }

  /// Adds an empty line.
  void addLine() => lines.add(BillLineForm());

  /// Removes a line, keeping at least one.
  void removeLine(int index) {
    if (lines.length <= 1) return;
    lines.removeAt(index).dispose();
  }

  /// Builds the JSON the API expects, or returns null and sets [fieldErrors] when the form is incomplete.
  /// Payment details are optional, but all three fields must be filled if any is.
  Map<String, dynamic>? buildBody() {
    final errors = <String, String>{};
    if (title.text.trim().isEmpty) errors['title'] = S.billTitleRequired;

    final items = <Map<String, dynamic>>[];
    for (final (index, line) in lines.indexed) {
      if (line.isBlank) continue;
      final name = line.name.text.trim();
      final price = tryParseCents(line.price.text, currency: currency.value);
      if (name.isEmpty || price == null || price <= 0) {
        errors['items'] ??= S.itemRowIncomplete(index + 1);
        continue;
      }
      items.add({'id': ?line.id, 'name': name, 'priceCents': price});
    }
    if (items.isEmpty) errors['items'] ??= S.needOneItem;

    final paymentFields = [bank.text.trim(), accountNumber.text.trim(), accountName.text.trim()];
    Map<String, dynamic>? payment;
    if (paymentFields.any((field) => field.isNotEmpty)) {
      if (paymentFields.any((field) => field.isEmpty)) {
        errors['payment'] = S.paymentIncomplete;
      } else {
        payment = {'bankName': paymentFields[0], 'accountNumber': paymentFields[1], 'accountName': paymentFields[2]};
      }
    }

    fieldErrors.assignAll(errors);
    if (errors.isNotEmpty) return null;
    return {'title': title.text.trim(), 'currency': currency.value, 'items': items, 'payment': payment};
  }

  /// Saves the bill. Returns it, or null if it didn't save, with the reason in [error] or [fieldErrors].
  /// A new bill gets an Idempotency-Key that is reused when Save is tapped again with the same form.
  Future<Bill?> save() async {
    if (saving.value) return null;
    _saveTapped = true;
    error.value = null;
    final body = buildBody();
    if (body == null) return null;

    saving.value = true;
    try {
      final Bill saved;
      final bill = existing;
      if (bill != null) {
        saved = await _bills.update(bill.id, body);
      } else {
        final encoded = jsonEncode(body);
        if (encoded != _pendingBody) {
          _pendingKey = _uuid.v4();
          _pendingBody = encoded;
        }
        saved = await _bills.create(body, idempotencyKey: _pendingKey!);
        _pendingKey = null;
        _pendingBody = null;
      }
      _savedSnapshot = _snapshot();
      return saved;
    } on ApiException catch (e) {
      // BILL_CLOSED's message tells the host to reopen the bill first.
      error.value = e.isNetwork ? S.saveOffline : e.message;
      return null;
    } finally {
      saving.value = false;
    }
  }

  /// Lets the host pick a screenshot of their bank's "receive money" QR and uploads it to their profile.
  Future<void> uploadQr() async {
    error.value = null;
    final PickedPhoto? photo;
    try {
      photo = await _picker.pick(ImageSource.gallery, maxWidth: 1600, imageQuality: 90);
    } on PhotoPickException catch (e) {
      error.value = e.message;
      return;
    }
    if (photo == null) return;
    uploadingQr.value = true;
    try {
      payQrUrl.value = await _users.uploadPayQr(photo.bytes, contentType: photo.contentType);
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      uploadingQr.value = false;
    }
  }

  @override
  void onClose() {
    for (final field in [title, bank, accountNumber, accountName]) {
      field.dispose();
    }
    for (final line in lines) {
      line.dispose();
    }
    super.onClose();
  }
}
