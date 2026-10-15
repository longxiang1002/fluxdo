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
///
/// D20 起本类还派生「闸门排队 vs 单请求固定税」归因，因此引用
/// [WebViewBridgeGate] 与 [WebViewBridgeProbe] 的只读计数（无环，两者都不
/// 反向依赖本类）。
library;

import 'webview_bridge_gate.dart';
import 'webview_bridge_probe.dart';

class WebViewBridgeDiagnostics {
  WebViewBridgeDiagnostics._();

  static final WebViewBridgeDiagnostics instance = WebViewBridgeDiagnostics._();

  /// 按请求类别聚合的计数器。
  int imageSameOrigin = 0;
  int imageOther = 0;
  int apiGet = 0;
  int apiWrite = 0;
  int other = 0;

  /// D26: 按请求类别聚合的**桥内耗时**（毫秒），与上面的类别计数一一对应。
  ///
  /// 动机（2026-10-13 深夜重定位）：D25 已能把走桥负载按「流路径 vs 文本路径」
  /// 拆分，但两条路径都可能同时被「图片」与「API」两类请求占用——老板真正要
  /// 判的是「活跃刷帖时发热到底来自哪一类请求」，好决定下一步砍哪一类。这里把
  /// 每请求的总耗时按类别累加，得到「哪一类请求吃掉了桥的大部分 CPU 时间」。
  ///
  /// 口径与 [totalMs] 一致（都是单请求桥内总耗时），只是多一维分类；纯整数
  /// 累加，零采样、零新增运行时开销，不触碰任何 WebView 挂起/暂停 API。
  int imageSameOriginMs = 0;
  int imageOtherMs = 0;
  int apiGetMs = 0;
  int apiWriteMs = 0;
  int otherMs = 0;

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

  /// D25: 二进制流响应走「WebMessageChannel 分块回传」的请求数。
  ///
  /// 动机（2026-10-13 深夜重定位）：D16/D17/D20/D21/D22 全都在回答
  /// 「桥贵不贵 / 贵在哪 / 限流值不值得做」，但都建立在 [totalRequests]
  /// 这个**混合口径**上——文本响应（`callHandler` 一次性回传）与二进制流
  /// （`createWebMessageChannel` + 握手 + N 次分块回调）的固定成本相差一个
  /// 数量级。若活跃刷帖时走桥的主要是二进制流，那么「每请求固定税」里真正
  /// 的大头是**通道建立 + 分块回调**，砍脚本体积毫无收益，该砍的是走桥的
  /// 流请求条数（即继续分流静态资源到原生栈）。
  ///
  /// 这三个计数与 [streamResponses] 的区别：[streamResponses] 是「桥搬了
  /// 多少流」，这三个是「为了搬这些流，额外付了多少次跨语言边界穿越」——
  /// 后者才是 CPU 峰值的直接来源。
  int binaryBridgeResponses = 0;

  /// D25: 上述流响应累计回传的字节量（与 [streamResponseBytes] 同口径，
  /// 单独记一份便于与「固定成本」做比值）。
  int binaryBridgeBytes = 0;

  /// D25: 上述流响应累计的**分块回调次数**（Dart 侧 `setWebMessageCallback`
  /// 被触发的次数）。每次回调都是一次 JS↔native 边界穿越 + 一次
  /// `Uint8List` 分配，活跃滚动大图时与 chunk 数同阶。
  int binaryBridgeChunks = 0;

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

  /// D17: 活跃发热「固定税拆解」——把 [totalMs] 拆成三段，回答
  /// 「桥的固定税到底花在哪」。
  ///
  /// 动机（2026-10-13 深夜重定位）：D16 只能判「桥单位成本高不高」，
  /// 判高了也不知道该砍哪一段。老板实测刷帖仍热，需要把每请求耗时拆成
  /// 「cookie 准备 / JS evaluate / 等浏览器返回」三段，才能确定优化靶点：
  ///   - cookiePrep 主导 → 继续砍 sweepAll / 边界同步（D2/D3/D4 方向）；
  ///   - jsEval 主导     → 砍 JS 脚本体积与跨语言调用次数；
  ///   - browserWait 主导→ 桥不是主因，转查 DoH 出口 / 网络往返 / 渲染。
  ///
  /// 纯累加整数，零采样、零新增运行时开销；三段之和略小于 [totalMs]
  /// （差值 = Dart 侧解析/回传等未单独计时的部分）。
  int cookiePrepMs = 0;
  int browserWaitMs = 0;
  int cookieBackSyncMs = 0;

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

