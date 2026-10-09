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

  /// 诊断用：读取 CFNetwork 已生效的代理配置（`CFNetworkCopyProxiesForURL`）。
  ///
  /// 只返回**固定字段、无 URL/无凭据、无 PAC 脚本正文**的结构化快照，
  /// 供 Dart 侧判断「WKWebView 的出口 == DoH 网关的出站」。
  ///
  /// `effectiveProxyUrl` 读的是**系统设置**里的代理（App 进程配置不出现在那里）；
  /// 本方法读的是 **App 进程真实生效**的代理字典，两者一致才说明
  /// 「App 内随系统代理」这一前提成立。
  ///
  /// 每项字段：`type`（http|https|socks|pac|direct）、`probeHost`（本机地址）、
  /// `host`/`port`（非 pac 时）、`hasPacScript`（仅布尔，不含脚本内容）、
  /// `consistentWithSystem`（与 `effectiveProxyUrl` 的 host:port 是否一致）。
  @objc func proxyProbeSnapshot() -> [String: Any] {
    let probeURL = URL(string: "https://example.invalid/")!
    let systemProxyUrl = effectiveProxyUrl

    // 第二个参数是 `CFDictionary?` 的 proxySettings（可空）。
    // 显式声明为可选 `CFDictionary?` 再传 nil，既满足类型要求，
    // 又让 CFNetwork 自行取当前进程生效的系统级代理配置。
    // ⚠️ 切勿在此传 `kCFAllocatorDefault`（那是 CFAllocator，不是 CFDictionary，
    //     CI 报 "Cannot convert value of type 'CFAllocator' to expected argument type
    //     'CFDictionary'"）。allocator 用 CFNetwork 默认即可。
    let proxySettings: CFDictionary? = nil
    let entries = CFNetworkCopyProxiesForURL(probeURL as CFURL, proxySettings)
      .takeRetainedValue() as? [[String: Any]]

    guard let entries else {
      return [
        "count": 0,
        "systemProxyUrl": systemProxyUrl as Any,
      ]
    }

    var items: [[String: Any]] = []
    for entry in entries {
      let type = (entry["kCFProxyTypeKey"] as? String) ?? "unknown"
      var item: [String: Any] = [
        "type": Self.shortProxyType(type),
        "probeHost": probeURL.host ?? "",
      ]

      if let host = entry["kCFProxyHostNameKey"] as? String, !host.isEmpty {
        item["host"] = host
      }
      if let port = entry["kCFProxyPortNumberKey"] as? NSNumber {
        item["port"] = port.intValue
      }
      if let script = entry["kCFProxyAutoConfigurationURLKey"] as? String {
        // 只记「有 PAC」与是否远端，脚本内容与 URL 本体不外泄。
        item["hasPacScript"] = true
        item["pacIsRemote"] = !script.isEmpty
      }

      if let host = item["host"] as? String, let port = item["port"] as? Int {
        item["consistentWithSystem"] = (systemProxyUrl == "http://\(host):\(port)")
      }
      items.append(item)
    }

    return [
      "count": items.count,
      "systemProxyUrl": systemProxyUrl as Any,
      "entries": items,
    ]
  }

  /// 把 CFNetwork 的长常量名压成长短串；未知类型原样保留，便于日后核对。
  private static func shortProxyType(_ type: String) -> String {
    switch type {
    case "kCFProxyTypeHTTP": return "http"
    case "kCFProxyTypeHTTPS": return "https"
    case "kCFProxyTypeSOCKS": return "socks"
    case "kCFProxyTypeAutoConfigurationURL": return "pac"
    case "kCFProxyTypeAutoConfigurationJavaScript": return "pacInline"
    case "kCFProxyTypeNone": return "direct"
    default: return type
    }
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
