import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../controllers/account_controller.dart';
import '../controllers/add_expense_controller.dart';
import '../controllers/auth_controller.dart';
import '../controllers/bill_detail_controller.dart';
import '../controllers/bill_editor_controller.dart';
import '../controllers/bills_controller.dart';
import '../controllers/expense_controller.dart';
import '../controllers/group_detail_controller.dart';
import '../controllers/groups_controller.dart';
import '../controllers/invites_controller.dart';
import '../controllers/settle_up_controller.dart';
import '../pages/account_page.dart';
import '../pages/add_expense_page.dart';
import '../pages/auth_pages.dart';
import '../pages/bill_detail_page.dart';
import '../pages/bill_editor_page.dart';
import '../pages/expense_page.dart';
import '../pages/group_detail_page.dart';
import '../pages/home_page.dart';
import '../pages/settle_up_page.dart';

abstract final class Routes {
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const confirm = '/confirm';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';
  static const groups = '/groups';
  static const account = '/account';
  static const group = '/groups/:groupId';
  static const addExpense = '/groups/:groupId/add-expense';
  static const expense = '/groups/:groupId/expenses/:expenseId';
  static const editExpense = '/groups/:groupId/expenses/:expenseId/edit';
  static const settleUp = '/groups/:groupId/settle-up';
  static const newBill = '/new-bill';
  static const bill = '/bills/:billId';
  static const editBill = '/bills/:billId/edit';

  static String groupPath(String id) => '/groups/$id';
  static String addExpensePath(String id) => '/groups/$id/add-expense';
  static String expensePath(String groupId, String expenseId) => '/groups/$groupId/expenses/$expenseId';
  static String editExpensePath(String groupId, String expenseId) => '/groups/$groupId/expenses/$expenseId/edit';
  static String settleUpPath(String id) => '/groups/$id/settle-up';
  static String billPath(String id) => '/bills/$id';
  static String editBillPath(String id) => '/bills/$id/edit';
}

/// Tells pages when another page covers them (bill polling pauses, the groups list refreshes on return).
final routeObserver = RouteObserver<PageRoute<dynamic>>();

Bindings _auth() => BindingsBuilder<void>(() => Get.lazyPut(() => AuthController(Get.find())));

/// Bindings are the dependency injection: each page gets its controller when it opens,
/// and GetX disposes the controller when the page is popped.
final pages = <GetPage<dynamic>>[
  GetPage(name: Routes.signIn, page: () => const SignInPage(), binding: _auth()),
  GetPage(name: Routes.signUp, page: () => const SignUpPage(), binding: _auth()),
  GetPage(name: Routes.confirm, page: () => const ConfirmPage(), binding: _auth()),
  GetPage(name: Routes.forgotPassword, page: () => const ForgotPasswordPage(), binding: _auth()),
  GetPage(name: Routes.resetPassword, page: () => const ResetPasswordPage(), binding: _auth()),
  // Home: the groups tab and the bills tab.
  GetPage(
    name: Routes.groups,
    page: () => const HomePage(),
    binding: BindingsBuilder<void>(() {
      Get.lazyPut(() => GroupsController(Get.find(), Get.find()));
      Get.lazyPut(() => InvitesController(Get.find()));
      Get.lazyPut(() => BillsController(Get.find()));
    }),
  ),
  GetPage(
    name: Routes.account,
    page: () => const AccountPage(),
    binding: BindingsBuilder<void>(() => Get.lazyPut(() => AccountController(Get.find(), Get.find()))),
  ),
  GetPage(
    name: Routes.group,
    page: () => const GroupDetailPage(),
    binding: BindingsBuilder<void>(
      () => Get.lazyPut(() => GroupDetailController(Get.parameters['groupId']!, Get.find(), Get.find())),
    ),
  ),
  GetPage(
    name: Routes.addExpense,
    page: () => const AddExpensePage(),
    binding: BindingsBuilder<void>(
      () => Get.lazyPut(
        () => AddExpenseController(
          group: Get.find<GroupDetailController>().group.value!,
          myUserId: Get.find<GroupDetailController>().myUserId,
          expenses: Get.find(),
        ),
      ),
    ),
  ),
  GetPage(
    name: Routes.expense,
    page: () => const ExpensePage(),
    binding: BindingsBuilder<void>(
      () => Get.lazyPut(
        () =>
            ExpenseController(Get.find<GroupDetailController>(), Get.parameters['expenseId']!, Get.find(), Get.find()),
      ),
    ),
  ),
  GetPage(
    name: Routes.editExpense,
    page: () => const AddExpensePage(),
    binding: BindingsBuilder<void>(
      () => Get.lazyPut(
        () => AddExpenseController(
          group: Get.find<GroupDetailController>().group.value!,
          myUserId: Get.find<GroupDetailController>().myUserId,
          expenses: Get.find(),
          existing: Get.find<ExpenseController>().expense,
        ),
      ),
    ),
  ),
  GetPage(
    name: Routes.newBill,
    page: () => const BillEditorPage(),
    binding: BindingsBuilder<void>(() => Get.lazyPut(() => BillEditorController(bills: Get.find(), users: Get.find()))),
  ),
  GetPage(
    name: Routes.bill,
    page: () => const BillDetailPage(),
    binding: BindingsBuilder<void>(
      () => Get.lazyPut(() => BillDetailController(Get.parameters['billId']!, Get.find())),
    ),
  ),
  GetPage(
    name: Routes.editBill,
    page: () => const BillEditorPage(),
    binding: BindingsBuilder<void>(
      () => Get.lazyPut(
        () => BillEditorController(
          existing: Get.find<BillDetailController>().bill.value,
          bills: Get.find(),
          users: Get.find(),
        ),
      ),
    ),
  ),
  GetPage(
    name: Routes.settleUp,
    page: () => const SettleUpPage(),
    binding: BindingsBuilder<void>(
      () => Get.lazyPut(() => SettleUpController(Get.find<GroupDetailController>(), Get.find())),
    ),
  ),
];