  /// D17: 把桥的「固定税」拆成三段并指出主导段。
  ///
  /// 与 [bridgeCostVerdict] 的区别：后者只回答「贵不贵」，本 getter 回答
  /// 「贵在哪」，直接给出优化靶点。判据只用已聚合的整数计数，纯派生、
  /// 零采样、零新增运行时开销。返回 `null` 表示样本不足。
  ///
  /// 判据口径：三段之和（cookiePrep + jsEval + browserWait）作为分母，
  /// 某段占比 ≥ [bridgeTaxDominantRatio] 即判为主导段。分母为 0（例如
  /// 全部走的是不记 jsEval 的路径）时退化为按绝对值取最大段。
  String? get bridgeTaxBreakdownVerdict {
    if (totalRequests < bridgeCostMinSamples) return null;
    final n = totalRequests;
    final avgCookiePrep = cookiePrepMs ~/ n;
    final avgJsEval = jsEvalMs ~/ n;
    final avgBrowserWait = browserWaitMs ~/ n;
    final avgTotal = totalMs ~/ n;
    final sum = avgCookiePrep + avgJsEval + avgBrowserWait;

    String pct(int part) => sum == 0 ? '—' : '${(part * 100 / sum).round()}%';

    final head =
        '桥固定税拆解：平均每请求 ${avgTotal}ms = '
        'cookie 准备 ${avgCookiePrep}ms(${pct(avgCookiePrep)}) + '
        'JS 调用 ${avgJsEval}ms(${pct(avgJsEval)}) + '
        '等浏览器 ${avgBrowserWait}ms(${pct(avgBrowserWait)})';

    // 主导段判定：优先按占比，分母为 0 时按绝对值。
    final dominant =
        avgCookiePrep >= avgJsEval && avgCookiePrep >= avgBrowserWait
        ? 'cookie'
        : (avgJsEval >= avgBrowserWait ? 'js' : 'browser');
    final dominantMs = dominant == 'cookie'
        ? avgCookiePrep
        : (dominant == 'js' ? avgJsEval : avgBrowserWait);
    final isDominant = sum == 0
        ? false
        : dominantMs * 100 >= sum * bridgeTaxDominantRatio;

    if (!isDominant) {
      return '$head。三段均衡，无单一段压倒性主导；'
          '优化需多段同时收（cookie 同步降频 + JS 脚本瘦身），'
          '或转查渲染/图片解码/DoH 出口。';
    }

    switch (dominant) {
      case 'cookie':
        return '$head。主导段 = cookie 准备（占 ${pct(avgCookiePrep)}）：'
            '活跃发热的固定税主要花在 cookie 边界同步上。'
            '下一步优先继续砍 sweepAll/边界同步（D2/D3/D4 方向），'
            '而不是优化 JS 或传输。';
      case 'js':
        return '$head。主导段 = JS 调用（占 ${pct(avgJsEval)}）：'
            '开销主要在跨语言 evaluateJavascript 与脚本体积。'
            '下一步优先砍 JS 脚本长度与每请求调用次数（合并调用/预编译脚本）。';
      default:
        return '$head。主导段 = 等浏览器返回（占 ${pct(avgBrowserWait)}）：'
            '时间花在 WebKit 网络往返而非跨桥搬运，桥本身不是活跃发热主因。'
            '下一步转查 DoH 出口/上游往返/图片解码与渲染。';
    }
  }

  /// D17: 某一段占「三段之和」多少即判为主导段（百分比）。
  ///
  /// 取 50：只有单段占到一半以上才算压倒性主导；低于此值说明三段均衡，
  /// 不宜把优化全部押在单段上。
  static const int bridgeTaxDominantRatio = 50;

  /// D20: 活跃发热「闸门排队 vs 请求固定税」归因速判。
  ///
  /// 动机（2026-10-13 深夜重定位）：D16/D17 只回答「桥贵不贵、贵在哪」，
  /// 但活跃刷帖发热有两种互斥成因，优化方向完全相反：
  ///   (a) **并发洪峰排队**：活跃期大量请求同时挤闸门（[WebViewBridgeGate]），
  ///       每个请求在飞时长被排队拉长，CPU 花在「等待 + 唤醒 + 分块回调」上。
  ///       对策 = 继续下调并发上限、或把更多请求分流到原生栈（D2 方向）。
  ///   (b) **单请求固定税**：并发本就不高（几乎不排队），但每个走桥请求都要付
  ///       跨语言 evaluateJavascript + 分块回传的固定成本。对策 = 砍脚本体积、
  ///       合并调用、减少走桥请求条数，而不是限流。
  ///
  /// 判据只用已聚合的整数计数（闸门排队/峰值 + 探针在飞时长/完成数），
  /// 纯派生、零采样、零新增运行时开销。返回 `null` 表示样本不足。
  ///
  /// 阈值依据：[gateQueueDominantRatio] 取 20——活跃刷帖时若超过五分之一的
  /// 走桥请求都因闸门满而排队，说明并发上限已是瓶颈；低于此值说明闸门基本
  /// 没拦住谁，限流无收益。
  String? get gateVsTaxVerdict {
    final gate = WebViewBridgeGate.instance;
    final probe = WebViewBridgeProbe.instance;
    final avgInFlight = probe.averageInFlightMs;
    if (totalRequests < bridgeCostMinSamples || avgInFlight == null) {
      return null;
    }
    final queuedRatio = gate.queuedTotal / totalRequests;
    final queuedPct = (queuedRatio * 100).round();
    final avgMs = avgInFlight.toStringAsFixed(0);

    if (queuedRatio >= gateQueueDominantRatio / 100) {
      return '活跃发热归因 = 闸门排队主导：$queuedPct% 的走桥请求'
          '（${gate.queuedTotal}/${totalRequests}）曾因并发上限 '
          '${gate.maxConcurrent} 而排队，峰值排队 ${gate.peakWaiting} 个，'
          '平均在飞 ${avgMs}ms。CPU 主要花在「排队等待 + 唤醒 + 分块回调」上。'
          '下一步优先下调并发上限（4→3→2）或把更多只读请求分流原生栈，'
          '而不是继续优化单次传输。';
    }
    if (avgInFlight >= bridgeCostHeavyMs) {
      return '活跃发热归因 = 单请求固定税主导：闸门几乎不排队'
          '（$queuedPct%，${gate.queuedTotal}/${totalRequests}），'
          '但平均在飞 ${avgMs}ms 远超原生直连。CPU 花在每个请求的跨语言 '
          'evaluateJavascript + 分块回传固定成本上，与并发无关。'
          '下一步砍脚本体积/合并调用/减少走桥请求条数，限流无收益。';
    }
    return '活跃发热归因 = 桥非主因：闸门几乎不排队（$queuedPct%），'
        '平均在飞 ${avgMs}ms 接近原生直连水平。'
        '若活跃发热仍在，应转查渲染/图片解码/DoH 出口，而非继续优化桥。';
  }

  /// D20: 判定「闸门排队主导」的排队请求占比阈值（百分比）。
  ///
  /// 取 20：活跃刷帖时若超过五分之一的走桥请求都因闸门满而排队，
  /// 说明并发上限已是瓶颈；低于此值说明闸门基本没拦住谁，限流无收益。
  static const int gateQueueDominantRatio = 20;

