import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'document_center_models.dart';

class DocumentReaderScreen extends StatefulWidget {
  final String fileName;
  final Future<DocumentPreviewData> Function() loader;
  final Future<DocumentPreviewChunk> Function({
    required String sectionId,
    required int offset,
  })?
  chunkLoader;
  final String? initialSectionId;
  final int initialOffset;
  final double initialProgress;
  final Future<void> Function({
    required String sectionId,
    required int offset,
    required double progress,
  })?
  onProgress;

  const DocumentReaderScreen({
    super.key,
    required this.fileName,
    required this.loader,
    this.chunkLoader,
    this.initialSectionId,
    this.initialOffset = 0,
    this.initialProgress = 0,
    this.onProgress,
  });

  @override
  State<DocumentReaderScreen> createState() => _DocumentReaderScreenState();
}

class _DocumentReaderScreenState extends State<DocumentReaderScreen> {
  late Future<DocumentPreviewData> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _retry() {
    setState(() => _future = widget.loader());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<DocumentPreviewData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ReaderError(message: '${snapshot.error}', onRetry: _retry);
          }
          return _ReaderContent(
            data: snapshot.requireData,
            chunkLoader: widget.chunkLoader,
            initialSectionId: widget.initialSectionId,
            initialOffset: widget.initialOffset,
            initialProgress: widget.initialProgress,
            onProgress: widget.onProgress,
          );
        },
      ),
    );
  }
}

class _ReaderContent extends StatefulWidget {
  final DocumentPreviewData data;
  final Future<DocumentPreviewChunk> Function({
    required String sectionId,
    required int offset,
  })?
  chunkLoader;
  final String? initialSectionId;
  final int initialOffset;
  final double initialProgress;
  final Future<void> Function({
    required String sectionId,
    required int offset,
    required double progress,
  })?
  onProgress;

  const _ReaderContent({
    required this.data,
    this.chunkLoader,
    this.initialSectionId,
    this.initialOffset = 0,
    this.initialProgress = 0,
    this.onProgress,
  });

  @override
  State<_ReaderContent> createState() => _ReaderContentState();
}

