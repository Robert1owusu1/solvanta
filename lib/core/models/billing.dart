// Billing, plans and subscriptions (Phase 4) — mirrors
// `backend/internal/domain/billing.go`. Money is in integer pesewas.

class PlatformSettings {
  final String billingMode; // 'testing' | 'live'
  final String liveStartDate; // yyyy-MM-dd, or ''
  final int graceDays;

  const PlatformSettings({
    this.billingMode = 'testing',
    this.liveStartDate = '',
    this.graceDays = 7,
  });

  bool get isLive => billingMode == 'live';

  factory PlatformSettings.fromJson(Map<String, dynamic> j) => PlatformSettings(
        billingMode: (j['billingMode'] ?? 'testing') as String,
        liveStartDate: (j['liveStartDate'] ?? '') as String,
        graceDays: ((j['graceDays'] ?? 7) as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'billingMode': billingMode,
        if (liveStartDate.isNotEmpty) 'liveStartDate': liveStartDate,
        'graceDays': graceDays,
      };

  PlatformSettings copyWith(
          {String? billingMode, String? liveStartDate, int? graceDays}) =>
      PlatformSettings(
        billingMode: billingMode ?? this.billingMode,
        liveStartDate: liveStartDate ?? this.liveStartDate,
        graceDays: graceDays ?? this.graceDays,
      );
}

class Plan {
  final String id;
  final String name;
  final String kind; // 'independent' | 'school'
  final bool isFreeTier;
  final int pricePerStudentMonth; // pesewas
  final int pricePerStudentTerm; // pesewas
  final String currency;
  final bool active;
  final Map<String, bool> features;
  final Map<String, int?> limits; // null = unlimited

  const Plan({
    required this.id,
    required this.name,
    this.kind = 'independent',
    this.isFreeTier = false,
    this.pricePerStudentMonth = 0,
    this.pricePerStudentTerm = 0,
    this.currency = 'GHS',
    this.active = true,
    this.features = const {},
    this.limits = const {},
  });

  bool includes(String feature) => features[feature] ?? false;

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        kind: (j['kind'] ?? 'independent') as String,
        isFreeTier: (j['isFreeTier'] ?? false) as bool,
        pricePerStudentMonth: ((j['pricePerStudentMonth'] ?? 0) as num).toInt(),
        pricePerStudentTerm: ((j['pricePerStudentTerm'] ?? 0) as num).toInt(),
        currency: (j['currency'] ?? 'GHS') as String,
        active: (j['active'] ?? true) as bool,
        features: ((j['features'] ?? const {}) as Map)
            .map((k, v) => MapEntry(k as String, v as bool)),
        limits: ((j['limits'] ?? const {}) as Map)
            .map((k, v) => MapEntry(k as String, (v as num?)?.toInt())),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'isFreeTier': isFreeTier,
        'pricePerStudentMonth': pricePerStudentMonth,
        'pricePerStudentTerm': pricePerStudentTerm,
        'currency': currency,
        'active': active,
        'features': features,
        'limits': limits,
      };

  Plan copyWith({
    String? name,
    bool? isFreeTier,
    int? pricePerStudentMonth,
    int? pricePerStudentTerm,
    bool? active,
    Map<String, bool>? features,
    Map<String, int?>? limits,
  }) =>
      Plan(
        id: id,
        name: name ?? this.name,
        kind: kind,
        isFreeTier: isFreeTier ?? this.isFreeTier,
        pricePerStudentMonth: pricePerStudentMonth ?? this.pricePerStudentMonth,
        pricePerStudentTerm: pricePerStudentTerm ?? this.pricePerStudentTerm,
        currency: currency,
        active: active ?? this.active,
        features: features ?? this.features,
        limits: limits ?? this.limits,
      );
}

/// A tenant's billing status, as served by `GET /api/billing/me`.
class MyBilling {
  final String billingMode;
  final bool liveOn;
  final String liveStartDate;
  final Plan plan;
  final int peakStudents;
  final int previewMonthPesewas;
  final int previewTermPesewas;

  const MyBilling({
    required this.billingMode,
    required this.liveOn,
    required this.liveStartDate,
    required this.plan,
    required this.peakStudents,
    required this.previewMonthPesewas,
    required this.previewTermPesewas,
  });

  bool get isTesting => billingMode == 'testing';

  factory MyBilling.fromJson(Map<String, dynamic> j) {
    final usage = (j['usage'] ?? const {}) as Map<String, dynamic>;
    final preview = (j['preview'] ?? const {}) as Map<String, dynamic>;
    return MyBilling(
      billingMode: (j['billingMode'] ?? 'testing') as String,
      liveOn: (j['liveOn'] ?? false) as bool,
      liveStartDate: (j['liveStartDate'] ?? '') as String,
      plan: Plan.fromJson((j['plan'] ?? const {}) as Map<String, dynamic>),
      peakStudents: ((usage['peakStudents'] ?? 0) as num).toInt(),
      previewMonthPesewas: ((preview['month'] ?? 0) as num).toInt(),
      previewTermPesewas: ((preview['term'] ?? 0) as num).toInt(),
    );
  }
}

/// Formats pesewas as `GHS 90.00`.
String formatGhs(int pesewas) => 'GHS ${(pesewas / 100).toStringAsFixed(2)}';

/// SOLVANTA never takes money in-app. Paid plans (anything but the free tier)
/// are arranged with sales; this is where schools are pointed to do that.
const String salesContact = 'sales@solvanta.app';

