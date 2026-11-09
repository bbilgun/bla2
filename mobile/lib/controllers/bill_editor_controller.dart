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

/// One editable line of the receipt. [id] is set for lines that already exist on the server,
/// so guests keep their ticks on them when the host edits.
class BillLineForm {
  BillLineForm({this.id, String name = '', String price = ''})
    : name = TextEditingController(text: name),
      price = TextEditingController(text: price),
      priceText = price.obs {
    this.price.addListener(() => priceText.value = this.price.text);
  }

  final String? id;
  final TextEditingController name;
  final TextEditingController price;

  /// Mirrors [price] so Obx can update the running total as the host types.
  final RxString priceText;

  bool get isBlank => name.text.trim().isEmpty && price.text.trim().isEmpty;

  void dispose() {
    name.dispose();
    price.dispose();
  }
}

/// Create a bill, or edit one. The server computes every total; this only collects what's on the receipt.
class BillEditorController extends GetxController {
  BillEditorController({this.existing, required this._bills, required this._users, Uuid? uuid, PhotoPicker? picker})
    : _uuid = uuid ?? const Uuid(),
      _picker = picker ?? PhotoPicker();

  /// Null when creating.
  final Bill? existing;
  final BillsRepository _bills;
  final UserRepository _users;
  final Uuid _uuid;
  final PhotoPicker _picker;

  bool get isEditing => existing != null;

  final title = TextEditingController();
  final currency = 'MNT'.obs;
  final lines = <BillLineForm>[].obs;
  final bank = TextEditingController();
  final accountNumber = TextEditingController();
  final accountName = TextEditingController();

  final payQrUrl = RxnString();
  final uploadingQr = false.obs;
  final saving = false.obs;
  final error = RxnString();
  final fieldErrors = <String, String>{}.obs;

  /// Same rule as adding an expense: one key per distinct create request, reused on retries.
  String? _pendingKey;
  String? _pendingBody;

  /// Once Save is tapped, the form belongs to the person: a late pre-fill would change the body,
  /// and a changed body gets a new Idempotency-Key, so a retry could create a second bill.
  bool _saveTapped = false;
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
          (i) => BillLineForm(
            id: i.id,
            name: i.name,
            price: centsToInput(i.priceCents, currency: bill.currency),
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

  // ---- unsaved changes ----

  String _savedSnapshot = '';

  String _snapshot() => jsonEncode({
    'title': title.text,
    'currency': currency.value,
    'lines': [
      for (final l in lines) [l.name.text, l.price.text],
    ],
    'payment': [bank.text, accountNumber.text, accountName.text],
  });

  /// Something was typed or changed since the form opened: leaving asks first.
  bool get isDirty => _snapshot() != _savedSnapshot;

  /// Pre-fills bank details saved from the last bill, and shows the QR image if there is one.
  Future<void> _loadProfile() async {
    try {
      final me = await _users.me();
      payQrUrl.value = me.payQrUrl;
      if (!isEditing && !_saveTapped && bank.text.isEmpty && accountNumber.text.isEmpty) {
        // The pre-fill isn't the person's change: if they hadn't typed anything yet, it's still "clean".
        final untouched = !isDirty;
        _fillPayment(me.payment);
        if (untouched) _savedSnapshot = _snapshot();
      }
    } on ApiException {
      // Pre-filling is a convenience; the form works without it.
    }
  }

  void _fillPayment(PaymentInfo? p) {
    if (p == null) return;
    bank.text = p.bankName;
    accountNumber.text = p.accountNumber;
    accountName.text = p.accountName;
  }

  /// Display hint only. The server recomputes the real total.
  int get totalCents =>
      lines.fold(0, (sum, l) => sum + (tryParseCents(l.priceText.value, currency: currency.value) ?? 0));

  void addLine() => lines.add(BillLineForm());

  void removeLine(int index) {
    if (lines.length <= 1) return;
    lines.removeAt(index).dispose();
  }

  /// The JSON the API validates, or null with [fieldErrors] set.
  Map<String, dynamic>? buildBody() {
    final errors = <String, String>{};
    if (title.text.trim().isEmpty) errors['title'] = S.billTitleRequired;

    final items = <Map<String, dynamic>>[];
    for (final (i, line) in lines.indexed) {
      if (line.isBlank) continue;
      final name = line.name.text.trim();
      final price = tryParseCents(line.price.text, currency: currency.value);
      if (name.isEmpty || price == null || price <= 0) {
        errors['items'] ??= S.itemRowIncomplete(i + 1);
        continue;
      }
      items.add({'id': ?line.id, 'name': name, 'priceCents': price});
    }
    if (items.isEmpty) errors['items'] ??= S.needOneItem;

    final paymentFields = [bank.text.trim(), accountNumber.text.trim(), accountName.text.trim()];
    Map<String, dynamic>? payment;
    if (paymentFields.any((f) => f.isNotEmpty)) {
      if (paymentFields.any((f) => f.isEmpty)) {
        errors['payment'] = S.paymentIncomplete;
      } else {
        payment = {'bankName': paymentFields[0], 'accountNumber': paymentFields[1], 'accountName': paymentFields[2]};
      }
    }

    fieldErrors.assignAll(errors);
    if (errors.isNotEmpty) return null;
    return {'title': title.text.trim(), 'currency': currency.value, 'items': items, 'payment': payment};
  }

  /// Returns the saved bill, or null (see [error] / [fieldErrors]).
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
    for (final c in [title, bank, accountNumber, accountName]) {
      c.dispose();
    }
    for (final l in lines) {
      l.dispose();
    }
    super.onClose();
  }
}