  /// D21: 并发闸门「上限是否卡到活跃负载」的判据。
  ///
  /// 动机（2026-10-13 深夜重定位）：D20 的 [gateVsTaxVerdict] 用
  /// 「排队占比」判断限流值不值得做，但排队占比为 0 有两种互斥含义：
  ///   (a) 活跃期并发本就不高（桥不是瓶颈）；
  ///   (b) 并发**长期顶在上限**，闸门把洪峰削平了，于是没人排队。
  /// 两者优化方向相反：(a) 该转查渲染/解码/DoH；(b) 该继续下调上限
  /// 或把更多请求分流原生。区别只看一个量：**活跃期平均并发**
  /// （[WebViewBridgeProbe.averageActiveConcurrency]）。
  ///
  /// 判据：活跃期平均并发 ≥ 上限的 [gateSaturationRatio]（75%）即判「饱和」——
  /// 说明闸门几乎一直贴着上限跑，活跃刷帖时桥是持续并发的共享资源，
  /// 限流/分流仍有收益。
  ///
  /// 纯派生计算，只用已聚合整数与探针均值，零采样、零新增运行时开销。
  /// 返回 `null` 表示样本不足（尚无活跃期采样）。
  String? get gateSaturationVerdict {
    final gate = WebViewBridgeGate.instance;
    final probe = WebViewBridgeProbe.instance;
    final avgConcurrency = probe.averageActiveConcurrency;
    if (avgConcurrency == null) return null;
    final avg = avgConcurrency.toStringAsFixed(2);
    final cap = gate.maxConcurrent;
    final ratio = cap == 0 ? 0.0 : avgConcurrency / cap;
    final pct = (ratio * 100).round();

    if (ratio >= gateSaturationRatio) {
      return '闸门饱和度：活跃期平均并发 $avg / 上限 $cap（$pct%），'
          '已贴近上限，说明活跃刷帖时桥是**持续并发**的共享资源，'
          '闸门确实在削峰。下一步可继续下调上限（$cap→${cap - 1}→${cap - 2}）'
          '或把更多只读请求分流原生栈，观察活跃期平均并发与发热是否同步下降。';
    }
    if (ratio >= gateSaturationRatio / 2) {
      return '闸门饱和度：活跃期平均并发 $avg / 上限 $cap（$pct%），'
          '中度占用。桥有负载但未打满，限流收益有限；'
          '优先把更多只读/静态请求分流原生栈，而不是单纯下调上限。';
    }
    return '闸门饱和度：活跃期平均并发 $avg / 上限 $cap（$pct%），'
        '远未打满，说明活跃期并发本就不高，桥不是活跃发热主因'
        '（与 D20 排队占比为 0 相互印证）。应转查渲染/图片解码/DoH 出口。';
  }

  /// D21: 判定「闸门饱和」的平均并发 / 上限 比例阈值。
  ///
  /// 取 0.75：活跃期平均并发达到上限的 3/4，说明闸门几乎一直贴着上限跑；
  /// 低于此值说明桥有余量，限流不是首要靶点。
  static const double gateSaturationRatio = 0.75;

  /// D22: 「下调并发上限」是否值得做实验的合并判据。
  ///
  /// 动机（2026-10-13 深夜重定位）：D20（排队占比）与 D21（闸门饱和度）各自
  /// 只能回答一半问题，且**单独看会互相打架**：
  ///   - 排队占比高 → 说明闸门已在削峰，继续下调上限只会让排队更长；
  ///   - 饱和度低（并发远未打满）→ 说明活跃期并发本就不高，限流无收益；
  ///   - 饱和度**高**且排队占比**低** → 这才是「上限恰好卡住活跃负载」的
  ///     特征：闸门一直贴着上限跑（说明需求 ≥ 上限），但还没到大量排队
  ///     （说明上限没低到伤吞吐）。此时下调上限（4→3→2）是最有希望的
  ///     降热实验，因为每减少一个并发名额就少一条同时在飞的跨语言回传链。
  ///
  /// 本 getter 把两者合成一句**可执行**结论，避免老板在诊断页上自己对着
  /// 两个数字做推理。纯派生计算，只用已聚合整数，零采样、零新增开销。
  /// 返回 `null` 表示样本不足。
  String? get gateTuningVerdict {
    final gate = WebViewBridgeGate.instance;
    final probe = WebViewBridgeProbe.instance;
    final avgConcurrency = probe.averageActiveConcurrency;
    if (avgConcurrency == null || totalRequests < bridgeCostMinSamples) {
      return null;
    }
    final cap = gate.maxConcurrent;
    if (cap == 0) return null;
    final satRatio = avgConcurrency / cap;
    final satPct = (satRatio * 100).round();
    final queuedPct = (gate.queuedTotal * 100 / totalRequests).round();
    final satHigh = satRatio >= gateSaturationRatio;
    final queueHigh =
        gate.queuedTotal * 100 >= totalRequests * gateQueueDominantRatio;

    if (satHigh && !queueHigh) {
      return '限流实验建议：**值得做**。活跃期平均并发 '
          '${avgConcurrency.toStringAsFixed(2)}/$cap（$satPct%）已贴近上限，'
          '但排队仅 $queuedPct%（${gate.queuedTotal}/${totalRequests}）——'
          '正是「上限恰好卡住活跃负载」的特征。'
          '下一步把上限下调一档（$cap→${cap - 1}）再刷一轮，'
          '对比活跃期平均并发与发热是否同步下降；若发热明显改善则继续降到 '
          '${cap - 2}，直到排队占比明显抬升（说明已伤吞吐）为止。';
    }
    if (satHigh && queueHigh) {
      return '限流实验建议：**已过头**。活跃期平均并发 '
          '${avgConcurrency.toStringAsFixed(2)}/$cap（$satPct%）贴近上限，'
          '且排队已达 $queuedPct%（${gate.queuedTotal}/${totalRequests}）——'
          '闸门已在明显削峰，再下调上限只会让排队更长、单个请求在飞更久，'
          'CPU 花在等待/唤醒上。下一步**不要**继续降上限，'
          '改为把更多只读请求分流到原生栈（图片分流已默认开启，可再看其它静态资源）。';
    }
    if (!satHigh && queueHigh) {
      return '限流实验建议：**先查排队来源**。活跃期平均并发 '
          '${avgConcurrency.toStringAsFixed(2)}/$cap（$satPct%）未打满，'
          '却有 $queuedPct%（${gate.queuedTotal}/${totalRequests}）的请求排队——'
          '通常意味着并发是**短时突发**（洪峰瞬间挤满、均值被拉低）。'
          '下一步先看突发来源（滚动时图片/API 是否同时涌入），'
          '优先做分流而非限流。';
    }
    return '限流实验建议：**无收益**。活跃期平均并发 '
        '${avgConcurrency.toStringAsFixed(2)}/$cap（$satPct%）远未打满，'
        '排队也仅 $queuedPct%。桥在活跃期有大量余量，'
        '限流不会降低发热。下一步转查渲染/图片解码/DoH 出口，'
        '或核对同源图片分流是否被 CF 403 回退。';
  }

