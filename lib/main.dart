import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';

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
  );

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
          ),
        ),
      ),
    );
  }
}
