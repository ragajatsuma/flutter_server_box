// ignore_for_file: invalid_use_of_protected_member

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/core/route.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/store/stores.dart';
import 'package:server_box/view/page/server/custom/shared.dart';

/// What one run of the page's script says about the 9router on this server.
final class NineRouterInfo {
  const NineRouterInfo({
    required this.processRunning,
    required this.portListening,
    required this.uptime,
    required this.health,
    required this.raw,
  });

  final bool processRunning;
  final bool portListening;
  final String uptime;
  final String health;
  final String raw;

  static NineRouterInfo parse(String out) {
    final lines = out.split('\n');
    final healthIdx = lines.indexWhere((l) => l.trim() == '__HEALTH__');
    final before = healthIdx < 0 ? lines : lines.sublist(0, healthIdx);
    final after = healthIdx < 0 ? const <String>[] : lines.sublist(healthIdx + 1);
    // The uptime is whatever `ps` printed: the one line that is neither a
    // marker nor a flag.
    final uptime = before
        .map((l) => l.trim())
        .firstWhere(
          (l) => l.isNotEmpty && !l.contains('PROC_') && !l.contains('PORT_'),
          orElse: () => '-',
        );
    final healthLine = after.map((l) => l.trim()).firstWhere(
      (l) => l.isNotEmpty,
      orElse: () => '-',
    );
    return NineRouterInfo(
      processRunning: before.any((l) => l.contains('PROC_OK')),
      portListening: before.any((l) => l.contains('PORT_OK')),
      uptime: uptime,
      // HEALTH_HTTP=200 reads as HTTP 200; anything else is the code as the
      // probe reported it.
      health: healthLine.startsWith('HEALTH_HTTP=')
          ? 'HTTP ${healthLine.substring('HEALTH_HTTP='.length)}'
          : healthLine,
      raw: out,
    );
  }
}

/// The 9router LLM router on this server: whether its process runs, whether
/// its port listens, what its health endpoint answers, and the dashboard.
///
/// The :20128 listener is plain HTTP — an HTTPS probe against it fails the
/// handshake, which is what an earlier check misread as the router being
/// down. The dashboard address is the user's own setting, empty until set:
/// the address differs per server and this app never assumes one.
final class NineRouterPage extends ConsumerStatefulWidget {
  final SpiRequiredArgs args;

  const NineRouterPage({super.key, required this.args});

  static const route = AppRouteArg<void, SpiRequiredArgs>(
    page: NineRouterPage.new,
    path: '/server/nine_router',
  );

  @override
  ConsumerState<NineRouterPage> createState() => _NineRouterPageState();
}

final class _NineRouterPageState extends ConsumerState<NineRouterPage> {
  /// Null until the server has answered.
  NineRouterInfo? _info;
  String? _err;
  bool _loading = false;

  Spi get _spi => widget.args.spi;

  /// The dashboard address as saved, empty when the user has not set one.
  String get _dashboardUrl => Stores.setting.nineRouterDashboardUrl.fetch();

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        title: TwoLineText(up: '9router', down: _spi.name),
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

extension on _NineRouterPageState {
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
          title: 'Status',
          icon: Icons.router_outlined,
          children: [
            CustomStatusRow(
              label: 'Process 9router-go',
              value: info.processRunning ? 'running' : 'not running',
              ok: info.processRunning,
            ),
            CustomStatusRow(
              label: 'Port 20128',
              value: info.portListening ? 'listening' : 'not listening',
              ok: info.portListening,
            ),
            CustomStatusRow(label: 'Uptime', value: info.uptime),
            CustomStatusRow(label: 'Health /api/health', value: info.health),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Dashboard',
          icon: Icons.dashboard_outlined,
          children: [
            CustomStatusRow(
              label: 'URL',
              value: _dashboardUrl.isEmpty ? 'not set' : _dashboardUrl,
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Btn.text(
                  text: libL10n.open,
                  onTap: _dashboardUrl.isEmpty ? null : _openDashboard,
                ),
                const SizedBox(width: 7),
                Btn.text(
                  text: libL10n.edit,
                  onTap: _editDashboardUrl,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Raw output',
          icon: Icons.terminal,
          children: [CustomLogBox(text: info.raw)],
        ),
      ],
    );
  }
}

// --- Actions ---

extension on _NineRouterPageState {
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
        // The health probe curls whatever address the port is actually
        // listening on, read off `ss` — the bind address differs per server
        // and is not this app's to assume. A wildcard bind is probed on
        // loopback. The listener is plain HTTP: an HTTPS probe fails the
        // handshake and reports the router down when it is up.
        "pgrep -f '9router-go' >/dev/null && echo PROC_OK || echo PROC_NO; "
        "ss -tln 2>/dev/null | grep -q ':20128' && echo PORT_OK || echo PORT_NO; "
        "netstat -tln 2>/dev/null | grep -q ':20128' && echo PORT_OK; "
        "ps -o etime= -C 9router-go 2>/dev/null | head -1; "
        "echo __HEALTH__; "
        "ADDR=\$(ss -tln 2>/dev/null | grep ':20128' | head -1 | awk '{print \$4}'); "
        "PORT=\${ADDR##*:}; "
        "case \"\$ADDR\" in '*:'*) ADDR=\"127.0.0.1:\$PORT\";; '[::]:'*) ADDR=\"[::1]:\$PORT\";; esac; "
        "if [ -n \"\$ADDR\" ]; then CODE=\$(curl -s -m 5 -o /dev/null -w '%{http_code}' \"http://\$ADDR/api/health\" 2>/dev/null); [ -n \"\$CODE\" ] || CODE=000; echo \"HEALTH_HTTP=\$CODE\"; else echo HEALTH_SKIP; fi",
      );
      if (!mounted) return;
      setState(() => _info = NineRouterInfo.parse(out));
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDashboard() async {
    final url = _dashboardUrl;
    if (url.isEmpty) return;
    final ok = await url.launchUrl();
    if (!ok && mounted) Toast.error('Could not open $url');
  }

  Future<void> _editDashboardUrl() async {
    final url = (await context.showInputSheet(
      title: '9router dashboard URL',
      initial: _dashboardUrl,
      label: 'URL',
      hint: 'http://<server-address>:20128/dashboard',
      icon: Icons.link,
      type: TextInputType.url,
    ))?.trim();
    if (url == null || !mounted) return;
    if (url.isNotEmpty &&
        !url.startsWith('http://') &&
        !url.startsWith('https://')) {
      Toast.error('URL must start with http:// or https://');
      return;
    }
    Stores.setting.nineRouterDashboardUrl.put(url);
    setState(() {});
  }
}
