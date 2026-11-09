// The API's JSON shapes as Dart classes, parsed by hand. Amounts are ints of minor units, and the
// `as int` casts throw if the server ever sends a float.
import '../app/strings.dart';

DateTime? _date(Object? value) => value == null ? null : DateTime.parse(value as String);

List<T> _list<T>(Object? json, T Function(Map<String, dynamic>) parseItem) => [
  for (final entry in (json as List<dynamic>? ?? const [])) parseItem(entry as Map<String, dynamic>),
];

/// One page of a newest-first list.
class CursorPage<T> {
  const CursorPage({required this.items, required this.nextCursor});

  /// The items on this page, newest first.
  final List<T> items;

  /// Pass this back to get the next page. Null on the last page.
  final String? nextCursor;

  factory CursorPage.fromJson(Map<String, dynamic> json, T Function(Map<String, dynamic>) item) =>
      CursorPage(items: _list(json['items'], item), nextCursor: json['nextCursor'] as String?);
}

/// A page of a group's expenses.
typedef ExpensePage = CursorPage<Expense>;

/// The signed-in user's own profile, from `GET /me`.
class Me {
  const Me({
    required this.userId,
    required this.email,
    required this.name,
    this.emailVerified = false,
    this.payment,
    this.payQrUrl,
  });

  /// The Cognito `sub`.
  final String userId;
  final String email;
  final String name;

  /// Whether the email is verified. Group invites only reach verified addresses.
  final bool emailVerified;

  /// Bank details from the last bill, to pre-fill the next one.
  final PaymentInfo? payment;

  /// Short-lived download URL of the bank QR screenshot, if one was uploaded.
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

/// A member of a group.
class Member {
  const Member({required this.userId, required this.email, required this.name});

  final String userId;
  final String email;
  final String name;

  factory Member.fromJson(Map<String, dynamic> json) =>
      Member(userId: json['userId'] as String, email: json['email'] as String, name: json['name'] as String);
}

/// An invite the group has sent that hasn't been accepted yet, as the group's members see it.
class GroupInvite {
  const GroupInvite({required this.id, required this.email, required this.invitedBy, required this.createdAt});

  final String id;
  final String email;

  /// User id of the member who sent it.
  final String invitedBy;
  final DateTime createdAt;

  factory GroupInvite.fromJson(Map<String, dynamic> json) => GroupInvite(
    id: json['id'] as String,
    email: json['email'] as String,
    invitedBy: json['invitedBy'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// A group of people sharing expenses in one currency.
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

  /// ISO code. Every amount in the group is in this currency.
  final String currency;
  final List<Member> members;

  /// Invites not yet accepted.
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

  /// The member's name, or "former member" for someone who has left but still appears on old expenses.
  String nameOf(String userId) {
    for (final member in members) {
      if (member.userId == userId) return member.name;
    }
    return S.formerMember;
  }

  /// Whether [userId] is currently in the group.
  bool isMember(String userId) => members.any((member) => member.userId == userId);
}

/// An invite addressed to the signed-in user, from `GET /invites`, to accept or decline.
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

/// How an expense is divided between people.
enum SplitType {
  even('EVEN', S.splitEven),
  exact('EXACT', S.splitExact),
  percent('PERCENT', S.splitPercent);

  const SplitType(this.wire, this.label);

  /// The value the API uses.
  final String wire;

  /// The Mongolian label for the split picker.
  final String label;

  /// Parses the API value. An unknown value from a newer server reads as [exact], because the
  /// splits still carry each person's amount and one odd expense shouldn't break the group page.
  static SplitType fromWire(String value) {
    return values.firstWhere((type) => type.wire == value, orElse: () => SplitType.exact);
  }
}

/// One person's share of an expense, as worked out by the server.
class Split {
  const Split({required this.userId, required this.amountCents});

  final String userId;

  /// Their share in minor units.
  final int amountCents;

  factory Split.fromJson(Map<String, dynamic> json) =>
      Split(userId: json['userId'] as String, amountCents: json['amountCents'] as int);
}

/// Something one member paid for that is shared between some of the group.
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

  /// The total in minor units.
  final int amountCents;

  /// User id of the member who paid.
  final String paidBy;
  final SplitType splitType;

  /// Everyone's share. The shares always add up to [amountCents].
  final List<Split> splits;
  final bool hasReceipt;
  final DateTime createdAt;

  /// Sent back with an edit. The server answers `EXPENSE_CHANGED` if someone else edited it first.
  final int version;

  /// When it was last edited, or null if it never was.
  final DateTime? updatedAt;

  /// User id of whoever last edited it.
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

  /// A copy with [hasReceipt] changed, used after a receipt upload.
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

/// Where one member stands in a group.
class MemberBalance {
  const MemberBalance({required this.userId, required this.name, required this.netCents});

  final String userId;
  final String name;

  /// Positive when the group owes them, negative when they owe the group.
  final int netCents;

  factory MemberBalance.fromJson(Map<String, dynamic> json) =>
      MemberBalance(userId: json['userId'] as String, name: json['name'] as String, netCents: json['netCents'] as int);
}

/// A payment the server suggests to settle the group.
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

/// A group's balances and the fewest payments that would settle them, from `GET /groups/:id/balances`.
class Balances {
  const Balances({required this.currency, required this.balances, required this.transfers});

  final String currency;

  /// One entry per member. They add up to zero.
  final List<MemberBalance> balances;

  /// Suggested payments that bring everyone to zero.
  final List<Transfer> transfers;

  factory Balances.fromJson(Map<String, dynamic> json) => Balances(
    currency: json['currency'] as String,
    balances: _list(json['balances'], MemberBalance.fromJson),
    transfers: _list(json['transfers'], Transfer.fromJson),
  );

  /// The member's net balance, or 0 if they aren't listed.
  int netOf(String userId) {
    for (final balance in balances) {
      if (balance.userId == userId) return balance.netCents;
    }
    return 0;
  }
}

/// A recorded payment from one member to another.
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

  /// Whether [userId] paid or received this payment. Only they may delete it.
  bool involves(String userId) => fromUserId == userId || toUserId == userId;
}

/// Permission to upload one file straight to S3, from the API. See [ApiClient.postPresigned].
class PresignedPost {
  const PresignedPost({required this.uploadUrl, required this.fields, required this.key, required this.maxBytes});