class _ReaderContentState extends State<_ReaderContent> {
  int _sectionIndex = 0;
  double _fontSize = 17;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.kind == 'pdf' && data.pdfUri != null) {
      return PdfViewer.uri(
        data.pdfUri!,
        headers: data.pdfHeaders,
        preferRangeAccess: true,
        useProgressiveLoading: true,
      );
    }
    if (data.sections.isEmpty) {
      return const Center(child: Text('文档没有可显示的内容'));
    }
    if (data.paged && widget.chunkLoader != null) {
      return _PagedTextReader(
        data: data,
        chunkLoader: widget.chunkLoader!,
        initialSectionId: widget.initialSectionId,
        initialOffset: widget.initialOffset,
        initialProgress: widget.initialProgress,
        onProgress: widget.onProgress,
      );
    }
    final section =
        data.sections[_sectionIndex.clamp(0, data.sections.length - 1)];
    return Column(
      children: [
        if (data.sections.length > 1)
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: _sectionIndex,
                        isExpanded: true,
                        items: [
                          for (
                            var index = 0;
                            index < data.sections.length;
                            index++
                          )
                            DropdownMenuItem(
                              value: index,
                              child: Text(
                                '${index + 1}. ${data.sections[index].title}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _sectionIndex = value);
                          }
                        },
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '减小文字',
                    onPressed: _fontSize <= 13
                        ? null
                        : () => setState(() => _fontSize -= 1),
                    icon: const Icon(Icons.text_decrease),
                  ),
                  IconButton(
                    tooltip: '增大文字',
                    onPressed: _fontSize >= 26
                        ? null
                        : () => setState(() => _fontSize += 1),
                    icon: const Icon(Icons.text_increase),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: SelectionArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 26, 22, 44),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (data.sections.length > 1)
                      Text(
                        section.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    if (data.sections.length > 1) const SizedBox(height: 20),
                    Text(
                      section.content,
                      style: TextStyle(
                        fontSize: _fontSize,
                        height: 1.75,
                        letterSpacing: 0,
                      ),
                    ),
                    if (data.truncated) ...[
                      const SizedBox(height: 24),
                      Text(
                        '内容较大，当前仅显示在线预览范围。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PagedTextReader extends StatefulWidget {
  final DocumentPreviewData data;
  final Future<DocumentPreviewChunk> Function({
    required String sectionId,
    required int offset,
  })
  chunkLoader;
  final String? initialSectionId;
  final int initialOffset;
  final double initialProgress;
  final Future<void> Function({
    required String sectionId,
    required int offset,
    required double progress,
  })?
  onProgress;

  const _PagedTextReader({
    required this.data,
    required this.chunkLoader,
    this.initialSectionId,
    this.initialOffset = 0,
    this.initialProgress = 0,
    this.onProgress,
  });

  @override
  State<_PagedTextReader> createState() => _PagedTextReaderState();
}

class _PagedTextReaderState extends State<_PagedTextReader> {
  final _pageController = PageController();
  final _pages = <_ReaderPage>[];
  int _currentPage = 0;
  int _generation = 0;
  int _startSectionIndex = 0;
  int _startOffset = 0;
  int _bufferSectionIndex = -1;
  int _bufferOffset = 0;
  int _bufferNextOffset = 0;
  String _buffer = '';
  String _bufferTitle = '';
  bool _bufferLoaded = false;
  bool _bufferHasMore = false;
  bool _sectionStarted = false;
  bool _endReached = false;
  bool _loading = false;
  bool _layoutResetScheduled = false;
  double? _layoutWidth;
  double? _layoutHeight;
  double _fontSize = 18;
  _ReaderTheme _theme = _ReaderTheme.paper;
  String _lastSavedPosition = '';

  Color get _backgroundColor => switch (_theme) {
    _ReaderTheme.paper => const Color(0xfff5eddf),
    _ReaderTheme.gray => const Color(0xffe7e7e2),
    _ReaderTheme.night => const Color(0xff1b1c1f),
  };

  Color get _foregroundColor => _theme == _ReaderTheme.night
      ? const Color(0xffe5e1d8)
      : const Color(0xff302d28);

  @override
  void initState() {
    super.initState();
    _startSectionIndex = _sectionForId(widget.initialSectionId);
    _startOffset = widget.initialOffset.clamp(0, 1 << 30);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  int _sectionForId(String? id) {
    if (id == null || id.isEmpty) return 0;
    final index = widget.data.sections.indexWhere((item) => item.id == id);
    return index < 0 ? 0 : index;
  }

  void _scheduleLayoutReset(double width, double height) {
    if (_layoutResetScheduled || width <= 0 || height <= 0) return;
    if (_layoutWidth != null &&
        (_layoutWidth! - width).abs() < .5 &&
        (_layoutHeight! - height).abs() < .5) {
      return;
    }
    _layoutResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutResetScheduled = false;
      if (!mounted) return;
      final current = _pages.isEmpty ? null : _pages[_currentPage];
      _resetPagination(
        sectionIndex: current == null
            ? _startSectionIndex
            : _sectionIndexForPage(current),
        offset: current?.startOffset ?? _startOffset,
        width: width,
        height: height,
      );
    });
  }

  int _sectionIndexForPage(_ReaderPage page) {
    final index = widget.data.sections.indexWhere(
      (section) => section.id == page.sectionId,
    );
    return index < 0 ? _startSectionIndex : index;
  }

  void _resetPagination({
    required int sectionIndex,
    required int offset,
    double? width,
    double? height,
  }) {
    _generation++;
    _startSectionIndex = sectionIndex.clamp(0, widget.data.sections.length - 1);
    _startOffset = offset;
    _bufferSectionIndex = -1;
    _buffer = '';
    _bufferLoaded = false;
    _bufferHasMore = false;
    _sectionStarted = false;
    _endReached = false;
    _loading = false;
    _currentPage = 0;
    _pages.clear();
    _layoutWidth = width ?? _layoutWidth;
    _layoutHeight = height ?? _layoutHeight;
    if (_pageController.hasClients) _pageController.jumpToPage(0);
    setState(() {});
    unawaited(_ensurePage(1, _generation));
  }

  TextStyle _bodyStyle() => TextStyle(
    color: _foregroundColor,
    fontSize: _fontSize,
    height: 1.85,
    letterSpacing: 0,
  );

  Future<bool> _loadBufferChunk(int generation, {required bool append}) async {
    if (!mounted || generation != _generation) return false;
    if (_bufferSectionIndex < 0) {
      _bufferSectionIndex = _startSectionIndex;
      _bufferOffset = _startOffset;
      _bufferTitle = widget.data.sections[_bufferSectionIndex].title;
    }
    final section = widget.data.sections[_bufferSectionIndex];
    final requestOffset = append ? _bufferNextOffset : _bufferOffset;
    final chunk = await widget.chunkLoader(
      sectionId: section.id,
      offset: requestOffset,
    );
    if (!mounted || generation != _generation) return false;
    if (append) {
      _buffer += chunk.content;
    } else {
      _buffer = chunk.content;
      _bufferOffset = chunk.offset;
    }
    _bufferNextOffset = chunk.nextOffset;
    _bufferHasMore = chunk.hasMore;
    _bufferLoaded = true;
    return chunk.content.isNotEmpty || chunk.hasMore;
  }

  Future<bool> _ensureBuffer(int generation) async {
    while (mounted && generation == _generation) {
      if (_buffer.isNotEmpty) return true;
      if (!_bufferLoaded) {
        if (!await _loadBufferChunk(generation, append: false)) break;
        continue;
      }
      if (_bufferHasMore) {
        if (!await _loadBufferChunk(generation, append: true)) break;
        continue;
      }
      final nextIndex = _bufferSectionIndex + 1;
      if (nextIndex >= widget.data.sections.length) break;
      _bufferSectionIndex = nextIndex;
      _bufferOffset = 0;
      _bufferNextOffset = 0;
      _bufferTitle = widget.data.sections[nextIndex].title;
      _bufferLoaded = false;
      _sectionStarted = false;
    }
    return _buffer.isNotEmpty;
  }

  int _fitTextEnd(String content, double width, double height) {
    final painter = TextPainter(
      text: TextSpan(text: content, style: _bodyStyle()),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.justify,
    )..layout(maxWidth: width);
    if (painter.height <= height + 1) return content.length;
    final position = painter.getPositionForOffset(Offset(width, height));
    var end = painter.getLineBoundary(position).end;
    if (end <= 0) {
      end = painter.getLineBoundary(const TextPosition(offset: 0)).end;
    }
    return end.clamp(1, content.length);
  }

  Future<bool> _appendVisualPage(int generation) async {
    final width = _layoutWidth;
    final height = _layoutHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return false;
    }
    while (mounted && generation == _generation) {
      if (!await _ensureBuffer(generation)) {
        _endReached = true;
        return false;
      }
      final bodyHeight = height - (_sectionStarted ? 0 : 58) - 80;
      final availableHeight = bodyHeight.clamp(80.0, height);
      final end = _fitTextEnd(_buffer, width, availableHeight);
      if (end == _buffer.length && _bufferHasMore) {
        await _loadBufferChunk(generation, append: true);
        continue;
      }
      final content = _buffer.substring(0, end);
      final startOffset = _bufferOffset;
      final endOffset = startOffset + utf8.encode(content).length;
      _buffer = _buffer.substring(end);
      _bufferOffset = endOffset;
      _pages.add(
        _ReaderPage(
          sectionId: widget.data.sections[_bufferSectionIndex].id,
          title: _sectionStarted ? '' : _bufferTitle,
          startOffset: startOffset,
          endOffset: endOffset,
          hasMore: _buffer.isNotEmpty || _bufferHasMore,
          content: content,
        ),
      );
      _sectionStarted = true;
      return true;
    }
    return false;
  }

  Future<void> _ensurePage(int index, int generation) async {
    if (_loading || index < 0) return;
    _loading = true;
    try {
      while (mounted &&
          generation == _generation &&
          _pages.length <= index &&
          !_endReached) {
        await _appendVisualPage(generation);
      }
      if (mounted && generation == _generation) {
        setState(() {});
        if (_pages.isNotEmpty) _saveProgress(_pages[_currentPage]);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _pages.add(_ReaderPage.error('$error')));
      }
    } finally {
      _loading = false;
    }
  }

  void _saveProgress(_ReaderPage page) {
    final callback = widget.onProgress;
    if (callback == null) return;
    final sectionIndex = _sectionIndexForPage(page);
    final progress =
        widget.data.totalBytes > 0 && widget.data.sections.length == 1
        ? (page.endOffset / widget.data.totalBytes).clamp(0.0, 1.0)
        : ((sectionIndex + (page.hasMore ? .5 : .99)) /
                  widget.data.sections.length)
              .clamp(0.0, 1.0);
    final key = '${page.sectionId}:${page.endOffset}';
    if (key == _lastSavedPosition) return;
    _lastSavedPosition = key;
    unawaited(
      callback(
        sectionId: page.sectionId,
        offset: page.endOffset,
        progress: progress,
      ),
    );
  }

  void _selectSection(String? sectionId) {
    if (sectionId == null) return;
    _resetPagination(
      sectionIndex: _sectionForId(sectionId),
      offset: 0,
      width: _layoutWidth,
      height: _layoutHeight,
    );
  }

  void _changeFont(double delta) {
    final current = _pages.isEmpty ? null : _pages[_currentPage];
    _fontSize = (_fontSize + delta).clamp(14, 28);
    _resetPagination(
      sectionIndex: current == null
          ? _startSectionIndex
          : _sectionIndexForPage(current),
      offset: current?.startOffset ?? _startOffset,
      width: _layoutWidth,
      height: _layoutHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 48).clamp(160.0, 1200.0);
        final height = constraints.maxHeight;
        _scheduleLayoutReset(width, height);
        return ColoredBox(
          color: _backgroundColor,
          child: Column(
            children: [
              Material(
                color: _backgroundColor,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value:
                                  widget.data.sections.any(
                                    (item) =>
                                        item.id ==
                                        (_pages.isEmpty
                                            ? null
                                            : _pages[_currentPage].sectionId),
                                  )
                                  ? _pages[_currentPage].sectionId
                                  : null,
                              hint: const Text('目录'),
                              isExpanded: true,
                              dropdownColor: _backgroundColor,
                              items: [
                                for (final section in widget.data.sections)
                                  DropdownMenuItem(
                                    value: section.id,
                                    child: Text(
                                      section.title,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: _selectSection,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '减小文字',
                          onPressed: _fontSize <= 14
                              ? null
                              : () => _changeFont(-1),
                          icon: const Icon(Icons.text_decrease),
                        ),
                        IconButton(
                          tooltip: '增大文字',
                          onPressed: _fontSize >= 28
                              ? null
                              : () => _changeFont(1),
                          icon: const Icon(Icons.text_increase),
                        ),
                        PopupMenuButton<_ReaderTheme>(
                          tooltip: '阅读主题',
                          icon: const Icon(Icons.palette_outlined),
                          onSelected: (value) => setState(() => _theme = value),
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: _ReaderTheme.paper,
                              child: Text('纸张'),
                            ),
                            PopupMenuItem(
                              value: _ReaderTheme.gray,
                              child: Text('灰底'),
                            ),
                            PopupMenuItem(
                              value: _ReaderTheme.night,
                              child: Text('夜间'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _pages.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : PageView.builder(
                        controller: _pageController,
                        itemCount: _pages.length,
                        onPageChanged: (index) {
                          _currentPage = index;
                          _saveProgress(_pages[index]);
                          unawaited(_ensurePage(index + 1, _generation));
                          setState(() {});
                        },
                        itemBuilder: (context, index) => _ReaderPageView(
                          page: _pages[index],
                          fontSize: _fontSize,
                          foregroundColor: _foregroundColor,
                        ),
                      ),
              ),
              Material(
                color: _backgroundColor,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 5, 18, 7),
                    child: Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: _pages.isEmpty
                                ? null
                                : widget.data.totalBytes > 0 &&
                                      widget.data.sections.length == 1
                                ? (_pages[_currentPage].endOffset /
                                          widget.data.totalBytes)
                                      .clamp(0.0, 1.0)
                                : null,
                            minHeight: 2,
                            color: colorScheme.primary,
                            backgroundColor: _foregroundColor.withValues(
                              alpha: .16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _pages.isEmpty
                              ? '加载中'
                              : '${_currentPage + 1}${_endReached ? ' / ${_pages.length}' : ' / …'}',
                          style: TextStyle(
                            color: _foregroundColor.withValues(alpha: .7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ReaderPageView extends StatelessWidget {
  final _ReaderPage page;
  final double fontSize;
  final Color foregroundColor;

  const _ReaderPageView({
    required this.page,
    required this.fontSize,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    if (page.error != null) {
      return Center(child: Text(page.error!, textAlign: TextAlign.center));
    }
    return SelectionArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 52),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (page.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Text(
                  page.title,
                  style: TextStyle(
                    color: foregroundColor.withValues(alpha: .65),
                    fontSize: 13,
                  ),
                ),
              ),
            Text(
              page.content,
              textAlign: TextAlign.justify,
              style: TextStyle(
                color: foregroundColor,
                fontSize: fontSize,
                height: 1.85,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ReaderTheme { paper, gray, night }

class _ReaderPage {
  final String sectionId;
  final String title;
  final int startOffset;
  final int endOffset;
  final bool hasMore;
  final String content;
  final String? error;

  const _ReaderPage({
    required this.sectionId,
    required this.title,
    required this.startOffset,
    required this.endOffset,
    required this.hasMore,
    required this.content,
  }) : error = null;

  const _ReaderPage.error(String message)
    : sectionId = '',
      title = '',
      startOffset = 0,
      endOffset = 0,
      hasMore = false,
      content = '',
      error = message;
}

class _ReaderError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ReaderError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_outlined, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
