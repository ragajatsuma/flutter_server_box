import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/data/provider/server/single.dart';

/// Runs [script] on [serverId] through the server's own connection — SSH
/// when that is how it is reached, the monitor agent when that is — and
/// returns what it printed on stdout.
///
/// The script goes through `sh` rather than the account's login shell: fish
/// rejects POSIX syntax outright, and a syntax error there is a diagnostic on
/// stderr rather than an exception. An empty stdout with something on stderr
/// is the command failing, so that is the exception the page shows instead of
/// an empty screen.
Future<String> runCustomScript(
  WidgetRef ref,
  String serverId,
  String script,
) async {
  final exec = await ref.read(serverProvider(serverId).notifier).ensureExec();
  final result = await exec.run(script, entry: 'sh');
  final out = result.stdout.trim();
  if (out.isEmpty) {
    final err = result.stderr.trim();
    throw Exception(
      err.isEmpty
          ? 'Command exited with ${result.exitCode}'
          : err.split('\n').first,
    );
  }
  return out;
}

/// One section of a custom server page: a titled card holding rows or a log.
final class CustomSectionCard extends StatelessWidget {
  const CustomSectionCard({
    super.key,
    required this.title,
    this.icon,
    required this.children,
  });

  final String title;
  final IconData? icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return CardX(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 17),
                  const SizedBox(width: 7),
                ],
                Text(title, style: UIs.text13Bold),
              ],
            ),
            const SizedBox(height: 7),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// One status line: a label, a value, and a dot saying whether it is good.
///
/// [ok] null means the line is not a verdict — no dot, grey value.
final class CustomStatusRow extends StatelessWidget {
  const CustomStatusRow({
    super.key,
    required this.label,
    required this.value,
    this.ok,
  });

  final String label;
  final String value;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          if (ok != null) ...[
            Icon(
              Icons.circle,
              size: 9,
              color: ok! ? scheme.primary : scheme.error,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(label, style: UIs.text13)),
          const SizedBox(width: 11),
          Flexible(
            child: Text(
              value,
              style: ok == null ? UIs.text13Grey : UIs.text13,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// Raw command output or a log tail: monospace, selectable, kept whole.
///
/// The page scrolls; this does not scroll itself, so a long tail stays one
/// read rather than a box inside a scroll.
final class CustomLogBox extends StatelessWidget {
  const CustomLogBox({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text,
      style: UIs.text12Grey.copyWith(fontFamily: 'monospace'),
    );
  }
}
