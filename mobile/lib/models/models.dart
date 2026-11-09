/// Hand-written fromJson so nothing is hidden: every amount arrives as an `int` of cents,
/// and `as int` throws if the server ever sent a float.
library;

import '../app/strings.dart';

class Me {
  const Me({required this.userId, required this.email, required this.name, this.payment, this.payQrUrl});

  final String userId;
  final String email;
  final String name;

  /// Bank details from the last bill, to pre-fill the next one.
  final PaymentInfo? payment;

  /// Presigned view URL of the bank QR screenshot, if one was uploaded.
  final String? payQrUrl;

  factory Me.fromJson(Map<String, dynamic> json) => Me(
    userId: json['userId'] as String,
    email: json['email'] as String,
    name: json['name'] as String,
    payment: json['payment'] == null ? null : PaymentInfo.fromJson(json['payment'] as Map<String, dynamic>),
    payQrUrl: json['payQrUrl'] as String?,
  );
}

class Member {
  const Member({required this.userId, required this.email, required this.name});

  final String userId;
  final String email;
  final String name;

  factory Member.fromJson(Map<String, dynamic> json) =>
      Member(userId: json['userId'] as String, email: json['email'] as String, name: json['name'] as String);
}

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.currency,
    required this.members,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String currency;
  final List<Member> members;
  final DateTime createdAt;

  factory Group.fromJson(Map<String, dynamic> json) => Group(
    id: json['id'] as String,
    name: json['name'] as String,
    currency: json['currency'] as String,
    members: (json['members'] as List).map((m) => Member.fromJson(m as Map<String, dynamic>)).toList(),
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  String nameOf(String userId) {
    for (final m in members) {
      if (m.userId == userId) return m.name;
    }
    return S.formerMember;
  }
}

enum SplitType {
  even('EVEN', S.splitEven),
  exact('EXACT', S.splitExact),
  percent('PERCENT', S.splitPercent);

  const SplitType(this.wire, this.label);
  final String wire;
  final String label;

  static SplitType fromWire(String value) => values.firstWhere((t) => t.wire == value);
}

class Split {
  const Split({required this.userId, required this.amountCents});

  final String userId;
  final int amountCents;

  factory Split.fromJson(Map<String, dynamic> json) =>
      Split(userId: json['userId'] as String, amountCents: json['amountCents'] as int);
}

class Expense {
  const Expense({
    required this.id,
    required this.groupId,
    required this.description,
    required this.amountCents,
    required this.paidBy,
    required this.splitType,
    required this.splits,
    required this.hasReceipt,
    required this.createdAt,
  });

  final String id;
  final String groupId;
  final String description;
  final int amountCents;
  final String paidBy;
  final SplitType splitType;
  final List<Split> splits;
  final bool hasReceipt;
  final DateTime createdAt;

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
    id: json['id'] as String,
    groupId: json['groupId'] as String,
    description: json['description'] as String,
    amountCents: json['amountCents'] as int,
    paidBy: json['paidBy'] as String,
    splitType: SplitType.fromWire(json['splitType'] as String),
    splits: (json['splits'] as List).map((s) => Split.fromJson(s as Map<String, dynamic>)).toList(),
    hasReceipt: json['hasReceipt'] as bool? ?? false,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  Expense copyWith({bool? hasReceipt}) => Expense(
    id: id,
    groupId: groupId,
    description: description,
    amountCents: amountCents,
    paidBy: paidBy,
    splitType: splitType,
    splits: splits,
    hasReceipt: hasReceipt ?? this.hasReceipt,
    createdAt: createdAt,
  );
}

class ExpensePage {
  const ExpensePage({required this.items, required this.nextCursor});

  final List<Expense> items;
  final String? nextCursor;

  factory ExpensePage.fromJson(Map<String, dynamic> json) => ExpensePage(
    items: (json['items'] as List).map((e) => Expense.fromJson(e as Map<String, dynamic>)).toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}

class MemberBalance {
  const MemberBalance({required this.userId, required this.name, required this.netCents});

  final String userId;
  final String name;

  /// Positive: the group owes them. Negative: they owe the group.
  final int netCents;

  factory MemberBalance.fromJson(Map<String, dynamic> json) =>
      MemberBalance(userId: json['userId'] as String, name: json['name'] as String, netCents: json['netCents'] as int);
}

class Transfer {
  const Transfer({required this.fromUserId, required this.toUserId, required this.amountCents});

  final String fromUserId;
  final String toUserId;
  final int amountCents;

  factory Transfer.fromJson(Map<String, dynamic> json) => Transfer(
    fromUserId: json['fromUserId'] as String,
    toUserId: json['toUserId'] as String,
    amountCents: json['amountCents'] as int,
  );
}

class Balances {
  const Balances({required this.currency, required this.balances, required this.transfers});

  final String currency;
  final List<MemberBalance> balances;
  final List<Transfer> transfers;

  factory Balances.fromJson(Map<String, dynamic> json) => Balances(
    currency: json['currency'] as String,
    balances: (json['balances'] as List).map((b) => MemberBalance.fromJson(b as Map<String, dynamic>)).toList(),
    transfers: (json['transfers'] as List).map((t) => Transfer.fromJson(t as Map<String, dynamic>)).toList(),
  );

  int netOf(String userId) {
    for (final b in balances) {
      if (b.userId == userId) return b.netCents;
    }
    return 0;
  }
}

class Settlement {
  const Settlement({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.amountCents,
    required this.createdAt,
  });

  final String id;
  final String fromUserId;
  final String toUserId;
  final int amountCents;
  final DateTime createdAt;