  /// D22: 判定「排队占比高」的阈值（百分比），与 [gateQueueDominantRatio] 同源。
  ///
  /// 复用同一常量语义：超过五分之一的请求排队即视为「闸门已在削峰」。
  static const int gateQueueHighRatio = gateQueueDominantRatio;

  /// D25: 「跨桥字节搬运税」归因——回答「该砍走桥请求条数，还是砍单请求固定税」。
  ///
  /// 动机（2026-10-13 深夜重定位）：D16~D22 全部建立在 [totalRequests] 这个
  /// **混合口径**上，但桥上有两条成本结构完全不同的路径：
  ///   (a) **文本响应**：一次 `evaluateJavascript` + 一次 `callHandler` 回传，
  ///       固定成本 ≈ 1 次跨语言往返，与请求数同阶；
  ///   (b) **二进制流响应**：`createWebMessageChannel` 建通道 + `postWebMessage`
  ///       握手 + 每个 chunk 一次 `setWebMessageCallback` 回调，固定成本
  ///       ≈ 2 + N 次跨语言往返（N = chunk 数）。
  ///
  /// 两者相差一个数量级。若活跃期走桥请求里 (b) 占主导，那么「每请求固定税」
  /// 的真实大头是**通道建立 + 分块回调**，此时：
  ///   - 砍 JS 脚本体积 → 几乎无收益（脚本只影响 (a)）；
  ///   - 把更多流请求分流到原生栈（D2 方向）→ 直接消掉整条 (b) 成本。
  ///
  /// 判据只用已聚合整数，纯派生、零采样、零新增运行时开销。返回 `null`
  /// 表示样本不足（尚无走桥请求）。
  String? get bridgeByteTaxVerdict {
    if (totalRequests < bridgeCostMinSamples) return null;
    final streamShare = binaryBridgeResponses * 100 / totalRequests;
    final streamPct = streamShare.round();
    final avgChunks = binaryBridgeResponses == 0
        ? 0
        : binaryBridgeChunks ~/ binaryBridgeResponses;
    final avgBytes = binaryBridgeResponses == 0
        ? 0
        : binaryBridgeBytes ~/ binaryBridgeResponses;
    final mb = binaryBridgeBytes / (1024 * 1024);

    if (binaryBridgeResponses == 0) {
      return '跨桥字节搬运税：本轮无二进制流走桥（$totalRequests 个走桥请求'
          '全是文本路径）。文本路径固定成本 ≈ 1 次跨语言往返/请求，'
          '此时「每请求固定税」与请求条数同阶 → 下一步优先**减少走桥请求条数**'
          '（把更多只读/静态请求分流原生），砍脚本体积收益有限。';
    }

    if (streamShare >= bridgeByteTaxStreamDominantRatio) {
      return '跨桥字节搬运税：**流路径主导**。$binaryBridgeResponses/$totalRequests'
          '（$streamPct%）的走桥请求是二进制流，共 ${mb.toStringAsFixed(2)}MB、'
          '$binaryBridgeChunks 次分块回调（平均每请求 $avgChunks 次回调 / '
          '$avgBytes B）。每次回调都是一次 JS↔native 边界穿越 + 一次 Uint8List '
          '分配，这才是活跃刷帖 CPU 峰值的直接来源。'
          '下一步优先**减少走桥的流请求条数**（继续把静态资源分流原生栈），'
          '而不是砍 JS 脚本体积。';
    }

    return '跨桥字节搬运税：**文本路径主导**。二进制流仅 '
        '$binaryBridgeResponses/$totalRequests（$streamPct%），'
        '合计 ${mb.toStringAsFixed(2)}MB / $binaryBridgeChunks 次回调。'
        '桥的固定成本主要来自「每请求一次 evaluateJavascript + 一次 '
        'callHandler 回传」，与请求条数同阶。'
        '下一步优先**减少走桥请求条数**（分流只读/静态请求），'
        '其次是合并调用/精简脚本；限流与砍传输收益都有限。';
  }

  /// D25: 判定「流路径主导」的流请求占走桥请求比例阈值（百分比）。
  ///
  /// 取 30：流路径的单请求固定成本（建通道 + 握手 + N 次回调）约为文本路径
  /// 的数倍，因此占比不到三成时其总成本已可与文本路径相当。超过 30% 即
  /// 认为「减少走桥流请求条数」是收益最高的方向。
  static const int bridgeByteTaxStreamDominantRatio = 30;

