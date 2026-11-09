/// Hand-written fromJson so nothing is hidden: every amount arrives as an `int` of cents,
/// and `as int` throws if the server ever sent a float.
library;

import '../app/strings.dart';

DateTime? _date(Object? value) => value == null ? null : DateTime.parse(value as String);

List<T> _list<T>(Object? json, T Function(Map<String, dynamic>) item) => [
  for (final x in (json as List<dynamic>? ?? const [])) item(x as Map<String, dynamic>),
];

/// One page of a newest-first list. Pass [nextCursor] back to get the next page; null means the end.
class CursorPage<T> {
  const CursorPage({required this.items, required this.nextCursor});

  final List<T> items;
  final String? nextCursor;

  factory CursorPage.fromJson(Map<String, dynamic> json, T Function(Map<String, dynamic>) item) =>
      CursorPage(items: _list(json['items'], item), nextCursor: json['nextCursor'] as String?);
}

typedef ExpensePage = CursorPage<Expense>;

class Me {
  const Me({
    required this.userId,
    required this.email,
    required this.name,
    this.emailVerified = false,
    this.payment,
    this.payQrUrl,
  });

  final String userId;
  final String email;
  final String name;

  /// Invites reach only a verified email address.
  final bool emailVerified;

  /// Bank details from the last bill, to pre-fill the next one.
  final PaymentInfo? payment;

  /// Presigned view URL of the bank QR screenshot, if one was uploaded.
  final String? payQrUrl;

