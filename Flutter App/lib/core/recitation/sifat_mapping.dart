/// Bridges the two vocabularies for the 10 Tajweed-attribute (sifat) heads.
///
/// The native **Phonetizer** (text -> expected labels) emits English literals
/// (`mofakham`, `hams`, ...), while the **model**'s `vocab.json` (audio ->
/// predicted labels) uses Arabic bracketed tokens (`[مفخم]`, `[همس]`, ...).
/// Scoring compares the two, so every model token is normalized to its English
/// literal here before comparison.
///
/// The Arabic strings are copied byte-exact from `assets/models/vocab.json`.
/// If the step-3 vocab-parity validation shows any string is off (most likely
/// the multi-word ones), fix it here — this is the single source of truth.
library;

/// The 10 sifat head names, in the order used across the model + Phonetizer.
const List<String> kSifatHeads = <String>[
  'hams_or_jahr',
  'shidda_or_rakhawa',
  'tafkheem_or_taqeeq',
  'itbaq',
  'safeer',
  'qalqla',
  'tikraar',
  'tafashie',
  'istitala',
  'ghonna',
];

/// head -> { English literal -> Arabic vocab token }.
const Map<String, Map<String, String>> kEnglishToArabic = <String, Map<String, String>>{
  'ghonna': {
    'maghnoon': '[مغن]',
    'not_maghnoon': '[لا غنة]',
  },
  'hams_or_jahr': {
    'hams': '[همس]',
    'jahr': '[جهر]',
  },
  'istitala': {
    'mostateel': '[مستطيل]',
    'not_mostateel': '[لا إستطالة]',
  },
  'itbaq': {
    'motbaq': '[مطبق]',
    'monfateh': '[منفتح]',
  },
  'qalqla': {
    'moqalqal': '[مقلقل]',
    'not_moqalqal': '[لا قلقلة]',
  },
  'safeer': {
    'safeer': '[صفير]',
    'no_safeer': '[لا صفير]',
  },
  'shidda_or_rakhawa': {
    'shadeed': '[شديد]',
    'between': '[بين الشدة والرخاوة]',
    'rikhw': '[رخو]',
  },
  'tafashie': {
    'motafashie': '[متفشي]',
    'not_motafashie': '[لا تفشي]',
  },
  'tafkheem_or_taqeeq': {
    'mofakham': '[مفخم]',
    'moraqaq': '[مرقق]',
    'low_mofakham': '[أدنى المفخم]',
  },
  'tikraar': {
    'mokarar': '[مكرر]',
    'not_mokarar': '[لا تكرار]',
  },
};

/// head -> { Arabic vocab token -> English literal } (inverse of the above).
final Map<String, Map<String, String>> kArabicToEnglish = <String, Map<String, String>>{
  for (final entry in kEnglishToArabic.entries)
    entry.key: {
      for (final pair in entry.value.entries) pair.value: pair.key,
    },
};

/// Normalizes a model (Arabic) sifat token for [head] to its English literal.
/// Returns the input unchanged if it is already English or unrecognized, so a
/// mapping gap degrades to "mismatch" rather than a crash.
String normalizeSifatToken(String head, String token) {
  return kArabicToEnglish[head]?[token] ?? token;
}
