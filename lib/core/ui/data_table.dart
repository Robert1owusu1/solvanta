import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One column of an [SvDataTable].
class SvColumn<T> {
  const SvColumn({
    required this.label,
    required this.cell,
    this.sortKey,
    this.flex = 2,
    this.numeric = false,
  });

  final String label;
  final Widget Function(T row) cell;

  /// The value to sort by; null makes the column unsortable.
  final Comparable<Object?>? Function(T row)? sortKey;
  final int flex;

  /// Right-aligns the column, as numbers read best.
  final bool numeric;
}

/// A desktop table: sortable headers, a hover highlight, the whole row
/// opens it, an optional actions cell, and pages of [pageSize] rows. Built
/// from rows rather than [DataTable] so columns share the width by flex and
/// it fits beside the sidebar without scrolling sideways.
class SvDataTable<T> extends StatefulWidget {
  const SvDataTable({
    super.key,
    required this.rows,
    required this.columns,
    this.onOpen,
    this.actions,
    this.pageSize = 15,
    this.initialSort,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 16),
  });

  final List<T> rows;
  final List<SvColumn<T>> columns;
  final void Function(T row)? onOpen;

  /// A trailing widget per row, such as a menu.
  final Widget Function(T row)? actions;
  final int pageSize;

  /// The column index sorted by at first, if any.
  final int? initialSort;
  final EdgeInsets padding;

  @override
  State<SvDataTable<T>> createState() => _SvDataTableState<T>();
}

class _SvDataTableState<T> extends State<SvDataTable<T>> {
  late int? _sortColumn = widget.initialSort;
  var _ascending = true;
  var _page = 0;
  int? _hover;

  List<T> get _sorted {
    final col = _sortColumn;
    final key = col == null ? null : widget.columns[col].sortKey;
    if (key == null) return widget.rows;
    final out = [...widget.rows];
    out.sort((a, b) {
      final ka = key(a), kb = key(b);
      final c = ka == null
          ? (kb == null ? 0 : 1)
          : kb == null
              ? -1
              : ka.compareTo(kb);
      return _ascending ? c : -c;
    });
    return out;
  }

  @override
  void didUpdateWidget(SvDataTable<T> old) {
    super.didUpdateWidget(old);
    // A new search or filter starts from the first page.
    if (old.rows.length != widget.rows.length) _page = 0;
  }

  void _sortBy(int i) {
    if (widget.columns[i].sortKey == null) return;
    setState(() {
      if (_sortColumn == i) {
        _ascending = !_ascending;
      } else {
        _sortColumn = i;
        _ascending = true;
      }
      _page = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _sorted;
    final pages = (rows.length / widget.pageSize).ceil().clamp(1, 1 << 30);
    final page = _page.clamp(0, pages - 1);
    final start = page * widget.pageSize;
    final shown = rows.sublist(start, (start + widget.pageSize).clamp(0, rows.length));
    final header = TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.body, letterSpacing: .3);

    return Padding(
      padding: widget.padding,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Container(
                color: AppColors.background,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    for (var i = 0; i < widget.columns.length; i++)
                      Expanded(
                        flex: widget.columns[i].flex,
                        child: _HeaderCell(
                          label: widget.columns[i].label.toUpperCase(),
                          style: header,
                          numeric: widget.columns[i].numeric,
                          sorted: _sortColumn == i ? _ascending : null,
                          onTap: widget.columns[i].sortKey == null ? null : () => _sortBy(i),
                        ),
                      ),
                    if (widget.actions != null) const SizedBox(width: 48),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              Expanded(
                child: ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: AppColors.border.withValues(alpha: .6)),
                  itemBuilder: (context, i) {
                    final row = shown[i];
                    return MouseRegion(
                      onEnter: (_) => setState(() => _hover = i),
                      onExit: (_) => setState(() => _hover = null),
                      child: InkWell(
                        onTap: widget.onOpen == null ? null : () => widget.onOpen!(row),
                        child: Container(
                          color: _hover == i ? AppColors.brand.withValues(alpha: .06) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          constraints: const BoxConstraints(minHeight: 52),
                          child: Row(
                            children: [
                              for (final c in widget.columns)
                                Expanded(
                                  flex: c.flex,
                                  child: Align(
                                    alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: DefaultTextStyle.merge(
                                        style: TextStyle(fontSize: 13.5, color: AppColors.ink),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        child: c.cell(row),
                                      ),
                                    ),
                                  ),
                                ),
                              if (widget.actions != null)
                                SizedBox(width: 48, child: Center(child: widget.actions!(row))),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        rows.isEmpty
                            ? 'No rows'
                            : 'Showing ${start + 1}–${start + shown.length} of ${rows.length}',
                        style: TextStyle(fontSize: 12.5, color: AppColors.muted),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous page',
                      onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('${page + 1} / $pages', style: TextStyle(fontSize: 12.5, color: AppColors.body)),
                    IconButton(
                      tooltip: 'Next page',
                      onPressed: page < pages - 1 ? () => setState(() => _page = page + 1) : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.label,
    required this.style,
    required this.numeric,
    required this.sorted,
    required this.onTap,
  });

  final String label;
  final TextStyle style;
  final bool numeric;

  /// True ascending, false descending, null not the sort column.
  final bool? sorted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    final arrow = sorted == null
        ? (onTap == null ? null : Icon(Icons.unfold_more, size: 14, color: AppColors.muted))
        : Icon(sorted! ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: AppColors.brand);
    final content = Row(
      mainAxisAlignment: numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        Flexible(child: text),
        if (arrow != null) ...[const SizedBox(width: 4), arrow],
        const SizedBox(width: 12),
      ],
    );
    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: 'Sort by $label',
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: content),
    );
  }
}
