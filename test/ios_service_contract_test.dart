import 'dart:convert';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shared state keeps the iOS packet tunnel contract', () {
    const state = SharedState(
      setupParams: SetupParams(selectedMap: {'GLOBAL': 'DIRECT'}, testUrl: ''),
      vpnOptions: VpnOptions(
        enable: true,
        port: 7890,
        ipv6: true,
        dnsHijacking: true,
        accessControlProps: AccessControlProps(),
        allowBypass: false,
        systemProxy: true,
        bypassDomain: ['localhost'],
        stack: 'mixed',
      ),
      stopTip: 'stop',
      startTip: 'start',
      currentProfileName: 'test',
      stopText: 'stop',
      onlyStatisticsProxy: false,
      crashlytics: false,
    );

    final json = jsonDecode(jsonEncode(state)) as Map<String, dynamic>;
    final setup = json['setupParams'] as Map<String, dynamic>;
    final vpn = json['vpnOptions'] as Map<String, dynamic>;

    expect(setup['selected-map'], {'GLOBAL': 'DIRECT'});
    expect(vpn['stack'], 'mixed');
    expect(vpn['dnsHijacking'], isTrue);
    expect(vpn['bypassDomain'], ['localhost']);
  });
}
