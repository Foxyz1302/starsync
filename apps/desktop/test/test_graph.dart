// Test support (not a test): the app's composition root for tests.
import 'package:flutter/widgets.dart';
import 'package:starsync/src/app/app_graph.dart';
import 'package:starsync/src/screens/home/health_probe.dart';
import 'package:starsync/src/session/identity.dart' show ClientIdentity;

/// One graph per test file, like the app's one per run: nothing starts
/// until a test calls `navigation.start()` (or `goHome`), so widget tests
/// see the app before your server is up.
AppGraph testGraph({HealthGetter healthGet = defaultHealthGet}) =>
    AppGraph.build(identity: ClientIdentity.ephemeral(), healthGet: healthGet);

/// [child] under [graph]'s [AppScope].
Widget scoped(AppGraph graph, Widget child) => AppScope(graph: graph, child: child);
