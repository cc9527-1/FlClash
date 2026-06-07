import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/proxies/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

/// Test file size for download speed measurement (5MB by default).
const _defaultTestFileSize = 5 * 1024 * 1024;

/// Default download test URL template.
const _defaultSpeedTestUrl =
    'https://speed.cloudflare.com/__down?bytes={size}';

class SpeedRankView extends ConsumerStatefulWidget {
  const SpeedRankView({super.key});

  @override
  ConsumerState<SpeedRankView> createState() => _SpeedRankViewState();
}

class _SpeedRankViewState extends ConsumerState<SpeedRankView> {
  bool _isTesting = false;
  int _testedCount = 0;
  int _totalCount = 0;

  /// Maps proxy name -> speed in MB/s (negative = timeout/error, 0 = pending)
  Map<String, double> _results = {};

  /// Maps proxy name -> set of group names containing this proxy
  Map<String, Set<String>> _proxyGroups = {};

  /// Sort mode: true = by speed, false = by name
  bool _sortBySpeed = true;

  List<Proxy>? _allProxies;

  /// System/internal proxy names excluded from speed tests.
  static const _systemProxies = <String>{
    'DIRECT', 'REJECT', 'GLOBAL', 'COMPATIBLE', 'PASS', 'REJECT-DROP',
  };

  List<MapEntry<String, double>> get _sortedResults {
    final entries = _results.entries.toList();
    if (_sortBySpeed) {
      entries.sort((a, b) {
        final aIsOk = a.value > 0;
        final bIsOk = b.value > 0;
        if (aIsOk && bIsOk) return b.value.compareTo(a.value);
        if (aIsOk && !bIsOk) return -1;
        if (!aIsOk && bIsOk) return 1;
        return 0;
      });
    } else {
      entries.sort((a, b) => a.key.compareTo(b.key));
    }
    return entries;
  }

  void _collectAllProxiesAndGroups() {
    final groups = getGroups();
    final proxyNameSet = <String>{};
    final result = <Proxy>[];
    final proxyGroups = <String, Set<String>>{};

    for (final group in groups) {
      for (final proxy in group.all) {
        if (_systemProxies.contains(proxy.name)) continue;
        proxyGroups.putIfAbsent(proxy.name, () => {}).add(group.name);
        if (proxyNameSet.add(proxy.name)) {
          result.add(proxy);
        }
      }
    }

    _proxyGroups = proxyGroups;
    _allProxies = result;
  }

  /// Find a Selector group containing [proxyName].
  /// Only Selector groups support manual proxy switching via changeProxy.
  /// Returns null if no Selector group contains this proxy (e.g. URL-test group).
  String? _findGroupForProxy(String proxyName) {
    final groups = getGroups();
    for (final group in groups) {
      if (group.type == GroupType.Selector &&
          group.all.any((p) => p.name == proxyName)) {
        return group.name;
      }
    }
    return null;
  }

  /// Get existing delay data for [proxyName] as a fallback indicator.
  int? _getExistingDelay(String proxyName) {
    final ref = globalState.container;
    final delayMap = ref.read(delayDataSourceProvider);
    final defaultTestUrl = ref.read(realTestUrlProvider(null));
    final groups = getGroups();
    final selectedMap = ref.read(
      currentProfileProvider.select((state) => state?.selectedMap ?? {}),
    );
    final state = computeRealSelectedProxyState(
      proxyName,
      groups: groups,
      selectedMap: selectedMap,
    );
    if (state.proxyName.isEmpty) return null;
    final testUrl = state.testUrl.takeFirstValid([defaultTestUrl]);
    return delayMap[testUrl]?[state.proxyName];
  }

