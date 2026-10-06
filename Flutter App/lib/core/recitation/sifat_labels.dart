/// Human-readable labels for the sifat head names and their English class
/// literals, used by the recitation results UI (the correction drawer).
library;

const Map<String, String> _headLabels = <String, String>{
  'hams_or_jahr': 'Hams / Jahr',
  'shidda_or_rakhawa': 'Shidda / Rakhawa',
  'tafkheem_or_taqeeq': 'Tafkheem / Tarqeeq',
  'itbaq': 'Itbaq',
  'safeer': 'Safeer',
  'qalqla': 'Qalqala',
  'tikraar': 'Tikraar',
  'tafashie': 'Tafashie',
  'istitala': 'Istitala',
  'ghonna': 'Ghunnah',
};

const Map<String, String> _classLabels = <String, String>{
  'hams': 'hams',
  'jahr': 'jahr',
  'shadeed': 'shadeed',
  'between': 'bayn',
  'rikhw': 'rikhw',
  'mofakham': 'mufakham',
  'moraqaq': 'muraqqaq',
  'low_mofakham': 'lower mufakham',
  'monfateh': 'munfatih',
  'motbaq': 'mutbaq',
  'safeer': 'safeer',
  'no_safeer': 'no safeer',
  'moqalqal': 'muqalqal',
  'not_moqalqal': 'no qalqala',
  'mokarar': 'mukarrar',
  'not_mokarar': 'no tikraar',
  'motafashie': 'mutafashie',
  'not_motafashie': 'no tafashie',
  'mostateel': 'mustateel',
  'not_mostateel': 'no istitala',
  'maghnoon': 'maghnoon',
  'not_maghnoon': 'no ghunnah',
};

String sifatHeadLabel(String head) => _headLabels[head] ?? head;

String sifatClassLabel(String klass) => _classLabels[klass] ?? klass;
