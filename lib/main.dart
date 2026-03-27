import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import 'package:path/path.dart' as p;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await requestPermissions();
  runApp(const InspectHeroApp());
}

Future<void> requestPermissions() async {
  await [
    Permission.camera,
    Permission.location,
    Permission.storage,
    Permission.photos,
  ].request();
}

class InspectHeroApp extends StatelessWidget {
  const InspectHeroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InspectHero App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  final GlobalKey webViewKey = GlobalKey();

  InAppWebViewController? webViewController;
  InAppWebViewSettings settings = InAppWebViewSettings(
    isInspectable: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    iframeAllow: "camera; microphone",
    iframeAllowFullscreen: true,
    javaScriptEnabled: true,
    domStorageEnabled: true,
    allowFileAccess: true,
    javaScriptCanOpenWindowsAutomatically: true,
    cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,
    databaseEnabled: true,
    useOnDownloadStart: true,
    useShouldOverrideUrlLoading: true,
  );

  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;

  PullToRefreshController? pullToRefreshController;
  String url = "https://inspecthero.pl/";

  @override
  void initState() {
    super.initState();

    pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(
        color: Colors.blue,
      ),
      onRefresh: () async {
        if (Platform.isAndroid) {
          webViewController?.reload();
        } else if (Platform.isIOS) {
          webViewController?.loadUrl(
              urlRequest:
                  URLRequest(url: await webViewController?.getUrl()));
        }
      },
    );

    connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      if (results.contains(ConnectivityResult.mobile) || results.contains(ConnectivityResult.wifi)) {
        // Regained internet - trigger sync in WebView
        webViewController?.evaluateJavascript(source: "window.dispatchEvent(new CustomEvent('sync-requested'));");
      }
    });
  }

  @override
  void dispose() {
    connectivitySubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Handling system back button
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (webViewController != null && await webViewController!.canGoBack()) {
          webViewController!.goBack();
        } else {
          // If we can't go back, we should actually pop the screen
          if (context.mounted && Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: InAppWebView(
            key: webViewKey,
            initialUrlRequest:
                URLRequest(url: WebUri("https://inspecthero.pl/")),
            initialSettings: settings,
            pullToRefreshController: pullToRefreshController,
            onWebViewCreated: (controller) {
              webViewController = controller;
            },
            onLoadStart: (controller, url) {
              setState(() {
                this.url = url.toString();
              });
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final url = navigationAction.request.url;
              if (url != null && 
                  (url.path.endsWith('.pdf') || 
                   url.queryParameters['download'] == 'true' ||
                   url.path.contains('/reports/'))) {
                // If it's a PDF or a direct download link, trigger download
                print("Intercepted PDF/Download: $url");
                // controller.onDownloadStartRequest will be called if we don't handle it here
                // but we can explicitly trigger it
                return NavigationActionPolicy.ALLOW; // Let onDownloadStartRequest handle it
              }
              return NavigationActionPolicy.ALLOW;
            },
            onPermissionRequest: (controller, request) async {
              return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT);
            },
            onLoadStop: (controller, url) async {
              pullToRefreshController?.endRefreshing();
              setState(() {
                this.url = url.toString();
              });
            },
            onDownloadStartRequest: (controller, downloadStartRequest) async {
              String urlString = downloadStartRequest.url.toString();
              print("Download started: $urlString");
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Przygotowywanie pliku...")),
                );
              }

              try {
                final tempDir = await getTemporaryDirectory();
                String fileName = downloadStartRequest.suggestedFilename ?? 
                    p.basename(downloadStartRequest.url.path);
                
                if (fileName.isEmpty || fileName == "blob") {
                  fileName = "report_${DateTime.now().millisecondsSinceEpoch}.pdf";
                }
                final savePath = p.join(tempDir.path, fileName);

                if (urlString.startsWith("blob:")) {
                  // Handle Blob by converting it to Base64 in JavaScript
                  print("Found blob URL, converting...");
                  final base64Data = await controller.evaluateJavascript(source: """
                    (async function() {
                      try {
                        const response = await fetch('$urlString');
                        const blob = await response.blob();
                        return new Promise((resolve, reject) => {
                          const reader = new FileReader();
                          reader.onloadend = () => resolve(reader.result.split(',')[1]);
                          reader.onerror = reject;
                          reader.readAsDataURL(blob);
                        });
                      } catch (e) {
                        return null;
                      }
                    })();
                  """);

                  if (base64Data == null) {
                    throw Exception("Błąd konwersji blob na base64");
                  }

                  final bytes = base64Decode(base64Data);
                  final file = File(savePath);
                  await file.writeAsBytes(bytes);
                  print("Blob saved to $savePath");
                } else {
                  // Handle standard URL with Dio
                  final dio = Dio();
                  await dio.download(
                    urlString,
                    savePath,
                  );
                }

                if (mounted) {
                  await Share.shareXFiles(
                    [XFile(savePath)],
                    subject: fileName,
                  );
                }
              } catch (e) {
                print("Download error: $e");
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Błąd pobierania: $e")),
                  );
                }
              }
            },
          ),
        ),
      ),
    );
  }
}
