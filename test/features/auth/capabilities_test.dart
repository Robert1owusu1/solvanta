import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/models/capabilities.dart';
import 'package:solvanta/core/models/school.dart';

void main() {
  group('capability matrix', () {
    test('a normal school allows every feature', () {
      for (final f in [
        Feature.fees,
        Feature.gate,
        Feature.sms,
        Feature.audit,
        Feature.studentsRegister,
        Feature.scoresManual,
        Feature.scoreSheet,
      ]) {
        expect(Capabilities.schoolAllows(SchoolKind.school, f), isTrue,
            reason: '$f should be allowed in a school');
      }
    });

    test('an independent workspace is denied the school-only modules', () {
      const denied = [
        Feature.fees,
        Feature.gate,
        Feature.sms,
        Feature.staffManage,
        Feature.announcements,
        Feature.reportApproval,
        Feature.analyticsSchool,
        Feature.audit,
        Feature.parentStudent,
      ];
      for (final f in denied) {
        expect(Capabilities.schoolAllows(SchoolKind.independent, f), isFalse,
            reason: '$f should be hidden from an independent workspace');
      }
    });

    test('an independent workspace keeps its teaching features', () {
      const allowed = [
        Feature.studentsRegister,
        Feature.studentsBulkImport,
        Feature.classesManage,
        Feature.assessmentsCreate,
        Feature.markingAi,
        Feature.scoresManual,
        Feature.scoresBulkUpload,
        Feature.scoreSheet,
        Feature.exportXlsx,
        Feature.exportPdf,
        Feature.questionBank,
        Feature.aiQuestionGen,
        Feature.analyticsClass,
      ];
      for (final f in allowed) {
        expect(Capabilities.schoolAllows(SchoolKind.independent, f), isTrue,
            reason: '$f should be available to an independent teacher');
      }
    });

    test('allows() reads a school’s kind', () {
      const indie = School(id: 'WS-1', name: 'ws', kind: SchoolKind.independent);
      const school = School(id: 'SCH-001', name: 's');
      expect(Capabilities.allows(indie, Feature.fees), isFalse);
      expect(Capabilities.allows(school, Feature.fees), isTrue);
    });
  });
}
