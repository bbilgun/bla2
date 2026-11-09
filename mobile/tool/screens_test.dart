// Renders the main screens with sample data to PNGs, for design review without a device:
//   flutter test --update-goldens tool/screens_test.dart
// Output: tool/screens/*.png (git-ignored). Text uses Roboto here; on iPhone the app uses SF Pro.
import 'dart:io';

import 'package:flutter/material.dart' hide Split;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/theme.dart';
import 'package:netzero/controllers/auth_controller.dart';
import 'package:netzero/controllers/bill_detail_controller.dart';
import 'package:netzero/controllers/bills_controller.dart';
import 'package:netzero/controllers/group_detail_controller.dart';
import 'package:netzero/controllers/groups_controller.dart';
import 'package:netzero/controllers/invites_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/pages/auth_pages.dart';
import 'package:netzero/pages/bill_detail_page.dart';
import 'package:netzero/pages/group_detail_page.dart';
import 'package:netzero/pages/home_page.dart';
import 'package:netzero/repositories/repositories.dart';
import 'package:netzero/services/auth_service.dart';

const me = 'me';

class FakeAuth extends GetxService implements AuthService {
  @override
  String? userId = me;

  @override
  bool takeExpiredNotice() => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final now = DateTime(2026, 11, 5, 12);
const members = [
  Member(userId: me, email: 'b@x.mn', name: 'Билгүүн'),
  Member(userId: 'bat', email: 'bat@x.mn', name: 'Бат'),
  Member(userId: 'saraa', email: 'saraa@x.mn', name: 'Сараа'),
];
Group group(String id, String name, [String currency = 'MNT']) =>
    Group(id: id, name: name, currency: currency, members: members, createdAt: now);

class FakeGroups implements GroupsRepository {
  @override
  Future<CursorPage<Group>> list({String? cursor, int limit = 50}) async => CursorPage(
    items: [group('g1', 'Байрны зардал'), group('g2', 'Токиогийн аялал', 'USD'), group('g3', 'Ажлын үдийн хоол')],
    nextCursor: null,
  );

  @override
  Future<Group> get(String id) async => group(id, 'Байрны зардал');

