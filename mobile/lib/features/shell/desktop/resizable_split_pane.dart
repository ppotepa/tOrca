import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/app_theme.dart';

class ResizableSplitPane extends StatefulWidget {
  const ResizableSplitPane({
    super.key,
    required this.sidebar,
    required this.content,
    this.minimumSidebarWidth = 240,
    this.maximumSidebarWidth = 520,
    this.initialSidebarWidth = 320,
    this.storageKey = 'torchat.desktop.sidebar.width',
  });

  final Widget sidebar;
  final Widget content;
  final double minimumSidebarWidth;
  final double maximumSidebarWidth;
  final double initialSidebarWidth;
  final String storageKey;

  @override
  State<ResizableSplitPane> createState() => _ResizableSplitPaneState();
}

class _ResizableSplitPaneState extends State<ResizableSplitPane> {
  late double _sidebarWidth = widget.initialSidebarWidth;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _restoreWidth();
  }

  Future<void> _restoreWidth() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getDouble(widget.storageKey);
    if (!mounted || stored == null) return;
    setState(() {
      _sidebarWidth = stored.clamp(
        widget.minimumSidebarWidth,
        widget.maximumSidebarWidth,
      );
    });
  }

  Future<void> _persistWidth() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(widget.storageKey, _sidebarWidth);
  }

  void _resize(double delta, double availableWidth) {
    final dynamicMaximum = (availableWidth * .48).clamp(
      widget.minimumSidebarWidth,
      widget.maximumSidebarWidth,
    );
    setState(() {
      _sidebarWidth = (_sidebarWidth + delta).clamp(
        widget.minimumSidebarWidth,
        dynamicMaximum,
      );
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final dynamicMaximum = (availableWidth * .48).clamp(
            widget.minimumSidebarWidth,
            widget.maximumSidebarWidth,
          );
          final width = _sidebarWidth.clamp(
            widget.minimumSidebarWidth,
            dynamicMaximum,
          );
          return Row(
            children: [
              SizedBox(width: width, child: widget.sidebar),
              _ResizeHandle(
                dragging: _dragging,
                onDoubleTap: () {
                  setState(() => _sidebarWidth = widget.initialSidebarWidth);
                  _persistWidth();
                },
                onDragStart: () => setState(() => _dragging = true),
                onDragUpdate: (delta) => _resize(delta, availableWidth),
                onDragEnd: () {
                  setState(() => _dragging = false);
                  _persistWidth();
                },
              ),
              Expanded(child: widget.content),
            ],
          );
        },
      );
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.dragging,
    required this.onDoubleTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool dragging;
  final VoidCallback onDoubleTap;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: onDoubleTap,
        onHorizontalDragStart: (_) => onDragStart(),
        onHorizontalDragUpdate: (details) => onDragUpdate(details.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 8,
          color: dragging
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .18)
              : shell.surface,
          child: Center(
            child: Container(
              width: dragging ? 3 : 1,
              height: 38,
              color: dragging
                  ? Theme.of(context).colorScheme.primary
                  : shell.border,
            ),
          ),
        ),
      ),
    );
  }
}
