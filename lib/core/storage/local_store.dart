import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/attendance.dart';
import '../models/announcement.dart';
import '../models/assessment.dart';
import '../models/assignment.dart';
import '../models/audit.dart';
import '../models/app_notification.dart';
import '../models/class_room.dart';
import '../models/correction.dart';
import '../models/gate_event.dart';
import '../models/intervention.dart';
import '../models/message.dart';
import '../models/question.dart';
import '../models/qgen_request.dart';
import '../models/role.dart';
import '../models/scan_page.dart';
import '../models/school.dart';
import '../models/school_term.dart';
import '../models/student.dart';
import '../models/submission.dart';
import '../models/user.dart';
import '../security/secret_hash.dart';

class LocalStore {
  static const _usersKey = 'solvanta.users_v1';
  static const _sessionKey = 'solvanta.session_user_id';
  static const _apiTokenKey = 'solvanta.api_token';
  static const _classesKey = 'solvanta.classes_v1';
  static const _studentsKey = 'solvanta.students_v1';
  static const _attendanceKey = 'solvanta.attendance_v1';
  static const _gateKey = 'solvanta.gate_v1';
  static const _bankKey = 'solvanta.bank_v1';
  static const _assessmentsKey = 'solvanta.assessments_v1';
  static const _submissionsKey = 'solvanta.submissions_v1';
  static const _messagesKey = 'solvanta.messages_v1';
  static const _targetsKey = 'solvanta.targets_v1';
  static const _schoolKey = 'solvanta.school_v1';
  static const _notificationsKey = 'solvanta.notifications_v1';
  static const _interventionsKey = 'solvanta.interventions_v1';
  static const _auditKey = 'solvanta.audit_v1';
  static const _assignmentsKey = 'solvanta.assignments_v1';
  static const _scansKey = 'solvanta.scans_v1';
  static const _correctionsKey = 'solvanta.corrections_v1';
  static const _announcementsKey = 'solvanta.announcements_v1';
  static const _termKey = 'solvanta.term_v1';
  static const _qgenKey = 'solvanta.qgen_v1';

