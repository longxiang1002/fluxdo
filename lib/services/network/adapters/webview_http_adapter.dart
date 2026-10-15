import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../constants.dart';
import '../../../utils/frame_jank_monitor.dart';
import '../../auth_session.dart';
import '../cookie/app_cookie_manager.dart';
import '../cookie/boundary_sync_service.dart';
import '../cookie/cookie_jar_service.dart';
import '../cookie/session_cookie_sentinel.dart';
import '../cookie/webview_cookie_priming.dart';
import '../../webview_settings.dart';
import '../../windows_webview_environment_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import 'adapter_log_metadata.dart';
import 'webview_bridge_diagnostics.dart';
import 'webview_bridge_gate.dart';
import 'webview_bridge_probe.dart';

/// WebView HTTP 适配器
///
/// 使用 InAppWebView 的 JS fetch() 发起 HTTP 请求。
/// 请求经过真正的 Chrome/WebKit 内核，TLS 指纹与浏览器完全一致，
/// 可绕过 Cloudflare Bot Management 等基于指纹的检测。
///
/// 全平台支持：Android (Chrome WebView)、iOS/macOS (WKWebView)、
/// Windows (WebView2)、Linux (WebKitGTK)。
class WebViewHttpAdapter implements HttpClientAdapter {
  static const Set<String> _forbiddenBrowserHeaders = {
    'accept-charset',
    'accept-encoding',
    'access-control-request-headers',
    'access-control-request-method',
    'connection',
    'content-length',
    'cookie',
    'cookie2',
    'date',
    'dnt',
    'expect',
    'host',
    'keep-alive',
    'origin',
    'referer',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'user-agent',
    'via',
  };
  @visibleForTesting
  static const String fetchCacheModeExtraKey = 'webViewFetchCacheMode';
  static const String resourceKindExtraKey = 'webViewResourceKind';
  static const String cookieModeExtraKey = 'webViewCookieMode';
  static const String resourceKindImage = 'image';
  static const String resourceKindUpload = 'upload';
  static const String cookieModeReadOnly = 'readOnly';
  static const String cookieModeNone = 'none';
  static const Set<String> _supportedFetchCacheModes = {
    'default',
    'no-store',
    'reload',
    'no-cache',
    'force-cache',
    'only-if-cached',
  };
  @visibleForTesting
  static const String defaultApiFetchCacheMode = 'no-store';
  HeadlessInAppWebView? _headlessWebView;
  InAppWebViewController? _controller;
  bool _isInitialized = false;
  Completer<void>? _initCompleter;
  Future<void>? _activeCriticalCookieSync;
  DateTime? _lastCriticalCookieSyncAt;

  /// 文本响应的待决请求：handler 里已把 JS 传来的对象解析成 Map，
  /// 这里直接携带 Map，调用方不再二次 `jsonDecode`（D5）。
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  int _requestId = 0;
  int _activeFetches = 0;
  bool _disposeWhenIdle = false;

  /// 初始化 WebView
  Future<void> initialize() async {
    if (_isInitialized && _controller != null) return;
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      await _initCompleter!.future;
      return;
    }

    final initCompleter = Completer<void>();
    _initCompleter = initCompleter;
    var pageLoadCompleter = Completer<void>();
    final initWatch = Stopwatch()..start();

    try {
      _headlessWebView = HeadlessInAppWebView(
        // Windows 需要 WebView2 环境，其他平台传 null
        webViewEnvironment: Platform.isWindows
            ? WindowsWebViewEnvironmentService.instance.environment
            : null,
        initialSettings: WebViewSettings.headless,
        initialUserScripts: WebViewSettings.compatPolyfillScripts,
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onWebViewCreated: (controller) {
          _controller = controller;
          WebViewSettings.applyWindowsHeadlessMemoryTarget(controller);
          WebViewSettings.registerJsErrorReporter(controller);

          controller.addJavaScriptHandler(
            handlerName: 'fetchResult',
            callback: (args) {
              if (args.isNotEmpty && args[0] is Map) {
                final data = args[0] as Map;
                final requestId = data['requestId']?.toString();
                if (requestId == null ||
                    !_pendingRequests.containsKey(requestId)) {
                  return;
                }
                // D5: 新形态把响应元数据与 body 作为**平级字段**传回，
                // 插件只会 JSON 序列化一次，body 不再被二次转义/反转义。
                // 旧形态把整个响应塞进 `result` 字符串，这里保留兜底解析，
                // 以便与未更新的 JS（如缓存中的旧页面）兼容。
                final Map<String, dynamic> parsed;
                if (data.containsKey('body') || data.containsKey('ok')) {
                  parsed = <String, dynamic>{
                    'ok': data['ok'],
                    'status': data['status'],
                    'statusText': data['statusText'],
                    'headers': data['headers'],
                    'body': data['body'],
                    'error': data['error'],
                  };
                } else {
                  final result = data['result']?.toString() ?? '';
                  parsed = result.isEmpty
                      ? <String, dynamic>{'ok': false, 'error': 'empty result'}
                      : (jsonDecode(result) as Map).cast<String, dynamic>();
                }
                _pendingRequests[requestId]!.complete(parsed);
                _pendingRequests.remove(requestId);
              }
            },
          );

          debugPrint('[WebViewAdapter] Controller created');
        },
        onLoadStop: (controller, url) {
          debugPrint('[WebViewAdapter] Page loaded: $url');
          if (!pageLoadCompleter.isCompleted) {
            pageLoadCompleter.complete();
          }
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame != false &&
              !pageLoadCompleter.isCompleted) {
            pageLoadCompleter.completeError(
              StateError(
                'WebView init failed: ${error.type} ${error.description}',
              ),
            );
          }
        },
      );

      await _headlessWebView!.run();
      final controller = _headlessWebView!.webViewController;
      if (controller == null) {
        throw StateError('Headless WebView controller is null');
      }

