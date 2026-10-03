/// iOS 原生网络能力。无法识别版本时保守使用 IO，不试调高版本 API。
int? appleSystemMajorVersion(String version) {
  final match = RegExp(
    r'^(?:Version\s+|iOS\s+)?(\d+)(?:\.|\s|$)',
    caseSensitive: false,
  ).firstMatch(version.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool needsIosIoFallback({required bool isIOS, required String systemVersion}) {
  if (!isIOS) return false;
  final major = appleSystemMajorVersion(systemVersion);
  return major == null || major < 15;
}

/// 延迟工厂保证旧系统根本不构造 Cupertino 配置或客户端。
T createIosCompatibleTransport<T>({
  required bool isIOS,
  required String systemVersion,
  required T Function() ioFactory,
  required T Function() nativeFactory,
}) {
  return needsIosIoFallback(isIOS: isIOS, systemVersion: systemVersion)
      ? ioFactory()
      : nativeFactory();
}
