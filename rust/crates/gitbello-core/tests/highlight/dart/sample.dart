/// A counter widget.
library counter;

import 'package:flutter/material.dart';

/* Block comment. */
/** Doc block. */
const int maxCount = 0x10;

enum Mode { light, dark }

@immutable
class Counter extends StatelessWidget with Diagnosticable {
  final String label;
  final int count;
  late final double ratio = count / 1.5e2;

  const Counter({super.key, required this.label, this.count = 0});

  @override
  Widget build(BuildContext context) {
    final text = 'Count: $count of ${count * 2}\n';
    final raw = r'no $interp \n';
    final multi = """three "quotes" $label""";
    if (count > maxCount) {
      return Text(text, style: TextStyle(fontSize: 12));
    } else if (count == 0) {
      throw ArgumentError.value(count);
    }
    for (var i = 0; i < count; i++) {
      continue;
    }
    switch (Mode.light) {
      case Mode.light:
        break;
      default:
        assert(false, raw);
    }
    return Column(children: [Text(multi), const SizedBox(height: 8)]);
  }

  Future<void> load() async {
    final dynamic data = await fetch(null);
    print(data is bool ? true : data);
  }
}

typedef Callback = void Function(num value);
mixin Logger on Object {}
extension Twice on int {
  int get twice => this * 2;
}
