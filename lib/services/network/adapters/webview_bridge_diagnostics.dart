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

  /// D4: 是否有「WV 侧 cookie 变化待收敛」。
  ///
  /// 由 [CookieStoreObserver] 在收到外部 cookie 变化时置位，由其在
  /// debounce 窗口到期后清位。置位期间走桥请求**不**在自身请求路径上跑
  /// `sweepAll`（改由 debounce 在请求路径之外统一收敛），清位后恢复
  /// 「已同步即跳过」的快路径。
  bool cookieResyncPending = false;

  /// D4: 因「cookie 变化已交由 debounce 延后收敛」而在请求路径上省下的
  /// `sweepAll` 次数。这个数字就是本轮从活跃请求路径上摘掉的边界同步批数。
  int cookieSweepsDeferred = 0;

  /// D4: 标记「WV 侧 cookie 变化待收敛」。
  void markResyncPending() {
    cookieResyncPending = true;
  }

  /// D4: 标记「待收敛的变化已由 debounce 处理完毕」。
  void clearResyncPending() {
    cookieResyncPending = false;
  }

  /// D2: WV 侧发生 cookie 写入后调用，让下一次边界同步重新生效。
  ///
  /// 由 [WebViewCookiePriming] / [SessionCookieSentinel] 在完成 WV 侧写入后调用。
  void markWvCookieMutated() {
    cookieBoundarySynced = false;
    // D3: WV 侧写入会改变 cookie 集合，变体计数缓存必须一并作废。
    invalidateVariantCounts();
  }

  /// D3: 变体计数缓存（name → 最近一次已知变体数）。
  ///
  /// 动机（活跃刷帖发热）：`sweepAll` 对「jar 适用 cookie ∪ WV 已有 cookie」
  /// 的每个 name 都要先读一次变体数（iOS 原生 = 一次
  /// `WKHTTPCookieStore.getAllCookies` 全量枚举 + 跨语言序列化），随后
  /// `_sweepInternal` 又对同一 name 读一次。同一批 name 在一次边界同步里
  /// 被枚举两遍，纯属重复劳动。
  ///
  /// 这里把「已读到的变体数」按 name 记住，供同一批 sweep 复用；任何
  /// **改变 WV cookie 集合** 的操作（写入 / 删除 / 新 WebView 会话）都必须
  /// 调 [invalidateVariantCounts] 作废，否则会用陈旧计数做决策。
  /// 只缓存整数，不缓存 cookie 值，无账户内容。
  final Map<String, int> _variantCounts = {};

  /// D3: 读取缓存的变体数；未缓存返回 null（调用方按原逻辑走原生读取）。
  int? cachedVariantCount(String name) => _variantCounts[name];

  /// D3: 记住某 name 的最新变体数。
  void rememberVariantCount(String name, int count) {
    _variantCounts[name] = count;
  }

  /// D3: 作废变体计数缓存（WV cookie 集合可能已变化时调用）。
  void invalidateVariantCounts() {
    _variantCounts.clear();
  }

  /// D3: 因复用缓存计数而省下的原生 `getAllCookies` 全量枚举次数。
  int variantCountCacheHits = 0;

  /// D5: 因「响应体免二次 JSON 转义」而省下的整包往返次数。
  ///
  /// 旧路径把整个响应体嵌进 `JSON.stringify({body})` 再交给插件序列化，
  /// 于是 body 被转义两次、Dart 侧被反转义两次（`jsonDecode` 内层 + 插件外层）。
  /// 新路径把 body 作为平级字段传回，只经插件一次序列化。每 +1 表示
  /// 一条文本响应省下「一次 JS 整包转义 + 一次 Dart 整包反转义」。
  int textBodyUnescaped = 0;

  /// D5: 上述省下的转义字节量（按响应体长度估算，仅整数累加）。
  int textBodyUnescapedBytes = 0;

  /// D6: 因「与 WebView 无关的设置版本变更」而**保留复用** WebView 桥的次数。
  ///
  /// 旧行为下每次设置版本 bump 都会 close 掉 WebView delegate，导致隐藏
  /// WKWebView 被 dispose、下一次走桥请求必须从零重建（run + loadData +
  /// 等页面加载 + 全量重灌 cookie）。每 +1 表示省下了一次这样的重建。
  int webViewPreservedOnConfigChange = 0;

  /// D6: 标记「配置变更时保留了 WebView 桥」。
  void markWebViewPreservedOnConfigChange() {
    webViewPreservedOnConfigChange++;
  }

  /// D7: 因「刚 prime 过、无需重复 prime」而被削掉的重复 priming 次数。
  ///
  /// 动机（活跃刷帖发热）：`CfClearanceRefreshService` / `WebViewSessionSync`
  /// 在每次重建隐藏 WebView 前都会 `invalidate()` + `prime()`。活跃刷帖时
  /// CF 持续触发刷新，每次 prime 都要对全部 cookie 做「先删后写 + 逐名计数
  /// 校验」——O(cookie 数) 次原生 cookie 库往返，是活跃负载下的固定 CPU 源。
  /// 这里把「距上次成功 prime 不足去抖窗口」的重复 prime 直接短路，只计一次
  /// 削峰。
  int primingDeduped = 0;

  /// D7: 标记「一次重复 priming 被去抖短路」。
  void markPrimingDeduped() {
    primingDeduped++;
  }

  /// D2: 新的 WebView 会话建立/销毁时复位（新存储 = 需重新同步）。
  void resetCookieBoundarySync() {
    cookieBoundarySynced = false;
    // D4: 新会话的 cookie 变化同样交由 debounce 收敛，而非请求路径。
    cookieResyncPending = false;
    // D3: 新会话 = 全新 cookie 存储，缓存计数一律作废。
    invalidateVariantCounts();
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
    variantCountCacheHits = 0;
    cookieResyncPending = false;
    cookieSweepsDeferred = 0;
    textBodyUnescaped = 0;
    textBodyUnescapedBytes = 0;
    webViewPreservedOnConfigChange = 0;
    primingDeduped = 0;
    _variantCounts.clear();
  }
}
