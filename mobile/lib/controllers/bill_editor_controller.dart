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
  BillEditorController({this.existing, required this._bills, required this._users, Uuid? uuid, ImagePicker? picker})
    : _uuid = uuid ?? const Uuid(),
      _picker = picker ?? ImagePicker();

  /// Null when creating.
  final Bill? existing;
  final BillsRepository _bills;
  final UserRepository _users;
  final Uuid _uuid;
  final ImagePicker _picker;

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
      lines.assignAll(bill.items.map((i) => BillLineForm(id: i.id, name: i.name, price: centsToInput(i.priceCents))));
      _fillPayment(bill.payment);
    } else {
      lines.assignAll([BillLineForm(), BillLineForm(), BillLineForm()]);
    }
    _loadProfile();
  }

  /// Pre-fills bank details saved from the last bill, and shows the QR image if there is one.
  Future<void> _loadProfile() async {
    try {
      final me = await _users.me();
      payQrUrl.value = me.payQrUrl;
      if (!isEditing && !_saveTapped && bank.text.isEmpty && accountNumber.text.isEmpty) _fillPayment(me.payment);
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
  int get totalCents => lines.fold(0, (sum, l) => sum + (tryParseCents(l.priceText.value) ?? 0));

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
      final price = tryParseCents(line.price.text);
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
      final bill = existing;
      if (bill != null) return await _bills.update(bill.id, body);

      final encoded = jsonEncode(body);
      if (encoded != _pendingBody) {
        _pendingKey = _uuid.v4();
        _pendingBody = encoded;
      }
      final created = await _bills.create(body, idempotencyKey: _pendingKey!);
      _pendingKey = null;
      _pendingBody = null;
      return created;
    } on ApiException catch (e) {
      error.value = e.isNetwork ? S.saveOffline : e.message;
      return null;
    } finally {
      saving.value = false;
    }
  }

  Future<void> uploadQr() async {
    final file = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 90);
    if (file == null) return;
    uploadingQr.value = true;
    error.value = null;
    try {
      final name = file.name.toLowerCase();
      final contentType = name.endsWith('.png')
          ? 'image/png'
          : name.endsWith('.heic')
          ? 'image/heic'
          : 'image/jpeg';
      await _users.uploadPayQr(await file.readAsBytes(), contentType: contentType);
      payQrUrl.value = (await _users.me()).payQrUrl;
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
