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
  }
}
