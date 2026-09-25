import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_shell.dart';
import 'update/update_controller.dart';
import 'update/update_screen.dart';
import 'update/update_activity.dart';
import 'sync/sync_guard_repository.dart';
import 'app_theme.dart';
import 'data/local/sqlite_pilgrimage_repository.dart';
import 'data/pilgrimage_repository.dart';
import 'data/sample_pilgrimage_repository.dart';
import 'desktop/desktop_pilgrimage_repository.dart';
import 'desktop/tauri_bridge.dart';
import 'plan/pilgrimage_models.dart';
import 'widgets/copyable_text.dart';
import 'widgets/app_motion.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'ProjectTabi Readable Dark / OpenFreeMap / OpenMapTiles',
    ], await rootBundle.loadString('assets/maps/LICENSE.txt'));
  });
  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  _installDesktopErrorLogging();
  runApp(const ProjectTabiBootstrap());
}

typedef PilgrimageRepositoryLoader = Future<PilgrimageRepository> Function();

class ProjectTabiBootstrap extends StatefulWidget {
  const ProjectTabiBootstrap({
    this.repositoryLoader = _createDefaultRepository,
    super.key,
  });

  final PilgrimageRepositoryLoader repositoryLoader;

  @override
  State<ProjectTabiBootstrap> createState() => _ProjectTabiBootstrapState();
}

class _ProjectTabiBootstrapState extends State<ProjectTabiBootstrap> {
  PilgrimageRepository? _repository;
  DesktopLauncherInfo? _launcherInfo;
  Object? _error;
  StackTrace? _stackTrace;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
      _stackTrace = null;
    });
    try {
      if (isTauriLauncherAvailable) {
        try {
          _launcherInfo = await loadDesktopLauncherInfo();
        } catch (_) {
          _launcherInfo = null;
        }
      }
      final repository = await widget.repositoryLoader();
      if (!mounted) {
        return;
      }
      setState(() {
        _repository = repository;
        _loading = false;
      });
    } catch (error, stackTrace) {
      unawaited(_writeDesktopError('startup failed', error, stackTrace));
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _stackTrace = stackTrace;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    if (repository != null) {
      return ProjectTabiApp(repository: repository);
    }
    return MaterialApp(
      title: 'ProjectTabi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: SafeArea(
          child: _loading
              ? const _DesktopStartupLoading()
              : _DesktopStartupError(
                  error: _error,
                  stackTrace: _stackTrace,
                  launcherInfo: _launcherInfo,
                  onRetry: _start,
                ),
        ),
      ),
    );
  }
}

class _DesktopStartupLoading extends StatelessWidget {
  const _DesktopStartupLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 20),
          Text('正在加载 ProjectTabi...'),
        ],
      ),
    );
  }
}

class _DesktopStartupError extends StatelessWidget {
  const _DesktopStartupError({
    required this.error,
    required this.stackTrace,
    required this.launcherInfo,
    required this.onRetry,
  });

  final Object? error;
  final StackTrace? stackTrace;
  final DesktopLauncherInfo? launcherInfo;
  final Future<void> Function() onRetry;

