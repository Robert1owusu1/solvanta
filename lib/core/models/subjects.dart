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
  // The rest of the Ghanaian basic-school (KG–JHS) curriculum.
  Subject('FRE', 'French'),
  Subject('GHL', 'Ghanaian Language'),
  Subject('CAD', 'Creative Arts & Design'),
  Subject('CTE', 'Career Technology'),
  Subject('PHE', 'Physical & Health Education'),
  Subject('OWOP', 'Our World Our People'),
  Subject('HIS', 'History'),
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