  factory Me.fromJson(Map<String, dynamic> json) => Me(
    userId: json['userId'] as String,
    email: json['email'] as String,
    name: json['name'] as String,
    emailVerified: json['emailVerified'] as bool? ?? false,
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

/// Someone invited to a group by email who hasn't accepted yet (the group's view).
class GroupInvite {
  const GroupInvite({required this.id, required this.email, required this.invitedBy, required this.createdAt});

  final String id;
  final String email;
  final String invitedBy;
  final DateTime createdAt;

  factory GroupInvite.fromJson(Map<String, dynamic> json) => GroupInvite(
    id: json['id'] as String,
    email: json['email'] as String,
    invitedBy: json['invitedBy'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.currency,
    required this.members,
    required this.createdAt,
    this.invites = const [],
  });

  final String id;
  final String name;
  final String currency;
  final List<Member> members;
  final List<GroupInvite> invites;
  final DateTime createdAt;

  factory Group.fromJson(Map<String, dynamic> json) => Group(
    id: json['id'] as String,
    name: json['name'] as String,
    currency: json['currency'] as String,
    members: _list(json['members'], Member.fromJson),
    invites: _list(json['invites'], GroupInvite.fromJson),
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  String nameOf(String userId) {
    for (final m in members) {
      if (m.userId == userId) return m.name;
    }
    return S.formerMember;
  }

  bool isMember(String userId) => members.any((m) => m.userId == userId);
}

/// An invite to me (GET /invites), shown on the groups page to accept or decline.
class PendingInvite {
  const PendingInvite({
    required this.id,
    required this.groupId,
    required this.groupName,
    required this.currency,
    required this.memberCount,
    required this.invitedByName,
    required this.createdAt,
  });

  final String id;
  final String groupId;
  final String groupName;
  final String currency;
  final int memberCount;
  final String invitedByName;
  final DateTime createdAt;

  factory PendingInvite.fromJson(Map<String, dynamic> json) => PendingInvite(
    id: json['id'] as String,
    groupId: json['groupId'] as String,
    groupName: json['groupName'] as String,
    currency: json['currency'] as String,
    memberCount: json['memberCount'] as int,
    invitedByName: json['invitedByName'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

enum SplitType {
  even('EVEN', S.splitEven),
  exact('EXACT', S.splitExact),
  percent('PERCENT', S.splitPercent);

  const SplitType(this.wire, this.label);
  final String wire;
  final String label;

  /// Unknown values (a newer server) read as [exact]: the rows still carry each person's amount,
  /// so one odd expense can't break the whole group page.
  static SplitType fromWire(String value) => values.firstWhere((t) => t.wire == value, orElse: () => SplitType.exact);
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
    this.version = 1,
    this.updatedAt,
    this.updatedBy,
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

  /// Sent back with an edit: the server refuses it (EXPENSE_CHANGED) if someone changed it meanwhile.
  final int version;
  final DateTime? updatedAt;
  final String? updatedBy;

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
    id: json['id'] as String,
    groupId: json['groupId'] as String,
    description: json['description'] as String,
    amountCents: json['amountCents'] as int,
    paidBy: json['paidBy'] as String,
    splitType: SplitType.fromWire(json['splitType'] as String),
    splits: _list(json['splits'], Split.fromJson),
    hasReceipt: json['hasReceipt'] as bool? ?? false,
    createdAt: DateTime.parse(json['createdAt'] as String),
    version: json['version'] as int? ?? 1,
    updatedAt: _date(json['updatedAt']),
    updatedBy: json['updatedBy'] as String?,
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
    version: version,
    updatedAt: updatedAt,
    updatedBy: updatedBy,
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
    balances: _list(json['balances'], MemberBalance.fromJson),
    transfers: _list(json['transfers'], Transfer.fromJson),
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

  bool involves(String userId) => fromUserId == userId || toUserId == userId;
}

/// A presigned S3 POST: send every field, then the file last as `file`. Then confirm the [key].
class PresignedPost {
  const PresignedPost({required this.uploadUrl, required this.fields, required this.key, required this.maxBytes});

  final String uploadUrl;
  final Map<String, String> fields;

  /// Where the object lands; the confirm call sends it back.
  final String key;

  /// S3 refuses anything bigger (the policy says so); checked before uploading too.
  final int maxBytes;

  factory PresignedPost.fromJson(Map<String, dynamic> json) => PresignedPost(
    uploadUrl: json['uploadUrl'] as String,
    fields: (json['fields'] as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String)),
    key: json['key'] as String,
    maxBytes: json['maxBytes'] as int? ?? 10 * 1024 * 1024,
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
    claimedBy: (json['claimedBy'] as List<dynamic>).cast<String>(),
    shares: (json['shares'] as Map<String, dynamic>).map((k, v) => MapEntry(k, v as int)),
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
    required this.paidCents,
    required this.dueCents,
  });

  final String id;
  final String name;
  final bool isHost;

  /// Marked paid, and what they marked covers their current total.
  final bool paid;
  final List<String> itemIds;
  final int totalCents;

  /// What the guest marked as paid (0 = not marked).
  final int paidCents;

  /// totalCents − paidCents, from the server: positive = still owes, negative = paid too much.
  final int dueCents;

  /// Marked paid, but their ticks changed afterwards so the amounts differ.
  bool get paidDiffers => paidCents > 0 && dueCents != 0;

  factory BillGuest.fromJson(Map<String, dynamic> json) => BillGuest(
    id: json['id'] as String,
    name: json['name'] as String,
    isHost: json['isHost'] as bool,
    paid: json['paid'] as bool,
    itemIds: (json['itemIds'] as List<dynamic>).cast<String>(),
    totalCents: json['totalCents'] as int,
    paidCents: json['paidCents'] as int,
    dueCents: json['dueCents'] as int,
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
    this.updatedAt,
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

  /// Last change on the server. A poll that answers with an older one is stale and is dropped.
  final DateTime? updatedAt;

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
    items: _list(json['items'], BillItem.fromJson),
    guests: _list(json['guests'], BillGuest.fromJson),
    totalCents: json['totalCents'] as int,
    unclaimedCents: json['unclaimedCents'] as int,
    owedCents: json['owedCents'] as int,
    paidCents: json['paidCents'] as int,
    payment: json['payment'] == null ? null : PaymentInfo.fromJson(json['payment'] as Map<String, dynamic>),
    hasPayQr: json['hasPayQr'] as bool? ?? false,
    url: json['url'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: _date(json['updatedAt']),
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