  Future<void> _openDirectory(BuildContext context, String target) async {
    try {
      await openDesktopDirectory(target: target);
    } catch (openError) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开目录：$openError')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = [
      if (error != null) error.toString(),
      if (stackTrace != null) stackTrace.toString(),
    ].join('\n');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.circleAlert,
                size: 52,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'ProjectTabi 启动失败',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                '用户数据没有被删除。请重试，或打开日志目录查看 startup.log。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const ValueKey('desktop-startup-retry'),
                onPressed: onRetry,
                icon: const Icon(LucideIcons.refreshCw),
                label: const Text('重试'),
              ),
              if (launcherInfo != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _openDirectory(context, 'logs'),
                      icon: const Icon(LucideIcons.fileText),
                      label: const Text('打开日志目录'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _openDirectory(context, 'data'),
                      icon: const Icon(LucideIcons.folderOpen),
                      label: const Text('打开数据目录'),
                    ),
                  ],
                ),
              ],
              if (details.isNotEmpty) ...[
                const SizedBox(height: 20),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('错误详情'),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: SelectionArea(
                        child: Text(
                          details,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ProjectTabiApp extends StatefulWidget {
  const ProjectTabiApp({this.repository, super.key});

  final PilgrimageRepository? repository;

  @override
  State<ProjectTabiApp> createState() => _ProjectTabiAppState();
}

class _ProjectTabiAppState extends State<ProjectTabiApp> with WidgetsBindingObserver {
  AppSettings _themeSettings = const AppSettings();
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  String? _notifiedUpdate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppUpdateController.instance.addListener(_updateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(AppUpdateController.instance.onForeground(true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppUpdateController.instance.removeListener(_updateChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(AppUpdateController.instance.onForeground(state == AppLifecycleState.resumed));
  }

  void _updateChanged() {
    final update = AppUpdateController.instance;
    final navigator = _navigatorKey.currentState;
    if (!mounted || !update.hasUpdate || update.version == _notifiedUpdate ||
        navigator == null || navigator.canPop() || UpdateActivity.busy) return;
    _notifiedUpdate = update.version;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(SnackBar(
        content: Text('ProjectTabi ${update.version} 已可更新'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: '查看', onPressed: () {
          if (!navigator.canPop() && !UpdateActivity.busy) {
            navigator.push(MaterialPageRoute<void>(builder: (_) => const AppUpdateScreen()));
          }
        }),
      ));
    });
  }

  @override
  void didChangePlatformBrightness() {
    if (!mounted) {
      return;
    }
    applyAppColorsFromSettings(
      _themeSettings,
      platformBrightness: currentPlatformBrightness(),
    );
    setState(() {});
  }

  void _handleSettingsChanged(AppSettings settings) {
    if (!mounted) {
      return;
    }
    applyAppColorsFromSettings(
      settings,
      platformBrightness: currentPlatformBrightness(),
    );
    setState(() {
      _themeSettings = settings;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = appThemeFor(
      _themeSettings,
      platformBrightness: currentPlatformBrightness(),
    );

    return MaterialApp(
      title: 'ProjectTabi',
      debugShowCheckedModeBanner: false,
      theme: theme,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      themeAnimationDuration: Duration.zero,
      themeAnimationStyle: AnimationStyle.noAnimation,
      navigatorObservers: [copyOverlayNavigatorObserver],
      builder: (context, child) => AppMotionScope(child: child!),
      home: AppShell(
        repository:
            widget.repository ??
            (kIsWeb
                ? SamplePilgrimageRepository()
                : SqlitePilgrimageRepository()),
        onSettingsChanged: _handleSettingsChanged,
      ),
    );
  }
}

Future<PilgrimageRepository> _createDefaultRepository() async {
  if (!kIsWeb) {
    return SyncGuardRepository(SqlitePilgrimageRepository());
  }
  if (isTauriLauncherAvailable) {
    return SyncGuardRepository(await DesktopPilgrimageRepository.create());
  }
  return SyncGuardRepository(SamplePilgrimageRepository());
}

void _installDesktopErrorLogging() {
  if (!kIsWeb || !isTauriLauncherAvailable) {
    return;
  }
  final previousFlutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    unawaited(
      _writeDesktopError(
        'Flutter framework error',
        details.exception,
        details.stack,
      ),
    );
    if (previousFlutterHandler != null) {
      previousFlutterHandler(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  final previousPlatformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(_writeDesktopError('uncaught Dart error', error, stackTrace));
    return previousPlatformHandler?.call(error, stackTrace) ?? false;
  };
}

Future<void> _writeDesktopError(
  String label,
  Object error,
  StackTrace? stackTrace,
) async {
  if (!isTauriLauncherAvailable) {
    return;
  }
  try {
    await appendDesktopStartupLog(
      message: '$label: $error${stackTrace == null ? '' : '\n$stackTrace'}',
    );
  } catch (_) {}
}
