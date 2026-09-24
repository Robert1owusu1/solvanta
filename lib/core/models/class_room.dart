class ClassRoom {
  final String id;
  final String name;
  final String stream;
  final String? teacherId;

  const ClassRoom({
    required this.id,
    required this.name,
    required this.stream,
    this.teacherId,
  });

  String get displayName => '$name$stream';

  factory ClassRoom.fromJson(Map<String, dynamic> json) => ClassRoom(
        id: json['id'] as String,
        name: json['name'] as String,
        stream: (json['stream'] ?? '') as String,
        teacherId: json['teacherId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'stream': stream,
        'teacherId': teacherId,
      };
}