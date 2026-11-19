// ignore_for_file: invalid_use_of_protected_member

import 'dart:convert';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/core/route.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/view/page/server/custom/shared.dart';

/// One Konoha profile: its label and what it is doing.
typedef KonohaProfile = ({String label, String mode});

/// What one run of the page's script says about the Konoha bots on this server.
final class KonohaInfo {
  const KonohaInfo({
    required this.healthOk,
    required this.healthProfiles,
    required this.profiles,
    required this.vpsService,
    required this.collectorService,
    required this.farmWatchCron,
    required this.petSurvivorCron,
    required this.playRunning,
    required this.playTelegramRunning,
    required this.playLevel,
    required this.playMoney,
    required this.playEnergy,
    required this.playLastLine,
    required this.raw,
  });

  final bool healthOk;
  final int healthProfiles;
  final List<KonohaProfile> profiles;
  final String vpsService;
  final String collectorService;
  final String farmWatchCron;
  final String petSurvivorCron;
  final bool playRunning;
  final bool playTelegramRunning;
  final String playLevel;
  final String playMoney;
  final String playEnergy;
  final String playLastLine;
  final String raw;

  static String _section(String out, String from, [String? to]) {
    final start = out.indexOf(from);
    if (start < 0) return '';
    final body = out.substring(start + from.length);
    if (to == null) return body;
    final end = body.indexOf(to);
    return end < 0 ? body : body.substring(0, end);
  }