  /// D27: 因命中「分流跳过名单」而**仍走桥**的同源图片次数。
  ///
  /// 动机：D2 把同源图片整体分流原生，但个别路径可能被 CF 拦/变糊，需要
  /// 逐条豁免（[WebViewAdapterSettingsService.imageSkipPaths]）。这个计数
  /// 回答「豁免名单到底生效了几次」——若为 0 而发热仍在，说明豁免不是主因；
  /// 若很大，说明该路径的图片仍是桥负载大头。
  int imageRoutingSkipped = 0;

  /// D26: 按请求类别聚合的总桥内耗时（毫秒），用于算各类别占比。
  int get totalClassifiedMs =>
      imageSameOriginMs + imageOtherMs + apiGetMs + apiWriteMs + otherMs;

  /// D31: 各类别**闸门外排队**耗时累计（毫秒），与 [totalClassifiedMs] 配对。
  ///
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：[totalClassifiedMs] 记的是
  /// 「进桥之后」的耗时，但 D22 下调并发上限后，代价会被**前置**到 Dart 侧排队上。
  /// 只看进桥耗时，会误判「限流让桥更轻了」而忽略「请求只是挪到门外等」。
  /// 把排队耗时也按类别归因，才能判断限流到底把代价压在了哪一类请求上。
  int imageSameOriginQueueMs = 0;
  int imageOtherQueueMs = 0;
  int apiGetQueueMs = 0;
  int apiWriteQueueMs = 0;
  int otherQueueMs = 0;

  /// D31: 全部类别的排队耗时之和（毫秒）。
  int get totalQueueMs =>
      imageSameOriginQueueMs +
      imageOtherQueueMs +
      apiGetQueueMs +
      apiWriteQueueMs +
      otherQueueMs;

  /// D34: 各类别**端到端桥代价**（= 闸门外排队 + 进桥后耗时）累计（毫秒）。
  ///
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：
  /// D26 只记「进桥之后花了多久」，D31 只记「闸门外等了多久」，D33 只回答
  /// 「闸门顶在上限的时间占比」——三者都只看到桥代价的**一半**。
  /// 而「限流到底让某类请求更轻了没有」必须看**端到端**：
  /// 一条图片请求可能「进桥只花 50ms」但「在门外等了 400ms」，
  /// 只看进桥耗时就会误判「图片已经不是瓶颈」，从而错误地把优化方向
  /// 从分流切到别处。
  ///
  /// 本组计数在请求**完全结束**时把两类数据相加落一次（见适配器侧
  /// `_recordClassEndToEnd`），因此是「每完成一条请求记一笔」，
  /// 与 [totalClassifiedMs] / [totalQueueMs] 的累加口径一致，
  /// 三者可直接相减交叉验证（端到端 ≈ 进桥 + 排队）。
  /// 纯整数累加，零采样、零新增运行时开销；不记录 URL / Headers / 正文。
  int imageSameOriginTotalMs = 0;
  int imageOtherTotalMs = 0;
  int apiGetTotalMs = 0;
  int apiWriteTotalMs = 0;
  int otherTotalMs = 0;

  /// D34: 各类别**端到端桥代价**之和（毫秒）。
  int get totalEndToEndMs =>
      imageSameOriginTotalMs +
      imageOtherTotalMs +
      apiGetTotalMs +
      apiWriteTotalMs +
      otherTotalMs;

  /// D34: 端到端代价里「排队占比」（0~100 的整数百分比）；无样本返回 null。
  ///
  /// 这是「限流把代价前置了多少」的直接数字：占比高说明请求主要卡在门外，
  /// 降低上限只会继续把它往后压；占比低说明桥内本身是瓶颈。
  int? get queueShareOfEndToEndPct {
    final total = totalEndToEndMs;
    if (total <= 0) return null;
    return (totalQueueMs * 100 / total).round();
  }

  /// D34: 各类别「端到端桥代价」速判——回答「活跃期桥代价由谁贡献」。
  ///
  /// 动机：D26/D31/D32/D33 分别回答了「进桥多久」「门外等多久」「三段怎么分」
  /// 「闸门饱和多久」，但**没有把类别与端到端代价合起来**。活跃刷帖发热时，
  /// 最需要的是一句可执行结论：桥代价主要压在图片上还是 API 上？
  /// 压图片 → 继续分流原生（D2/D19）；压 API → 合并调用/降条数/减少轮询；
  /// 两者都不突出 → 桥不是主因，转查桥外（渲染/图片解码/DoH 出口）。
  ///
  /// 判据只用已聚合整数，纯派生、零采样、零新增运行时开销。返回 `null`
  /// 表示样本不足。
  String? get endToEndAttributionVerdict {
    final total = totalEndToEndMs;
    if (total <= 0) return null;
    final imageMs = imageSameOriginTotalMs + imageOtherTotalMs;
    final imagePct = (imageMs * 100 / total).round();
    final apiMs = apiGetTotalMs + apiWriteTotalMs;
    final apiPct = (apiMs * 100 / total).round();
    final queuePct = queueShareOfEndToEndPct ?? 0;
    final head =
        '端到端桥代价归因（D34）：合计 $total ms，'
        '图片 $imageMs ms（$imagePct%）、API $apiMs ms（$apiPct%）、'
        '其它 $otherTotalMs ms；其中闸门外排队占 $queuePct%。';

    if (imagePct >= 50) {
      return '$head **代价压在图片上**——图片是活跃刷帖的主要桥负载，'
          '下一步继续把同源图片分流原生栈（D2/D19），'
          '或用跳过名单（D27）先豁免大图路径。';
    }
    if (apiPct >= 50) {
      return '$head **代价压在 API 上**——图片分流已见效，'
          '瓶颈转为 API 请求条数/单请求固定税；'
          '下一步合并调用、降轮询频率或减少走桥条数（D16/D17）。';
    }
    return '$head 图片与 API **均不突出**——桥代价分散，'
        '说明活跃发热可能不在桥内；转查桥外因素'
        '（列表渲染/图片解码/DoH 出口/CF 刷新重建）。';
  }

