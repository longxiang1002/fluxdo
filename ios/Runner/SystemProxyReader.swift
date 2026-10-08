import CFNetwork
import Foundation

/// 读取 iOS 系统 HTTP/HTTPS 代理设置（CFNetwork 栈）。
///
/// 背景：WKWebView / URLSession 默认跟随系统代理（CFNetwork 栈），而 rhttp
/// （Rust reqwest）自建 socket 直连系统设置，两者出口 IP 不一致会让
/// cf_clearance 对 Dio 请求失效 → CF 验证无限循环（与 Windows 上
/// WebView2 vs Dio 的问题同构，见 SystemProxyService 注释）。
/// rhttp 侧通过 MethodChannel 拿到这份配置，与 WebView 保持同一出口。
///
/// 仅返回固定 HTTP/HTTPS 代理；PAC / 自动代理脚本不做原生侧求值，
/// 未配置固定代理时返回 nil（与 Windows 注册表读取同策略）。
///
/// ⚠️ iOS 特别说明：
/// - `kCFNetworkProxiesHTTPSEnable/HTTPSProxy/HTTPSPort` 是 macOS-only 常量，
///   iOS 上引用会编译报 unavailable；这里改用其等值的字符串字面量（CFNetwork
///   代理字典标准 key），iOS/macOS 均可编译。
/// - 仅在 `*Enable == true` 且 host 非空、port 合法时才返回。未配置代理时
///   CFNetwork 字典里根本不带这些键，因此返回 nil → 直连，不会误判。
/// - 只接受 `http://` scheme（NSDictionary 里的代理必然是 HTTP CONNECT 型，
///   不存在 socks 声明），避免把非法值传给 rhttp/Dio 造成请求全挂。
@objc class SystemProxyReader: NSObject {
  @objc static let shared = SystemProxyReader()

  /// 当前系统代理 URL（`http://host:port`），未启用固定代理时为 nil。
  /// 优先 HTTPS 代理设置，其次 HTTP 代理设置。
  @objc var effectiveProxyUrl: String? {
    guard let settings = CFNetworkCopySystemProxySettings()?
      .takeRetainedValue() as? [String: Any] else {
      return nil
    }

    if let https = proxyEntry(
      settings,
      enabledKey: "HTTPSEnable",
      hostKey: "HTTPSProxy",
      portKey: "HTTPSPort"
    ) {
      return https
    }
    return proxyEntry(
      settings,
      enabledKey: "HTTPEnable",
      hostKey: "HTTPProxy",
      portKey: "HTTPPort"
    )
  }

  private func proxyEntry(
    _ settings: [String: Any],
    enabledKey: String,
    hostKey: String,
    portKey: String
  ) -> String? {
    // enabled 可能是 Bool 或 NSNumber(1/0)，两种都接受；只有明确为真才继续。
    let enabled = (settings[enabledKey] as? Bool)
      ?? ((settings[enabledKey] as? NSNumber)?.boolValue ?? false)
    guard enabled,
          let host = settings[hostKey] as? String,
          !host.isEmpty,
          host != "0.0.0.0",
          let portNumber = settings[portKey] as? NSNumber,
          portNumber.intValue > 0, portNumber.intValue <= 65535 else {
      return nil
    }
    return "http://\(host):\(portNumber.intValue)"
  }
}
