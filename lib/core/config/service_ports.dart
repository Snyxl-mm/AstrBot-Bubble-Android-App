import 'package:settings/settings.dart';

class ServicePorts {
  static const int defaultDashboardPort = 6185;
  static const int defaultOneBotWsPort = 6199;
  static const int defaultNapCatWebUiPort = 6099;
  static const int defaultOpenCodePort = 4096;
  static const int defaultSnowLumaWebUiPort = 5099;
  static const int defaultSnowLumaVncPort = 6081;
  static const int defaultSnowLumaOneBotWsPort = 3001;

  static SettingNode get _dashboardPort => 'astrbot_dashboard_port'.setting;
  static SettingNode get _oneBotWsPort => 'astrbot_onebot_ws_port'.setting;
  static SettingNode get _napCatWebUiPort => 'napcat_webui_port'.setting;
  static SettingNode get _openCodePort => 'opencode_webui_port'.setting;
  static SettingNode get _snowLumaWebUiPort => 'snowluma_webui_port'.setting;
  static SettingNode get _snowLumaVncPort => 'snowluma_vnc_port'.setting;
  static SettingNode get _snowLumaOneBotWsPort =>
      'snowluma_onebot_ws_port'.setting;

  static int get dashboardPort =>
      _readPort(_dashboardPort, defaultDashboardPort);
  static int get oneBotWsPort => _readPort(_oneBotWsPort, defaultOneBotWsPort);
  static int get napCatWebUiPort =>
      _readPort(_napCatWebUiPort, defaultNapCatWebUiPort);
  static int get openCodePort => _readPort(_openCodePort, defaultOpenCodePort);
  static int get snowLumaWebUiPort =>
      _readPort(_snowLumaWebUiPort, defaultSnowLumaWebUiPort);
  static int get snowLumaVncPort =>
      _readPort(_snowLumaVncPort, defaultSnowLumaVncPort);
  static int get snowLumaOneBotWsPort =>
      _readPort(_snowLumaOneBotWsPort, defaultSnowLumaOneBotWsPort);

  static String get dashboardUrl => 'http://127.0.0.1:$dashboardPort';
  static String get napCatWebUiUrl => 'http://127.0.0.1:$napCatWebUiPort/webui';
  static String get oneBotWsUrl => 'ws://localhost:$oneBotWsPort/ws';
  static String get openCodeWebUiUrl => 'http://127.0.0.1:$openCodePort';
  static String get snowLumaWebUiUrl => 'http://127.0.0.1:$snowLumaWebUiPort/';
  static String get snowLumaVncUrl =>
      'http://127.0.0.1:$snowLumaVncPort/vnc.html';
  static String get snowLumaOneBotWsUrl =>
      'ws://127.0.0.1:$snowLumaOneBotWsPort/';
  static int get napCatXDisplay {
    if (dashboardPort == defaultDashboardPort &&
        oneBotWsPort == defaultOneBotWsPort &&
        napCatWebUiPort == defaultNapCatWebUiPort) {
      return 1;
    }
    return 10 + dashboardPort % 80;
  }

  static void saveDashboardPort(int port) {
    _dashboardPort.set(port);
  }

  static void saveOpenCodePort(int port) {
    _openCodePort.set(port);
  }

  static bool isValidPort(int port) => port >= 1024 && port <= 65535;

  static int _readPort(SettingNode node, int fallback) {
    final value = node.get();
    final port = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (port == null || !isValidPort(port)) {
      return fallback;
    }
    return port;
  }
}
