// ignore_for_file: invalid_use_of_protected_member

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/core/route.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/view/page/server/custom/shared.dart';

/// What one run of the page's script says about the Hermes agent on this server.
final class HermesInfo {
  const HermesInfo({
    required this.gatewayCount,
    required this.gatewayUptime,
    required this.agentCount,
    required this.sessionCount,
    required this.guiLog,
    required this.gatewayLog,
    required this.raw,
  });

  final int gatewayCount;
  final String gatewayUptime;
  final int agentCount;
  final int sessionCount;
  final String guiLog;
  final String gatewayLog;
  final String raw;

  static HermesInfo parse(String out) {
    final lines = out.split('\n');
    final countIdx = lines.indexWhere((l) => l.trim() == '__COUNT__');
    final logIdx = lines.indexWhere((l) => l.trim() == '__LOG__');
    final gwLogIdx = lines.indexWhere((l) => l.trim() == '__GWLOG__');
    final gwLines = (countIdx < 0 ? lines : lines.sublist(0, countIdx))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final counts =
        (countIdx < 0 || logIdx < 0
                ? const <String>[]
                : lines.sublist(countIdx + 1, logIdx))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
    final guiLog =
        (logIdx < 0
                ? ''
                : lines.sublist(logIdx + 1, gwLogIdx < 0 ? lines.length : gwLogIdx).join('\n'))
            .trim();
    final gwLog = (gwLogIdx < 0 ? '' : lines.sublist(gwLogIdx + 1).join('\n')).trim();
    return HermesInfo(
      gatewayCount: gwLines.length,
      // `ps -eo etime,args`: the elapsed time is the first field.
      gatewayUptime: gwLines.isEmpty
          ? '-'
          : gwLines.first.split(RegExp(r'\s+')).first,
      agentCount: counts.isEmpty ? 0 : int.tryParse(counts[0]) ?? 0,
      sessionCount: counts.length < 2 ? 0 : int.tryParse(counts[1]) ?? 0,
      guiLog: guiLog,
      gatewayLog: gwLog,
      raw: out,
    );
  }
}

/// The Hermes agent on this server: its gateways, its sessions, and the tail
/// of its logs.
///
/// The logs are read, never written to: this page watches the agent, it does
/// not steer it.
final class HermesPage extends ConsumerStatefulWidget {
  final SpiRequiredArgs args;

  const HermesPage({super.key, required this.args});

  static const route = AppRouteArg<void, SpiRequiredArgs>(
    page: HermesPage.new,
    path: '/server/hermes',
  );

  @override
  ConsumerState<HermesPage> createState() => _HermesPageState();
}

final class _HermesPageState extends ConsumerState<HermesPage> {
  /// Null until the server has answered.
  HermesInfo? _info;
  String? _err;
  bool _loading = false;

  Spi get _spi => widget.args.spi;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        title: TwoLineText(up: 'Hermes', down: _spi.name),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(13),
              child: SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Btn.icon(
              text: libL10n.refresh,
              icon: const Icon(Icons.refresh),
              onTap: _load,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }
}

// --- Widget build ---

extension on _HermesPageState {
  Widget _buildBody() {
    final err = _err;
    if (err != null) {
      return PageIssueView(title: libL10n.error, detail: err, onRetry: _load);
    }
    final info = _info;
    if (info == null) return UIs.centerLoading;
    return ListView(
      padding: const EdgeInsets.only(left: 7, right: 7, top: 7, bottom: 27),
      children: [
        CustomSectionCard(
          title: 'Gateway',
          icon: Icons.smart_toy_outlined,
          children: [
            CustomStatusRow(
              label: 'Gateways',
              value: info.gatewayCount > 0
                  ? '${info.gatewayCount} running'
                  : 'not running',
              ok: info.gatewayCount > 0,
            ),
            CustomStatusRow(label: 'Gateway uptime', value: info.gatewayUptime),
            CustomStatusRow(
              label: 'Agents',
              value: '${info.agentCount}',
            ),
            CustomStatusRow(
              label: 'Sessions in ~/.hermes/sessions',
              value: '${info.sessionCount}',
            ),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Log tail · ~/.hermes/logs/gui.log',
          icon: Icons.article_outlined,
          children: [
            CustomLogBox(
              text: info.guiLog.isEmpty
                  ? 'Log is empty or cannot be read.'
                  : info.guiLog,
            ),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Gateway starts · ~/.hermes/gateway-starts.log',
          icon: Icons.article_outlined,
          children: [
            CustomLogBox(
              text: info.gatewayLog.isEmpty
                  ? 'Log is empty or cannot be read.'
                  : info.gatewayLog,
            ),
          ],
        ),
      ],
    );
  }
}

// --- Actions ---

extension on _HermesPageState {
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final out = await runCustomScript(
        ref,
        _spi.id,
        "ps -eo etime,args | grep 'hermes_cli.main gateway run' | grep -v grep; echo __COUNT__; "
        "ps aux | grep -c '[h]ermes-agent/hermes'; ls ~/.hermes/sessions 2>/dev/null | wc -l; "
        "echo __LOG__; tail -n 60 ~/.hermes/logs/gui.log 2>/dev/null; echo __GWLOG__; tail -n 20 ~/.hermes/gateway-starts.log 2>/dev/null",
      );
      if (!mounted) return;
      setState(() => _info = HermesInfo.parse(out));
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
