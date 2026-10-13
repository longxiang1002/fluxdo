/// WebView 桥开销聚合统计（D1 量化用）。
///
/// 目的：把「走网络桥的请求数/字节量/耗时」压成 O(1) 的整数聚合，
/// 供 iOS14 网络诊断页只读展示，回答「活跃刷帖时图片 vs API 各占多少」。
///
/// 刻意设计：
/// - **常开但零日志**：只做整数累加，内存恒定、不落盘、不逐请求写日志，
///   因此激活态下开销可忽略（基准：每次请求一次分类 + 几次加法）。
/// - 不记录 URL/Headers/正文，无账户内容，只记类别计数与字节量。
/// - 与 [DohRouteDiagnostics] 的「默认关闭 + 逐条队列」不同：那个要看清单独
///   请求链路，这里要的是总量画像，所以始终聚合、由诊断页在需要时重置。
class WebViewBridgeDiagnostics {
  WebViewBridgeDiagnostics._();

  static final WebViewBridgeDiagnostics instance = WebViewBridgeDiagnostics._();

  /// 按请求类别聚合的计数器。
  int imageSameOrigin = 0;
  int imageOther = 0;
  int apiGet = 0;
  int apiWrite = 0;
  int other = 0;

  /// 响应形态聚合：文本响应的请求数与字节量（string 路径）。
  int textResponses = 0;
  int textResponseBytes = 0;

  /// 二进制流（WebMessageChannel 分块回传）的请求数与字节量。
  int streamResponses = 0;
  int streamResponseBytes = 0;

  /// 请求体形态聚合：base64 fallback（arrayBuffer→base64→Dart 解码）次数。
  /// 这是桥里最重的序列化路径，D3 优化是否值得做以它为据。
  int requestBodyBase64 = 0;
  int requestBodyStreamBridge = 0;
  int requestBodyDirect = 0;

  /// 耗时聚合（毫秒），用于算均值：总量与 JS evaluate 两段。
  int totalMs = 0;
  int jsEvalMs = 0;

  /// 失败次数（异常/超时/非 2xx 由调用方判定），只计异常路径。
  int failed = 0;

  /// D2: 边界同步（sweepAll）实际执行次数。
  /// 降频前每请求一次；降频后只在新 WebView 会话或 WV 侧写过 cookie 后执行。
  int cookieSweeps = 0;

  /// D2: 因「本会话已同步且 WV 未再写入」被跳过的 sweepAll 次数。
  /// 这个数字就是本轮省下的原生 method channel 往返批次。
  int cookieSweepsSkipped = 0;

  /// D3: sweepAll 里用批量取数（一次原生 `getAllCookies` 枚举）替代
  /// 逐 name 调用的次数。每 +1 表示省下了 `names.length - 1` 次全量枚举。
  int cookieBatchCountCalls = 0;

  /// D3: 批量取数累计覆盖的 name 数（用于估算省下的枚举次数）。
  int cookieBatchCountNames = 0;

  /// D2: 因「同源图片分流到原生栈」而从桥上省下的请求数。
  ///
  /// 这些请求本会走「JS fetch → WebMessageChannel 分块回传」的重路径；
  /// 分流后由原生 Dio 直连。计数用于量化本轮省下的桥负载规模。
  int imageRoutedNative = 0;

  /// D2: 当前 WebView 会话是否已完成过一次 cookie 边界同步（sweepAll）。
  ///
  /// `prime()` 幂等（只灌一次），但紧随其后的 `sweepAll()` 不是——它对
  /// 「jar 适用 cookie ∪ WV 已有 cookie」的**每个 name** 逐个走
  /// `countCookiesByName` + `nukeAllVariants` + `countCookiesByName`
  /// 三次原生 method channel 往返（iOS: `WKHTTPCookieStore.getAllCookies`
  /// 全量枚举），几十个 cookie 就是上百次跨语言调用，且此前每个走桥请求
  /// 都跑一遍。这是活跃刷帖时的固定桥开销，与请求本身无关。
  ///
  /// 边界同步的真实职责是「清理 WV 里 jar 不知道的多余变体」，而变体的唯一
  /// 来源是 WV 自己写入 cookie（CF 轮换 / 服务端下发）。因此只在
  /// **WV 确实写过 cookie 之后**才需要再 sweep；一个 WebView 会话内没有
  /// 新的 WV 写入时，重复 sweep 的结果必然与上一次相同（幂等 → 全 noop）。
  ///
  /// 注意：这里**不**触碰任何 WebView 挂起/暂停 API，也不阻塞 JS 执行，
  /// 只是把一次多余的同步调用省掉。
  bool cookieBoundarySynced = false;

  /// D2: WV 侧发生 cookie 写入后调用，让下一次边界同步重新生效。
  ///
  /// 由 [WebViewCookiePriming] / [SessionCookieSentinel] 在完成 WV 侧写入后调用。
  void markWvCookieMutated() {
    cookieBoundarySynced = false;
  }

  /// D2: 新的 WebView 会话建立/销毁时复位（新存储 = 需重新同步）。
  void resetCookieBoundarySync() {
    cookieBoundarySynced = false;
  }

  int get totalRequests =>
      imageSameOrigin + imageOther + apiGet + apiWrite + other;

  int get totalResponseBytes => textResponseBytes + streamResponseBytes;

  void reset() {
    imageSameOrigin = 0;
    imageOther = 0;
    apiGet = 0;
    apiWrite = 0;
    other = 0;
    textResponses = 0;
    textResponseBytes = 0;
    streamResponses = 0;
    streamResponseBytes = 0;
    requestBodyBase64 = 0;
    requestBodyStreamBridge = 0;
    requestBodyDirect = 0;
    totalMs = 0;
    jsEvalMs = 0;
    failed = 0;
    cookieSweeps = 0;
    cookieSweepsSkipped = 0;
    cookieBatchCountCalls = 0;
    cookieBatchCountNames = 0;
    imageRoutedNative = 0;
  }
}
