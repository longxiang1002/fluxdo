import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import '../../pages/network_settings_page/widgets/cf_verify_card.dart';
import '../../pages/network_settings_page/widgets/debug_tools_card.dart';
import '../../pages/network_settings_page/widgets/doh_settings_card.dart';
import '../../pages/network_settings_page/widgets/engine_card.dart';
import '../../pages/network_settings_page/widgets/eruda_card.dart';
import '../../pages/network_settings_page/widgets/http_proxy_card.dart';
import '../../pages/network_settings_page/widgets/rate_limit_card.dart';
import '../../pages/network_settings_page/widgets/vpn_auto_toggle_card.dart';
import '../settings_model.dart';
import '../../pages/ios14_network_diagnostics_page.dart';
import '../../pages/ios14_diagnostics_page.dart';

/// 网络设置数据声明
List<SettingsGroup> buildNetworkGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    // 网络引擎
    SettingsGroup(
      title: l10n.networkSettings_engine,
      icon: Symbols.speed_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'engine',
          title: l10n.networkSettings_engine,
          subtitle: 'rhttp · WebView',
          builder: (context, ref) => const EngineCard(),
        ),
      ],
    ),

    // 网络代理
    SettingsGroup(
      title: l10n.networkSettings_proxy,
      icon: Symbols.dns_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'dohSettings',
          title: 'DNS over HTTPS',
          subtitle: l10n.networkSettings_proxy,
          builder: (context, ref) => const DohSettingsCard(),
        ),
        CustomModel(
          id: 'httpProxy',
          title: l10n.httpProxy_title,
          subtitle: l10n.networkSettings_proxy,
          builder: (context, ref) => const HttpProxyCard(),
        ),
      ],
    ),

    // 辅助功能
    SettingsGroup(
      title: l10n.networkSettings_auxiliary,
      icon: Symbols.tune_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'vpnAutoToggle',
          title: l10n.vpnToggle_title,
          subtitle: l10n.vpnToggle_subtitle,
          builder: (context, ref) => const VpnAutoToggleCard(),
        ),
        CustomModel(
          id: 'cfVerify',
          title: l10n.cf_securityVerifyTitle,
          subtitle: l10n.networkSettings_auxiliary,
          builder: (context, ref) => const CfVerifyCard(),
        ),
      ],
    ),

    // 高级
    SettingsGroup(
      title: l10n.networkSettings_advanced,
      icon: Symbols.settings_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'rateLimit',
          title: l10n.networkSettings_rateLimitTitle,
          subtitle: l10n.networkSettings_advanced,
          builder: (context, ref) => const RateLimitCard(),
        ),
      ],
    ),

    // 调试
    SettingsGroup(
      title: l10n.networkSettings_debug,
      icon: Symbols.bug_report_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'ios14NetworkDiagnostics',
          title: 'iOS 14 网络验证',
          subtitle: 'DoH 实际路径与系统能力',
          builder: (context, ref) => ListTile(
            title: const Text('iOS 14 网络验证'),
            subtitle: const Text('验证 DoH、真实请求路由及 WebView 覆盖范围'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Ios14NetworkDiagnosticsPage(),
              ),
            ),
          ),
        ),
        CustomModel(
          id: 'ios14LoadDiagnostics',
          title: '刷帖负载诊断',
          subtitle: '脱敏聚合计数，默认关闭',
          builder: (context, ref) => ListTile(
            title: const Text('刷帖负载诊断'),
            subtitle: const Text('阅读上报、CF 和视频生命周期计数'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Ios14DiagnosticsPage(),
              ),
            ),
          ),
        ),
        CustomModel(
          id: 'debugTools',
          title: l10n.appLogs_title,
          subtitle: l10n.networkSettings_debug,
          builder: (context, ref) => const DebugToolsCard(),
        ),
        CustomModel(
          id: 'erudaConsole',
          title: 'Eruda 调试控制台',
          subtitle: l10n.networkSettings_debug,
          builder: (context, ref) => const ErudaCard(),
        ),
      ],
    ),
  ];
}
