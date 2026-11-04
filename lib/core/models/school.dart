/// How a school records assessment scores.
///
/// [both] (the default) keeps AI/OCR marking and manual entry open; [ai] hides
/// the manual-entry affordances; [manual] hides the AI capture/marking entry
/// points (for schools that mark on paper). The API enforces the same split.
enum MarkingMode {
  ai('AI marking only'),
  manual('Manual entry only'),
  both('AI marking and manual entry');

  const MarkingMode(this.label);

  final String label;

  static MarkingMode fromKey(String? key) => MarkingMode.values
      .firstWhere((m) => m.name == key, orElse: () => MarkingMode.both);
}

/// A normal school, or an independent teacher's own workspace (a tenant owned
/// by one teacher, with a reduced feature set). Mirrors Go's SchoolKind.
enum SchoolKind {
  school,
  independent;

  static SchoolKind fromKey(String? key) => SchoolKind.values
      .firstWhere((k) => k.name == key, orElse: () => SchoolKind.school);
}

class School {
  final String id;
  final String name;
  final String motto;
  final String address;
  final String phone;
  final String email;
  final String region;
  final MarkingMode markingMode;
  final SchoolKind kind;
  final String ownerUserId;
  final String dataProtectionAcceptedAt;
  final bool archived;

  const School({
    required this.id,
    required this.name,
    this.motto = '',
    this.address = '',
    this.phone = '',
    this.email = '',
    this.region = '',
    this.markingMode = MarkingMode.both,
    this.kind = SchoolKind.school,
    this.ownerUserId = '',
    this.dataProtectionAcceptedAt = '',
    this.archived = false,
  });

  bool get allowsAiMarking => markingMode != MarkingMode.manual;
  bool get allowsManualScores => markingMode != MarkingMode.ai;
  bool get isIndependent => kind == SchoolKind.independent;

  factory School.fromJson(Map<String, dynamic> json) => School(
        id: json['id'] as String,
        name: json['name'] as String,
        motto: (json['motto'] ?? '') as String,
        address: (json['address'] ?? '') as String,
        phone: (json['phone'] ?? '') as String,
        email: (json['email'] ?? '') as String,
        region: (json['region'] ?? '') as String,
        markingMode: MarkingMode.fromKey(json['markingMode'] as String?),
        kind: SchoolKind.fromKey(json['kind'] as String?),
        ownerUserId: (json['ownerUserId'] ?? '') as String,
        dataProtectionAcceptedAt:
            (json['dataProtectionAcceptedAt'] ?? '') as String,
        archived: (json['archived'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'motto': motto,
        'address': address,
        'phone': phone,
        'email': email,
        'region': region,
        // Mirrors the Go `omitempty`: only sent when not the default.
        if (markingMode != MarkingMode.both) 'markingMode': markingMode.name,
        if (kind != SchoolKind.school) 'kind': kind.name,
        if (ownerUserId.isNotEmpty) 'ownerUserId': ownerUserId,
        if (dataProtectionAcceptedAt.isNotEmpty)
          'dataProtectionAcceptedAt': dataProtectionAcceptedAt,
        if (archived) 'archived': archived,
      };

  School copyWith({
    String? name,
    String? motto,
    String? address,
    String? phone,
    String? email,
    String? region,
    MarkingMode? markingMode,
    SchoolKind? kind,
    String? ownerUserId,
    String? dataProtectionAcceptedAt,
    bool? archived,
  }) =>
      School(
        id: id,
        name: name ?? this.name,
        motto: motto ?? this.motto,
        address: address ?? this.address,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        region: region ?? this.region,
        markingMode: markingMode ?? this.markingMode,
        kind: kind ?? this.kind,
        ownerUserId: ownerUserId ?? this.ownerUserId,
        dataProtectionAcceptedAt:
            dataProtectionAcceptedAt ?? this.dataProtectionAcceptedAt,
        archived: archived ?? this.archived,
      );
}