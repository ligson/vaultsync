import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/api_exception.dart';
import 'remote_file_preview.dart';

class FilePreviewScreen extends StatefulWidget {
  final String fileName;
  final Future<RemoteFilePreviewData> Function() loader;

  const FilePreviewScreen({
    super.key,
    required this.fileName,
    required this.loader,
  });

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  late Future<RemoteFilePreviewData> _previewFuture;

  @override
  void initState() {
    super.initState();
    _previewFuture = widget.loader();
  }

  void _retry() {
    setState(() {
      _previewFuture = widget.loader();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: FutureBuilder<RemoteFilePreviewData>(
        future: _previewFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _PreviewLoadingView();
          }
          if (snapshot.hasError) {
            return _PreviewErrorView(
              message: userReadableErrorMessage(snapshot.error!),
              onRetry: _retry,
            );
          }
          return _PreviewContent(data: snapshot.requireData);
        },
      ),
    );
  }
}

class _PreviewLoadingView extends StatelessWidget {
  const _PreviewLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在安全下载并解密...'),
        ],
      ),
    );
  }
}

class _PreviewErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _PreviewErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.preview_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewContent extends StatelessWidget {
  final RemoteFilePreviewData data;

  const _PreviewContent({required this.data});

  @override
  Widget build(BuildContext context) {
    return switch (data.kind) {
      RemoteFilePreviewKind.image => _ImagePreview(bytes: data.bytes),
      RemoteFilePreviewKind.video => _VideoPreview(
        fileName: data.name,
        bytes: data.bytes,
      ),
      RemoteFilePreviewKind.pdf => PdfViewer.data(
        data.bytes,
        sourceName: data.name,
      ),
      RemoteFilePreviewKind.text => _TextPreview(bytes: data.bytes),
    };
  }
}

class _ImagePreview extends StatelessWidget {
  final Uint8List bytes;

  const _ImagePreview({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) =>
                const _MediaError(message: '图片内容无法显示，可能是设备不支持此编码格式'),
          ),
        ),
      ),
    );
  }
}

class _TextPreview extends StatelessWidget {
  final Uint8List bytes;

  const _TextPreview({required this.bytes});

  @override
  Widget build(BuildContext context) {
    final content = utf8.decode(bytes, allowMalformed: true);
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: Text(
            content,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
        ),
      ),
    );
  }
}

class _VideoPreview extends StatefulWidget {
  final String fileName;
  final Uint8List bytes;

  const _VideoPreview({required this.fileName, required this.bytes});

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  File? _temporaryFile;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final temporaryDirectory = await getTemporaryDirectory();
      final previewDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}vaultsync-preview',
      );
      await previewDirectory.create(recursive: true);
      await _clearStalePreviewFiles(previewDirectory);
      final extension = _safeExtension(widget.fileName);
      final file = File(
        '${previewDirectory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}$extension',
      );
      await file.writeAsBytes(widget.bytes, flush: true);
      _temporaryFile = file;
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      controller.addListener(_onControllerChanged);
      if (!mounted) {
        await controller.dispose();
        await _deleteTemporaryFile(file);
        return;
      }
      setState(() {
        _controller = controller;
      });
    } catch (error) {
      final file = _temporaryFile;
      _temporaryFile = null;
      await _deleteTemporaryFile(file);
      if (mounted) {
        setState(() {
          _error = error;
        });
      }
    }
  }

  Future<void> _clearStalePreviewFiles(Directory directory) async {
    try {
      await for (final entity in directory.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }
    } catch (_) {
      // A stale file can remain until the OS clears its temporary directory.
    }
  }

  String _safeExtension(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex < 0) {
      return '.mp4';
    }
    final extension = fileName.substring(dotIndex).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.mp4';
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    final file = _temporaryFile;
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      controller.dispose().whenComplete(() => _deleteTemporaryFile(file));
    } else {
      _deleteTemporaryFile(file);
    }
    super.dispose();
  }

  Future<void> _deleteTemporaryFile(File? file) async {
    if (file == null) {
      return;
    }
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // The OS temporary directory remains the fallback cleanup boundary.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const ColoredBox(
        color: Colors.black,
        child: _MediaError(message: '视频无法播放，可能是设备不支持此编码格式'),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final value = controller.value;
    final durationMilliseconds = value.duration.inMilliseconds;
    final positionMilliseconds = value.position.inMilliseconds.clamp(
      0,
      durationMilliseconds,
    );
    return ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: GestureDetector(
                onTap: _togglePlayback,
                child: AspectRatio(
                  aspectRatio: value.aspectRatio == 0
                      ? 16 / 9
                      : value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoPlayer(controller),
                      if (!value.isPlaying)
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: value.isPlaying ? '暂停' : '播放',
                    onPressed: _togglePlayback,
                    color: Colors.white,
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: positionMilliseconds.toDouble(),
                      max: durationMilliseconds <= 0
                          ? 1
                          : durationMilliseconds.toDouble(),
                      onChanged: durationMilliseconds <= 0
                          ? null
                          : (next) => controller.seekTo(
                              Duration(milliseconds: next.round()),
                            ),
                    ),
                  ),
                  Text(
                    '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _togglePlayback() {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      if (controller.value.position >= controller.value.duration) {
        controller.seekTo(Duration.zero);
      }
      controller.play();
    }
  }

  String _formatDuration(Duration value) {
    String two(int number) => number.toString().padLeft(2, '0');
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }
}

class _MediaError extends StatelessWidget {
  final String message;

  const _MediaError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