  /// Download speed test for a single proxy via the Clash HTTP proxy.
  Future<double> _testProxyDownloadSpeed(
    String proxyName,
    String groupName,
    int proxyPort,
    String speedTestUrl,
  ) async {
    final ref = globalState.container;
    final originalProxyName = ref.read(
      selectedMapProvider.select((state) => state[groupName]),
    );

    await coreController.changeProxy(
      ChangeProxyParams(groupName: groupName, proxyName: proxyName),
    );
    await Future.delayed(const Duration(milliseconds: 300));

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.findProxy = (uri) => 'PROXY 127.0.0.1:$proxyPort';

    try {
      final stopwatch = Stopwatch()..start();
      final request = await client.getUrl(Uri.parse(speedTestUrl));
      final response = await request.close();

      int totalBytes = 0;
      await for (final chunk in response) {
        totalBytes += chunk.length;
      }
      stopwatch.stop();

      final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
      if (elapsedSec <= 0 || totalBytes <= 0) return -1;
      return (totalBytes / (1024 * 1024)) / elapsedSec;
    } catch (e) {
      return -1;
    } finally {
      client.close();
      if (originalProxyName != null && originalProxyName != proxyName) {
        await coreController.changeProxy(
          ChangeProxyParams(groupName: groupName, proxyName: originalProxyName),
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> _startDownloadSpeedTest() async {
    _collectAllProxiesAndGroups();
    final proxies = _allProxies;
    if (proxies == null || proxies.isEmpty) return;

    final ref = globalState.container;
    final mixedPort = ref.read(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    if (mixedPort <= 0) {
      if (mounted) {
        globalState.showMessage(
          title: 'Error',
          message: const TextSpan(
            text: 'Proxy port not available. Please start the service first.',
          ),
        );
      }
      return;
    }

    final speedTestUrl =
        _defaultSpeedTestUrl.replaceAll('{size}', '$_defaultTestFileSize');

    setState(() {
      _isTesting = true;
      _testedCount = 0;
      _totalCount = proxies.length;
      _results = {};
    });

    for (final proxy in proxies) {
      // Check if proxy is in a Selector group (download-testable)
      final groupName = _findGroupForProxy(proxy.name);
      if (groupName == null) {
        // Not testable via download — use existing delay data as fallback
        if (mounted) {
          final delay = _getExistingDelay(proxy.name);
          setState(() {
            _results[proxy.name] = delay != null && delay > 0
                ? -(delay.toDouble()) // negative = delay fallback
                : -1;
            _testedCount++;
          });
        }
        continue;
      }

      // Show "testing" state
      if (mounted) {
        setState(() {
          _results[proxy.name] = 0;
        });
      }

      final speed = await _testProxyDownloadSpeed(
        proxy.name, groupName, mixedPort, speedTestUrl,
      );

      if (mounted) {
        setState(() {
          _results[proxy.name] = speed;
          _testedCount++;
        });
      }
    }

    if (mounted) {
      setState(() {
        _isTesting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_allProxies == null) _collectAllProxiesAndGroups();
    final proxies = _allProxies ?? <Proxy>[];
    final sortedResults = _sortedResults;
    final measure = globalState.measure;

    final okCount = sortedResults.where((e) => e.value > 0).length;
    final timeoutCount = sortedResults.where((e) => e.value < 0).length;
    final testingCount = sortedResults.where((e) => e.value == 0).length;

    return CommonScaffold(
      title: Intl.message('speedRank'),
      floatingActionButton: _isTesting
          ? null
          : FloatingActionButton.extended(
              onPressed: _startDownloadSpeedTest,
              icon: const Icon(Icons.speed),
              label: Text(Intl.message('startSpeedTest')),
            ),
      body: Column(
        children: [
          // Progress section
          if (_isTesting) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LinearProgressIndicator(
                value: _totalCount > 0 ? _testedCount / _totalCount : 0,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${Intl.message('testing')}: $_testedCount / $_totalCount',
                style: context.textTheme.bodySmall,
              ),
            ),
          ],
          // Sort toggles
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                _buildSortChip(context, Intl.message('sortBySpeed'),
                    _sortBySpeed, () => setState(() => _sortBySpeed = true)),
                const SizedBox(width: 8),
                _buildSortChip(context, Intl.message('sortByName'),
                    !_sortBySpeed, () => setState(() => _sortBySpeed = false)),
              ],
            ),
          ),
          // Stats
          if (sortedResults.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SizedBox(
                height: measure.bodySmallHeight,
                child: Row(
                  children: [
                    _buildStatChip(context, '${proxies.length}',
                        Intl.message('total'), null),
                    const SizedBox(width: 8),
                    _buildStatChip(
                        context, '$okCount', 'OK', Colors.green),
                    const SizedBox(width: 8),
                    _buildStatChip(
                        context, '$timeoutCount', Intl.message('timeout'),
                        Colors.red.shade300),
                    if (testingCount > 0) ...[
                      const SizedBox(width: 8),
                      _buildStatChip(context, '$testingCount',
                          Intl.message('testing'), Colors.orange),
                    ],
                  ],
                ),
              ),
            ),
          // Ranking list
          Expanded(
            child: sortedResults.isEmpty
                ? Center(
                    child: Text(
                      Intl.message('noSpeedTestResults'),
                      style: context.textTheme.bodyLarge,
                    ),
                  )
                : ListView.separated(
                    itemCount: sortedResults.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 0, indent: 72),
                    itemBuilder: (_, index) {
                      final entry = sortedResults[index];
                      final speed = entry.value;
                      final groups = _proxyGroups[entry.key] ?? {};
                      return ListTile(
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        leading: SizedBox(
                          width: 40,
                          child: Center(child: _buildRankBadge(index)),
                        ),
                        title: Text(entry.key,
                            overflow: TextOverflow.ellipsis, maxLines: 1,
                            style: context.textTheme.bodyMedium),
                        subtitle: Text(groups.join(', '),
                            overflow: TextOverflow.ellipsis, maxLines: 1,
                            style: context.textTheme.bodySmall?.copyWith(
                                color: context.textTheme.bodySmall?.color
                                    ?.withValues(alpha: 0.7))),
                        trailing: _buildSpeedWidget(speed),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRankBadge(int index) {
    final isTop3 = index < 3;
    Color bgColor, fgColor;
    if (isTop3) {
      const topColors = [
        Color(0xFFFFD700), Color(0xFFC0C0C0), Color(0xFFCD7F32),
      ];
      bgColor = topColors[index];
      fgColor = Colors.black87;
    } else {
      bgColor = Colors.transparent;
      fgColor = Colors.grey;
    }
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(isTop3 ? 14 : 4),
      ),
      alignment: Alignment.center,
      child: Text(
        '${index + 1}',
        style: TextStyle(
          fontSize: isTop3 ? 13 : 12, fontWeight: FontWeight.bold,
          color: fgColor, fontFamily: FontFamily.jetBrainsMono.value,
        ),
      ),
    );
  }

  Widget _buildSortChip(
    BuildContext context, String label, bool selected, VoidCallback onSelected,
  ) {
    return FilterChip(
      label: Text(label, style: context.textTheme.labelMedium),
      selected: selected,
      onSelected: (_) => onSelected(),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildStatChip(
    BuildContext context, String value, String label, Color? color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color?.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (color ?? Colors.grey).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
              color: color, fontFamily: FontFamily.jetBrainsMono.value)),
          const SizedBox(width: 4),
          Text(label,
            style: TextStyle(fontSize: 11,
              color: color?.withValues(alpha: 0.8))),
        ],
      ),
    );
  }

  Widget _buildSpeedWidget(double speed) {
    if (speed > 0) {
      String displayText;
      Color displayColor;
      if (speed >= 1.0) {
        displayText = '${speed.toStringAsFixed(2)} MB/s';
        displayColor = speed >= 5.0 ? Colors.green
            : speed >= 1.0 ? Colors.orange : Colors.red;
      } else {
        displayText = '${(speed * 1024).toStringAsFixed(0)} KB/s';
        displayColor = Colors.red;
      }
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: displayColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(displayText,
          style: TextStyle(color: displayColor,
            fontWeight: FontWeight.w600,
            fontFamily: FontFamily.jetBrainsMono.value, fontSize: 13)),
      );
    }
    if (speed == 0) {
      return const SizedBox(
        width: 18, height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    // Negative value = delay-only fallback (show delay in ms)
    // speed = -1 = pure timeout
    if (speed < -0.5) {
      final delayMs = (-speed).round();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '$delayMs ms',
          style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500,
            color: Colors.blue.shade300,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        Intl.message('timeout'),
        style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w500,
          color: Colors.red.shade300,
        ),
      ),
    );
  }
}