  Future<List<User>> loadUsers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_usersKey);
    if (raw == null) return _seed(prefs);
    final list = jsonDecode(raw) as List;
    final users =
        list.map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
    // Upgrade an install written before passwords were hashed: the plain value
    // is still readable here, so hash it once and rewrite. After this read the
    // file no longer holds a usable password for any account, and later reads
    // find everything already hashed (so the write happens at most once).
    if (users
        .any((u) => u.password.isNotEmpty && !isHashedSecret(u.password))) {
      await prefs.setString(_usersKey, jsonEncode(_encodeUsers(users)));
    }
    return users;
  }

  Future<List<ClassRoom>> loadClasses() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_classesKey);
    if (raw == null) {
      final list = _seedClasses();
      await saveClasses(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.map((e) => ClassRoom.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveClasses(List<ClassRoom> classes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _classesKey,
      jsonEncode(classes.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<Student>> loadStudents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_studentsKey);
    if (raw == null) {
      final list = _seedStudents();
      await saveStudents(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.map((e) => Student.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveStudents(List<Student> students) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _studentsKey,
      jsonEncode(students.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<AttendanceRecord>> loadAttendance() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_attendanceKey);
    if (raw == null) {
      final list = _seedAttendance();
      await saveAttendance(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => AttendanceRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveAttendance(List<AttendanceRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _attendanceKey,
      jsonEncode(records.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<GateEvent>> loadGateEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_gateKey);
    if (raw == null) {
      final list = _seedGate();
      await saveGateEvents(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.map((e) => GateEvent.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveGateEvents(List<GateEvent> events) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _gateKey,
      jsonEncode(events.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<Question>> loadQuestionBank() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bankKey);
    if (raw == null) {
      final list = _seedQuestionBank();
      await saveQuestionBank(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.map((e) => Question.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveQuestionBank(List<Question> questions) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _bankKey,
      jsonEncode(questions.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<Assessment>> loadAssessments() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_assessmentsKey);
    if (raw == null) {
      final seeded = <Assessment>[..._seedAssessments(), ..._seedMocks()];
      await saveAssessments(seeded);
      return seeded;
    }
    final existing = (jsonDecode(raw) as List)
        .map((e) => Assessment.fromJson(e as Map<String, dynamic>))
        .toList();
    final missing = _seedMocks()
        .where((m) => !existing.any((x) => x.id == m.id))
        .toList();
    if (missing.isNotEmpty) {
      final merged = [...existing, ...missing];
      await saveAssessments(merged);
      return merged;
    }
    return existing;
  }

  Future<void> saveAssessments(List<Assessment> assessments) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _assessmentsKey,
      jsonEncode(assessments.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<AssessmentSubmission>> loadSubmissions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_submissionsKey);
    if (raw == null) {
      final list = _seedSubmissions();
      await saveSubmissions(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => AssessmentSubmission.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveSubmissions(List<AssessmentSubmission> subs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _submissionsKey,
      jsonEncode(subs.map((e) => e.toJson()).toList()),
    );
  }

  /// JSON for [users] with every password hashed before it reaches disk.
  ///
  /// Offline login compares against the stored copy, so that copy used to be a
  /// usable plaintext password inside `solvanta.users_v1` — anything that could
  /// read the app's prefs got every account's password. [hashSecret] is
  /// idempotent, so a user already loaded from disk round-trips unchanged.
  List<Map<String, dynamic>> _encodeUsers(List<User> users) => users.map((u) {
        final json = u.toJson();
        json['password'] = hashSecret(u.password);
        return json;
      }).toList();

  Future<void> saveUsers(List<User> users) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _usersKey,
      jsonEncode(_encodeUsers(users)),
    );
  }

  Future<List<Message>> loadMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_messagesKey);
    if (raw == null) {
      final list = _seedMessages();
      await saveMessages(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveMessages(List<Message> messages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _messagesKey,
      jsonEncode(messages.map((e) => e.toJson()).toList()),
    );
  }

  Future<Map<String, String>> loadTargets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_targetsKey);
    if (raw == null) return _seedTargets();
    return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, v as String));
  }

  Future<void> saveTargets(Map<String, String> targets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_targetsKey, jsonEncode(targets));
  }

  Future<School?> loadSchool() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_schoolKey);
    if (raw == null) {
      const school = School(
        id: 'SCH-001',
        name: 'Accra Junior High School',
        motto: 'Knowledge, Character, Service',
        address: '12 Independence Avenue, Accra',
        phone: '0302-000-000',
        email: 'info@accrajhs.school.gh',
        region: 'Greater Accra',
      );
      await saveSchool(school);
      return school;
    }
    return School.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveSchool(School school) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_schoolKey, jsonEncode(school.toJson()));
  }

  Future<List<AppNotification>> loadNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_notificationsKey);
    if (raw == null) {
      final list = _seedNotifications();
      await saveNotifications(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveNotifications(List<AppNotification> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _notificationsKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<Intervention>> loadInterventions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_interventionsKey);
    if (raw == null) {
      final list = _seedInterventions();
      await saveInterventions(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Intervention.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Announcement>> loadAnnouncements() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_announcementsKey);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Announcement.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveAnnouncements(List<Announcement> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _announcementsKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<SchoolTerm> loadTerm() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_termKey);
    if (raw == null) {
      await saveTerm(SchoolTerm.fallback);
      return SchoolTerm.fallback;
    }
    return SchoolTerm.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveTerm(SchoolTerm term) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_termKey, jsonEncode(term.toJson()));
  }

  Future<void> saveInterventions(List<Intervention> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _interventionsKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<AuditEntry>> loadAudit() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_auditKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => AuditEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveAudit(List<AuditEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _auditKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<Assignment>> loadAssignments() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_assignmentsKey);
    if (raw == null) {
      final list = _seedAssignments();
      await saveAssignments(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Assignment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveAssignments(List<Assignment> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _assignmentsKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<ScanPage>> loadScans() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scansKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => ScanPage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveScans(List<ScanPage> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _scansKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<Correction>> loadCorrections() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_correctionsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Correction.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveCorrections(List<Correction> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _correctionsKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<QuestionGenRequest>> loadQuestionGenRequests() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_qgenKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => QuestionGenRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveQuestionGenRequests(List<QuestionGenRequest> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _qgenKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> setSessionUser(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionKey, userId);
  }

  Future<String?> getSessionUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_sessionKey);
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
  }

  /// The bearer token the backend issued at login.
  ///
  /// It has to be persisted alongside the session id: `ApiClient.sharedToken`
  /// is a plain static that dies with the process, so without this a cold
  /// start still knows *who* is signed in (the session id survives) but has
  /// no way to authenticate — every API call goes out with no Authorization
  /// header and comes back 401, while the offline-first read paths quietly
  /// keep serving the local copy. The app then looks healthy and never syncs.
  Future<void> setApiToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await prefs.remove(_apiTokenKey);
    } else {
      await prefs.setString(_apiTokenKey, token);
    }
  }

  Future<String?> getApiToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiTokenKey);
  }

  List<User> _seed(SharedPreferences prefs) {
    final users = <User>[
      const User(
        id: 'USR-SUPER',
        name: 'Solvanta Platform',
        email: 'super@solvanta.app',
        phone: '0240000000',
        password: 'super123',
        role: AppRole.superAdmin,
      ),
      const User(
        id: 'USR-ADM-001',
        name: 'Mrs. Adjoa Amankwah',
        email: 'admin@solvanta.app',
        phone: '0241000001',
        password: 'admin123',
        role: AppRole.schoolAdmin,
        schoolId: 'SCH-001',
      ),
      const User(
        id: 'USR-HRT-001',
        name: 'Kwame Boateng',
        email: 'head@school.gh',
        phone: '0242000002',
        password: 'head123',
        role: AppRole.headteacher,
        schoolId: 'SCH-001',
      ),
      const User(
        id: 'USR-TCH-001',
        name: 'Ms. Efua Mensah',
        email: 'efua.mensah@school.gh',
        phone: '0243000003',
        password: 'teacher123',
        role: AppRole.teacher,
        schoolId: 'SCH-001',
        classId: 'JHS2A',
      ),
      const User(
        id: 'USR-PRN-001',
        name: 'Ama Owusu',
        email: 'ama.owusu@school.gh',
        phone: '0244000004',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-001'],
      ),
      const User(
        id: 'USR-PRN-002',
        name: 'Akua Boaduwaa',
        email: 'akua.boaduwaa@school.gh',
        phone: '0246300003',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-002'],
      ),
      const User(
        id: 'USR-PRN-003',
        name: 'Adwoa Adjei',
        email: 'adwoa.adjei@school.gh',
        phone: '0246400001',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-003'],
      ),
      const User(
        id: 'USR-PRN-004',
        name: 'Kwabena Serwaa',
        email: 'kwabena.serwaa@school.gh',
        phone: '0246500001',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-004'],
      ),
      const User(
        id: 'USR-PRN-005',
        name: 'Nana Darko',
        email: 'nana.darko@school.gh',
        phone: '0246600001',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-005'],
      ),
      const User(
        id: 'USR-PRN-006',
        name: 'Efua Adwoa',
        email: 'efua.adwoa@school.gh',
        phone: '0246700001',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-006'],
      ),
      const User(
        id: 'USR-PRN-007',
        name: 'Esi Manu',
        email: 'esi.manu@school.gh',
        phone: '0246800001',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-007'],
      ),
      const User(
        id: 'USR-PRN-008',
        name: 'Ama Amponsah',
        email: 'ama.amponsah@school.gh',
        phone: '0246900001',
        password: 'parent123',
        role: AppRole.parent,
        schoolId: 'SCH-001',
        studentIds: ['STU-008'],
      ),
      const User(
        id: 'USR-STU-001',
        name: 'Kojo Owusu',
        email: 'kojo.owusu@school.gh',
        phone: '0245000005',
        password: 'student123',
        role: AppRole.student,
        schoolId: 'SCH-001',
        classId: 'JHS2A',
      ),
    ];
    prefs.setString(
      _usersKey,
      jsonEncode(_encodeUsers(users)),
    );
    return users;
  }

  List<ClassRoom> _seedClasses() => const [
        ClassRoom(
            id: 'JHS1A', name: 'JHS 1', stream: 'A', teacherId: null),
        ClassRoom(
            id: 'JHS1B', name: 'JHS 1', stream: 'B', teacherId: null),
        ClassRoom(
            id: 'JHS2A', name: 'JHS 2', stream: 'A', teacherId: 'USR-TCH-001'),
        ClassRoom(
            id: 'JHS2B', name: 'JHS 2', stream: 'B', teacherId: null),
        ClassRoom(
            id: 'JHS3A', name: 'JHS 3', stream: 'A', teacherId: null),
        ClassRoom(
            id: 'JHS3B', name: 'JHS 3', stream: 'B', teacherId: null),
      ];

  List<Student> _seedStudents() => [
        const Student(
          id: 'STU-001',
          firstName: 'Kojo',
          lastName: 'Owusu',
          gender: 'M',
          dateOfBirth: '2010-04-12',
          admissionDate: '2023-09-04',
          admissionNo: 'S-2023-001',
          classId: 'JHS2A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-001',
          guardians: [
            Person(name: 'Ama Owusu', phone: '0244000004', relation: 'Mother'),
            Person(name: 'Kofi Owusu', phone: '0246100006', relation: 'Father'),
          ],
          emergencyContacts: [
            Person(name: 'Yaw Amankwah', phone: '0246200002', relation: 'Uncle'),
          ],
          authorizedPickup: [
            Person(name: 'Ama Owusu', phone: '0244000004', relation: 'Mother'),
            Person(name: 'Yaw Amankwah', phone: '0246200002', relation: 'Uncle'),
          ],
        ),
        const Student(
          id: 'STU-002',
          firstName: 'Akosua',
          lastName: 'Boaduwaa',
          gender: 'F',
          dateOfBirth: '2010-06-03',
          admissionDate: '2023-09-04',
          admissionNo: 'S-2023-002',
          classId: 'JHS2A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-002',
          guardians: [
            Person(name: 'Akua Boaduwaa', phone: '0246300003', relation: 'Mother'),
          ],
          emergencyContacts: [
            Person(name: 'Kwame Boaduwaa', phone: '0246300004', relation: 'Father'),
          ],
          authorizedPickup: [
            Person(name: 'Akua Boaduwaa', phone: '0246300003', relation: 'Mother'),
          ],
        ),
        const Student(
          id: 'STU-003',
          firstName: 'Kwabena',
          lastName: 'Adjei',
          gender: 'M',
          dateOfBirth: '2010-01-20',
          admissionDate: '2023-09-04',
          admissionNo: 'S-2023-003',
          classId: 'JHS2A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-003',
          guardians: [
            Person(name: 'Adwoa Adjei', phone: '0246400001', relation: 'Mother'),
          ],
          authorizedPickup: [
            Person(name: 'Adwoa Adjei', phone: '0246400001', relation: 'Mother'),
            Person(name: 'Sam Adjei', phone: '0246400002', relation: 'Brother'),
          ],
        ),
        const Student(
          id: 'STU-004',
          firstName: 'Abena',
          lastName: 'Serwaa',
          gender: 'F',
          dateOfBirth: '2010-09-15',
          admissionDate: '2023-09-04',
          admissionNo: 'S-2023-004',
          classId: 'JHS2A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-004',
          guardians: [
            Person(name: 'Kwabena Serwaa', phone: '0246500001', relation: 'Father'),
          ],
          authorizedPickup: [
            Person(name: 'Kwabena Serwaa', phone: '0246500001', relation: 'Father'),
          ],
        ),
        const Student(
          id: 'STU-005',
          firstName: 'Yaw',
          lastName: 'Darko',
          gender: 'M',
          dateOfBirth: '2011-02-28',
          admissionDate: '2023-09-04',
          admissionNo: 'S-2023-005',
          classId: 'JHS2A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-005',
          guardians: [
            Person(name: 'Nana Darko', phone: '0246600001', relation: 'Mother'),
          ],
          authorizedPickup: [
            Person(name: 'Nana Darko', phone: '0246600001', relation: 'Mother'),
          ],
        ),
        const Student(
          id: 'STU-006',
          firstName: 'Maame',
          lastName: 'Adwoa',
          gender: 'F',
          dateOfBirth: '2010-11-07',
          admissionDate: '2023-09-04',
          admissionNo: 'S-2023-006',
          classId: 'JHS2A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-006',
          guardians: [
            Person(name: 'Efua Adwoa', phone: '0246700001', relation: 'Mother'),
          ],
          authorizedPickup: [
            Person(name: 'Efua Adwoa', phone: '0246700001', relation: 'Mother'),
          ],
        ),
        const Student(
          id: 'STU-007',
          firstName: 'Kofi',
          lastName: 'Manu',
          gender: 'M',
          dateOfBirth: '2012-03-19',
          admissionDate: '2024-09-02',
          admissionNo: 'S-2024-001',
          classId: 'JHS1A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-007',
          guardians: [
            Person(name: 'Esi Manu', phone: '0246800001', relation: 'Mother'),
          ],
          authorizedPickup: [
            Person(name: 'Esi Manu', phone: '0246800001', relation: 'Mother'),
          ],
        ),
        const Student(
          id: 'STU-008',
          firstName: 'Esi',
          lastName: 'Amponsah',
          gender: 'F',
          dateOfBirth: '2012-01-11',
          admissionDate: '2024-09-02',
          admissionNo: 'S-2024-002',
          classId: 'JHS1A',
          schoolId: 'SCH-001',
          parentUserId: 'USR-PRN-008',
          guardians: [
            Person(name: 'Ama Amponsah', phone: '0246900001', relation: 'Mother'),
          ],
          authorizedPickup: [
            Person(name: 'Ama Amponsah', phone: '0246900001', relation: 'Mother'),
          ],
        ),
      ];

  List<AttendanceRecord> _seedAttendance() {
    final jhs2a = _seedStudents()
        .where((s) => s.classId == 'JHS2A')
        .map((s) => s.id)
        .toList();
    final days = _lastWeekdayDates(5);
    final records = <AttendanceRecord>[];
    for (final (d, day) in days.indexed) {
      for (final (i, sid) in jhs2a.indexed) {
        final status =
            switch ((i * 3 + d * 2) % 10) { 7 => AttendanceStatus.excused, 8 => AttendanceStatus.absent, 9 => AttendanceStatus.late, _ => AttendanceStatus.present };
        records.add(AttendanceRecord(
          id: 'ATT-$day-$sid',
          studentId: sid,
          classId: 'JHS2A',
          date: day,
          status: status,
          checkIn: status == AttendanceStatus.absent ? null : '07:4${i % 5}',
        ));
      }
    }
    return records;
  }

  List<GateEvent> _seedGate() {
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));
    final y = '${yesterday.year.toString().padLeft(4, '0')}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';

    return [
      GateEvent(
        id: 'GATE-$y-001',
        studentId: 'STU-001',
        type: GateEventType.arrival,
        time: '07:40',
        date: y,
        reporter: 'Ms. Efua Mensah',
        detail: 'Arrival verified at gate',
      ),
      GateEvent(
        id: 'GATE-$y-002',
        studentId: 'STU-002',
        type: GateEventType.arrival,
        time: '07:42',
        date: y,
        reporter: 'Ms. Efua Mensah',
        detail: 'Arrival verified at gate',
      ),
      GateEvent(
        id: 'GATE-$y-003',
        studentId: 'STU-001',
        type: GateEventType.pickupAuthorized,
        time: '14:30',
        date: y,
        reporter: 'Gate Officer',
        person: 'Ama Owusu',
        detail: 'Pickup verified against authorized list',
      ),
      GateEvent(
        id: 'GATE-$y-004',
        studentId: 'STU-003',
        type: GateEventType.pickupAuthorized,
        time: '14:35',
        date: y,
        reporter: 'Gate Officer',
        person: 'Adwoa Adjei',
        detail: 'Pickup verified against authorized list',
      ),
      GateEvent(
        id: 'GATE-$y-005',
        studentId: 'STU-004',
        type: GateEventType.earlyDeparture,
        time: '12:10',
        date: y,
        reporter: 'Ms. Efua Mensah',
        detail: 'Early departure — documented reason: medical',
      ),
    ];
  }

  List<String> _lastWeekdayDates(int count) {
    final out = <String>[];
    var d = DateTime.now().subtract(const Duration(days: 1));
    while (out.length < count) {
      final wd = d.weekday;
      if (wd >= 1 && wd <= 5) {
        out.add('${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
      }
      d = d.subtract(const Duration(days: 1));
    }
    return out.reversed.toList();
  }

  List<Question> _seedQuestionBank() => [
        Question(
          id: 'Q-MATH-001',
          type: QuestionType.mcq,
          subjectId: 'MATH',
          classId: 'JHS2A',
          topic: 'Fractions',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 2,
          stem: 'Which fraction is equivalent to 1/2?',
          options: const ['2/4', '2/3', '3/4', '1/3'],
          correctAnswer: '2/4',
          explanation: 'Multiplying numerator and denominator of 1/2 by 2 gives 2/4.',
        ),
        Question(
          id: 'Q-MATH-002',
          type: QuestionType.mcq,
          subjectId: 'MATH',
          classId: 'JHS2A',
          topic: 'Fractions',
          difficulty: 2,
          cognitiveLevel: 'Application',
          marks: 3,
          stem: 'A rope is 3/4 m long. Half of it is used. What length is left?',
          options: const ['3/8 m', '1/4 m', '1/2 m', '3/2 m'],
          correctAnswer: '3/8 m',
          explanation: '3/4 × 1/2 = 3/8.',
        ),
        Question(
          id: 'Q-MATH-003',
          type: QuestionType.math,
          subjectId: 'MATH',
          classId: 'JHS2A',
          topic: 'Fractions',
          difficulty: 3,
          cognitiveLevel: 'Analysis',
          marks: 4,
          stem: 'Simplify: 3/4 + 1/6. Show your working.',
          explanation:
              'Common denominator 12: 9/12 + 2/12 = 11/12.',
        ),
        Question(
          id: 'Q-ENG-001',
          type: QuestionType.trueFalse,
          subjectId: 'ENG',
          classId: 'JHS2A',
          topic: 'Comprehension',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 1,
          stem: 'A noun is a naming word.',
          correctAnswer: 'True',
          explanation: 'A noun names a person, place, or thing.',
        ),
        Question(
          id: 'Q-ENG-002',
          type: QuestionType.fillBlank,
          subjectId: 'ENG',
          classId: 'JHS2A',
          topic: 'Grammar',
          difficulty: 2,
          cognitiveLevel: 'Comprehension',
          marks: 2,
          stem: 'She ___ to school every morning. (go / goes)',
          correctAnswer: 'goes',
          explanation: 'Third person singular takes "goes".',
        ),
        Question(
          id: 'Q-ENG-003',
          type: QuestionType.shortAnswer,
          subjectId: 'ENG',
          classId: 'JHS2A',
          topic: 'Comprehension',
          difficulty: 2,
          cognitiveLevel: 'Application',
          marks: 3,
          stem: 'Write one sentence using a conjunction.',
          explanation: 'Conjunctions: and, but, because, or.',
        ),
        Question(
          id: 'Q-SCI-001',
          type: QuestionType.mcq,
          subjectId: 'SCI',
          classId: 'JHS2A',
          topic: 'Photosynthesis',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 2,
          stem: 'Which gas do plants absorb during photosynthesis?',
          options: const ['Oxygen', 'Carbon dioxide', 'Nitrogen', 'Hydrogen'],
          correctAnswer: 'Carbon dioxide',
          explanation: 'Plants take in CO2 and release oxygen.',
        ),
        Question(
          id: 'Q-SCI-002',
          type: QuestionType.mcq,
          subjectId: 'SCI',
          classId: 'JHS2A',
          topic: 'Photosynthesis',
          difficulty: 2,
          cognitiveLevel: 'Application',
          marks: 3,
          stem: 'The pigment that makes leaves green is called ___?',
          options: const ['Chlorophyll', 'Carotene', 'Chloroplast', 'Xylem'],
          correctAnswer: 'Chlorophyll',
          explanation: 'Chlorophyll captures light energy.',
        ),
        Question(
          id: 'Q-SOC-001',
          type: QuestionType.trueFalse,
          subjectId: 'SOC',
          classId: 'JHS2A',
          topic: 'Ghana Independence',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 1,
          stem: 'Ghana became independent in 1957.',
          correctAnswer: 'True',
          explanation: 'Ghana gained independence on 6 March 1957.',
        ),
        Question(
          id: 'Q-SOC-002',
          type: QuestionType.shortAnswer,
          subjectId: 'SOC',
          classId: 'JHS2A',
          topic: 'Ghana Independence',
          difficulty: 2,
          cognitiveLevel: 'Comprehension',
          marks: 2,
          stem: 'Name one of Ghana\'s three regions that… name which city is the capital of Ghana.',
          explanation: 'Accra is the capital city of Ghana.',
        ),
      ];

  List<Assessment> _seedAssessments() {
    final bank = _seedQuestionBank();
    Question byId(String id) =>
        bank.firstWhere((q) => q.id == id);

    final mathQuiz = Assessment(
      id: 'ASSMT-MAT-HALF',
      title: 'Fractions Quick Diagnostic',
      type: AssessmentType.diagnostic,
      subjectId: 'MATH',
      classId: 'JHS2A',
      date: '2026-09-10',
      createdBy: 'Ms. Efua Mensah',
      questions: [
        byId('Q-MATH-001'),
        byId('Q-MATH-002'),
        byId('Q-MATH-003'),
      ],
    );

    final engTest = Assessment(
      id: 'ASSMT-ENG-T1',
      title: 'English Language — Term 1 Test',
      type: AssessmentType.classTest,
      subjectId: 'ENG',
      classId: 'JHS2A',
      date: '2026-09-12',
      createdBy: 'Ms. Efua Mensah',
      questions: [
        byId('Q-ENG-001'),
        byId('Q-ENG-002'),
        byId('Q-ENG-003'),
      ],
    );

    return [mathQuiz, engTest];
  }

  List<AssessmentSubmission> _seedSubmissions() {
    return [
      AssessmentSubmission(
        id: 'SUB-M1-STU001',
        assessmentId: 'ASSMT-MAT-HALF',
        studentId: 'STU-001',
        classId: 'JHS2A',
        date: '2026-09-10',
        answers: const {
          'Q-MATH-001': '2/4',
          'Q-MATH-002': '3/8 m',
          'Q-MATH-003': '11/12',
        },
        teacherMarks: const {'Q-MATH-003': 3},
        earned: 8,
      ),
      AssessmentSubmission(
        id: 'SUB-M1-STU002',
        assessmentId: 'ASSMT-MAT-HALF',
        studentId: 'STU-002',
        classId: 'JHS2A',
        date: '2026-09-10',
        answers: const {
          'Q-MATH-001': '2/4',
          'Q-MATH-002': '1/2 m',
        },
        teacherMarks: const {},
        earned: 2,
      ),
      AssessmentSubmission(
        id: 'SUB-E1-STU001',
        assessmentId: 'ASSMT-ENG-T1',
        studentId: 'STU-001',
        classId: 'JHS2A',
        date: '2026-09-12',
        answers: const {
          'Q-ENG-001': 'True',
          'Q-ENG-002': 'goes',
          'Q-ENG-003': 'Kojo ran, but he was late.',
        },
        teacherMarks: const {'Q-ENG-003': 3},
        earned: 6,
      ),
    ];
  }

  List<Assessment> _seedMocks() {
    final bank = _seedQuestionBank();
    Question byId(String id) => bank.firstWhere((q) => q.id == id);
    return [
      Assessment(
        id: 'ASSMT-MOCK-BECE-MATH',
        title: 'BECE Mathematics Mock',
        type: AssessmentType.mock,
        subjectId: 'MATH',
        classId: 'JHS2A',
        date: '2026-09-14',
        createdBy: 'Ms. Efua Mensah',
        questions: [byId('Q-MATH-001'), byId('Q-MATH-002'), byId('Q-MATH-003')],
      ),
      Assessment(
        id: 'ASSMT-MOCK-BECE-ENG',
        title: 'BECE English Mock',
        type: AssessmentType.mock,
        subjectId: 'ENG',
        classId: 'JHS2A',
        date: '2026-09-16',
        createdBy: 'Ms. Efua Mensah',
        questions: [byId('Q-ENG-001'), byId('Q-ENG-002'), byId('Q-ENG-003')],
      ),
    ];
  }

  List<Message> _seedMessages() => [
        const Message(
          id: 'MSG-001',
          fromId: 'USR-TCH-001',
          toId: 'USR-PRN-001',
          relatedStudentId: 'STU-001',
          subject: 'Fractions diagnostic — great progress',
          body:
              'Dear Ama, Kojo scored 8/9 on the Fractions diagnostic. '
              'Keep practising equivalent fractions at home. - Ms. Mensah',
          timestamp: '2026-09-11T08:15',
        ),
        const Message(
          id: 'MSG-002',
          fromId: 'USR-PRN-001',
          toId: 'USR-TCH-001',
          relatedStudentId: 'STU-001',
          subject: 'Re: Fractions diagnostic — great progress',
          body: 'Thank you, Ms. Mensah. We will practice over the weekend.',
          timestamp: '2026-09-11T19:40',
          read: true,
        ),
        const Message(
          id: 'MSG-003',
          fromId: 'USR-TCH-001',
          toId: 'USR-PRN-001',
          relatedStudentId: 'STU-001',
          subject: 'Attendance reminder',
          body: 'Kojo was marked late twice this week. Please ensure he '
              'arrives by 7:30am.',
          timestamp: '2026-09-15T07:20',
          read: true,
        ),
      ];

  Map<String, String> _seedTargets() => const {
        'MATH': 'B',
        'ENG': 'C',
        'SCI': 'B',
        'SOC': 'C',
      };

  List<AppNotification> _seedNotifications() {
    final yesterday = DateTime.now()
        .subtract(const Duration(days: 1))
        .toIso8601String()
        .substring(0, 16)
        .replaceAll('T', ' ');
    return [
      AppNotification(
        id: 'NOTIF-001',
        kind: NotificationKind.gate,
        title: 'Kojo arrived at school',
        body: 'Arrival verified at the gate at 07:40.',
        timestamp: '$yesterday 07:40',
        studentId: 'STU-001',
      ),
      AppNotification(
        id: 'NOTIF-002',
        kind: NotificationKind.attendance,
        title: 'Late arrival recorded',
        body: 'Kojo was marked late again this week. Please ensure timely arrival.',
        timestamp: '$yesterday 08:05',
        studentId: 'STU-001',
      ),
      AppNotification(
        id: 'NOTIF-003',
        kind: NotificationKind.assessment,
        title: 'New results available',
        body: 'Fractions Quick Diagnostic results are ready for review.',
        timestamp: '$yesterday 15:20',
        studentId: 'STU-001',
      ),
    ];
  }

  List<Intervention> _seedInterventions() => [
        Intervention(
          id: 'INTV-001',
          studentId: 'STU-002',
          topic: 'Fractions',
          action: 'Targeted practice on equivalent fractions; re-teach and '
              'reassess in 2 weeks.',
          assignedBy: 'Ms. Efua Mensah',
          createdDate: '2026-09-14',
        ),
      ];

  List<Assignment> _seedAssignments() => [
        Assignment(
          id: 'ASG-001',
          classId: 'JHS2A',
          subjectId: 'MATH',
          title: 'Fractions practice set',
          instructions: 'Complete questions 1–6 in your exercise book. Show '
              'all working. Due Friday.',
          deadline: '2026-09-25',
          createdBy: 'Ms. Efua Mensah',
          createdAt: '2026-09-18',
        ),
        Assignment(
          id: 'ASG-002',
          classId: 'JHS2A',
          subjectId: 'ENG',
          title: 'Write a short paragraph',
          instructions: 'Describe your best friend using at least three '
              'adjectives and one conjunction.',
          deadline: '2026-09-24',
          createdBy: 'Ms. Efua Mensah',
          createdAt: '2026-09-18',
        ),
      ];
}