  @override
  Future<Balances> balances(String groupId) async => const Balances(
    currency: 'MNT',
    balances: [
      MemberBalance(userId: me, name: 'Билгүүн', netCents: 4_250_000),
      MemberBalance(userId: 'bat', name: 'Бат', netCents: -3_000_000),
      MemberBalance(userId: 'saraa', name: 'Сараа', netCents: -1_250_000),
    ],
    transfers: [
      Transfer(fromUserId: 'bat', toUserId: me, amountCents: 3_000_000),
      Transfer(fromUserId: 'saraa', toUserId: me, amountCents: 1_250_000),
    ],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class FakeExpenses implements ExpensesRepository {
  @override
  Future<ExpensePage> list(String groupId, {String? cursor, int limit = 20}) async {
    Expense e(String id, String d, int amount, String paidBy, int day, {bool receipt = false}) => Expense(
      id: id,
      groupId: groupId,
      description: d,
      amountCents: amount,
      paidBy: paidBy,
      splitType: SplitType.even,
      splits: [for (final m in members) Split(userId: m.userId, amountCents: amount ~/ 3)],
      hasReceipt: receipt,
      createdAt: DateTime(2026, 11, day, 12),
    );
    return ExpensePage(
      items: [
        e('e1', 'Хүнсний дэлгүүр', 18_600_000, me, 5, receipt: true),
        e('e2', 'Цахилгааны төлбөр', 9_000_000, 'bat', 3),
        e('e3', 'Интернэт', 4_500_000, me, 1),
        e('e4', 'Такси', 2_400_000, 'saraa', 1),
      ],
      nextCursor: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class FakeInvites implements InvitesRepository {
  @override
  Future<List<PendingInvite>> list() async => [
    PendingInvite(
      id: 'i1',
      groupId: 'g9',
      groupName: 'Говийн аялал',
      currency: 'MNT',
      memberCount: 4,
      invitedByName: 'Бат',
      createdAt: now,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class FakeUsers implements UserRepository {
  @override
  Future<Me> me() async => const Me(userId: 'me', email: 'b@x.mn', name: 'Билгүүн');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Bill sampleBill() => Bill.fromJson({
  'id': 'b1',
  'code': '7KQ2HM',
  'title': 'Оройн хоол',
  'currency': 'MNT',
  'status': 'OPEN',
  'hostName': 'Билгүүн',
  'items': [
    {
      'id': 'i1',
      'name': 'Хуушуур',
      'priceCents': 3_000_000,
      'claimedBy': ['bat', 'host', 'saraa'],
      'shares': {'bat': 1_000_000, 'host': 1_000_000, 'saraa': 1_000_000},
    },
    {
      'id': 'i2',
      'name': 'Кола',
      'priceCents': 450_000,
      'claimedBy': ['bat'],
      'shares': {'bat': 450_000},
    },
    {'id': 'i3', 'name': 'Салат', 'priceCents': 1_200_000, 'claimedBy': <String>[], 'shares': <String, int>{}},
  ],
  'guests': [
    {
      'id': 'host',
      'name': 'Билгүүн',
      'isHost': true,
      'paid': false,
      'itemIds': ['i1'],
      'totalCents': 1_000_000,
      'paidCents': 0,
      'dueCents': 1_000_000,
    },
    {
      'id': 'bat',
      'name': 'Бат',
      'isHost': false,
      'paid': false,
      'itemIds': ['i1', 'i2'],
      'totalCents': 1_450_000,
      'paidCents': 1_000_000,
      'dueCents': 450_000,
    },
    {
      'id': 'saraa',
      'name': 'Сараа',
      'isHost': false,
      'paid': true,
      'itemIds': ['i1'],
      'totalCents': 1_000_000,
      'paidCents': 1_000_000,
      'dueCents': 0,
    },
  ],
  'totalCents': 4_650_000,
  'unclaimedCents': 1_200_000,
  'owedCents': 2_450_000,
  'paidCents': 1_450_000,
  'payment': {'bankName': 'Хаан банк', 'accountNumber': '5000123456', 'accountName': 'Билгүүн'},
  'hasPayQr': false,
  'url': 'https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com/b/AbCdEfGhIjKlMnOpQrStUv',
  'createdAt': '2026-11-05T10:00:00.000Z',
});

class FakeBills implements BillsRepository {
  @override
  Future<CursorPage<BillSummary>> list({String? cursor, int limit = 20}) async => CursorPage(
    nextCursor: null,
    items: [
      BillSummary(
        id: 'b1',
        title: 'Оройн хоол',
        currency: 'MNT',
        isOpen: true,
        totalCents: 4_650_000,
        guestCount: 2,
        paidCount: 1,
        createdAt: now,
      ),
      BillSummary(
        id: 'b2',
        title: 'Төрсөн өдөр',
        currency: 'MNT',
        isOpen: false,
        totalCents: 32_000_000,
        guestCount: 6,
        paidCount: 6,
        createdAt: DateTime(2026, 10, 28),
      ),
    ],
  );

  @override
  Future<Bill> get(String id) async => sampleBill();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> loadFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/Users/bilguun/development/flutter';
  final dir = '$flutterRoot/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Light', 'Regular', 'Medium', 'Bold', 'Black']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$dir/Roboto-$w.ttf').readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$dir/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

Future<void> shoot(WidgetTester tester, String name, Widget page, {Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = const Size(393 * 2, 852 * 2);
  tester.view.devicePixelRatio = 2;
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness),
        locale: const Locale('mn'),
        supportedLocales: const [Locale('mn')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: page,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.runAsync(() => precacheImage(const AssetImage('assets/brand/mark.png'), key.currentContext!));
  await tester.pump();
  await expectLater(find.byKey(key), matchesGoldenFile('screens/$name.png'));
}

void main() {
  setUpAll(loadFonts);
  setUp(() {
    Get.testMode = true;
    Get.put<AuthService>(FakeAuth());
  });
  tearDown(Get.reset);

  testWidgets('sign in', (tester) async {
    Get.put(AuthController(Get.find()));
    await shoot(tester, '1-sign-in', const SignInPage());
  });

  testWidgets('home: groups', (tester) async {
    Get.put(GroupsController(FakeGroups(), FakeUsers()));
    Get.put(InvitesController(FakeInvites()));
    Get.put(BillsController(FakeBills()));
    await shoot(tester, '2-groups', const HomePage());
  });

  testWidgets('group detail', (tester) async {
    Get.put(GroupDetailController('g1', FakeGroups(), FakeExpenses()));
    await shoot(tester, '3-group', const GroupDetailPage());
  });

  testWidgets('group detail, dark', (tester) async {
    Get.put(GroupDetailController('g1', FakeGroups(), FakeExpenses()));
    await shoot(tester, '4-group-dark', const GroupDetailPage(), brightness: Brightness.dark);
  });

  testWidgets('bill detail', (tester) async {
    final c = Get.put(BillDetailController('b1', FakeBills(), pollEvery: const Duration(days: 1)));
    await shoot(tester, '5-bill', const BillDetailPage());
    c.onClose();
  });
}
