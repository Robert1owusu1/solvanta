import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/billing.dart';
import '../../core/platform/file_share.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Super-admin "Usage": each tenant's counted activity this month against the
/// cost to the platform, so prices can be set from real testing numbers.
/// Exportable to `.xlsx`. Reads `GET /api/platform/usage`.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, this.client});

  final ApiClient? client;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageRow {
  final String school, kind, month;
  final int peakStudents, classes, aiPages, exports, ocrCostPesewas;
  _UsageRow(Map<String, dynamic> j)
      : school = (j['school'] ?? '') as String,
        kind = (j['kind'] ?? '') as String,
        month = (j['month'] ?? '') as String,
        peakStudents = ((j['peakStudents'] ?? 0) as num).toInt(),
        classes = ((j['classes'] ?? 0) as num).toInt(),
        aiPages = ((j['aiPages'] ?? 0) as num).toInt(),
        exports = ((j['exports'] ?? 0) as num).toInt(),
        ocrCostPesewas = ((j['ocrCostPesewas'] ?? 0) as num).toInt();
}

class _UsageScreenState extends State<UsageScreen> {
  ApiClient get _api => widget.client ?? ApiClient();
  bool get _online => widget.client != null || ApiClient.isConfigured;
  late Future<List<_UsageRow>> _data = _online ? _load() : Future.value([]);

  Future<List<_UsageRow>> _load() async {
    final rows = (await _api.get('/api/platform/usage') as List)
        .cast<Map<String, dynamic>>();
    return rows.map(_UsageRow.new).toList();
  }

  Future<void> _exportXlsx(List<_UsageRow> rows) async {
    final excel = Excel.createExcel();
    final ws = excel['Usage'];
    ws.appendRow([TextCellValue('SOLVANTA — Usage')]);
    ws.appendRow([
      TextCellValue('School'),
      TextCellValue('Kind'),
      TextCellValue('Month'),
      TextCellValue('Peak students'),
      TextCellValue('Classes'),
      TextCellValue('AI pages'),
      TextCellValue('Exports'),
      TextCellValue('OCR cost'),
    ]);
    for (final r in rows) {
      ws.appendRow([
        TextCellValue(r.school),
        TextCellValue(r.kind),
        TextCellValue(r.month),
        IntCellValue(r.peakStudents),
        IntCellValue(r.classes),
        IntCellValue(r.aiPages),
        IntCellValue(r.exports),
        TextCellValue(formatGhs(r.ocrCostPesewas)),
      ]);
    }
    await saveAndShareFile(Uint8List.fromList(excel.encode() ?? const []),
        'usage.xlsx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Usage',
        subtitle: 'Per-tenant activity this month',
        actions: [
          if (_online)
            FutureBuilder<List<_UsageRow>>(
              future: _data,
              builder: (context, snap) => IconButton(
                tooltip: 'Export .xlsx',
                icon: const Icon(Icons.download, color: Colors.white),
                onPressed: (snap.data?.isEmpty ?? true)
                    ? null
                    : () => _exportXlsx(snap.data!),
              ),
            ),
        ],
      ),
      body: !_online
          ? const SvEmptyState(
              icon: Icons.cloud_off,
              title: 'Server required',
              message: 'Usage is computed on the server.')
          : FutureBuilder<List<_UsageRow>>(
              future: _data,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SvListSkeleton();
                }
                if (snap.hasError) {
                  return SvErrorState(
                      message: 'Could not load usage',
                      onRetry: () => setState(() => _data = _load()));
                }
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return const SvEmptyState(
                      icon: Icons.insights_outlined,
                      title: 'No usage yet',
                      message: 'Activity appears here as schools use SOLVANTA.');
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, i) => _tile(rows[i]),
                );
              },
            ),
    );
  }

  Widget _tile(_UsageRow r) => Card(
        child: ListTile(
          title: Text(r.school,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(
              '${r.kind} · ${r.month}\n'
              '${r.peakStudents} students · ${r.classes} classes · '
              '${r.aiPages} AI pages · OCR ${formatGhs(r.ocrCostPesewas)}',
              style: TextStyle(fontSize: 12, color: AppColors.body)),
          isThreeLine: true,
        ),
      );
}
