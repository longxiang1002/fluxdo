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

  /// D13: 其中「同源图片」走桥时的响应字节量（[streamResponseBytes] 的子集）。
  ///
  /// 用于对比 D2（同源图片分流到原生 Dio）的收益：若这个数字很大，
  /// 说明分流前的桥负载主要来自图片；分流后它应趋近 0。
  int imageResponseBytes = 0;

  /// D14: 二进制流在 JS 侧合并前的原始 chunk 总数。
  ///
  /// 每个原始 chunk 本会各自触发一次 `postMessage` 跨 JS↔native 边界；
  /// 合并后实际发出的消息数见 [streamCoalescedMessages]。两者之比
  /// 就是本轮省下的跨语言边界穿越批数。
  int streamRawChunks = 0;

  /// D14: 二进制流在 JS 侧合并后实际发出的消息数（跨桥回传批数）。
  int streamCoalescedMessages = 0;

  /// D14: 因 JS 侧合并而省下的跨桥消息数（[streamRawChunks] - [streamCoalescedMessages]）。
  int get streamMessagesSaved => streamRawChunks > streamCoalescedMessages
      ? streamRawChunks - streamCoalescedMessages
      : 0;

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

  /// D8: 因「只读图片请求」而省下的 `sweepAll` 边界同步次数。
  ///
  /// 动机（活跃刷帖发热）：同源图片在桥上是只读 cookie 模式
  /// （`cookieModeReadOnly`），从不往 WV 侧写 cookie，因此紧随 `prime()`
  /// 之后的 `sweepAll()`（清理 WV 侧多余变体）对它们毫无意义。改前每个
  /// 图片请求都要跑一遍 `sweepAll`——O(cookie 数) 次原生 method channel
  /// 往返。每 +1 表示从活跃请求路径上摘掉了一整批边界同步。
  int cookieSweepsSkippedForImage = 0;

  /// D9: 因「800ms 去抖窗口」被合并掉的**响应侧**边界回同步次数。
  ///
  /// 动机（活跃刷帖发热）：改前写请求（POST/PUT/…）走
  /// `force: trustsWebViewSession || (method != 'GET' && method != 'HEAD')`，
  /// 即**每个写请求都强制**跑一次 `_syncCriticalCookiesBackToJar` →
  /// `readCookiesFromWebView`（iOS = `WKHTTPCookieStore.getAllCookies`
  /// 全量枚举 + 跨 method channel 序列化）。活跃刷帖时点赞/回复/浏览上报
  /// 等写请求密集，这是活跃负载下的固定 CPU 源。改后写请求与读请求共用
  /// 同一 800ms 去抖快路径，窗口内到达的请求直接合并。每 +1 表示省下
  /// 一次全量 WV cookie 枚举 + 边界同步。
  int cookieBackSyncDeduped = 0;

  /// D10: 因「小请求体直接内联 JS 字面量」而省下的整包 base64 往返次数。
  ///
  /// 动机（活跃刷帖发热）：改前非流式请求体一律走
  /// `base64Encode(bytes)` → `jsonEncode(base64)` 嵌进脚本 → JS 侧
  /// `atob()` 解码 → `Uint8Array.from()` 逐字节还原。这是桥里最重的
  /// 请求侧序列化路径：一次请求体在 Dart 侧编码、JS 侧解码，两端各一份
  /// 完整副本，且 `Uint8Array.from(atob(x), cb)` 是逐字符回调。
  ///
  /// 活跃刷帖时点赞/回复/上报等写请求密集，请求体普遍很小（几十~几百字节），
  /// 走 base64 桥纯属杀鸡用牛刀。改后小体量请求体直接以 JSON 字符串字面量
  /// 内联进脚本（`fetchOptions.body = "..."`）——Dart 的 `jsonEncode` 已经
  /// 负责转义，JS 侧零解码、零回调、零额外副本。每 +1 表示省下一次整包
  /// base64 编解码往返。
  ///
  /// 阈值以内的体量才内联；超过阈值仍走 base64（大 body 内联会让脚本本身
  /// 膨胀，得不偿失）。阈值只影响「怎么送」，不影响「送什么」。
  int requestBodyInlineSmall = 0;

  /// D10: 小请求体内联的字节阈值。
  ///
  /// 取值依据：活跃刷帖的写请求体（点赞/回复/浏览上报/CSRF 表单）实测都在
  /// 数百字节量级；4KB 覆盖绝大多数写请求，同时保证内联脚本本身不会大到
  /// 让 `evaluateJavascript` 的源码传输成为新瓶颈。
  static const int requestBodyInlineMaxBytes = 4096;

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

  /// D15: 活跃发热归因速判——把桥侧计数压成一句可读结论，供「刷帖前后各看
  /// 一次差值」时一眼判读「活跃期发热是否由桥负载主导」。
  ///
  /// 纯派生计算，不采样、不新增任何运行时开销；判据只用已在聚合的整数计数。
  /// 返回 `null` 表示样本不足（尚无走桥请求），不冒充结论。
  String? get activeLoadVerdict {
    if (totalRequests == 0) return null;
    // 桥侧是否仍在搬运大量图片字节：同源图片走桥次数 + 图片响应字节。
    final imageOnBridge = imageSameOrigin;
    final imageBytesOnBridge = imageResponseBytes;
    // 已分流到原生直连的同源图片次数（D2）。
    final imageOffloaded = imageRoutedNative;
    final mb = totalResponseBytes / (1024 * 1024);
    final bytesText = mb.toStringAsFixed(2);

    if (imageOffloaded > imageOnBridge) {
      // 图片大头已被分流，桥主要剩 API/文本。
      if (totalResponseBytes < 2 * 1024 * 1024) {
        return '桥负载已瘦身：图片分流 $imageOffloaded 次，'
            '桥仅搬运 ${bytesText}MB（以 API/文本为主）。'
            '若活跃发热仍在，真凶大概率不在桥，转查渲染/图片解码/DoH 出口。';
      }
      return '图片已分流 $imageOffloaded 次（走桥仅 $imageOnBridge 次），'
          '但桥仍在搬运 ${bytesText}MB，其中图片字节 '
          '${(imageBytesOnBridge / (1024 * 1024)).toStringAsFixed(2)}MB。'
          '桥负载仍显著，可继续收紧并发闸门或核对分流是否被 CF 403 回退。';
    }
    if (imageBytesOnBridge > totalResponseBytes ~/ 2) {
      return '桥负载由图片主导：图片字节 '
          '${(imageBytesOnBridge / (1024 * 1024)).toStringAsFixed(2)}MB'
          '占桥总量 ${bytesText}MB 的一半以上（走桥 $imageOnBridge 次，'
          '分流 $imageOffloaded 次）。图片分流未覆盖到位，是活跃发热首选靶点。';
    }
    return '桥负载以 API/文本为主（共 ${bytesText}MB，图片字节 '
        '${(imageBytesOnBridge / (1024 * 1024)).toStringAsFixed(2)}MB）。'
        '若活跃发热仍在，桥不是主因，转查渲染/图片解码/DoH 出口。';
  }

  /// D16: 活跃发热「成本预算」速判——把桥的**单位成本**压成一句可读结论。
  ///
  /// 动机（2026-10-13 深夜重定位）：D15 的 [activeLoadVerdict] 只回答
  /// 「桥搬了多少」，但老板实测 test-48 后**刷一会仍发热**。桥的绝对字节量
  /// 可能不大（D15 判「桥负载已瘦身」），可如果**每个请求的平均耗时**远高于
  /// 原生直连（原生 iOS 直连通常 30~80ms），说明真正的开销不是「搬了多少
  /// 字节」，而是「每个请求都在付跨语言 + 分块回传的固定税」——活跃刷帖时
  /// 请求密集，这份固定税被反复支付，才是活跃发热的主因。
  ///
  /// 判据只用已在聚合的整数计数（[totalMs] / [totalRequests] / 探针均值），
  /// 纯派生、零采样、零新增运行时开销。返回 `null` 表示样本不足。
  ///
  /// 阈值依据：[bridgeCostHeavyMs] 取 250ms——原生直连的 3~8 倍，足以把
  /// 「正常网络往返」与「跨桥固定税」区分开；[bridgeCostMinSamples] 取 8，
  /// 避免一两个冷启动请求（含 WebView 初始化）把均值拉高后误判。
  String? get bridgeCostVerdict {
    if (totalRequests < bridgeCostMinSamples) return null;
    final avgMs = totalMs ~/ totalRequests;
    final avgJsEvalMs = jsEvalMs ~/ totalRequests;
    // 注：这里只用本类已聚合的整数（totalMs/totalRequests/jsEvalMs），
    // 不引用 WebViewBridgeProbe（那会引入跨文件依赖/环）。探针的
    // averageInFlightMs 是另一套采样口径，诊断页单独展示即可。

    if (avgMs >= bridgeCostHeavyMs) {
      return '桥单位成本偏高：平均每请求 ${avgMs}ms'
          '（其中 JS evaluate ${avgJsEvalMs}ms），'
          '远超原生直连的几十 ms。活跃发热的主因大概率是「每个请求都在付'
          '跨语言+分块回传的固定税」，而非桥搬运的总字节量。'
          '下一步优先砍「走桥请求条数」（把更多只读/静态请求分流原生），'
          '而不是继续优化单次传输。';
    }
    if (avgMs >= bridgeCostHeavyMs ~/ 2) {
      return '桥单位成本中等：平均每请求 ${avgMs}ms'
          '（JS evaluate ${avgJsEvalMs}ms）。'
          '桥有固定税但未到压倒性；若活跃发热仍在，需与渲染/解码/DoH 出口'
          '交叉排查，同时留意走桥请求条数是否偏高。';
    }
    return '桥单位成本良好：平均每请求 ${avgMs}ms'
        '（JS evaluate ${avgJsEvalMs}ms），'
        '接近原生直连水平。桥本身不是活跃发热主因，'
        '应把排查重心转向渲染/图片解码/DoH 出口。';
  }

  /// D16: 判定「桥单位成本偏高」的平均耗时阈值（毫秒）。
  ///
  /// 取 250ms：原生 iOS 直连通常 30~80ms，250ms 已是其 3~8 倍，
  /// 足以把「正常网络往返」与「跨桥固定税」区分开，同时不会被偶发慢网误触。
  static const int bridgeCostHeavyMs = 250;

  /// D16: 成本速判所需的最少走桥请求数（避免冷启动样本污染均值）。
  static const int bridgeCostMinSamples = 8;

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
    imageResponseBytes = 0;
    streamRawChunks = 0;
    streamCoalescedMessages = 0;
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
    cookieSweepsSkippedForImage = 0;
    cookieBackSyncDeduped = 0;
    requestBodyInlineSmall = 0;
    _variantCounts.clear();
  }
}