  factory Settlement.fromJson(Map<String, dynamic> json) => Settlement(
    id: json['id'] as String,
    fromUserId: json['fromUserId'] as String,
    toUserId: json['toUserId'] as String,
    amountCents: json['amountCents'] as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class ReceiptUpload {
  const ReceiptUpload({required this.uploadUrl, required this.headers});

  final String uploadUrl;
  final Map<String, String> headers;

  factory ReceiptUpload.fromJson(Map<String, dynamic> json) => ReceiptUpload(
    uploadUrl: json['uploadUrl'] as String,
    headers: (json['headers'] as Map).map((k, v) => MapEntry(k as String, v as String)),
  );
}

// ---------------------------------------------------------------- bills (QR bill splitting)

class PaymentInfo {
  const PaymentInfo({required this.bankName, required this.accountNumber, required this.accountName});

  final String bankName;
  final String accountNumber;
  final String accountName;

  factory PaymentInfo.fromJson(Map<String, dynamic> json) => PaymentInfo(
    bankName: json['bankName'] as String,
    accountNumber: json['accountNumber'] as String,
    accountName: json['accountName'] as String,
  );

  Map<String, dynamic> toJson() => {'bankName': bankName, 'accountNumber': accountNumber, 'accountName': accountName};
}

class BillItem {
  const BillItem({
    required this.id,
    required this.name,
    required this.priceCents,
    required this.claimedBy,
    required this.shares,
  });

  final String id;
  final String name;
  final int priceCents;

  /// Guest ids sharing this line.
  final List<String> claimedBy;

  /// Guest id -> their share of the line, computed by the server.
  final Map<String, int> shares;

  factory BillItem.fromJson(Map<String, dynamic> json) => BillItem(
    id: json['id'] as String,
    name: json['name'] as String,
    priceCents: json['priceCents'] as int,
    claimedBy: (json['claimedBy'] as List).cast<String>(),
    shares: (json['shares'] as Map).map((k, v) => MapEntry(k as String, v as int)),
  );
}

class BillGuest {
  const BillGuest({
    required this.id,
    required this.name,
    required this.isHost,
    required this.paid,
    required this.itemIds,
    required this.totalCents,
  });

  final String id;
  final String name;
  final bool isHost;
  final bool paid;
  final List<String> itemIds;
  final int totalCents;

  factory BillGuest.fromJson(Map<String, dynamic> json) => BillGuest(
    id: json['id'] as String,
    name: json['name'] as String,
    isHost: json['isHost'] as bool,
    paid: json['paid'] as bool,
    itemIds: (json['itemIds'] as List).cast<String>(),
    totalCents: json['totalCents'] as int,
  );
}

/// A bill as the host sees it. Every total is computed by the server on each read.
class Bill {
  const Bill({
    required this.id,
    required this.code,
    required this.title,
    required this.currency,
    required this.isOpen,
    required this.hostName,
    required this.items,
    required this.guests,
    required this.totalCents,
    required this.unclaimedCents,
    required this.owedCents,
    required this.paidCents,
    required this.payment,
    required this.hasPayQr,
    required this.url,
    required this.createdAt,
  });

  static const hostGuestId = 'host';

  final String id;
  final String code;
  final String title;
  final String currency;
  final bool isOpen;
  final String hostName;
  final List<BillItem> items;
  final List<BillGuest> guests;
  final int totalCents;
  final int unclaimedCents;

  /// What the guests (not the host) owe the host, and how much of it they've marked paid.
  final int owedCents;
  final int paidCents;
  final PaymentInfo? payment;
  final bool hasPayQr;

  /// The link in the QR code. Guests open it in their phone's browser.
  final String url;
  final DateTime createdAt;

  BillGuest get host => guests.firstWhere((g) => g.isHost);
  List<BillGuest> get others => guests.where((g) => !g.isHost).toList();

  String nameOf(String guestId) {
    for (final g in guests) {
      if (g.id == guestId) return g.name;
    }
    return '';
  }

  factory Bill.fromJson(Map<String, dynamic> json) => Bill(
    id: json['id'] as String,
    code: json['code'] as String,
    title: json['title'] as String,
    currency: json['currency'] as String,
    isOpen: json['status'] == 'OPEN',
    hostName: json['hostName'] as String,
    items: (json['items'] as List).map((i) => BillItem.fromJson(i as Map<String, dynamic>)).toList(),
    guests: (json['guests'] as List).map((g) => BillGuest.fromJson(g as Map<String, dynamic>)).toList(),
    totalCents: json['totalCents'] as int,
    unclaimedCents: json['unclaimedCents'] as int,
    owedCents: json['owedCents'] as int,
    paidCents: json['paidCents'] as int,
    payment: json['payment'] == null ? null : PaymentInfo.fromJson(json['payment'] as Map<String, dynamic>),
    hasPayQr: json['hasPayQr'] as bool? ?? false,
    url: json['url'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class BillSummary {
  const BillSummary({
    required this.id,
    required this.title,
    required this.currency,
    required this.isOpen,
    required this.totalCents,
    required this.guestCount,
    required this.paidCount,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String currency;
  final bool isOpen;
  final int totalCents;
  final int guestCount;
  final int paidCount;
  final DateTime createdAt;

  factory BillSummary.fromJson(Map<String, dynamic> json) => BillSummary(
    id: json['id'] as String,
    title: json['title'] as String,
    currency: json['currency'] as String,
    isOpen: json['status'] == 'OPEN',
    totalCents: json['totalCents'] as int,
    guestCount: json['guestCount'] as int,
    paidCount: json['paidCount'] as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