      pageLoadCompleter = Completer<void>();
      if (Platform.isWindows) {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(_windowsBootstrapUrl)),
        );
      } else {
        await controller.loadData(
          data: _bootstrapHtml,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }

      await pageLoadCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('WebView init timeout');
        },
      );

      if (Platform.isWindows) {
        await _writeBootstrapHtml(controller);
      }

      // D18: 把「与具体请求无关」的 JS 辅助函数（abort 控制器表 + abort 函数）
      // 在 WebView 就绪时一次性装好。改前每个走桥请求的脚本里都要重新声明
      // 一遍 `window.__fluxdoFetchAborters` / `window.__fluxdoAbortFetch`，
      // 这些声明与请求无关、且幂等；活跃刷帖时每请求多解析一段脚本，
      // 直接抬高 D17 里「JS 调用」那一段的固定税。装一次即可，语义不变。
      // 装失败不阻断初始化：请求脚本只保留 `|| {}` 兜底，abort 退化为 no-op
      // （_abortWebViewFetch 本就有存在性守卫），不影响响应正确性。
      await _installFetchHelpers(controller);

      _isInitialized = true;
      if (!initCompleter.isCompleted) {
        initCompleter.complete();
      }
      initWatch.stop();
      debugPrint(
        '[WebViewAdapter] Initialized (${initWatch.elapsedMilliseconds}ms)',
      );
      // WebView 创建占用平台主线程,与掉帧时间轴对齐归因
      FrameJankMonitor.logEvent(
        'WEBVIEW',
        'HttpAdapter init ${initWatch.elapsedMilliseconds}ms',
      );
    } catch (e) {
      debugPrint('[WebViewAdapter] Init failed: $e');
      if (!initCompleter.isCompleted) {
        initCompleter.completeError(e);
      }
      close(force: true);
      rethrow;
    } finally {
      if (identical(_initCompleter, initCompleter) && !_isInitialized) {
        _initCompleter = null;
      }
    }
  }

  Future<void> _writeBootstrapHtml(InAppWebViewController controller) async {
    final html = jsonEncode(_bootstrapHtml);
    await controller.evaluateJavascript(
      source:
          '''
document.open();
document.write($html);
document.close();
''',
    );
  }

  /// D18: 一次性安装与请求无关的 JS 辅助函数。
  ///
  /// 只装「abort 控制器表」与「abort 函数」——它们此前被内联在每个走桥
  /// 请求的脚本里重复声明（幂等但每次都要重新解析）。装到 window 上后，
  /// 每个请求脚本只需 `window.__fluxdoFetchAborters[id] = controller`。
  ///
  /// 与请求行为无关、不触碰任何 WebView 挂起/暂停 API，也不改变 fetch
  /// 语义（cookie/凭据/CF 指纹路径完全不变）。安装失败只记日志：请求脚本
  /// 仍带 `|| {}` 兜底，abort 退化为 no-op，不会白屏。
  Future<void> _installFetchHelpers(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: '''
        (function() {
          window.__fluxdoFetchAborters = window.__fluxdoFetchAborters || {};
          window.__fluxdoAbortFetch = window.__fluxdoAbortFetch || function(id) {
            const controller = window.__fluxdoFetchAborters && window.__fluxdoFetchAborters[id];
            if (controller) {
              controller.abort();
              delete window.__fluxdoFetchAborters[id];
            }
          };
        })();
      ''',
      );
    } catch (e) {
      debugPrint('[WebViewAdapter] fetch helper install failed: $e');
    }
  }

  String get _windowsBootstrapUrl => '${AppConstants.baseUrl}/robots.txt';

  String get _bootstrapHtml =>
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body></body></html>';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    setRequestAdapterLogName(options, 'webview');
    _activeFetches++;
    // D26: 先给这条请求定类别——既用于结束时的桥内耗时归因，也用于
    // D31 的「排队等待」归因（排队发生在 acquire 里，必须先有类别）。
    // 分类只读请求元数据，不解析 URL 内容、不触碰 WebView，零额外开销。
    final requestUri = options.uri;
    final requestClass = _recordBridgeRequestKind(
      options,
      requestUri,
      options.method.toUpperCase(),
    );
    // D13: 桥并发闸门——超出上限的请求在 Dart 侧排队，避免一起涌进单条 JS 线程。
    // 等待只发生在 Dart 的 Completer 队列上，不触碰任何 WebView 挂起/暂停 API。
    // D28: 图片类走桥请求按 imageWeight 占槽位——它响应体大、分块回调多、
    // 在飞时间长，给它更高权重可让「同时在飞的大图数」自然下降，削平
    // 活跃滚动期的 CPU 峰值（仍是纯 Dart 侧排队，不阻塞 JS）。
    final gateWeight = _isImageRequest(options)
        ? WebViewBridgeGate.imageWeight
        : 1;
    // D31: 排队等待按类别归因——把「这次在闸门外等了多久」记到本请求的类别上。
    // 回调在闸门放行时同步触发（就在 acquire 的 Future 完成之前），
    // 因此这里捕获的 requestClass 一定是本请求自己的类别。
    final gate = WebViewBridgeGate.instance;
    gate.onQueueWait = (int waitedMs) =>
        _recordClassQueueWait(requestClass, waitedMs);
    await gate.acquire(weight: gateWeight);
    // D31: 归因回调只服务于「本请求排队」这一件事，用完立刻摘掉，
    // 避免它在下一次别的请求排队时被误触发。
    gate.onQueueWait = null;
    // D12: 活跃期并发/耗时探针（只计数，不改行为）。
    WebViewBridgeProbe.instance.onRequestStart();

    final totalWatch = Stopwatch()..start();
    Duration? cookiePrepElapsed;
    Duration? jsEvalElapsed;
    Duration? browserWaitElapsed;
    Duration? cookieBackSyncElapsed;

    try {
      if (!_isInitialized || _controller == null) {
        await initialize();
      }

      if (_controller == null) {
        throw DioException(
          requestOptions: options,
          error: 'WebView controller not available',
          type: DioExceptionType.unknown,
        );
      }

      final url = options.uri.toString();
      final method = options.method.toUpperCase();
      final requestId = (++_requestId).toString();
      // D31: requestUri 已在 fetch 开头算过（排队归因需要），此处复用。
      final baseUri = Uri.parse(AppConstants.baseUrl);
      final shouldSyncAppCookies = _shouldSyncAppCookies(requestUri, baseUri);
      final cookieMode = _resolveCookieMode(options, shouldSyncAppCookies);
      final syncAppCookies = cookieMode == _WebViewCookieMode.sync;
      final prepareAppCookies = cookieMode != _WebViewCookieMode.none;
      // D8: 同源静态图片（只读 cookie 模式）不需要「写回同步」语义，只需
      // 一次轻量 prime 让 WV 拿到 jar 的 cookie 即可。改前这些请求每次都要
      // 跑一遍完整 prepareAppCookies（prime + sweepAll），而 sweepAll 是
      // O(cookie 数) 次原生 method channel 往返——活跃刷帖时图片请求占桥
      // 负载大头，这是被平白背上的固定开销。这里让只读模式走轻量路径。
      final isReadOnlyImageRequest =
          cookieMode == _WebViewCookieMode.readOnly &&
          options.extra[resourceKindExtraKey]?.toString() == resourceKindImage;
      final wantsBinaryStream =
          options.responseType == ResponseType.stream ||
          options.responseType == ResponseType.bytes;

      // D1: 桥开销归因。仅整数累加，不发散存储、不写日志，激活态开销可忽略。
      final bridgeStats = WebViewBridgeDiagnostics.instance;
      // D26: 请求类别已在 fetch 开头确定（D31 排队归因需要），此处不再重复分类。

      if (prepareAppCookies) {
        // v0.4.0: 取代 RawSetCookieQueue.flush + _repair + _syncCookiesFromJar
        // 1. Priming: 确保 WV 中 jar 的 critical cookies 已就绪
        // 2. sweepAll: 清理 critical cookies 的多变体 (兜底)
        // 3. mark as path B: 让 onResponse 走路径 B 处理 (跳过 jar 写入,
        //    sweep 反向同步)
        final cookiePrepWatch = Stopwatch()..start();
        try {
          // D8: 只读图片请求走轻量 prime——prime() 自身幂等（已 prime 直接
          // 短路），且不需要紧随其后的 sweepAll 边界清理。图片只读 cookie，
          // 不会往 WV 侧写 cookie，因此不存在「变体清理」的需求；改前每次
          // 图片请求都白跑一遍 sweepAll 的 O(cookie 数) 原生往返。
          await WebViewCookiePriming.instance.prime(url);
        } catch (e) {
          debugPrint('[WebViewAdapter] priming failed (continuing): $e');
        }
        if (syncAppCookies) {
          // D2: 仅在「本 WebView 会话尚未做过边界同步」或「WV 自上次同步后又
          // 写过 cookie」时才跑 sweepAll。sweepAll 是 O(cookie 数) 次原生
          // method channel 往返（每 name 3 次），活跃刷帖时每个请求都跑一遍
          // 是纯浪费——prime() 幂等保证 jar→WV 已经就绪，sweep 只负责
          // 清 WV 侧多出来的变体，而变体只可能来自 WV 自身写入。
          // D4: 若 WV 侧 cookie 变化正「待收敛」（CookieStoreObserver 已收到
          // 变化、其 500ms debounce 尚未到期），则**不在本请求路径上**同步
          // sweep——变化由 debounce 在请求路径之外统一收敛，本请求直接用
          // 已就绪的 cookie 集。这样刷帖时 CF 持续下发 cookie 不再让每个
          // 请求都背一次边界同步。
          if (!bridgeStats.cookieBoundarySynced) {
            if (bridgeStats.cookieResyncPending) {
              bridgeStats.cookieSweepsDeferred++;
            } else {
              await SessionCookieSentinel.instance.sweepAll(url);
              bridgeStats.cookieBoundarySynced = true;
              bridgeStats.cookieSweeps++;
            }
          } else {
            bridgeStats.cookieSweepsSkipped++;
          }
        } else if (isReadOnlyImageRequest) {
          // D8: 只读图片请求不跑 sweepAll（省下 O(cookie 数) 原生往返）。
          bridgeStats.cookieSweepsSkippedForImage++;
        }
        cookiePrepWatch.stop();
        cookiePrepElapsed = cookiePrepWatch.elapsed;
        if (syncAppCookies) {
          AppCookieManager.markAsWebViewAdapter(options);
        }
      }

      // 非应用站点的备选路径：通过 CookieManager 写入 cookie
      final cookieHeader = options.headers['Cookie']?.toString();
      if (cookieMode == _WebViewCookieMode.none &&
          cookieHeader != null &&
          cookieHeader.isNotEmpty) {
        await _syncCookiesViaCookieManager(url, cookieHeader);
      }

      // 构建 headers（移除 Cookie，由 WebView 自动处理）
      final headersMap = _buildBrowserSafeHeaders(options.headers);
      final fetchCacheMode = resolveFetchCacheMode(options);
      if (fetchCacheMode != null) {
        _setNetworkLogField(options, 'webViewCacheMode', fetchCacheMode);
      }

      // 构建 body
      final bodyPlan = await _buildRequestBodyPlan(
        options,
        requestStream,
        method: method,
        requestId: requestId,
        requestUri: requestUri,
      );
      final bodyScript = bodyPlan.script;
      _recordBridgeBodyShape(bridgeStats, bodyPlan.shape);

      if (wantsBinaryStream) {
        final response = await _fetchBinaryStreamResponse(
          options,
          requestClass: requestClass,
          requestId: requestId,
          method: method,
          url: url,
          headersMap: headersMap,
          bodyScript: bodyScript,
          fetchCacheMode: fetchCacheMode,
          cancelFuture: cancelFuture,
          totalWatch: totalWatch,
          cookiePrepElapsed: cookiePrepElapsed,
        );
        return response;
      }

      final completer = Completer<Map<String, dynamic>>();
      _pendingRequests[requestId] = completer;

      final script =
          '''
      (async function() {
        const requestId = ${jsonEncode(requestId)};
        try {
          // D18: abort 辅助函数（__fluxdoFetchAborters / __fluxdoAbortFetch）
          // 已在 WebView 就绪时一次性装好，这里不再重复声明函数体——只保证
          // 控制器表存在即可。装失败时 abort 退化为 no-op（_abortWebViewFetch
          // 本就有 `if (window.__fluxdoAbortFetch)` 守卫），不影响响应正确性。
          window.__fluxdoFetchAborters = window.__fluxdoFetchAborters || {};

          const controller = new AbortController();
          window.__fluxdoFetchAborters[requestId] = controller;

          const fetchOptions = {
            method: ${jsonEncode(method)},
            headers: ${jsonEncode(headersMap)},
            credentials: 'include',
            signal: controller.signal${fetchCacheMode != null ? ",\n            cache: ${jsonEncode(fetchCacheMode)}" : ''}
          };
          $bodyScript

          const response = await fetch(${jsonEncode(url)}, fetchOptions);

          const bodyData = await response.text();

          const headersObj = {};
          response.headers.forEach((v, k) => headersObj[k] = v);

          // D5: body 与元数据平级传回，避免把 body 嵌进 JSON 字符串里
          // 造成「JS 转义一次 + 插件再转义一次 / Dart 反转义两次」的整包往返。
          window.flutter_inappwebview.callHandler('fetchResult', {
            requestId: requestId,
            ok: true,
            status: response.status,
            statusText: response.statusText,
            headers: headersObj,
            body: bodyData,
            isBase64: false
          });
        } catch (e) {
          window.flutter_inappwebview.callHandler('fetchResult', {
            requestId: requestId,
            ok: false,
            error: e.toString()
          });
        } finally {
          if (window.__fluxdoFetchAborters) {
            delete window.__fluxdoFetchAborters[requestId];
          }
        }
      })();
    ''';

      debugPrint('[WebViewAdapter] Fetching: $method $url (id: $requestId)');

      final cancelFutureForRequest = cancelFuture;
      if (cancelFutureForRequest != null) {
        unawaited(
          cancelFutureForRequest.then<void>((_) async {
            final pending = _pendingRequests.remove(requestId);
            if (pending != null && !pending.isCompleted) {
              pending.completeError(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.cancel,
                  error: 'WebView request canceled',
                ),
              );
            }
            await _abortWebViewFetch(requestId);
          }, onError: (_) {}),
        );
      }

      try {
        final jsEvalWatch = Stopwatch()..start();
        await _controller!.evaluateJavascript(source: script);
        jsEvalWatch.stop();
        jsEvalElapsed = jsEvalWatch.elapsed;
      } catch (_) {
        _pendingRequests.remove(requestId);
        rethrow;
      }

      // 超时从 RequestOptions 读取，默认 30 秒
      final timeout =
          options.receiveTimeout ??
          options.connectTimeout ??
          const Duration(seconds: 30);

      final browserWaitWatch = Stopwatch()..start();
      final responseData = await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRequests.remove(requestId);
          unawaited(_abortWebViewFetch(requestId));
          throw DioException(
            requestOptions: options,
            error: 'WebView request timeout',
            type: DioExceptionType.receiveTimeout,
          );
        },
      );
      browserWaitWatch.stop();
      browserWaitElapsed = browserWaitWatch.elapsed;

      // D5: handler 已把 JS 对象解析成 Map，这里不再 `jsonDecode`。
      if (responseData['ok'] != true) {
        throw DioException(
          requestOptions: options,
          error: responseData['error']?.toString() ?? 'Unknown error',
          type: DioExceptionType.unknown,
        );
      }

      final statusCode = responseData['status'] as int? ?? 200;
      final bodyContent = responseData['body'] as String? ?? '';

      final responseHeaders = <String, List<String>>{};

      if (responseData['headers'] is Map) {
        (responseData['headers'] as Map).forEach((key, value) {
          responseHeaders[key.toString()] = [value.toString()];
        });
      }

      _throwIfSessionExpired(options);

      if (syncAppCookies) {
        final trustsWebViewSession = _trustsWebViewSessionFromResponse(
          options,
          statusCode,
          responseHeaders,
        );
        // 成功的 WebView 登录态请求本身就是服务端认可 session 的证明。
        // 失败/登出信号路径仍只同步非登录态 cookie，避免旧 _t 回灌。
        //
        // D9: 写请求（POST/PUT/…）不再**无条件**强制全量边界同步。
        // 改前 `force: trustsWebViewSession || (method != 'GET' && method != 'HEAD')`
        // 让每个写请求都绕过 800ms 去抖窗口，触发一次
        // `readCookiesFromWebView`（iOS = `WKHTTPCookieStore.getAllCookies`
        // 全量枚举 + 跨 method channel 序列化），活跃刷帖时点赞/回复/浏览
        // 上报等写请求密集，这是活跃负载下的固定 CPU 源。
        //
        // 正确性：WV 侧 cookie 变化已由 [CookieStoreObserver] 的 500ms
        // debounce（native `WKHTTPCookieStoreObserver` 推送）在请求路径之外
        // 统一收敛；写请求的响应 cookie 并不比 observer 更早/更全。因此写
        // 请求与读请求共用同一去抖快路径即可，不会漏掉任何 cookie 变化。
        // 仅「服务端已确认登录态」这一强信号仍需 force（它决定 auth cookie
        // 是否立即落 jar，不能延后）。
        final cookieBackSyncWatch = Stopwatch()..start();
        await _syncCriticalCookiesBackToJar(
          url,
          force: trustsWebViewSession,
          requestGeneration: options.extra['_sessionGeneration'] as int?,
          excludeCookieNames: trustsWebViewSession
              ? null
              : CookieJarService.authCookieNames,
        );
        cookieBackSyncWatch.stop();
        cookieBackSyncElapsed = cookieBackSyncWatch.elapsed;
      }

      _throwIfSessionExpired(options);

      totalWatch.stop();
      _recordTimings(
        options,
        total: totalWatch.elapsed,
        cookiePrep: cookiePrepElapsed,
        jsEval: jsEvalElapsed,
        browserWait: browserWaitElapsed,
        cookieBackSync: cookieBackSyncElapsed,
      );

      debugPrint(
        '[WebViewAdapter] Response: $statusCode ('
        'total=${totalWatch.elapsedMilliseconds}ms, '
        'browser=${browserWaitElapsed.inMilliseconds}ms)',
      );

      // D1: 文本响应（JSON/HTML）经 JS .text() 跨桥回传的字节画像。
      bridgeStats.textResponses++;
      bridgeStats.textResponseBytes += bodyContent.length;
      bridgeStats.totalMs += totalWatch.elapsedMilliseconds;
      // D26: 把本条文本响应的桥内耗时归到它的请求类别。
      _recordClassTime(requestClass, totalWatch.elapsedMilliseconds);
      bridgeStats.jsEvalMs += jsEvalElapsed.inMilliseconds;
      // D5: 本次响应体走的是「平级字段」新路径，省下了旧路径的整包二次转义。
      bridgeStats.textBodyUnescaped++;
      bridgeStats.textBodyUnescapedBytes += bodyContent.length;

      return ResponseBody.fromString(
        bodyContent,
        statusCode,
        headers: responseHeaders,
      );
    } catch (_) {
      WebViewBridgeDiagnostics.instance.failed++;
      rethrow;
    } finally {
      _activeFetches--;
      // D12: 记录本次在飞时长并收敛并发计数。
      WebViewBridgeProbe.instance.onRequestEnd(totalWatch.elapsed);
      // D13: 释放桥名额（必须在 onRequestEnd 之后，保证在飞时长含排队时间）。
      // D28: 权重必须与 acquire 时一致，否则槽位计数漂移。
      WebViewBridgeGate.instance.release(weight: gateWeight);
      if (_activeFetches == 0 && _disposeWhenIdle) {
        close(force: false);
      }
    }
  }

  /// D28: 判断这条走桥请求是否属于「图片类」——用于在并发闸门里给它更高权重。
  ///
  /// 只读请求元数据（`extra` 里的 resourceKind），不解析 URL、不触碰 WebView，
  /// 因此对桥上行为零影响、零额外开销。
  bool _isImageRequest(RequestOptions options) {
    return options.extra[resourceKindExtraKey]?.toString() == resourceKindImage;
  }

  /// D1: 把「这条走桥的请求是哪一类」记进聚合计数。
  ///
  /// 分类只依赖请求自身元数据（resourceKind / 同源判断 / 方法），不解析 URL 内容，
  /// 也不触碰任何 WebView API，因此对桥上行为零影响。
  void _recordBridgeRequestKind(
    RequestOptions options,
    Uri requestUri,
    String method,
  ) {
    final stats = WebViewBridgeDiagnostics.instance;
    final resourceKind = options.extra[resourceKindExtraKey]?.toString();
    if (resourceKind == resourceKindImage) {
      if (WebViewAdapterSettingsService.instance.canUseWebView(requestUri)) {
        stats.imageSameOrigin++;
        return _BridgeRequestClass.imageSameOrigin;
      } else {
        stats.imageOther++;
        return _BridgeRequestClass.imageOther;
      }
    }
    if (method == 'GET' || method == 'HEAD') {
      stats.apiGet++;
      return _BridgeRequestClass.apiGet;
    }
    if (method == 'POST' ||
        method == 'PUT' ||
        method == 'PATCH' ||
        method == 'DELETE') {
      stats.apiWrite++;
      return _BridgeRequestClass.apiWrite;
    }
    stats.other++;
    return _BridgeRequestClass.other;
  }

  /// D26: 把一条走桥请求的桥内总耗时累加到它的类别上。
  ///
  /// 与 [_recordBridgeRequestKind] 配对：请求开始时拿到类别，结束时（文本与
  /// 二进制流两条路径各自）把 totalMs 归到对应类别。纯整数累加，零采样。
  void _recordClassTime(_BridgeRequestClass cls, int ms) {
    final stats = WebViewBridgeDiagnostics.instance;
    switch (cls) {
      case _BridgeRequestClass.imageSameOrigin:
        stats.imageSameOriginMs += ms;
      case _BridgeRequestClass.imageOther:
        stats.imageOtherMs += ms;
      case _BridgeRequestClass.apiGet:
        stats.apiGetMs += ms;
      case _BridgeRequestClass.apiWrite:
        stats.apiWriteMs += ms;
      case _BridgeRequestClass.other:
        stats.otherMs += ms;
    }
  }

  /// D31: 把一条走桥请求在**闸门外排队**的时长累加到它的类别上。
  ///
  /// 与 [_recordClassTime] 的区别：后者记的是「进桥之后花了多久」，本方法记的是
  /// 「因为闸门满而在 Dart 侧等了多久」。两者相加才是这条请求端到端的桥代价。
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：D20/D21/D22 只能给出
  /// **整体**排队占比与饱和度，无法回答「排队代价压在图片上还是 API 上」——
  /// 而这两者的优化手段完全不同（图片→继续分流原生；API 读→合并调用/降条数）。
  ///
  /// 纯整数累加，零采样、零新增运行时开销；不记录 URL / Headers / 正文。
  void _recordClassQueueWait(_BridgeRequestClass cls, int ms) {
    if (ms <= 0) return;
    final stats = WebViewBridgeDiagnostics.instance;
    switch (cls) {
      case _BridgeRequestClass.imageSameOrigin:
        stats.imageSameOriginQueueMs += ms;
      case _BridgeRequestClass.imageOther:
        stats.imageOtherQueueMs += ms;
      case _BridgeRequestClass.apiGet:
        stats.apiGetQueueMs += ms;
      case _BridgeRequestClass.apiWrite:
        stats.apiWriteQueueMs += ms;
      case _BridgeRequestClass.other:
        stats.otherQueueMs += ms;
    }
  }

  /// D1: 请求体在桥上的传输形态归因（base64 fallback 是 D3 的优化靶点）。
  void _recordBridgeBodyShape(
    WebViewBridgeDiagnostics stats,
    _BodyShape shape,
  ) {
    if (shape == _BodyShape.base64) {
      stats.requestBodyBase64++;
    } else if (shape == _BodyShape.streamBridge) {
      stats.requestBodyStreamBridge++;
    } else if (shape == _BodyShape.direct) {
      stats.requestBodyDirect++;
    } else if (shape == _BodyShape.inlineSmall) {
      // D10: 小请求体内联，省下一次整包 base64 编解码往返。
      stats.requestBodyInlineSmall++;
    }
  }

  void disposeWhenIdle() {
    _disposeWhenIdle = true;
    if (_activeFetches == 0) {
      close(force: false);
    }
  }

  Future<ResponseBody> _fetchBinaryStreamResponse(
    RequestOptions options, {
    required _BridgeRequestClass requestClass,
    required String requestId,
    required String method,
    required String url,
    required Map<String, String> headersMap,
    required String bodyScript,
    required String? fetchCacheMode,
    required Future<void>? cancelFuture,
    required Stopwatch totalWatch,
    required Duration? cookiePrepElapsed,
  }) async {
    final bridge = await _createBinaryResponseBridge(
      options,
      requestId: requestId,
    );

    final script =
        '''
      (async function() {
        const requestId = ${jsonEncode(requestId)};
        let responsePort = null;
        try {
          responsePort = await window.__fluxdoTakeBinaryResponsePort(requestId);

          // D18: abort 辅助函数已一次性装好，这里只保证控制器表存在。
          window.__fluxdoFetchAborters = window.__fluxdoFetchAborters || {};

          const controller = new AbortController();
          window.__fluxdoFetchAborters[requestId] = controller;

          const fetchOptions = {
            method: ${jsonEncode(method)},
            headers: ${jsonEncode(headersMap)},
            credentials: 'include',
            signal: controller.signal${fetchCacheMode != null ? ",\n            cache: ${jsonEncode(fetchCacheMode)}" : ''}
          };
          $bodyScript

          const response = await fetch(${jsonEncode(url)}, fetchOptions);
          const headersObj = {};
          response.headers.forEach((v, k) => headersObj[k] = v);

          responsePort.postMessage(JSON.stringify({
            kind: 'headers',
            requestId: requestId,
            status: response.status,
            statusText: response.statusText,
            headers: headersObj
          }));

          const sendBuffer = function(buffer) {
            if (!buffer || buffer.byteLength === 0) return;
            try {
              responsePort.postMessage(buffer, [buffer]);
            } catch (_) {
              responsePort.postMessage(buffer);
            }
          };

          // D14: 把 reader 的小 chunk 在 JS 侧合并成较大的消息再跨桥回传。
          // 每个 postMessage 都要跨一次 JS↔native 边界(结构化克隆/转移 +
          // Dart 侧回调派发)，活跃刷帖时大图会以许多小 chunk 到达，
          // 边界穿越次数与 chunk 数同阶 → CPU 峰值叠加。
          // 合并到 COALESCE_TARGET 再发，可把消息数压到约 1/N，
          // 语义与字节序完全不变(仍是同一段连续字节，只是分批粒度更粗)。
          const COALESCE_TARGET = 65536;
          let pending = null;
          let pendingLen = 0;
          let rawChunks = 0;
          let sentMessages = 0;

          const flushPending = function() {
            if (!pending || pendingLen === 0) return;
            // 必须让 out 独占一块恰好 pendingLen 的 ArrayBuffer：postMessage
            // 转移的是整个 buffer，若沿用 64KB 大缓冲会把尾部未用字节一并送出。
            const out = new Uint8Array(pendingLen);
            out.set(pending.subarray(0, pendingLen));
            pending = null;
            pendingLen = 0;
            sentMessages++;
            sendBuffer(out.buffer);
          };

          const pushChunk = function(value) {
            if (!value || value.byteLength === 0) return;
            rawChunks++;
            let src = value;
            if (value.byteOffset !== 0 || value.byteLength !== value.buffer.byteLength) {
              src = value.slice();
            }
            if (!pending) {
              pending = new Uint8Array(COALESCE_TARGET);
              pendingLen = 0;
            }
            let offset = 0;
            while (offset < src.byteLength) {
              const room = COALESCE_TARGET - pendingLen;
              const take = Math.min(room, src.byteLength - offset);
              pending.set(src.subarray(offset, offset + take), pendingLen);
              pendingLen += take;
              offset += take;
              if (pendingLen >= COALESCE_TARGET) {
                flushPending();
                pending = new Uint8Array(COALESCE_TARGET);
                pendingLen = 0;
              }
            }
          };

          if (response.body && response.body.getReader) {
            const reader = response.body.getReader();
            while (true) {
              const chunk = await reader.read();
              if (chunk.done) break;
              pushChunk(chunk.value);
            }
            flushPending();
          } else {
            sendBuffer(await response.arrayBuffer());
          }

          responsePort.postMessage(JSON.stringify({
            kind: 'coalesceStats',
            requestId: requestId,
            rawChunks: rawChunks,
            sentMessages: sentMessages
          }));

          responsePort.postMessage(JSON.stringify({
            kind: 'complete',
            requestId: requestId
          }));
        } catch (e) {
          const payload = JSON.stringify({
            kind: 'error',
            requestId: requestId,
            error: e && e.name === 'AbortError'
              ? 'WebView request canceled'
              : String(e)
          });
          if (responsePort) {
            responsePort.postMessage(payload);
          } else {
            window.flutter_inappwebview.callHandler('fetchResult', {
              requestId: requestId,
              ok: false,
              error: String(e)
            });
          }
        } finally {
          if (window.__fluxdoFetchAborters) {
            delete window.__fluxdoFetchAborters[requestId];
          }
        }
      })();
    ''';

    debugPrint(
      '[WebViewAdapter] Fetching binary stream: $method $url (id: $requestId)',
    );

    final cancelFutureForRequest = cancelFuture;
    if (cancelFutureForRequest != null) {
      unawaited(
        cancelFutureForRequest.then<void>((_) async {
          bridge.completeError(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
              error: 'WebView request canceled',
            ),
          );
          await _abortWebViewFetch(requestId);
        }, onError: (_) {}),
      );
    }

    final headerWatch = Stopwatch()..start();
    Duration? jsEvalElapsed;
    try {
      final jsEvalWatch = Stopwatch()..start();
      await _controller!.evaluateJavascript(source: script);
      jsEvalWatch.stop();
      jsEvalElapsed = jsEvalWatch.elapsed;
    } catch (e) {
      bridge.completeError(e);
      rethrow;
    }

    final timeout =
        options.receiveTimeout ??
        options.connectTimeout ??
        const Duration(seconds: 30);
    final headers = await bridge.headersCompleter.future.timeout(
      timeout,
      onTimeout: () {
        unawaited(_abortWebViewFetch(requestId));
        throw DioException(
          requestOptions: options,
          error: 'WebView binary response header timeout',
          type: DioExceptionType.receiveTimeout,
        );
      },
    );
    headerWatch.stop();
    totalWatch.stop();

    _recordTimings(
      options,
      total: totalWatch.elapsed,
      cookiePrep: cookiePrepElapsed,
      jsEval: jsEvalElapsed,
      browserWait: headerWatch.elapsed,
    );
    _setNetworkLogField(options, 'webViewBinaryStream', true);

    // D1: 二进制流经 WebMessageChannel 分块回传的字节画像（最有价值的桥负载指标）。
    final bridgeStats = WebViewBridgeDiagnostics.instance;
    bridgeStats.streamResponses++;
    bridgeStats.totalMs += totalWatch.elapsedMilliseconds;
    // D26: 把本条流响应的桥内耗时归到它的请求类别。
    _recordClassTime(requestClass, totalWatch.elapsedMilliseconds);
    bridgeStats.jsEvalMs += jsEvalElapsed.inMilliseconds;

    bridge.done.whenComplete(() {
      bridgeStats.streamResponseBytes += bridge.bytesReceived;
      // D25: 流路径的「固定成本」归因——建通道 + 握手 + N 次分块回调。
      // 与 streamResponses 的区别：后者是「搬了多少」，这里是「为此额外付了
      // 多少次跨语言边界穿越」。纯整数累加，零采样、零新增运行时开销。
      bridgeStats.binaryBridgeResponses++;
      bridgeStats.binaryBridgeBytes += bridge.bytesReceived;
      bridgeStats.binaryBridgeChunks += bridge.chunksReceived;
      // D13: 同源图片走桥时的响应字节单独归因，用于对比 D2 分流收益。
      if (options.extra[resourceKindExtraKey]?.toString() ==
          resourceKindImage) {
        bridgeStats.imageResponseBytes += bridge.bytesReceived;
      }
      _setNetworkLogField(options, 'webViewBinaryBytes', bridge.bytesReceived);
      _setNetworkLogField(
        options,
        'webViewBinaryChunks',
        bridge.chunksReceived,
      );
      debugPrint(
        '[WebViewAdapter] Binary stream complete: '
        '$method $url (id: $requestId, status=${headers.statusCode}, '
        'bytes=${bridge.bytesReceived}, chunks=${bridge.chunksReceived})',
      );
    });

    return ResponseBody(
      bridge.stream,
      headers.statusCode,
      headers: headers.headers,
      statusMessage: headers.statusMessage,
    );
  }

  Future<_BinaryResponseBridge> _createBinaryResponseBridge(
    RequestOptions options, {
    required String requestId,
  }) async {
    final controller = _controller;
    if (controller == null) {
      throw DioException(
        requestOptions: options,
        error: 'WebView controller not available',
        type: DioExceptionType.unknown,
      );
    }

    await _installBinaryResponseBridge(controller);

    final channel = await controller.createWebMessageChannel();
    if (channel == null) {
      throw DioException(
        requestOptions: options,
        error: 'WebView binary response channel unavailable',
        type: DioExceptionType.unknown,
      );
    }

    late final _BinaryResponseBridge bridge;
    bridge = _BinaryResponseBridge(
      requestOptions: options,
      channel: channel,
      onCancel: () async {
        await _abortWebViewFetch(requestId);
      },
    );

    final readyCompleter = Completer<void>();
    final port = channel.port1;
    await port.setWebMessageCallback((message) async {
      final payload = message?.data;
      final bytes = _binaryMessageBytes(payload);
      if (bytes != null) {
        bridge.addBytes(bytes);
        return;
      }

      if (payload is! String || payload.isEmpty) {
        return;
      }
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map) return;
        final kind = decoded['kind']?.toString();
        if (kind == 'ready') {
          if (!readyCompleter.isCompleted) readyCompleter.complete();
        } else if (kind == 'headers') {
          bridge.completeHeaders(_BinaryResponseHeaders.fromJson(decoded));
        } else if (kind == 'complete') {
          bridge.complete();
        } else if (kind == 'coalesceStats') {
          // D14: JS 侧合并统计——原始 chunk 数 vs 实际发出的跨桥消息数。
          final raw = decoded['rawChunks'];
          final sent = decoded['sentMessages'];
          if (raw is num && sent is num) {
            final stats = WebViewBridgeDiagnostics.instance;
            stats.streamRawChunks += raw.toInt();
            stats.streamCoalescedMessages += sent.toInt();
          }
        } else if (kind == 'error') {
          bridge.completeError(
            DioException(
              requestOptions: options,
              type: DioExceptionType.unknown,
              error: decoded['error']?.toString() ?? 'WebView binary error',
            ),
          );
        }
      } catch (e) {
        bridge.completeError(e);
      }
    });

    await controller.postWebMessage(
      message: WebMessage(
        data: '__fluxdo:binary-response:$requestId',
        ports: [channel.port2],
      ),
      targetOrigin: WebUri(Uri.parse(AppConstants.baseUrl).origin),
    );

    await readyCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        bridge.completeError(
          TimeoutException(
            'WebView binary response port setup timeout for $requestId',
          ),
        );
        throw TimeoutException(
          'WebView binary response port setup timeout for $requestId',
        );
      },
    );

    return bridge;
  }

  Future<void> _installBinaryResponseBridge(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source: '''
        (function() {
          if (window.__fluxdoBinaryResponseBridgeInstalled) return;
          window.__fluxdoBinaryResponseBridgeInstalled = true;
          window.__fluxdoBinaryResponsePorts = new Map();
          window.__fluxdoBinaryResponseWaiters = new Map();

          window.__fluxdoTakeBinaryResponsePort = function(requestId) {
            var existing = window.__fluxdoBinaryResponsePorts.get(requestId);
            if (existing) {
              window.__fluxdoBinaryResponsePorts.delete(requestId);
              return Promise.resolve(existing);
            }
            return new Promise(function(resolve, reject) {
              var timer = setTimeout(function() {
                window.__fluxdoBinaryResponseWaiters.delete(requestId);
                reject(new Error('Binary response port timeout for ' + requestId));
              }, 5000);
              window.__fluxdoBinaryResponseWaiters.set(requestId, function(port) {
                clearTimeout(timer);
                resolve(port);
              });
            });
          };

          window.addEventListener('message', function(event) {
            if (typeof event.data !== 'string' ||
                !event.data.startsWith('__fluxdo:binary-response:')) {
              return;
            }

            var requestId = event.data.substring('__fluxdo:binary-response:'.length);
            var port = event.ports && event.ports[0];
            if (!port) return;
            if (port.start) port.start();

            var waiter = window.__fluxdoBinaryResponseWaiters.get(requestId);
            if (waiter) {
              window.__fluxdoBinaryResponseWaiters.delete(requestId);
              waiter(port);
            } else {
              window.__fluxdoBinaryResponsePorts.set(requestId, port);
            }
            port.postMessage(JSON.stringify({ kind: 'ready', requestId: requestId }));
          });
        })();
      ''',
    );
  }

  Uint8List? _binaryMessageBytes(Object? payload) {
    if (payload is Uint8List) {
      return payload;
    }
    if (payload is ByteBuffer) {
      return payload.asUint8List();
    }
    if (payload is List<int>) {
      return Uint8List.fromList(payload);
    }
    return null;
  }

  void _recordTimings(
    RequestOptions options, {
    required Duration total,
    Duration? cookiePrep,
    Duration? jsEval,
    Duration? browserWait,
    Duration? cookieBackSync,
  }) {
    _setNetworkLogField(options, 'webViewTotalMs', total.inMilliseconds);
    // D17: 把每请求耗时拆成三段聚合，供诊断页判读「固定税花在哪」。
    // 纯累加整数，不新增任何采样/定时器，也不改变请求行为。
    final stats = WebViewBridgeDiagnostics.instance;
    if (cookiePrep != null) {
      _setNetworkLogField(
        options,
        'webViewCookiePrepMs',
        cookiePrep.inMilliseconds,
      );
      stats.cookiePrepMs += cookiePrep.inMilliseconds;
    }
    if (jsEval != null) {
      _setNetworkLogField(options, 'webViewJsEvalMs', jsEval.inMilliseconds);
    }
    if (browserWait != null) {
      _setNetworkLogField(
        options,
        'webViewBrowserWaitMs',
        browserWait.inMilliseconds,
      );
      stats.browserWaitMs += browserWait.inMilliseconds;
    }
    if (cookieBackSync != null) {
      _setNetworkLogField(
        options,
        'webViewCookieBackSyncMs',
        cookieBackSync.inMilliseconds,
      );
      stats.cookieBackSyncMs += cookieBackSync.inMilliseconds;
    }
  }

  @override
  void close({bool force = false}) {
    if (!force && _activeFetches > 0) {
      _disposeWhenIdle = true;
      return;
    }
    if (_headlessWebView != null) {
      FrameJankMonitor.logEvent('WEBVIEW', 'HttpAdapter dispose');
    }
    _headlessWebView?.dispose();
    _headlessWebView = null;
    _controller = null;
    _isInitialized = false;
    _disposeWhenIdle = false;
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      _initCompleter!.completeError(StateError('WebView adapter closed'));
    }
    _initCompleter = null;
    _activeCriticalCookieSync = null;
    _lastCriticalCookieSyncAt = null;
    // 新的 WebView 会话 = 新的 cookie 存储，边界同步标记必须一并复位，
    // 否则重建后的第一个请求会跳过 sweep，把 WV 侧残留变体留在库里。
    WebViewBridgeDiagnostics.instance.resetCookieBoundarySync();
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
            error: 'WebView adapter closed',
          ),
        );
      }
    }
    _pendingRequests.clear();
  }

  bool _shouldSyncAppCookies(Uri requestUri, Uri baseUri) {
    final requestHost = requestUri.host;
    final baseHost = baseUri.host;
    if (requestHost.isEmpty || baseHost.isEmpty) {
      return false;
    }
    return requestHost == baseHost || requestHost.endsWith('.$baseHost');
  }

  _WebViewCookieMode _resolveCookieMode(
    RequestOptions options,
    bool shouldSyncAppCookies,
  ) {
    final explicitMode = options.extra[cookieModeExtraKey]?.toString();
    if (explicitMode == cookieModeNone) {
      return _WebViewCookieMode.none;
    }
    if (explicitMode == cookieModeReadOnly) {
      return shouldSyncAppCookies
          ? _WebViewCookieMode.readOnly
          : _WebViewCookieMode.none;
    }
    return shouldSyncAppCookies
        ? _WebViewCookieMode.sync
        : _WebViewCookieMode.none;
  }

  bool _trustsWebViewSessionFromResponse(
    RequestOptions options,
    int statusCode,
    Map<String, List<String>> responseHeaders,
  ) {
    if (statusCode < 200 || statusCode >= 400) return false;
    if (!_hasRequestHeaderValue(
      options.headers,
      'Discourse-Logged-In',
      'true',
    )) {
      return false;
    }
    return !_hasNonEmptyResponseHeader(responseHeaders, 'discourse-logged-out');
  }

  bool _hasRequestHeaderValue(
    Map<String, dynamic> headers,
    String name,
    String expectedValue,
  ) {
    final normalized = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != normalized) continue;
      return entry.value?.toString().toLowerCase() ==
          expectedValue.toLowerCase();
    }
    return false;
  }

  bool _hasNonEmptyResponseHeader(
    Map<String, List<String>> responseHeaders,
    String name,
  ) {
    final normalized = name.toLowerCase();
    for (final entry in responseHeaders.entries) {
      if (entry.key.toLowerCase() != normalized) continue;
      return entry.value.any((value) => value.trim().isNotEmpty);
    }
    return false;
  }

  /// 通过全平台 CookieManager API 写入 cookie
  Future<void> _syncCookiesViaCookieManager(
    String url,
    String cookieHeader,
  ) async {
    try {
      final cookieManager = _resolveCookieManager();
      final webUri = WebUri(url);
      final cookies = cookieHeader.split('; ');
      for (final cookie in cookies) {
        final parts = cookie.split('=');
        if (parts.length >= 2) {
          final name = parts[0].trim();
          final value = parts.sublist(1).join('=').trim();
          await cookieManager.setCookie(url: webUri, name: name, value: value);
        }
      }
    } catch (e) {
      debugPrint('[WebViewAdapter] Failed to sync cookies: $e');
    }
  }

  Future<_RequestBodyPlan> _buildRequestBodyPlan(
    RequestOptions options,
    Stream<Uint8List>? requestStream, {
    required String method,
    required String requestId,
    required Uri requestUri,
  }) async {
    if (method == 'GET' || method == 'HEAD') {
      return const _RequestBodyPlan(script: '');
    }

    final directBodyScript = await _buildDirectBodyScript(options);
    if (directBodyScript != null) {
      return _RequestBodyPlan(
        script: directBodyScript,
        shape: _BodyShape.direct,
      );
    }

    final streamedBodyScript = await _buildStreamedBodyScript(
      requestStream,
      requestId: requestId,
      requestUri: requestUri,
    );
    if (streamedBodyScript != null) {
      return _RequestBodyPlan(
        script: streamedBodyScript,
        shape: _BodyShape.streamBridge,
      );
    }

    final requestBytes = await _readRequestBytes(requestStream);
    if (requestBytes != null && requestBytes.isNotEmpty) {
      // D10: 小请求体直接内联为 JSON 字符串字面量。
      //
      // 活跃刷帖时写请求（点赞/回复/浏览上报）体量普遍很小，走
      // base64Encode → jsonEncode → JS atob → Uint8Array.from 的整包往返
      // 是纯开销：两端各一份完整副本，且逐字符回调解码。
      //
      // 内联路径只做一次 Dart 侧 `jsonEncode`（负责全部转义），JS 侧拿到
      // 的就是现成字符串，零解码、零回调、零额外副本。唯一前提是请求体能
      // 无损当成 UTF-8 文本送——这里用「严格解码 + 再编码比对」判定，
      // 二进制体（图片/压缩流/加密块）会因解码失败或字节不一致而回退到
      // base64 路径，语义不变。
      final inlineScript = _buildInlineSmallBodyScript(requestBytes);
      if (inlineScript != null) {
        return _RequestBodyPlan(
          script: inlineScript,
          shape: _BodyShape.inlineSmall,
        );
      }

      final bodyBase64 = base64Encode(requestBytes);
      return _RequestBodyPlan(
        script:
            '''
          const bodyBytes = Uint8Array.from(
            atob(${jsonEncode(bodyBase64)}),
            (char) => char.charCodeAt(0)
          );
          const contentTypeHeader = Object.entries(fetchOptions.headers).find(
            ([key]) => key.toLowerCase() === 'content-type'
          );
          const contentType = contentTypeHeader ? String(contentTypeHeader[1] ?? '') : '';
          if (
            /application\\/x-www-form-urlencoded/i.test(contentType) ||
            /application\\/json/i.test(contentType) ||
            /^text\\//i.test(contentType)
          ) {
            fetchOptions.body = new TextDecoder().decode(bodyBytes);
          } else {
            fetchOptions.body = contentType
              ? new Blob([bodyBytes], { type: contentType })
              : new Blob([bodyBytes]);
          }
      ''',
        shape: _BodyShape.base64,
      );
    }

    if (options.data == null) {
      return const _RequestBodyPlan(script: '');
    }

    return _RequestBodyPlan(
      script: "fetchOptions.body = ${jsonEncode(options.data.toString())};",
      shape: _BodyShape.direct,
    );
  }

  Future<String?> _buildStreamedBodyScript(
    Stream<Uint8List>? requestStream, {
    required String requestId,
    required Uri requestUri,
  }) async {
    if (requestStream == null) {
      return null;
    }

    final controller = _controller;
    if (controller == null) {
      return null;
    }

    WebMessageChannel? channel;
    var transferStarted = false;

    try {
      await _installRequestBodyBridge(controller);

      channel = await controller.createWebMessageChannel();
      if (channel == null) {
        return null;
      }

      final port = channel.port1;
      final readyCompleter = Completer<void>();
      final completeCompleter = Completer<void>();
      final errorCompleter = Completer<String>();

      await port.setWebMessageCallback((message) async {
        final payload = message?.data;
        if (payload is! String || payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map) return;
          final kind = decoded['kind']?.toString();
          if (kind == 'ready' && !readyCompleter.isCompleted) {
            readyCompleter.complete();
          } else if (kind == 'complete' && !completeCompleter.isCompleted) {
            completeCompleter.complete();
          } else if (kind == 'error' && !errorCompleter.isCompleted) {
            errorCompleter.complete(decoded['error']?.toString() ?? 'unknown');
          }
        } catch (_) {}
      });

      final origin = requestUri.origin;
      await controller.postWebMessage(
        message: WebMessage(
          data: '__fluxdo:body:$requestId',
          ports: [channel.port2],
        ),
        targetOrigin: WebUri(origin),
      );

      await _awaitRequestBodyPortReady(
        readyCompleter,
        errorCompleter,
        requestId: requestId,
      );

      transferStarted = true;
      await _pipeRequestStreamToPort(requestStream, port);

      await _postRequestBodyControlMessage(port, {
        'kind': 'complete',
        'requestId': requestId,
      });

      await _awaitRequestBodyTransferComplete(
        completeCompleter,
        errorCompleter,
        requestId: requestId,
      );

      return 'fetchOptions.body = window.__fluxdoTakeRequestBody(${jsonEncode(requestId)});';
    } catch (e) {
      if (!transferStarted) {
        debugPrint(
          '[WebViewAdapter] Stream bridge unavailable, fallback to base64: $e',
        );
        return null;
      }
      rethrow;
    } finally {
      channel?.dispose();
    }
  }

  Future<String?> _buildDirectBodyScript(RequestOptions options) async {
    final data = options.data;
    if (data == null || data is FormData) {
      return null;
    }
    if (data is Uint8List || data is List<int>) {
      return null;
    }

    final bodyText = await Transformer.defaultTransformRequest(
      options,
      (object) => jsonEncode(object),
    );
    return "fetchOptions.body = ${jsonEncode(bodyText)};";
  }

  Future<void> _installRequestBodyBridge(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source: '''
        (function() {
          if (window.__fluxdoRequestBodyBridgeInstalled) return;
          window.__fluxdoRequestBodyBridgeInstalled = true;
          window.__fluxdoRequestBodyTransfers = new Map();

          function ensureState(requestId) {
            var state = window.__fluxdoRequestBodyTransfers.get(requestId);
            if (!state) {
              state = {
                chunks: [],
                body: null
              };
              window.__fluxdoRequestBodyTransfers.set(requestId, state);
            }
            return state;
          }

          window.__fluxdoTakeRequestBody = function(requestId) {
            var state = window.__fluxdoRequestBodyTransfers.get(requestId);
            if (!state || state.body === null) {
              throw new Error('Request body not ready for request ' + requestId);
            }
            var body = state.body;
            window.__fluxdoRequestBodyTransfers.delete(requestId);
            return body;
          };

          window.addEventListener('message', function(event) {
            if (typeof event.data !== 'string' || !event.data.startsWith('__fluxdo:body:')) {
              return;
            }

            var requestId = event.data.substring('__fluxdo:body:'.length);
            var port = event.ports && event.ports[0];
            if (!port) return;

            var state = ensureState(requestId);
            state.chunks = [];
            state.body = null;

            port.onmessage = function(portEvent) {
              try {
                var payload = portEvent.data;
                if (typeof payload === 'string') {
                  var message = JSON.parse(payload);
                  switch (message.kind) {
                    case 'complete':
                      state.body = new Blob(state.chunks);
                      state.chunks = [];
                      port.postMessage(JSON.stringify({ kind: 'complete', requestId: requestId }));
                      break;
                  }
                  return;
                }

                if (payload instanceof ArrayBuffer) {
                  state.chunks.push(payload);
                  return;
                }

                if (ArrayBuffer.isView(payload)) {
                  state.chunks.push(payload.buffer.slice(
                    payload.byteOffset,
                    payload.byteOffset + payload.byteLength
                  ));
                }
              } catch (error) {
                port.postMessage(JSON.stringify({
                  kind: 'error',
                  requestId: requestId,
                  error: String(error)
                }));
              }
            };

            if (port.start) {
              port.start();
            }
            port.postMessage(JSON.stringify({ kind: 'ready', requestId: requestId }));
          });
        })();
      ''',
    );
  }

  Future<void> _postRequestBodyControlMessage(
    WebMessagePort port,
    Map<String, dynamic> payload,
  ) {
    return port.postMessage(WebMessage(data: jsonEncode(payload)));
  }

  Future<void> _awaitRequestBodyPortReady(
    Completer<void> readyCompleter,
    Completer<String> errorCompleter, {
    required String requestId,
  }) async {
    await Future.any([
      readyCompleter.future,
      errorCompleter.future.then<void>((error) {
        throw StateError(
          'Request body port setup failed for request $requestId: $error',
        );
      }),
    ]).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Request body port setup timeout for request $requestId',
      ),
    );
  }

  Future<void> _awaitRequestBodyTransferComplete(
    Completer<void> completeCompleter,
    Completer<String> errorCompleter, {
    required String requestId,
  }) async {
    await Future.any([
      completeCompleter.future,
      errorCompleter.future.then<void>((error) {
        throw StateError(
          'Request body transfer failed for request $requestId: $error',
        );
      }),
    ]).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'Request body transfer timeout for request $requestId',
      ),
    );
  }

  Future<void> _pipeRequestStreamToPort(
    Stream<Uint8List> requestStream,
    WebMessagePort port,
  ) async {
    const targetChunkBytes = 64 * 1024;

    var bufferedLength = 0;
    var builder = BytesBuilder(copy: false);

    Future<void> flush() async {
      if (bufferedLength == 0) {
        return;
      }
      final bytes = builder.takeBytes();
      builder = BytesBuilder(copy: false);
      bufferedLength = 0;
      await port.postMessage(
        WebMessage(data: bytes, type: WebMessageType.ARRAY_BUFFER),
      );
    }

    await for (final chunk in requestStream) {
      if (chunk.isEmpty) {
        continue;
      }
      if (chunk.length >= targetChunkBytes) {
        await flush();
        await port.postMessage(
          WebMessage(data: chunk, type: WebMessageType.ARRAY_BUFFER),
        );
        continue;
      }

      if (bufferedLength + chunk.length > targetChunkBytes &&
          bufferedLength > 0) {
        await flush();
      }

      builder.add(chunk);
      bufferedLength += chunk.length;

      if (bufferedLength >= targetChunkBytes) {
        await flush();
      }
    }

    await flush();
  }

  @visibleForTesting
  static String? resolveFetchCacheMode(RequestOptions options) {
    final requestedMode = options.extra[fetchCacheModeExtraKey]
        ?.toString()
        .trim()
        .toLowerCase();
    if (requestedMode != null && requestedMode.isNotEmpty) {
      if (_supportedFetchCacheModes.contains(requestedMode)) {
        return requestedMode;
      }
      debugPrint(
        '[WebViewAdapter] Ignore unsupported fetch cache mode: $requestedMode',
      );
    }

    final method = options.method.toUpperCase();
    if (method == 'GET' || method == 'HEAD') {
      return defaultApiFetchCacheMode;
    }
    return null;
  }

  Future<Uint8List?> _readRequestBytes(Stream<Uint8List>? requestStream) async {
    if (requestStream == null) return null;

    final builder = BytesBuilder(copy: false);
    await for (final chunk in requestStream) {
      if (chunk.isNotEmpty) {
        builder.add(chunk);
      }
    }
    return builder.isEmpty ? null : builder.takeBytes();
  }

  /// D10: 把小请求体内联成 JS 字符串字面量脚本；不适用时返回 null。
  ///
  /// 适用条件（全部满足才内联）：
  /// 1. 体量 ≤ [WebViewBridgeDiagnostics.requestBodyInlineMaxBytes]；
  /// 2. 字节可被严格 UTF-8 解码（无非法序列）；
  /// 3. 解码后再编码与原始字节完全一致（排除「能解码但非规范文本」的体，
  ///    例如含孤立代理项或非规范编码的二进制块）。
  ///
  /// 三条保证内联后的字符串与原字节语义等价，因此不会改变请求内容；
  /// 任何一条不满足就回退 base64 路径。
  ///
  /// 注意：这里只改变「请求体如何跨桥送达」，不触碰任何 WebView
  /// 挂起/暂停 API，也不改变 JS 执行时机。
  String? _buildInlineSmallBodyScript(Uint8List requestBytes) {
    if (requestBytes.length >
        WebViewBridgeDiagnostics.requestBodyInlineMaxBytes) {
      return null;
    }
    final String bodyText;
    try {
      bodyText = utf8.decode(requestBytes);
    } catch (_) {
      return null;
    }
    final roundTrip = utf8.encode(bodyText);
    if (roundTrip.length != requestBytes.length) {
      return null;
    }
    for (var i = 0; i < roundTrip.length; i++) {
      if (roundTrip[i] != requestBytes[i]) {
        return null;
      }
    }
    // jsonEncode 负责全部转义（引号/反斜杠/换行/控制字符），
    // JS 侧拿到的是可直接赋值的字符串字面量。
    return 'fetchOptions.body = ${jsonEncode(bodyText)};';
  }

  Map<String, String> _buildBrowserSafeHeaders(Map<String, dynamic> headers) {
    final headersMap = <String, String>{};
    final droppedHeaders = <String>[];

    headers.forEach((key, value) {
      if (value == null) return;
      if (_isForbiddenBrowserHeader(key)) {
        droppedHeaders.add(key);
        return;
      }
      final headerValue = _headerValueToString(value);
      if (headerValue == null || headerValue.isEmpty) {
        return;
      }
      headersMap[key] = headerValue;
    });

    if (droppedHeaders.isNotEmpty) {
      debugPrint(
        '[WebViewAdapter] Dropped browser-managed headers: '
        '${droppedHeaders.join(', ')}',
      );
    }

    return headersMap;
  }

  bool _isForbiddenBrowserHeader(String key) {
    final normalized = key.trim().toLowerCase();
    if (_forbiddenBrowserHeaders.contains(normalized)) {
      return true;
    }
    return normalized.startsWith('sec-') || normalized.startsWith('proxy-');
  }

  String? _headerValueToString(Object? value) {
    if (value == null) return null;
    if (value is Iterable) {
      return value
          .where((e) => e != null)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .join(', ');
    }
    return value.toString().trim();
  }

  void _setNetworkLogField(RequestOptions options, String key, Object? value) {
    final currentFields = options.extra['_networkLogFields'];
    if (currentFields is Map<String, dynamic>) {
      currentFields[key] = value;
      return;
    }

    final mergedFields = <String, dynamic>{};
    if (currentFields is Map) {
      currentFields.forEach((fieldKey, fieldValue) {
        if (fieldKey is String) {
          mergedFields[fieldKey] = fieldValue;
        }
      });
    }
    mergedFields[key] = value;
    options.extra['_networkLogFields'] = mergedFields;
  }

  CookieManager _resolveCookieManager() {
    return Platform.isWindows
        ? WindowsWebViewEnvironmentService.instance.cookieManager
        : CookieManager.instance();
  }

  Future<void> _abortWebViewFetch(String requestId) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(
        source:
            'if (window.__fluxdoAbortFetch) window.__fluxdoAbortFetch(${jsonEncode(requestId)});',
      );
    } catch (e) {
      debugPrint('[WebViewAdapter] Abort fetch failed: $e');
    }
  }

  void _throwIfSessionExpired(RequestOptions options) {
    final requestGeneration = options.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        error:
            '会话已过期 (gen=$requestGeneration, current=${AuthSession().generation})',
      );
    }
  }

  Future<void> _syncCriticalCookiesBackToJar(
    String currentUrl, {
    bool force = false,
    int? requestGeneration,
    Set<String>? excludeCookieNames,
  }) async {
    final controller = _controller;
    if (controller == null) return;

    if (!force) {
      final lastSyncAt = _lastCriticalCookieSyncAt;
      if (lastSyncAt != null &&
          DateTime.now().difference(lastSyncAt) <
              const Duration(milliseconds: 800)) {
        final active = _activeCriticalCookieSync;
        if (active != null) {
          await active;
        }
        // D9: 记录一次「因去抖窗口被合并」的边界回同步。
        // 改前写请求会绕过这里，每个写请求各跑一次全量 WV cookie 枚举；
        // 现在写请求也走此快路径，这个计数即本轮从活跃负载上摘掉的
        // 全量枚举批次（含写请求贡献的部分）。
        WebViewBridgeDiagnostics.instance.cookieBackSyncDeduped++;
        return;
      }
    }

    final active = _activeCriticalCookieSync;
    if (active != null) {
      await active;
      if (!force) return;
    }

    final future = BoundarySyncService.instance.syncFromWebView(
      currentUrl: currentUrl,
      controller: controller,
      cookieNames: CookieJarService.criticalCookieNames,
      excludeCookieNames: excludeCookieNames,
      requestGeneration: requestGeneration,
    );

    _activeCriticalCookieSync = future.whenComplete(() {
      _lastCriticalCookieSyncAt = DateTime.now();
      _activeCriticalCookieSync = null;
    });

    await _activeCriticalCookieSync!;
  }
}

