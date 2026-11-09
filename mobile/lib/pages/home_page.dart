// The home page: a bottom bar switching between the groups tab and the bills tab.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/groups_controller.dart';
import '../controllers/invites_controller.dart';
import 'bills_page.dart';
import 'groups_page.dart';
import 'widgets.dart';

/// The two ways to split: ongoing groups for a flat or a trip, and one-off bills shared by QR for a
/// restaurant or a party.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  var _tab = 0;

  // Coming back from a group, the list may have changed: the user may have left, renamed or deleted it.
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
        onDestinationSelected: (index) => setState(() => _tab = index),
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
