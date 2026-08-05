import 'package:flutter/material.dart';

import 'resizable_split_pane.dart';

/// Shared responsive frame used by desktop-capable Flutter applications.
///
/// The shell owns layout state only. Application-specific navigation, lists,
/// content and inspector widgets are supplied as slots so the shared package
/// never depends on a runner, bridge, or feature controller.
class DesktopWorkspaceShell extends StatefulWidget {
  const DesktopWorkspaceShell({
    super.key,
    required this.rail,
    required this.sidebar,
    required this.content,
    this.inspector,
    this.inspectorToggleTooltip = 'Toggle details',
    this.inspectorOpen = true,
    this.onInspectorClosed,
  });

  final Widget Function(BuildContext context, bool compact, VoidCallback toggle)
      rail;
  final Widget sidebar;
  final Widget content;
  final Widget? inspector;
  final String inspectorToggleTooltip;
  final bool inspectorOpen;
  final VoidCallback? onInspectorClosed;

  @override
  State<DesktopWorkspaceShell> createState() => _DesktopWorkspaceShellState();
}

class _DesktopWorkspaceShellState extends State<DesktopWorkspaceShell> {
  late bool _railExpanded = true;
  late bool _inspectorOpen = widget.inspectorOpen;

  @override
  void didUpdateWidget(covariant DesktopWorkspaceShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inspectorOpen != widget.inspectorOpen) {
      _inspectorOpen = widget.inspectorOpen;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactRail = constraints.maxWidth < 900 || !_railExpanded;
        final canShowInspector = constraints.maxWidth >= 1280;
        final showInspector =
            canShowInspector && _inspectorOpen && widget.inspector != null;

        return Row(
          children: [
            SizedBox(
              width: compactRail ? 68 : 164,
              child: widget.rail(
                context,
                compactRail,
                () => setState(() => _railExpanded = !_railExpanded),
              ),
            ),
            Expanded(
              child: ResizableSplitPane(
                sidebar: widget.sidebar,
                content: Row(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(child: widget.content),
                          if (widget.inspector != null && canShowInspector)
                            Positioned(
                              top: 12,
                              right: 12,
                              child: Tooltip(
                                message: widget.inspectorToggleTooltip,
                                child: IconButton.filledTonal(
                                  onPressed: () => setState(
                                    () => _inspectorOpen = !_inspectorOpen,
                                  ),
                                  icon: Icon(
                                    showInspector
                                        ? Icons.expand_less
                                        : Icons.info_outline,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (showInspector) widget.inspector!,
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