  /// D32: 按请求类别拆出的三段桥内耗时——cookie 准备 / JS 调用 / 等浏览器。
  ///
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：
  /// D31 把「闸门外排队」按类别归因了，但**进桥之后**的耗时仍只有一个总数
  /// （[imageSameOriginMs] 等）。而 D17 已把单请求耗时拆成「cookie准备 /
  /// JS调用 / 等浏览器」三段，只是**没按类别分开**——于是无法回答：
  /// 图片类走桥请求的 CPU 时间到底花在「拼 JS 脚本 + evaluateJavascript」
  /// 还是「等 WebKit 网络返回」？前者是纯 CPU（可优化：脚本瘦身/复用），
  /// 后者是 I/O 等待（优化手段完全不同：降并发或换原生栈）。
  ///
  /// 三段口径与 [cookiePrepMs] / [jsEvalMs] / [browserWaitMs] 完全一致，
  /// 只是按类别各存一份。纯整数累加，零采样、零新增运行时开销。
  int imageSameOriginCookieMs = 0;
  int imageSameOriginJsMs = 0;
  int imageSameOriginBrowserMs = 0;
  int imageOtherCookieMs = 0;
  int imageOtherJsMs = 0;
  int imageOtherBrowserMs = 0;
  int apiGetCookieMs = 0;
  int apiGetJsMs = 0;
  int apiGetBrowserMs = 0;
  int apiWriteCookieMs = 0;
  int apiWriteJsMs = 0;
  int apiWriteBrowserMs = 0;
  int otherCookieMs = 0;
  int otherJsMs = 0;
  int otherBrowserMs = 0;

  /// D32: 全部类别的「cookie 准备」耗时之和（毫秒）。
  int get totalClassifiedCookieMs =>
      imageSameOriginCookieMs +
      imageOtherCookieMs +
      apiGetCookieMs +
      apiWriteCookieMs +
      otherCookieMs;

  /// D32: 全部类别的「JS 调用」耗时之和（毫秒）——即纯 CPU 侧固定税。
  int get totalClassifiedJsMs =>
      imageSameOriginJsMs +
      imageOtherJsMs +
      apiGetJsMs +
      apiWriteJsMs +
      otherJsMs;

  /// D32: 全部类别的「等浏览器」耗时之和（毫秒）——即 I/O 等待。
  int get totalClassifiedBrowserMs =>
      imageSameOriginBrowserMs +
      imageOtherBrowserMs +
      apiGetBrowserMs +
      apiWriteBrowserMs +
      otherBrowserMs;

  /// D32: 「活跃发热的 CPU 时间到底花在哪一段」——把桥内耗时按
  /// 「cookie准备 / JS调用 / 等浏览器」三段拆开，给出可执行靶点。
  ///
  /// 动机（2026-10-13 深夜重定位）：D26 回答「哪一类请求吃掉了桥时间」，
  /// D31 回答「排队代价压在谁身上」，但都还没回答**这一段时间是 CPU 还是等待**。
  /// 这决定优化方向：
  ///   - **JS 调用段主导** → 是纯 CPU（拼脚本 + evaluateJavascript + 回传解码），
  ///     下一步走脚本瘦身（D18 方向）、减少跨桥条数、复用 Stream bridge；
  ///   - **等浏览器段主导** → 是 WebKit 网络/渲染 I/O 等待，桥本身不是 CPU 源，
  ///     下一步应降并发或把该类请求分流原生栈，而不是继续抠脚本；
  ///   - **cookie 准备段主导** → 是 WKHTTPCookieStore 往返，下一步继续砍
  ///     边界同步频率（D9 方向）。
  ///
  /// 判据只用已聚合整数，纯派生、零采样、零新增运行时开销。返回 `null`
  /// 表示样本不足（尚无走桥请求或三段全为 0）。
  String? get classPhaseVerdict {
    if (totalRequests < bridgeCostMinSamples) return null;
    final cookie = totalClassifiedCookieMs;
    final js = totalClassifiedJsMs;
    final browser = totalClassifiedBrowserMs;
    final total = cookie + js + browser;
    if (total <= 0) return null;

    int pct(int ms) => (ms * 100 / total).round();
    final cookiePct = pct(cookie);
    final jsPct = pct(js);
    final browserPct = pct(browser);
    final head =
        '桥内分段归因（D32）：cookie准备 $cookie ms（$cookiePct%）、'
        'JS调用 $js ms（$jsPct%）、等浏览器 $browser ms（$browserPct%）。';

    if (jsPct >= 50) {
      return '$head **JS 调用段主导**——这是纯 CPU 固定税'
          '（拼脚本 + evaluateJavascript + 回传解码），'
          '下一步走脚本瘦身（D18 方向）、减少跨桥条数、'
          '复用 Stream bridge 避免 base64 fallback。';
    }
    if (browserPct >= 50) {
      return '$head **等浏览器段主导**——桥本身不是 CPU 源，'
          '时间花在 WebKit 网络/渲染 I/O 上，'
          '下一步应降该类并发或把该类请求分流原生栈（D2 方向），'
          '继续抠脚本收益有限。';
    }
    if (cookiePct >= 50) {
      return '$head **cookie 准备段主导**——时间花在 WKHTTPCookieStore 往返上，'
          '下一步继续砍边界同步频率（D9 方向）或按需同步。';
    }
    return '$head 三段分散，没有单一段主导，'
        '桥内耗时结构均衡，可按占比从高到低依次优化。';
  }