  static KonohaInfo parse(String out) {
    final healthRaw = _section(out, '', '__SYS__').trim();
    var healthOk = false;
    var healthProfiles = 0;
    try {
      final health = jsonDecode(healthRaw) as Map<String, dynamic>;
      healthOk = health['ok'] == true;
      healthProfiles = (health['profiles'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // The health endpoint did not answer JSON: HEALTH_FAIL, or curl found
      // nothing listening. The sections below still say what is running.
    }
    final sysLines = _section(out, '__SYS__', '__CRON__')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final cronLines = _section(out, '__CRON__', '__PROFILES__')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final profilesJson = _section(out, '__PROFILES__', '__PLAY__').trim();
    final playSection = _section(out, '__PLAY__');
    final lastLv = playSection
        .split('\n')
        .lastWhere((l) => l.contains('lv='), orElse: () => '');
    return KonohaInfo(
      healthOk: healthOk,
      healthProfiles: healthProfiles,
      profiles: _parseProfiles(profilesJson),
      vpsService: sysLines.isEmpty ? 'unknown' : sysLines[0],
      collectorService: sysLines.length < 2 ? 'unknown' : sysLines[1],
      farmWatchCron: cronLines.firstWhere(
        (l) => l.contains('farm_watch'),
        orElse: () => '-',
      ),
      petSurvivorCron: cronLines.firstWhere(
        (l) => l.contains('pet_survivor'),
        orElse: () => '-',
      ),
      playRunning: playSection.contains('PLAY_OK'),
      playTelegramRunning: playSection.contains('TG_OK'),
      playLevel:
          RegExp(r'lv=(\d+)').firstMatch(lastLv)?.group(1) ?? '-',
      playMoney:
          RegExp(r'money=(\d+)').firstMatch(lastLv)?.group(1) ?? '-',
      playEnergy:
          RegExp(r'energy=([0-9/]+)').firstMatch(lastLv)?.group(1) ?? '-',
      playLastLine: lastLv.trim(),
      raw: out,
    );
  }

  /// The profiles file is a JSON array of objects carrying `label` and
  /// `mode` — an older shape keyed by label is read the same way. When the
  /// file cannot be read or parsed, the farm state file names say which
  /// profiles exist, without saying what they are doing.
  static List<KonohaProfile> _parseProfiles(String jsonText) {
    if (jsonText.isEmpty || jsonText == 'UNAVAILABLE') return const [];
    try {
      final decoded = jsonDecode(jsonText);
      final List<Map<String, dynamic>> entries;
      if (decoded is List) {
        entries = [
          for (final e in decoded)
            if (e is Map<String, dynamic>) e,
        ];
      } else if (decoded is Map<String, dynamic>) {
        entries = [
          for (final e in decoded.entries)
            if (e.value is Map<String, dynamic>)
              {'label': e.key, ...e.value}
            else
              {'label': e.key, 'mode': e.value.toString()},
        ];
      } else {
        entries = const [];
      }
      final profiles = <KonohaProfile>[
        for (final e in entries)
          (
            label: (e['label'] ?? '?').toString(),
            mode: (e['mode'] ?? e['memori'] ?? '?').toString(),
          ),
      ];
      profiles.sort((a, b) => a.label.compareTo(b.label));
      return profiles;
    } catch (_) {
      return [
        for (final m in RegExp(
          r'farm_state_([A-Z0-9]+)\.json',
        ).allMatches(jsonText).map((m) => m.group(1)).toSet())
          (label: m ?? '?', mode: '?'),
      ];
    }
  }
}

/// The Konoha game bots on this server: the konohagame.com stack — its
/// health endpoint, its profiles, its systemd units and their crons — and the
/// play.konohagame.com stack, whose processes are reported as they actually
/// are rather than assumed running.
///
/// Restart runs `sudo -n systemctl restart <unit>`: no password is ever typed
/// into this page, and a server whose sudo needs one says so in the result.
final class KonohaPage extends ConsumerStatefulWidget {
  final SpiRequiredArgs args;

  const KonohaPage({super.key, required this.args});

  static const route = AppRouteArg<void, SpiRequiredArgs>(
    page: KonohaPage.new,
    path: '/server/konoha',
  );

  @override
  ConsumerState<KonohaPage> createState() => _KonohaPageState();
}

final class _KonohaPageState extends ConsumerState<KonohaPage> {
  /// Null until the server has answered.
  KonohaInfo? _info;
  String? _err;
  bool _loading = false;
  bool _restarting = false;

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
        title: TwoLineText(up: 'Konoha', down: _spi.name),
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

extension on _KonohaPageState {
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
          title: 'Health · :8181/health',
          icon: Icons.favorite_outlined,
          children: [
            CustomStatusRow(
              label: 'Health endpoint',
              value: info.healthOk
                  ? 'ok · ${info.healthProfiles} profiles'
                  : 'unreachable',
              ok: info.healthOk,
            ),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Profiles',
          icon: Icons.group_outlined,
          children: [
            if (info.profiles.isEmpty)
              const CustomStatusRow(label: 'Profiles', value: 'none found')
            else
              for (final p in info.profiles)
                CustomStatusRow(label: p.label, value: p.mode),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Services',
          icon: Icons.settings_outlined,
          children: [
            CustomStatusRow(
              label: 'konoha-vps.service',
              value: info.vpsService,
              ok: info.vpsService == 'active',
            ),
            CustomStatusRow(
              label: 'konoha-collector.service',
              value: info.collectorService,
              ok: info.collectorService == 'active',
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Btn.text(
                  text: 'Restart VPS',
                  onTap: _restarting
                      ? null
                      : () => _restart(
                          'konoha-vps.service',
                        ),
                ),
                const SizedBox(width: 7),
                Btn.text(
                  text: 'Restart collector',
                  onTap: _restarting
                      ? null
                      : () => _restart(
                          'konoha-collector.service',
                        ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Cron',
          icon: Icons.schedule,
          children: [
            CustomStatusRow(label: 'farm_watch', value: info.farmWatchCron),
            CustomStatusRow(label: 'pet_survivor', value: info.petSurvivorCron),
          ],
        ),
        const SizedBox(height: 7),
        CustomSectionCard(
          title: 'Play · play.konohagame.com (rgj)',
          icon: Icons.sports_esports_outlined,
          children: [
            CustomStatusRow(
              label: 'play_cycle.py',
              value: info.playRunning ? 'running' : 'not running',
              ok: info.playRunning,
            ),
            CustomStatusRow(
              label: 'telegram_control.py',
              value: info.playTelegramRunning ? 'running' : 'not running',
              ok: info.playTelegramRunning,
            ),
            CustomStatusRow(label: 'Level', value: info.playLevel),
            CustomStatusRow(label: 'Money', value: info.playMoney),
            CustomStatusRow(label: 'Energy', value: info.playEnergy),
            if (info.playLastLine.isNotEmpty) ...[
              const SizedBox(height: 7),
              CustomLogBox(text: info.playLastLine),
            ],
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

extension on _KonohaPageState {
  static const _script =
      "curl -s -m 5 http://127.0.0.1:8181/health 2>/dev/null || echo HEALTH_FAIL; echo __SYS__; "
      "systemctl is-active konoha-vps.service konoha-collector.service 2>/dev/null; echo __CRON__; "
      "crontab -l 2>/dev/null | grep -E 'farm_watch|pet_survivor'; echo __PROFILES__; "
      "sudo -n cat /opt/konoha-chatv1/tools/profiles_state.json 2>/dev/null || cat /opt/konoha-chatv1/tools/profiles_state.json 2>/dev/null || echo UNAVAILABLE; "
      "echo __PLAY__; "
      "pgrep -f 'play_cycle.py' >/dev/null && echo PLAY_OK || echo PLAY_NO; "
      "pgrep -f 'telegram_control.py' >/dev/null && echo TG_OK || echo TG_NO; "
      "grep -E 'lv=[0-9]+' ~/cycle.log 2>/dev/null | tail -n 1";

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final out = await runCustomScript(ref, _spi.id, _script);
      if (!mounted) return;
      setState(() => _info = KonohaInfo.parse(out));
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restart(String unit) async {
    setState(() => _restarting = true);
    try {
      final out = await runCustomScript(
        ref,
        _spi.id,
        'sudo -n systemctl restart $unit 2>&1; echo EXIT=\$?',
      );
      if (!mounted) return;
      if (out.contains('EXIT=0')) {
        Toast.show('Restarted $unit');
      } else {
        Toast.error('Restart failed', body: out);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      Toast.error('Restart failed', body: '$e');
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }
}
