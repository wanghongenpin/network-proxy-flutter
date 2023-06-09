import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:network_proxy/network/util/host_filter.dart';
import 'package:network_proxy/utils/platform.dart';
import 'package:path_provider/path_provider.dart';

import '../channel.dart';
import '../handler.dart';
import '../http/codec.dart';
import '../util/logger.dart';
import '../util/request_rewrite.dart';
import '../util/system_proxy.dart';

Future<void> main() async {
  ProxyServer().start();
}

/// 代理服务器
class ProxyServer {
  bool init = false;
  int port = 6666;
  bool _enableSsl = false;
  bool enableDesktop = true;

  Server? server;
  EventListener? listener;
  RequestRewrites requestRewrites = RequestRewrites();

  final List<Function> _initializedListeners = [];

  ProxyServer({this.listener});

  bool get enableSsl => _enableSsl;

  //初始化
  Future<void> initializedListener(Function action) async {
    _initializedListeners.add(action);
  }

  Future<File> homeDir() async {
    String? userHome;
    if (Platforms.isDesktop()) {
      userHome = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    } else {
      userHome = (await getApplicationSupportDirectory()).path;
    }

    var separator = Platform.pathSeparator;
    return File("${userHome!}$separator.proxypin");
  }

  /// 配置文件
  Future<File> configFile() async {
    var separator = Platform.pathSeparator;
    var home = await homeDir();
    return File("${home.path}${separator}config.cnf");
  }

  /// 是否启用ssl
  set enableSsl(bool enableSsl) {
    _enableSsl = enableSsl;
    server?.enableSsl = enableSsl;
    if (server == null || server?.isRunning == false) {
      return;
    }

    if (Platform.isMacOS) {
      SystemProxy.setSslProxyEnableMacOS(enableSsl, port);
    }
  }

  /// 启动代理服务
  Future<Server> start() async {
    Server server = Server();
    if (!init) {
      // 读取配置文件
      init = true;
      await _loadConfig();
      for (var element in _initializedListeners) {
        element.call();
      }
    }

    server.enableSsl = _enableSsl;
    server.initChannel((channel) {
      channel.pipeline.handle(HttpRequestCodec(), HttpResponseCodec(),
          HttpChannelHandler(listener: listener, requestRewrites: requestRewrites));
    });
    return server.bind(port).then((serverSocket) {
      logger.i("listen on $port");
      this.server = server;
      if (enableDesktop) {
        SystemProxy.setSystemProxy(port, enableSsl);
      }
      return server;
    });
  }

  /// 停止代理服务
  Future<Server?> stop() async {
    logger.i("stop on $port");
    if (enableDesktop) {
      if (Platform.isMacOS) {
        await SystemProxy.setProxyEnableMacOS(false, enableSsl);
      } else if (Platform.isWindows) {
        await SystemProxy.setProxyEnableWindows(false);
      }
    }
    await server?.stop();
    return server;
  }

  /// 重启代理服务
  restart() {
    stop().then((value) => start());
  }

  /// 刷新配置文件
  flushConfig() async {
    var file = await configFile();
    var exists = await file.exists();
    if (!exists) {
      file = await file.create(recursive: true);
    }
    HostFilter.whitelist.toJson();
    HostFilter.blacklist.toJson();
    var json = jsonEncode(toJson());
    logger.i('刷新配置文件 $runtimeType ${toJson()}');
    file.writeAsString(json);
  }

  /// 加载配置文件
  Future<void> _loadConfig() async {
    var file = await configFile();
    var exits = await file.exists();
    if (!exits) {
      return;
    }
    Map<String, dynamic> config = jsonDecode(await file.readAsString());
    logger.i('加载配置文件 [$file]');
    port = config['port'] ?? port;
    enableSsl = config['enableSsl'] == true;
    enableDesktop = config['enableDesktop'] ?? true;
    HostFilter.whitelist.load(config['whitelist']);
    HostFilter.blacklist.load(config['blacklist']);

    await _loadRequestRewriteConfig();
  }

  /// 加载请求重写配置文件
  Future<void> _loadRequestRewriteConfig() async {
    var home = await homeDir();
    var file = File('${home.path}${Platform.pathSeparator}request_rewrite.json');
    var exits = await file.exists();
    if (!exits) {
      return;
    }

    Map<String, dynamic> config = jsonDecode(await file.readAsString());

    logger.i('加载请求重写配置文件 [$file]');
    requestRewrites.load(config);
  }

  /// 保存请求重写配置文件
  flushRequestRewriteConfig() async {
    var home = await homeDir();
    var file = File('${home.path}${Platform.pathSeparator}request_rewrite.json');
    bool exists = await file.exists();
    if (!exists) {
      await file.create(recursive: true);
    }
    var json = jsonEncode(requestRewrites.toJson());
    logger.i('刷新请求重写配置文件 ${file.path}');
    file.writeAsString(json);
  }

  Map<String, dynamic> toJson() {
    return {
      'port': port,
      'enableSsl': enableSsl,
      'enableDesktop': enableDesktop,
      'whitelist': HostFilter.whitelist.toJson(),
      'blacklist': HostFilter.blacklist.toJson(),
    };
  }
}
