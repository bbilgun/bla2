import 'package:get/get.dart';

import '../controllers/add_expense_controller.dart';
import '../controllers/auth_controller.dart';
import '../controllers/bill_detail_controller.dart';
import '../controllers/bill_editor_controller.dart';
import '../controllers/bills_controller.dart';
import '../controllers/expense_controller.dart';
import '../controllers/group_detail_controller.dart';
import '../controllers/groups_controller.dart';
import '../controllers/settle_up_controller.dart';
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
  static const groups = '/groups';
  static const group = '/groups/:groupId';
  static const addExpense = '/groups/:groupId/add-expense';
  static const expense = '/groups/:groupId/expenses/:expenseId';
  static const settleUp = '/groups/:groupId/settle-up';
  static const newBill = '/new-bill';
  static const bill = '/bills/:billId';
  static const editBill = '/bills/:billId/edit';

  static String groupPath(String id) => '/groups/$id';
  static String addExpensePath(String id) => '/groups/$id/add-expense';
  static String expensePath(String groupId, String expenseId) => '/groups/$groupId/expenses/$expenseId';
  static String settleUpPath(String id) => '/groups/$id/settle-up';
  static String billPath(String id) => '/bills/$id';
  static String editBillPath(String id) => '/bills/$id/edit';
}

/// Bindings are the dependency injection: each page gets its controller when it opens,
/// and GetX disposes the controller when the page is popped.
final pages = <GetPage<dynamic>>[
  GetPage(
    name: Routes.signIn,
    page: () => const SignInPage(),
    binding: BindingsBuilder(() => Get.lazyPut(() => AuthController(Get.find()))),
  ),
  GetPage(
    name: Routes.signUp,
    page: () => const SignUpPage(),
    binding: BindingsBuilder(() => Get.lazyPut(() => AuthController(Get.find()))),
  ),
  GetPage(
    name: Routes.confirm,
    page: () => const ConfirmPage(),
    binding: BindingsBuilder(() => Get.lazyPut(() => AuthController(Get.find()))),
  ),
  // Home: the groups tab and the bills tab.
  GetPage(
    name: Routes.groups,
    page: () => const HomePage(),
    binding: BindingsBuilder(() {
      Get.lazyPut(() => GroupsController(Get.find(), Get.find(), Get.find()));
      Get.lazyPut(() => BillsController(Get.find()));
    }),
  ),
  GetPage(
    name: Routes.group,
    page: () => const GroupDetailPage(),
    binding: BindingsBuilder(
      () => Get.lazyPut(() => GroupDetailController(Get.parameters['groupId']!, Get.find(), Get.find())),
    ),
  ),
  GetPage(
    name: Routes.addExpense,
    page: () => const AddExpensePage(),
    binding: BindingsBuilder(
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
    binding: BindingsBuilder(
      () => Get.lazyPut(
        () => ExpenseController(Get.find<GroupDetailController>(), Get.parameters['expenseId']!, Get.find()),
      ),
    ),
  ),
  GetPage(
    name: Routes.newBill,
    page: () => const BillEditorPage(),
    binding: BindingsBuilder(() => Get.lazyPut(() => BillEditorController(bills: Get.find(), users: Get.find()))),
  ),
  GetPage(
    name: Routes.bill,
    page: () => const BillDetailPage(),
    binding: BindingsBuilder(() => Get.lazyPut(() => BillDetailController(Get.parameters['billId']!, Get.find()))),
  ),
  GetPage(
    name: Routes.editBill,
    page: () => const BillEditorPage(),
    binding: BindingsBuilder(
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
    binding: BindingsBuilder(
      () => Get.lazyPut(() => SettleUpController(Get.find<GroupDetailController>(), Get.find())),
    ),
  ),
];
