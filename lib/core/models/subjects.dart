class Subject {
  final String id;
  final String name;

  const Subject(this.id, this.name);
}

const subjects = [
  Subject('MATH', 'Mathematics'),
  Subject('ENG', 'English Language'),
  Subject('SCI', 'Integrated Science'),
  Subject('SOC', 'Social Studies'),
  Subject('ICT', 'Information & Communication Technology'),
  Subject('RME', 'Religious & Moral Education'),
];

const cognitiveLevels = [
  'Knowledge',
  'Comprehension',
  'Application',
  'Analysis',
];

String subjectName(String id) => subjects
    .firstWhere((s) => s.id == id, orElse: () => Subject('?', id))
    .name;