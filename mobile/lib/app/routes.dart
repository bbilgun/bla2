// Route names and the page table. Each route's binding creates the controller its page needs.
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

/// Route names, and helpers that fill in their path parameters.
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

  /// The group page.
  static String groupPath(String id) => '/groups/$id';

  /// The add expense form for a group.
  static String addExpensePath(String id) => '/groups/$id/add-expense';

  /// One expense in a group.
  static String expensePath(String groupId, String expenseId) => '/groups/$groupId/expenses/$expenseId';

  /// The edit form for one expense.
  static String editExpensePath(String groupId, String expenseId) => '/groups/$groupId/expenses/$expenseId/edit';

  /// The settle up page for a group.
  static String settleUpPath(String id) => '/groups/$id/settle-up';

  /// The bill page.
  static String billPath(String id) => '/bills/$id';

  /// The bill editor for an existing bill.
  static String editBillPath(String id) => '/bills/$id/edit';
}

/// Tells pages when another page covers them or is popped off them. The groups list uses it to
/// refresh on return, and the bill page to pause polling while it is hidden.
final routeObserver = RouteObserver<PageRoute<dynamic>>();

Bindings _authBinding() => BindingsBuilder<void>(() => Get.lazyPut(() => AuthController(Get.find())));

/// Every page in the app. A binding creates the page's controller when the route opens, and GetX
/// disposes it when the route is popped. Pages nested under a group or bill reuse that screen's
/// controller, which is still alive underneath them.
final pages = <GetPage<dynamic>>[
  GetPage(name: Routes.signIn, page: () => const SignInPage(), binding: _authBinding()),
  GetPage(name: Routes.signUp, page: () => const SignUpPage(), binding: _authBinding()),
  GetPage(name: Routes.confirm, page: () => const ConfirmPage(), binding: _authBinding()),
  GetPage(name: Routes.forgotPassword, page: () => const ForgotPasswordPage(), binding: _authBinding()),
  GetPage(name: Routes.resetPassword, page: () => const ResetPasswordPage(), binding: _authBinding()),
  // Home has two tabs, so it binds the groups and bills controllers, plus the invites shown on the groups tab.
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
