import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/groups_controller.dart';
import '../controllers/invites_controller.dart';
import 'bills_page.dart';
import 'groups_page.dart';
import 'widgets.dart';

/// Two ways to split: ongoing groups (flat, trip) and one-off bills shared by QR (restaurant, party).
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  var _tab = 0;

  /// Back from a group (or anywhere): the list may have changed there (left, renamed, deleted).
  void _refresh() {
    if (Get.isRegistered<GroupsController>()) unawaited(Get.find<GroupsController>().refreshQuietly());
    if (Get.isRegistered<InvitesController>()) unawaited(Get.find<InvitesController>().load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RouteVisibility(
        onUncovered: _refresh,
        child: IndexedStack(index: _tab, children: const [GroupsPage(), BillsPage()]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups),
            label: S.tabGroups,
          ),
          NavigationDestination(
            icon: Icon(Icons.qr_code_2_outlined),
            selectedIcon: Icon(Icons.qr_code_2),
            label: S.tabBills,
          ),
        ],
      ),
    );
  }
}
