import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'dart:collection';
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
    allowFileAccessFromFileURLs: true,
    allowUniversalAccessFromFileURLs: true,
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
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source: """
                  (function() {
                    const originalCreateObjectURL = URL.createObjectURL;
                    URL.createObjectURL = function(blob) {
                      const url = originalCreateObjectURL(blob);
                      if (!window._blobs) window._blobs = {};
                      window._blobs[url] = blob;
                      return url;
                    };
                    
                    // Intercept clicks to catch 'download' attribute
                    window.addEventListener('click', function(e) {
                      const target = e.target.closest('a');
                      if (target && target.getAttribute('download')) {
                        window._lastDownloadAttribute = target.getAttribute('download');
                      }
                    }, true);
                  })();
                """,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START
              ),
            ]),
            onWebViewCreated: (controller) {
              webViewController = controller;
              // Register JavaScript Handler for blobs once
              controller.addJavaScriptHandler(handlerName: "onBlobDataReceived", callback: (args) async {
                final String result = args[0];
                final String fileName = args[1];
                
                if (result.startsWith("ERROR:")) {
                  print("JS Download Error: $result");
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Błąd wewnątrz WebView: $result"), backgroundColor: Colors.red),
                    );
                  }
                } else {
                  print("Blob data received via handler! Length: ${result.length}");
                  await _saveAndShareFile(result, fileName);
                }
              });
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

              if (urlString.startsWith("blob:")) {
                // Use the intercepted blob from our global map instead of fetch/XHR
                await controller.evaluateJavascript(source: """
                  (function() {
                    try {
                      var blob = (window._blobs && window._blobs['$urlString']) ? window._blobs['$urlString'] : null;
                      if (!blob) {
                        // Fallback to fetch if not in our map (unlikely but possible)
                        var xhr = new XMLHttpRequest();
                        xhr.open('GET', '$urlString', true);
                        xhr.responseType = 'blob';
                        xhr.onload = function() {
                          if (this.status == 200) { processBlob(this.response); }
                          else { window.flutter_inappwebview.callHandler('onBlobDataReceived', 'ERROR: Blob not found and fetch failed', ''); }
                        };
                        xhr.onerror = function() { window.flutter_inappwebview.callHandler('onBlobDataReceived', 'ERROR: XHR Failed', ''); };
                        xhr.send();
                      } else {
                        processBlob(blob);
                      }

                      function processBlob(b) {
                        var reader = new FileReader();
                        reader.readAsDataURL(b);
                        reader.onloadend = function() {
                          var base64data = reader.result.split(',')[1];
                          var fileName = window._lastDownloadAttribute || '${downloadStartRequest.suggestedFilename}';
                          if (fileName === 'null' || fileName === 'Unknown' || fileName === '') {
                             fileName = 'raport.pdf';
                          }
                          window.flutter_inappwebview.callHandler('onBlobDataReceived', base64data, fileName);
                          // Clear the attribute after use
                          window._lastDownloadAttribute = null;
                        };
                      }
                    } catch (err) {
                      window.flutter_inappwebview.callHandler('onBlobDataReceived', 'ERROR: ' + err.message, '');
                    }
                  })();
                """);
              } else {
                try {
                  final tempDir = await getTemporaryDirectory();
                  String fileName = downloadStartRequest.suggestedFilename ?? 
                      p.basename(downloadStartRequest.url.path);
                  if (fileName.isEmpty) {
                    fileName = "report_${DateTime.now().millisecondsSinceEpoch}.pdf";
                  }
                  final savePath = p.join(tempDir.path, fileName);
                  
                  final dio = Dio();
                  await dio.download(urlString, savePath);
                  
                  // Use our robust sharing logic
                  final bytes = await File(savePath).readAsBytes();
                  await _saveAndShareFile(base64Encode(bytes), fileName);
                } catch (e) {
                  print("Dio download error: $e");
                }
              }
            },
          ),
        ),
      ),
    );
  }
  Future<void> _saveAndShareFile(String base64Data, String fileName) async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Przetwarzanie danych...")),
        );
      }
      
      final tempDir = await getTemporaryDirectory();
      
      // Better filename handling
      String finalName = fileName;
      if (finalName == "null" || finalName.isEmpty || finalName == "Unknown" || finalName == "blob") {
        finalName = "raport_${DateTime.now().millisecondsSinceEpoch}.pdf";
      }
      
      // Ensure PDF extension
      if (!finalName.toLowerCase().endsWith(".pdf")) {
        finalName += ".pdf";
      }
      
      final savePath = p.join(tempDir.path, finalName);
      
      // Sanitise base64 data (strip whitespace)
      final cleanBase64 = base64Data.replaceAll(RegExp(r'\s+'), '');
      final bytes = base64Decode(cleanBase64);
      
      final file = File(savePath);
      await file.writeAsBytes(bytes);
      print("File saved successfully to $savePath");
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Gotowe: $finalName. Udostępnianie...")),
        );
        await Share.shareXFiles([XFile(savePath)], subject: finalName);
      }
    } catch (e) {
      print("Error saving/sharing file: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Błąd zapisu pliku: $e")),
        );
      }
    }
  }
}