  /// The S3 bucket URL to POST the form to.
  final String uploadUrl;

  /// Signed form fields that must be sent unchanged, before the file.
  final Map<String, String> fields;

  /// Where the object lands in the bucket. The confirm call sends it back to the API.
  final String key;

  /// The largest file the signed policy accepts, in bytes.
  final int maxBytes;

  factory PresignedPost.fromJson(Map<String, dynamic> json) => PresignedPost(
    uploadUrl: json['uploadUrl'] as String,
    fields: (json['fields'] as Map<String, dynamic>).map((name, value) => MapEntry(name, value as String)),
    key: json['key'] as String,
    maxBytes: json['maxBytes'] as int? ?? 10 * 1024 * 1024,
  );
}

// QR bills

/// Bank details guests transfer money to.
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

  /// The JSON the API expects.
  Map<String, dynamic> toJson() => {'bankName': bankName, 'accountNumber': accountNumber, 'accountName': accountName};
}

/// One line on a bill, and who claimed it.
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

  /// Ids of the guests sharing this line.
  final List<String> claimedBy;

  /// Each claiming guest's share of the price, keyed by guest id. Worked out by the server.
  final Map<String, int> shares;

  factory BillItem.fromJson(Map<String, dynamic> json) => BillItem(
    id: json['id'] as String,
    name: json['name'] as String,
    priceCents: json['priceCents'] as int,
    claimedBy: (json['claimedBy'] as List<dynamic>).cast<String>(),
    shares: (json['shares'] as Map<String, dynamic>).map((guestId, cents) => MapEntry(guestId, cents as int)),
  );
}

/// Someone who joined a bill, including the host.
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

  /// Whether they're marked paid and the amount covers their current total.
  final bool paid;

  /// Ids of the items they claimed.
  final List<String> itemIds;

  /// Their share of the bill.
  final int totalCents;

  /// What they're marked as having paid. 0 means not marked.
  final int paidCents;

  /// [totalCents] minus [paidCents]. Positive means they still owe, negative means they paid too much.
  final int dueCents;

  /// Whether they were marked paid but changed their items afterwards, so what they paid differs from their total.
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

/// A bill as its host sees it. The server works out every total on each read.
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

  /// The guest id the server gives the host.
  static const hostGuestId = 'host';

  final String id;

  /// Short code guests put in the bank transfer reference, so the host can match payments.
  final String code;
  final String title;
  final String currency;

  /// Whether guests can still change what they claimed.
  final bool isOpen;
  final String hostName;
  final List<BillItem> items;

  /// Everyone on the bill, the host included.
  final List<BillGuest> guests;
  final int totalCents;

  /// The part of the total nobody has claimed yet.
  final int unclaimedCents;

  /// What the guests, not counting the host, owe the host.
  final int owedCents;

  /// How much of [owedCents] guests have marked as paid.
  final int paidCents;
  final PaymentInfo? payment;

  /// Whether the host uploaded a bank QR screenshot for guests.
  final bool hasPayQr;

  /// The link in the QR code. Guests open it in their phone's browser.
  final String url;
  final DateTime createdAt;

  /// The last change on the server. A poll that answers with an older value is stale and is dropped.
  final DateTime? updatedAt;

  /// The host's own entry in [guests].
  BillGuest get host => guests.firstWhere((guest) => guest.isHost);

  /// Every guest except the host.
  List<BillGuest> get others => guests.where((guest) => !guest.isHost).toList();

  /// The guest's name, or an empty string for an id that isn't on the bill.
  String nameOf(String guestId) {
    for (final guest in guests) {
      if (guest.id == guestId) return guest.name;
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

/// A bill as it appears in the bills list.
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

  /// Guests other than the host.
  final int guestCount;

  /// How many of those guests have paid.
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