  /// D32: 图片类「JS 调用段」耗时（纯 CPU 侧），供诊断页细看。
  ///
  /// 便于回答「图片类的 CPU 税 vs API 类的 CPU 税各占多少」，
  /// 与 [classPhaseVerdict] 的整体判据互补。
  int get imageJsMs => imageSameOriginJsMs + imageOtherJsMs;

  /// D32: 图片类「等浏览器」耗时（I/O），与 [imageJsMs] 配对。
  int get imageBrowserMs => imageSameOriginBrowserMs + imageOtherBrowserMs;

  /// D33: 「闸门饱和时间占比」速判——回答「限流到底削掉了多少并发洪峰」。
  ///
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：D20/D21/D22 用
  /// 「排队条数占比」与「采样平均并发」判断限流值不值得做，但两者都会被
  /// 活跃期「脉冲式满/空」抹平——一条请求在闸门外等 300ms，这 300ms 里
  /// 闸门一直是满的，而均值看不出来。本判据直接给「闸门顶在上限的时间
  /// 占比」，这才是限流真实生效强度的证据，也是决定「继续下调上限 vs
  /// 回退上限」的最后一块拼图。
  ///
  /// 判据只用闸门已聚合的整数（[WebViewBridgeGate.saturatedMs] 等），
  /// 纯派生、零采样、零新增运行时开销。返回 `null` 表示尚无观测样本。
  String? get gateSaturationTimeVerdict {
    final gate = WebViewBridgeGate.instance;
    final pct = gate.saturationPct;
    if (pct == null) return null;
    final saturated = gate.saturatedMs;
    final observed = gate.observedMs;
    final head = '闸门饱和时间占比（D33）：$pct%（饱和 $saturated ms / 观测 $observed ms）。';

    if (pct >= 70) {
      return '$head **闸门长期顶在上限**——限流确实在削峰，'
          '但同时也说明走桥请求的供给远超上限，活跃期桥被持续打满。'
          '下一步优先**继续把同源图片分流原生**（D2/D19）或减少走桥条数，'
          '而不是再下调上限（下调只会把更多请求压在队列里）。';
    }
    if (pct >= 30) {
      return '$head 闸门**间歇性饱和**——活跃期有洪峰但未长期顶格，'
          '当前上限大致匹配负载。若活跃发热仍在，'
          '重点转向单请求固定税（D16/D17/D32）而非并发数。';
    }
    return '$head 闸门**基本不饱和**——并发上限不是瓶颈，'
        '限流对发热几乎没有贡献，可考虑回退上限以降低排队延迟；'
        '活跃发热应转向单请求成本（脚本/回传）或桥外因素'
        '（渲染/图片解码/DoH 出口）。';
  }

  /// D31: 「限流代价压在谁身上」——按类别归因闸门外排队耗时，给出可执行靶点。
  ///
  /// 动机（2026-10-13 深夜重定位）：D13/D28 的闸门与权重是**纯 Dart 侧排队**，
  /// 不阻塞 JS，但排队本身仍要付出代价（请求更晚开始、在飞更久、内存驻留更久）。
  /// D22 只回答「该不该继续下调上限」，本判据回答「下调的代价落在谁头上」：
  ///   - 代价压在**同源图片**上 → 说明图片权重 2 仍不够狠，下一步继续把图片
  ///     分流原生栈（D2），而不是再降上限；
  ///   - 代价压在 **API 读**上 → 说明限流已经开始伤交互请求（帖子列表/详情
  ///     变慢），应回退上限或改为合并 API 调用；
  ///   - 排队耗时占比很低 → 限流代价可忽略，可继续按 D22 建议下调上限。
  ///
  /// 判据只用已聚合整数，纯派生、零采样、零新增运行时开销。返回 `null`
  /// 表示样本不足（尚无排队）。
  String? get queueAttributionVerdict {
    final total = totalQueueMs;
    if (total <= 0) return null;
    final gate = WebViewBridgeGate.instance;
    final imageMs = imageSameOriginQueueMs + imageOtherQueueMs;
    final imagePct = (imageMs * 100 / total).round();
    final apiGetPct = (apiGetQueueMs * 100 / total).round();
    final apiWritePct = (apiWriteQueueMs * 100 / total).round();
    final avgWait = gate.queuedTotal == 0 ? 0 : total ~/ gate.queuedTotal;

    if (imagePct >= 50) {
      return '限流代价归因（D31）：**压在图片上**——闸门外排队 '
          '$total ms，其中图片 $imageMs ms（$imagePct%），'
          'API 读 $apiGetQueueMs ms（$apiGetPct%）、写 $apiWriteQueueMs ms'
          '（$apiWritePct%）；平均每请求等待 $avgWait ms。'
          '说明图片权重 ${WebViewBridgeGate.imageWeight} 仍不够狠，'
          '下一步继续把同源图片分流原生栈（D2），而不是再下调上限。';
    }
    if (apiGetPct >= 50) {
      return '限流代价归因（D31）：**压在 API 读上**——闸门外排队 '
          '$total ms，其中 API 读 $apiGetQueueMs ms（$apiGetPct%），'
          '图片 $imageMs ms（$imagePct%）；平均每请求等待 $avgWait ms。'
          '限流已开始伤交互请求（列表/详情变慢），'
          '下一步应回退并发上限或改为合并 API 调用，而不是继续降上限。';
    }
    if (apiWritePct >= 50) {
      return '限流代价归因（D31）：**压在写请求上**——闸门外排队 '
          '$total ms，其中写 $apiWriteQueueMs ms（$apiWritePct%）；'
          '平均每请求等待 $avgWait ms。写请求必须过桥（借浏览器指纹提交），'
          '排队会直接拖慢点赞/回复等交互，'
          '下一步优先给写请求更高优先级（插队）或提高上限。';
    }
    return '限流代价归因（D31）：**分散**——闸门外排队共 $total ms'
        '（图片 $imageMs ms/$imagePct%、API 读 $apiGetQueueMs ms/$apiGetPct%、'
        '写 $apiWriteQueueMs ms/$apiWritePct%），平均每请求等待 $avgWait ms。'
        '没有单一类别被明显拖累，限流代价可接受，'
        '可按 D22 建议继续微调上限或推进分流。';
  }