class _RequestBodyPlan {
  const _RequestBodyPlan({required this.script, this.shape = _BodyShape.none});

  final String script;
  final _BodyShape shape;
}

/// 请求体在桥上的传输形态，供 D1/D3 聚合归因（不影响行为）。
enum _BodyShape { none, direct, streamBridge, base64, inlineSmall }

enum _WebViewCookieMode { sync, readOnly, none }

/// D26: 走桥请求的类别，用于把桥内耗时按类别归因（见 [classTimeVerdict]）。
enum _BridgeRequestClass {
  imageSameOrigin,
  imageOther,
  apiGet,
  apiWrite,
  other,
}

class _BinaryResponseHeaders {
  const _BinaryResponseHeaders({
    required this.statusCode,
    required this.headers,
    this.statusMessage,
  });

  factory _BinaryResponseHeaders.fromJson(Map<dynamic, dynamic> json) {
    final headers = <String, List<String>>{};
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers[key.toString()] = [value.toString()];
      });
    }
    return _BinaryResponseHeaders(
      statusCode: json['status'] as int? ?? 200,
      statusMessage: json['statusText']?.toString(),
      headers: headers,
    );
  }

  final int statusCode;
  final String? statusMessage;
  final Map<String, List<String>> headers;
}

class _BinaryResponseBridge {
  _BinaryResponseBridge({
    required this.requestOptions,
    required this.channel,
    required Future<void> Function() onCancel,
  }) : _streamController = StreamController<Uint8List>(
         onCancel: () async {
           await onCancel();
         },
       );

  final RequestOptions requestOptions;
  final WebMessageChannel channel;
  final StreamController<Uint8List> _streamController;
  final headersCompleter = Completer<_BinaryResponseHeaders>();
  final _doneCompleter = Completer<void>();

  int bytesReceived = 0;
  int chunksReceived = 0;
  bool _closed = false;

  Stream<Uint8List> get stream => _streamController.stream;
  Future<void> get done => _doneCompleter.future;

  void completeHeaders(_BinaryResponseHeaders headers) {
    if (!headersCompleter.isCompleted) {
      headersCompleter.complete(headers);
    }
  }

  void addBytes(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    bytesReceived += bytes.length;
    chunksReceived++;
    _streamController.add(bytes);
  }

  void complete() {
    if (_closed) return;
    _closed = true;
    _streamController.close();
    channel.dispose();
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  void completeError(Object error) {
    if (!headersCompleter.isCompleted) {
      headersCompleter.completeError(error);
    }
    if (!_closed) {
      _closed = true;
      _streamController.addError(error);
      _streamController.close();
      channel.dispose();
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}
