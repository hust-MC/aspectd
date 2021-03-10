import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:vm/target/flutter.dart';

import 'track_visitor.dart';

class TrackTransformer extends FlutterProgramTransformer {

  @override
  void transform(Component component) {
    print('Start track transform');
    WidgetCreatorTracker().transform(component, component.libraries, null);
  }
}