  /// D26: 活跃发热「按请求类别归因」——直接回答「哪一类走桥请求吃掉了桥的
  /// 大部分 CPU 时间」，给出下一步该砍哪一类的可执行靶点。
  ///
  /// 动机（2026-10-13 深夜重定位）：D25 把负载拆成「流路径 vs 文本路径」，
  /// 但那是**传输形态**维度；老板要判的是**请求类别**维度（图片 / API 读 /
  /// 写 / 其他），两者正交。例如「流路径主导」既可能因为图片多（分流图片即可），
  /// 也可能因为 API 返回大 JSON（分流图片没用）。本判据把每请求耗时按类别累加，
  /// 用「耗时占比」而非「条数占比」定靶——因为发热由 CPU 时间决定，不由条数决定。
  ///
  /// 判据只用已聚合整数，纯派生、零采样、零新增运行时开销。返回 `null`
  /// 表示样本不足（尚无走桥请求或耗时全为 0）。
  String? get classTimeVerdict {
    if (totalRequests < bridgeCostMinSamples) return null;
    final total = totalClassifiedMs;
    if (total <= 0) return null;

    int pct(int ms) => (ms * 100 / total).round();
    final imageMs = imageSameOriginMs + imageOtherMs;
    final imagePct = pct(imageMs);
    final apiGetPct = pct(apiGetMs);
    final apiWritePct = pct(apiWriteMs);

    // 单类别耗时占比过半即认定为「主导类别」，靶点明确。
    if (imagePct >= 50) {
      return '类别耗时归因（D26）：**图片主导**——同源图片走桥耗时 $imageMs ms'
          '（$imagePct%），API 读 $apiGetMs ms（$apiGetPct%）、写 $apiWriteMs ms'
          '（$apiWritePct%）。图片是活跃刷帖 CPU 时间的主要来源，'
          '下一步优先把更多图片请求分流到原生栈（D2 方向），'
          '或对同源图片降并发以削峰。';
    }
    if (apiGetPct >= 50) {
      return '类别耗时归因（D26）：**API 读主导**——API 读请求走桥耗时 $apiGetMs ms'
          '（$apiGetPct%），图片 $imageMs ms（$imagePct%）、写 $apiWriteMs ms'
          '（$apiWritePct%）。发热主要来自 API 读请求的桥固定税（拼脚本 + '
          'evaluateJavascript + 回传），分流图片收益有限，'
          '下一步优先减少 API 读的走桥条数（只读请求改原生）或合并调用。';
    }
    if (apiWritePct >= 50) {
      return '类别耗时归因（D26）：**写请求主导**——写请求走桥耗时 $apiWriteMs ms'
          '（$apiWritePct%）。写请求必须过桥（借浏览器指纹提交），'
          '下一步只能降单请求成本：复用 Stream bridge 避免 base64 fallback、'
          '精简请求体序列化。';
    }
    return '类别耗时归因（D26）：**无单一主导类别**——图片 $imageMs ms'
        '（$imagePct%）、API 读 $apiGetMs ms（$apiGetPct%）、'
        '写 $apiWriteMs ms（$apiWritePct%）、其他 $otherMs ms'
        '（${pct(otherMs)}%）。桥负载分散，'
        '下一步按占比从高到低依次分流，或整体降并发上限削峰。';
  }

  void reset() {
    imageSameOrigin = 0;
    imageOther = 0;
    apiGet = 0;
    apiWrite = 0;
    other = 0;
    imageSameOriginMs = 0;
    imageOtherMs = 0;
    apiGetMs = 0;
    apiWriteMs = 0;
    otherMs = 0;
    imageSameOriginQueueMs = 0;
    imageOtherQueueMs = 0;
    apiGetQueueMs = 0;
    apiWriteQueueMs = 0;
    otherQueueMs = 0;
    // D34: 端到端桥代价一并清零，保证「端到端 ≈ 进桥 + 排队」的交叉验证
    // 在重置后仍然成立。
    imageSameOriginTotalMs = 0;
    imageOtherTotalMs = 0;
    apiGetTotalMs = 0;
    apiWriteTotalMs = 0;
    otherTotalMs = 0;
    imageSameOriginCookieMs = 0;
    imageSameOriginJsMs = 0;
    imageSameOriginBrowserMs = 0;
    imageOtherCookieMs = 0;
    imageOtherJsMs = 0;
    imageOtherBrowserMs = 0;
    apiGetCookieMs = 0;
    apiGetJsMs = 0;
    apiGetBrowserMs = 0;
    apiWriteCookieMs = 0;
    apiWriteJsMs = 0;
    apiWriteBrowserMs = 0;
    otherCookieMs = 0;
    otherJsMs = 0;
    otherBrowserMs = 0;
    textResponses = 0;
    textResponseBytes = 0;
    streamResponses = 0;
    streamResponseBytes = 0;
    imageResponseBytes = 0;
    binaryBridgeResponses = 0;
    binaryBridgeBytes = 0;
    binaryBridgeChunks = 0;
    streamRawChunks = 0;
    streamCoalescedMessages = 0;
    requestBodyBase64 = 0;
    requestBodyStreamBridge = 0;
    requestBodyDirect = 0;
    totalMs = 0;
    jsEvalMs = 0;
    cookiePrepMs = 0;
    browserWaitMs = 0;
    cookieBackSyncMs = 0;
    failed = 0;
    cookieSweeps = 0;
    cookieSweepsSkipped = 0;
    cookieBatchCountCalls = 0;
    cookieBatchCountNames = 0;
    imageRoutedNative = 0;
    imageRoutingSkipped = 0;
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
