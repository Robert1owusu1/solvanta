class School {
  final String id;
  final String name;
  final String motto;
  final String address;
  final String phone;
  final String email;
  final String region;

  const School({
    required this.id,
    required this.name,
    this.motto = '',
    this.address = '',
    this.phone = '',
    this.email = '',
    this.region = '',
  });

  factory School.fromJson(Map<String, dynamic> json) => School(
        id: json['id'] as String,
        name: json['name'] as String,
        motto: (json['motto'] ?? '') as String,
        address: (json['address'] ?? '') as String,
        phone: (json['phone'] ?? '') as String,
        email: (json['email'] ?? '') as String,
        region: (json['region'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'motto': motto,
        'address': address,
        'phone': phone,
        'email': email,
        'region': region,
      };

  School copyWith({
    String? name,
    String? motto,
    String? address,
    String? phone,
    String? email,
    String? region,
  }) =>
      School(
        id: id,
        name: name ?? this.name,
        motto: motto ?? this.motto,
        address: address ?? this.address,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        region: region ?? this.region,
      );
}