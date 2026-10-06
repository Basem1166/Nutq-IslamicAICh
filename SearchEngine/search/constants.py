import re

surah_data= [
    (1,  ["الفاتحة", "al-fatiha", "al fatiha", "fatiha", "al-fatihah"]),
    (2,  ["البقرة", "al-baqarah", "al baqarah", "baqarah", "al-baqara"]),
    (3,  ["آل عمران", "al-imran", "al imran", "imran", "aali imran"]),
    (4,  ["النساء", "an-nisa", "an nisa", "nisa", "nissa"]),
    (5,  ["المائدة", "al-maidah", "al maidah", "maidah", "al-ma'idah"]),
    (6,  ["الأنعام", "al-anam", "al anam", "anam", "al-an'am"]),
    (7,  ["الأعراف", "al-araf", "al araf", "araf"]),
    (8,  ["الأنفال", "al-anfal", "al anfal", "anfal"]),
    (9,  ["التوبة", "at-tawbah", "at tawbah", "tawbah", "tawba"]),
    (10, ["يونس", "yunus", "younus"]),
    (11, ["هود", "hud"]),
    (12, ["يوسف", "yusuf", "yousef"]),
    (13, ["الرعد", "ar-rad", "ar rad", "ra'd"]),
    (14, ["إبراهيم", "ibrahim"]),
    (15, ["الحجر", "al-hijr", "al hijr", "hijr"]),
    (16, ["النحل", "an-nahl", "an nahl", "nahl"]),
    (17, ["الإسراء", "al-isra", "al isra", "isra"]),
    (18, ["الكهف", "al-kahf", "al kahf", "kahf"]),
    (19, ["مريم", "maryam", "mariam"]),
    (20, ["طه", "ta-ha", "ta ha", "taha"]),
    (21, ["الأنبياء", "al-anbiya", "al anbiya", "anbiya"]),
    (22, ["الحج", "al-hajj", "al hajj", "hajj"]),
    (23, ["المؤمنون", "al-muminun", "al muminun", "muminun"]),
    (24, ["النور", "an-nur", "an nur", "nur"]),
    (25, ["الفرقان", "al-furqan", "al furqan", "furqan"]),
    (26, ["الشعراء", "ash-shuara", "ash shuara", "shuara"]),
    (27, ["النمل", "an-naml", "an naml", "naml"]),
    (28, ["القصص", "al-qasas", "al qasas", "qasas"]),
    (29, ["العنكبوت", "al-ankabut", "al ankabut", "ankabut"]),
    (30, ["الروم", "ar-rum", "ar rum", "rum"]),
    (31, ["لقمان", "luqman"]),
    (32, ["السجدة", "as-sajdah", "as sajdah", "sajdah"]),
    (33, ["الأحزاب", "al-ahzab", "al ahzab", "ahzab"]),
    (34, ["سبأ", "saba", "sheba"]),
    (35, ["فاطر", "fatir", "faatir"]),
    (36, ["يس", "ya-sin", "ya sin", "yaseen", "yasin"]),
    (37, ["الصافات", "as-saffat", "as saffat", "saffat"]),
    (38, ["ص", "sad"]),
    (39, ["الزمر", "az-zumar", "az zumar", "zumar"]),
    (40, ["غافر", "ghafir", "ghaafir"]),
    (41, ["فصلت", "fussilat"]),
    (42, ["الشورى", "ash-shura", "ash shura", "shura"]),
    (43, ["الزخرف", "az-zukhruf", "az zukhruf", "zukhruf"]),
    (44, ["الدخان", "ad-dukhan", "ad dukhan", "dukhan"]),
    (45, ["الجاثية", "al-jathiyah", "al jathiyah", "jathiyah"]),
    (46, ["الأحقاف", "al-ahqaf", "al ahqaf", "ahqaf"]),
    (47, ["محمد", "muhammad"]),
    (48, ["الفتح", "al-fath", "al fath", "fath"]),
    (49, ["الحجرات", "al-hujurat", "al hujurat", "hujurat"]),
    (50, ["ق", "qaf"]),
    (51, ["الذاريات", "adh-dhariyat", "adh dhariyat", "dhariyat"]),
    (52, ["الطور", "at-tur", "at tur", "tur"]),
    (53, ["النجم", "an-najm", "an najm", "najm"]),
    (54, ["القمر", "al-qamar", "al qamar", "qamar"]),
    (55, ["الرحمن", "ar-rahman", "ar rahman", "rahman"]),
    (56, ["الواقعة", "al-waqi'ah", "al waqiah", "waqiah"]),
    (57, ["الحديد", "al-hadid", "al hadid", "hadid"]),
    (58, ["المجادلة", "al-mujadila", "al mujadila", "mujadila"]),
    (59, ["الحشر", "al-hashr", "al hashr", "hashr"]),
    (60, ["الممتحنة", "al-mumtahanah", "al mumtahanah", "mumtahanah"]),
    (61, ["الصف", "as-saf", "as saf", "saf"]),
    (62, ["الجمعة", "al-jumuah", "al jumuah", "jumuah", "jumu'ah"]),
    (63, ["المنافقون", "al-munafiqun", "al munafiqun", "munafiqun"]),
    (64, ["التغابن", "at-taghabun", "at taghabun", "taghabun"]),
    (65, ["الطلاق", "at-talaq", "at talaq", "talaq"]),
    (66, ["التحريم", "at-tahrim", "at tahrim", "tahrim"]),
    (67, ["الملك", "al-mulk", "al mulk", "mulk"]),
    (68, ["القلم", "al-qalam", "al qalam", "qalam"]),
    (69, ["الحاقة", "al-haqqah", "al haqqah", "haqqah"]),
    (70, ["المعارج", "al-maarij", "al maarij", "maarij"]),
    (71, ["نوح", "nuh", "nooh"]),
    (72, ["الجن", "al-jinn", "al jinn", "jinn"]),
    (73, ["المزمل", "al-muzzammil", "al muzzammil", "muzzammil"]),
    (74, ["المدثر", "al-muddaththir", "al muddaththir", "muddaththir"]),
    (75, ["القيامة", "al-qiyamah", "al qiyamah", "qiyamah"]),
    (76, ["الإنسان", "al-insan", "al insan", "insan"]),
    (77, ["المرسلات", "al-mursalat", "al mursalat", "mursalat"]),
    (78, ["النبأ", "an-naba", "an naba", "naba"]),
    (79, ["النازعات", "an-naziat", "an naziat", "naziat"]),
    (80, ["عبس", "abasa"]),
    (81, ["التكوير", "at-takwir", "at takwir", "takwir"]),
    (82, ["الانفطار", "al-infitar", "al infitar", "infitar"]),
    (83, ["المطففين", "al-mutaffifin", "al mutaffifin", "mutaffifin"]),
    (84, ["الانشقاق", "al-inshiqaq", "al inshiqaq", "inshiqaq"]),
    (85, ["البروج", "al-buruj", "al buruj", "buruj"]),
    (86, ["الطارق", "at-tariq", "at tariq", "tariq"]),
    (87, ["الأعلى", "al-ala", "al ala", "a'la"]),
    (88, ["الغاشية", "al-ghashiyah", "al ghashiyah", "ghashiyah"]),
    (89, ["الفجر", "al-fajr", "al fajr", "fajr"]),
    (90, ["البلد", "al-balad", "al balad", "balad"]),
    (91, ["الشمس", "ash-shams", "ash shams", "shams"]),
    (92, ["الليل", "al-layl", "al layl", "layl"]),
    (93, ["الضحى", "ad-duha", "ad duha", "duha"]),
    (94, ["الشرح", "ash-sharh", "ash sharh", "sharh", "inshirah"]),
    (95, ["التين", "at-tin", "at tin", "tin"]),
    (96, ["العلق", "al-alaq", "al alaq", "alaq"]),
    (97, ["القدر", "al-qadr", "al qadr", "qadr"]),
    (98, ["البينة", "al-bayyinah", "al bayyinah", "bayyinah"]),
    (99, ["الزلزلة", "az-zalzalah", "az zalzalah", "zalzalah"]),
    (100, ["العاديات", "al-adiyat", "al adiyat", "adiyat"]),
    (101, ["القارعة", "al-qariah", "al qariah", "qariah"]),
    (102, ["التكاثر", "at-takathur", "at takathur", "takathur"]),
    (103, ["العصر", "al-asr", "al asr", "asr"]),
    (104, ["الهمزة", "al-humazah", "al humazah", "humazah"]),
    (105, ["الفيل", "al-fil", "al fil", "fil"]),
    (106, ["قريش", "quraysh", "quraish"]),
    (107, ["الماعون", "al-maun", "al maun", "maun"]),
    (108, ["الكوثر", "al-kawthar", "al kawthar", "kawthar"]),
    (109, ["الكافرون", "al-kafirun", "al kafirun", "kafirun"]),
    (110, ["النصر", "an-nasr", "an nasr", "nasr"]),
    (111, ["المسد", "al-masad", "al masad", "masad", "lahab"]),
    (112, ["الإخلاص", "الاخلاص", "al-ikhlas", "al ikhlas", "ikhlas"]),
    (113, ["الفلق", "al-falaq", "al falaq", "falaq"]),
    (114, ["الناس", "an-nas", "an nas", "nas"]),
]

HISTORICAL_EVENT_TOKENS= frozenset({
    "غزوه", "معركه", "هجره", "فتح", "سريه",
    "بدر", "احد", "خندق", "حنين", "تبوك", "خيبر", "حديبيه",
    "اسراء", "معراج", "الاسراء", "المعراج",
    "battle", "expedition", "migration", "conquest", "hijra",
    "ghazwa", "ghazwah", "isra", "miraj"
})

STORY_FRAME_TOKENS= frozenset({"قصه", "قصة", "حادثه", "حادثة", "واقعه", "واقعة", "حكايه", "حكاية"})

FRAME_WORDS= frozenset({
    "آيات", "آية", "احاديث", "حديث", "عن", "في", "موضوع",
    "ما", "ورد", "يتعلق", "تتعلق", "الواردة", "المتعلقة", "المتعلق", "كيف",})

FIQH_SCOPE_SIGNALS= frozenset({
    # Marriage / family law
    "نكاح", "مهر", "صداق", "طلاق", "خلع", "نفقة", "عدة", "رضاع",
    # Financial transactions
    "ربا", "بيع", "شراء", "تجارة", "زكاة", "فطر", "صدقة",
    # Ritual practice with fiqh dimension
    "وضوء", "غسل", "تيمم", "صلاة", "حج", "عمرة", "صوم",
    # Fiqh labels
    "حلال", "حرام", "فريضة", "سنة", "مكروه", "واجب",
    # Specific query combos
    "زكاة الفطر", "نكاح مهر", "فرائض سنة",})

QURAN_SCOPE_SIGNALS= frozenset({
    "آية", "آيات", "سورة", "قرآن", "تلاوة", "تفسير", "جنة نار",
    "كوثر", "إخلاص", "فاتحة", "بقرة", "آل عمران",})

HADITH_SCOPE_SIGNALS= frozenset({
    "حديث", "سنة", "بخاري", "مسلم", "ترمذي",
    "النصيحة", "الأعمال بالنيات", "دعاء كرب",})

ENGLISH_EMOTIONAL_SUPPLEMENTS: list[tuple[list[str], str]]= [
    (["hopeless", "despair", "despairing", "no hope", "lost hope", "give up",
      "hopelessness", "feeling hopeless", "feel hopeless"],
     "لا تقنطوا من رحمة الله الأمل الرحمة فإن مع العسر يسرا لا تيأس"),
    (["grief", "grieving", "loss", "lost someone", "mourning", "bereavement"],
     "الصبر الحزن رحمة الله إنا لله وإنا إليه راجعون"),
    (["sad", "sadness", "depressed", "depression", "unhappy", "miserable"],
     "الحزن الصبر الرحمة لا تحزن إن الله معنا"),
    (["anxious", "anxiety", "worry", "worried", "fear", "scared", "afraid",
      "when i am scared", "when scared", "when afraid", "when i feel scared"],
     "الخوف الطمأنينة التوكل ألا بذكر الله تطمئن القلوب آية الكرسي المعوذتين الفلق الناس"),
    (["stress", "stressed", "overwhelmed", "burnout"],
     "الصبر الطمأنينة يسر العسر"),
    (["what is inside", "inside their hearts", "based on what is inside",
      "intention", "niyyah", "niyya",
      "what we think", "sincere", "sincerity", "inside their hearts",
      "rewarded based on"],
     "النية الأعمال بالنيات الإخلاص الثواب إنما الأعمال بالنيات القلوب"),
    (["forgive", "forgiveness", "repent", "repentance", "sins", "sin", "guilty"],
     "التوبة المغفرة الاستغفار غفران الذنوب"),
    (["grateful", "gratitude", "thankful", "thankfulness", "blessings"],
     "الشكر النعمة الحمد لئن شكرتم"),
    (["hardship", "difficulty", "test", "trial", "trials", "tribulation"],
     "البلاء الصبر الابتلاء فإن مع العسر يسرا"),
    (["patience", "patient", "persevere", "perseverance", "endure"],
     "الصبر الصابرين إن الله مع الصابرين"),
    (["trust allah", "rely on allah", "tawakkul", "trust god", "rely on god"],
     "التوكل على الله ومن يتوكل على الله فهو حسبه"),
    (["death", "dying", "afterlife", "hereafter", "paradise", "hell"],
     "الموت الآخرة الجنة كل نفس ذائقة الموت"),
    (["overthinking", "overthink", "excessive thinking", "too much thinking",
      "racing thoughts", "rumination", "كثرة التفكير"],
     "التوكل الهم الغم الوسواس لا تحزن لا تقلق الطمأنينة"),
    (["good character", "beautiful character", "good manners", "kind to people",
      "mercy to people", "treat people well", "character and mercy",
      "حسن الخلق", "الرحمة بالناس"],
     "حسن الخلق الأخلاق الرحمة الرفق بالناس مكارم الأخلاق"),]

ENGLISH_PRESCRIPTIVE_SUPPLEMENTS: list[tuple[list[str], str]]= [
    (["what should i read", "what to read", "what to recite", "dua for",
      "protect me", "protection from", "what to say",
      "what to read when", "what should i read when", "what to recite when"],
     "آية الكرسي المعوذتين الفلق الناس دعاء حصن المسلم أعوذ بالله"),
    (["virtue of quran", "reward of reading quran", "reciting quran",
      "reading quran", "merit of quran", "فضل قراءة", "فضل القرآن",
      "فضل تلاوة"],
     "فضل قراءة القرآن تلاوة القرآن ثواب قراءة القرآن أجر القرآن"),]

ARABIC_AMBIGOUS_EXPANSIONS: dict[str, str]= {
    "التجارة": "البيع والشراء الكسب الحلال",
    "الغضب":   "كظم الغيظ لا تغضب الحلم",
    "المال":  "الزكاة الإنفاق الرزق",
    "الحرب":   "الجهاد القتال السلام",
    "النساء":  "المرأة الزوجة الأم",
    "الرجل":  "الزوج الأب المؤمن",
    "القلب":  "التقوى النية الإيمان",
    "العلم":  "طلب العلم الفقه المعرفة",
    "الصدق": "الأمانة الصدق في القول والعمل",
    "الكذب": "النفاق الزور الكذب محرم",
    "الحسد":  "الحقد الغيرة الحسد محرم",
    "الصبر":  "الصبر على البلاء والمصيبة",
    "الجهاد": "الجهاد في سبيل الله الصبر",
    "الطلاق": "الزواج الطلاق الفراق",
    "الزواج":   "النكاح الزواج المهر",
    "التفكير":  "التوكل الهم الغم الوسواس الطمأنينة لا تحزن",
    "كثرة التفكير": "التوكل الهم الغم الوسواس لا تقلق الطمأنينة",
    "فضل":   "الثواب الأجر المكانة الفضيلة",
    "فضل القرآن": "ثواب قراءة القرآن أجر التلاوة فضل تلاوة",
    "فضل قراءة": "ثواب قراءة أجر تلاوة القرآن",
    "الخلق":  "حسن الخلق الأخلاق مكارم الأخلاق الرفق",
    "حسن الخلق": "مكارم الأخلاق الرفق بالناس الرحمة الحلم",
    "جنة نار":   "الجنة والنار النعيم والعذاب الآخرة الجزاء",
    "فرائض سنة": "الفرض السنة الواجب المستحب الأركان النوافل فروض الكفاية السنن الرواتب",
    "توبة استغفار": "التوبة والاستغفار شروط التوبة قبول التوبة الإنابة إلى الله",
    "نكاح مهر": "عقد النكاح فريضة المهر الصداق ولي الأمر الزواج",
    "دعاء كرب":  "دعاء الكرب دعاء يونس لا إله إلا أنت سبحانك إني كنت من الظالمين اللهم إني أسألك يا ذا الجلال والإكرام دعاء الغم والهم",
    "حجاب عفة":  "الحجاب الشرعي العفاف يدنين عليهن من جلابيبهن غض البصر الستر",
    "صلاة الفجر": "صلاة الصبح الفجر ركعتا الفجر قراءة الفجر مشهودا أقم الصلاة لدلوك الشمس",
    "حقوق الجار": "حسن الجوار إكرام الجار أذى الجار الإحسان إلى الجار لا يؤذي جاره الرفق بالجار",
    "حق الجار":   "حسن الجوار إكرام الجار أذى الجار الإحسان إلى الجار لا يؤذي جاره",
    "الجار":       "حسن الجوار أذى الجار إكرام الجار الإحسان إلى الجار",}

QURAN_FRGMENT_PHRASES: list[str]= [
    "بعد العسر يسرا", "مع العسر يسرا", "ان مع العسر",
    "كل نفس ذائقة", "لا اكراه في الدين",
    "وما خلقت الجن", "خلقت الجن والانس",
    "ومن يتوكل على الله", "حسبنا الله ونعم الوكيل",
    "ربنا اتنا في الدنيا", "ربنا لا تزغ قلوبنا",
    "رب زدني علما", "لا اله الا انت سبحانك",
    "انا لله وانا اليه راجعون", "واعتصموا بحبل الله",
    "ولنبلونكم", "سنجعل الله", "ومن يتق الله",
    "فان مع العسر", "فاذكروني اذكركم",
    "لقد خلقنا الانسان", "وعسى ان تكرهوا",
    "ان الله مع الصابرين",
    "الله مع الصابرين",
    "ان الله مع الذين اتقوا",
    "واستعينوا بالصبر والصلاة",
    "يا ايها الذين امنوا استعينوا بالصبر",
    "حافظوا على الصلوات",
    "اقم الصلاة لدلوك الشمس",
    "والذين جاهدوا فينا",
    "ولا تحسبن الذين قتلوا",
    "ان مع العسر يسرا",
    "فان مع العسر يسرا",
    "كل نفس ذائقة الموت",
    "لا اكراه في الدين",
    "انا اعطيناك الكوثر",
    "قل هو الله احد",
    "وما خلقت الجن والانس",]

COMPARATIVE_CANONICAL_HINTS: list[tuple[frozenset, list[str]]]= [
    # إيمان vs إسلام -> Hadith Jibril is the canonical definitional source
    (frozenset({"ايمان", "اسلام"}), ["H_eng-muslim_93"]),
    # زكاة vs صدقة -> Q 9:60 defines the 8 mustahiqqs of zakat;
    # Q 2:271 contrasts public vs secret sadaqa
    (frozenset({"زكاه", "صدقه"}), ["Q_9:60", "Q_2:271"]),
    # توبة vs استغفار -> Q 11:90 is the only ayah pairing both terms explicitly
    (frozenset({"توبه", "استغفار"}), ["Q_11:90", "Q_3:135"]),
    # نبي vs رسول -> Q 22:52 is the key Quran verse distinguishing the two roles
    (frozenset({"نبي", "رسول"}), ["Q_22:52"]),
    # حلال vs حرام (food) -> Q 2:173 lists the four prohibited categories
    (frozenset({"حلال", "حرام"}), ["Q_2:173", "Q_5:3"]),]

COMPARATIVE_SUPPORT: list[tuple[str, str]]= [
    # خوف / رجاء -> fear of Allah vs hope in His mercy
    ("خوف",  "الخوف من الله خشية الله الخشية المعنوية الروحانية"),
    ("رجاء", "الرجاء في الله الأمل في رحمة الله"),
    # إيمان / إسلام -> canonical source is hadith Jibril
    ("الإيمان", "الإيمان اليقين العقيدة الإيمان بالله شعب الإيمان حديث جبريل"),
    ("الإسلام", "دين الإسلام الإسلام الشريعة أركان الإسلام بني الإسلام على خمس حديث جبريل"),
    ("إيمان",   "الإيمان اليقين العقيدة الإيمان بالله شعب الإيمان حديث جبريل"),
    ("إسلام",   "دين الإسلام الإسلام الشريعة أركان الإسلام بني الإسلام على خمس"),
    # ذكر / دعاء
    ("الذكر", "ذكر الله تسبيح استغفار"),
    ("الدعاء", "دعاء الله العبادة التضرع"),
    # زكاة / صدقة
    ("الزكاة",   "زكاة المال الفريضة أركان الإسلام نصاب الزكاة مصارف الزكاة"),
    ("الصدقة",   "صدقة التطوع الإنفاق في سبيل الله النفل التطوع"),
    ("زكاة",     "زكاة المال الفريضة أركان الإسلام نصاب الزكاة مصارف الزكاة"),
    ("صدقة",     "صدقة التطوع الإنفاق في سبيل الله النفل التطوع"),
    ("sadaqah",  "voluntary charity spending good deed"),
    ("zakat",    "obligatory alms pillar of islam purification wealth"),
    # توبة / استغفار
    ("التوبة",   "توبة الإنابة شروط التوبة الرجوع إلى الله المغفرة"),
    ("توبة",     "توبة الإنابة شروط التوبة الرجوع إلى الله المغفرة"),
    ("الاستغفار", "استغفار الله غفران الذنوب أستغفر الله طلب المغفرة"),
    ("استغفار",  "استغفار الله غفران الذنوب أستغفر الله طلب المغفرة"),
    # خشوع / خضوع
    ("الخشوع",  "خشوع القلب الخشوع في الصلاة التضرع الروحاني"),
    ("خشوع",    "خشوع القلب الخشوع في الصلاة التضرع الروحاني"),
    ("الخضوع",  "خضوع الجسد الاستسلام الانقياد الطاعة الظاهرة"),
    ("خضوع",    "خضوع الجسد الاستسلام الانقياد الطاعة الظاهرة"),
    # نبي / رسول -> distinctive terms per concept
    ("النبي",   "نبي الوحي المنبأ النبوة الأنبياء بعث"),
    ("نبي",     "نبي الوحي المنبأ النبوة الأنبياء بعث"),
    ("الرسول",  "رسول الرسالة المرسل الوحي التبليغ أرسل"),
    ("رسول",    "رسول الرسالة المرسل الوحي التبليغ أرسل"),
    # صلاة فريضة / نافلة -> adding specific vocabulary for the comparison
    ("الفريضة",  "الصلاة المفروضة الفرض الواجب الصلوات الخمس"),
    ("فريضة",   "الصلاة المفروضة الفرض الواجب الصلوات الخمس"),
    ("النافلة",  "صلاة النفل التطوع السنن الرواتب قيام الليل"),
    ("نافلة",   "صلاة النفل التطوع السنن الرواتب قيام الليل"),
    # حلال / حرام
    ("الحلال",  "حلال مباح مأذون به ما أحل الله"),
    ("حلال",    "حلال مباح مأذون به ما أحل الله"),
    ("الحرام",  "حرام محظور ممنوع ما حرم الله المحرمات"),
    ("حرام",    "حرام محظور ممنوع ما حرم الله المحرمات"),
    # نكاح / مهر
    ("النكاح",  "نكاح عقد الزواج"),
    ("نكاح",    "نكاح عقد الزواج"),
    ("المهر",   "مهر صداق فريضة المهر حق الزوجة"),
    ("مهر",     "مهر صداق فريضة المهر حق الزوجة"),]

DEFINITIONAL_EXPANSION_MAP: list[tuple[list[str], str]]= [
    # الإسلام / أركان الإسلام
    (["اركان الاسلام", "اركان الإسلام", "pillars of islam",
      "اركان",
      "اركان الدين",
     ],
     "شهادة صلاة زكاة صوم حج بني الاسلام خمس"),

    # الإيمان
    (["ايمان", "الايمان", "الإيمان", "تعريف الإيمان", "تعريف الايمان", "faith", "belief"],
     "ملائكته كتبه رسله القدر حلاوة الايمان شعبة البعث"),

    # الصلاة
    (["صلاة", "الصلاة", "معنى الصلاة", "prayer", "salah", "salat"],
     "الصلوات الخمس الركوع السجود الوضوء الفحشاء الوقت افتراض"),

    # الزكاة
    (["زكاة", "الزكاة", "تعريف الزكاة", "شروط الزكاة", "zakat", "zakah"],
     "النصاب الحول مصارف الفقراء المساكين ايتاء فريضة"),

    # الصيام / الصوم
    (["تعريف الصيام", "تعريف الصوم", "معنى الصيام", "معنى الصوم",
      "أركان الصيام", "اركان الصيام", "fasting"],
     "الصيام الامساك النية الفجر المغرب رمضان"),

    # الحج / العمرة
    (["حج", "الحج", "عمرة", "العمرة", "أحكام الحج", "hajj", "umrah"],
     "الاحرام الطواف السعي عرفات اتموا العمرة"),

    # التوحيد
    (["توحيد", "التوحيد", "معنى التوحيد", "tawheed", "tawhid", "monotheism"],
     "اله واحد وحده شريك الربوبية الالوهية الاسماء الصفات"),

    # الشرك
    (["شرك", "الشرك", "ما هو الشرك", "shirk", "polytheism"],
     "تشرك ظلم عظيم المشرك يشرك الكبائر يغفر"),

    # الإحسان
    (["احسان", "الإحسان", "ihsan"],
     "تعبد كانك تراه يراك"),

    # الفرائض والسنن
    (["فرائض سنة", "الفرض والسنة", "فرض وسنة", "الفرائض والسنن",
      "فرائض وسنن", "الفرض والمستحب"],
     "الفرض السنة الواجب المستحب الأركان النوافل السنن الرواتب فروض الكفاية"),]



# Definitional BM25 query helpers 
# These tokens appear in a user's definitional question but NEVER in the Quran /
# Hadith corpus text itself.  Sending them to BM25 produces zero-match noise;
# stripping them leaves only the Islamic concept name that BM25 can actually hit.
DEF_META_TOKENS= frozenset({
    # Arabic meta / question words
    "تعريف", "معنى", "مفهوم", "أركان", "اركان", "شروط", "واجبات", "فرائض",
    "مكونات", "عناصر", "أسس", "قواعد", "مبادئ",
    "ما", "هو", "هي", "هل", "كيف", "لماذا", "كم",
    # Conjunctive-suffix forms that appear in definitional queries
    # like "تعريف الزكاة وشروطها" -> strip "وشروطها", "وأركانه", "وفرائضها"
    "وشروطها", "وشروطه", "وأركانها", "وأركانه", "وفرائضها", "وفرائضه",
    "وواجباتها", "وواجباته", "ومكوناته", "ومكوناتها",
    # Short prepositions
    "في", "من", "عن", "على", "الى", "إلى",
    # Scope framing words that are NOT Islamic concept names.
    "الحديث", "السنة", "النبوية", "الاسلامي", "الاسلامية",
    "القران", "الكريم", "الشريف",
    # Number adjectives that add no lexical signal for BM25
    "الخمسة", "الخمس", "الاربعة", "الثلاثة",})

# Longer scope phrases to strip as whole substrings before token-level removal
DEF_SCOPE_PHRASES= (
    "في القرآن الكريم",
    "في القرآن",
    "في السنة النبوية",
    "في السنة",
    "في الإسلام",
    "في الاسلام",
    "في الحديث",
    "في الشريعة",
    "القرآن الكريم",
    "القرآن",
    "السنة النبوية",)


STRONG_DEF_KEYWORDS= frozenset({
    "تعريف", "معنى", "مفهوم", "أركان", "اركان", "شروط",
    "فرائض", "واجبات", "definition", "define", "pillars",
    "conditions", "requirements", "meaning",
    "ما هو", "ما هي",})

FIQH_SIGNALS= {
    "ruling", "permissible", "is it allowed", "is it haram", "is it halal",
    "can i", "can muslims", "is music", "is it forbidden", "obligatory",
    "forbidden", "fiqh", "fatwa", "obligatory", "recommended", "disliked",
    "prohibited", "what is the ruling", "what does islam say",
    "حكم", "احكام", "أحكام", "جائز", "يجوز", "لا يجوز", "حرام", "حلال", "يحرم", "يجب",
    "واجب", "مستحب", "مكروه", "فتوى", "فقه", "مباح", "ما حكم",}

DEFINITIONAL_ARABIC_SIGNALS= frozenset({
    # Definition request words
    "تعريف", "معنى", "ما معنى", "ما هو معنى", "ما هي", "ما هو",
    "مفهوم", "شرح", "ما المقصود", "ما المراد",
    # Pillars / conditions / components
    "أركان", "اركان", "شروط", "واجبات", "فرائض", "مكونات", "عناصر",
    "أسس", "قواعد", "مبادئ",
    # Enumeration signals with question word
    "كم ركن", "كم شرط", "كم فريضة",})

DEFINITIONAL_ENGLISH_SIGNALS= frozenset({
    "definition", "define", "what is", "what are", "meaning of",
    "pillars of", "conditions of", "requirements of", "components of",
    "explain", "describe", "concept of",})

NARATIVE_SIGNALS= {
    "story of", "story about", "tale of", "what happened", "when did",
    "people of", "companions of", "prophet", "messenger",
    "yusuf", "musa", "ibrahim", "isa", "adam", "nuh", "dawud", "sulayman",
    "yahya", "zakariyya", "idris", "ilyas", "ayyub", "yunus",
    "people of the cave", "companions of the cave", "sleepers of the cave",
    "قصة", "قصص", "أصحاب", "أهل", "حين", "عندما", "ما حدث",
    "يوسف", "موسى", "إبراهيم", "عيسى", "آدم", "نوح", "داود",
    "سليمان", "يحيى", "زكريا", "أيوب", "يونس",
    "أصحاب الكهف", "اصحاب الكهف", "أهل الكهف", "اهل الكهف",
    "أصحاب الفيل", "لقمان", "ذو القرنين", "ذو الكفل",}

CONCEPT_SPLIT_PATTERN = re.compile(
    r'''
    \b(?:and|vs|versus|or)\b   # 1. English comparison separators
    | (?<!\w)(?:مع|عن)(?!\w)   # 2. Arabic standalone separators (with, about)
    | (?<=\s)و(?=\S)           # 3. Arabic attached conjunction 'and' (like, ' والصدقة')
    | \bو\b                    # 4. Arabic standalone conjunction 'and'
    ''', 
    re.IGNORECASE | re.VERBOSE
)

COMPARATIVE_STRONG_SIGNALS = frozenset({
    "what is the difference", "difference between", 
    "ما الفرق بين", "الفرق بين", "مقارنة بين", "مقارنه بين",
    "ما الفرق", "كيف يختلف"})

COMPARATIVE_WEAK_SIGNALS = frozenset({
    "vs", "versus", "compare", "قارن", "الفرق", "مقارنة", "مقارنه", "يختلف", "difference"
})

COMPARATIVE_GLUE_WORDS = frozenset({"بين", "ما", "كيف", "and", "و"})
QUESTION_WORDS= {"ما", "من", "كيف", "هل", "لماذا", "متى", "اين", "فضل", "اهميه", "معنى", "حكم", "خلق"}

THEMATIC_NOUNS= {"خلق", "رحمه", "رحمة", "فضل", "تلاوه", "قراءه", "ذكر", "صبر", "توبه", "مغفره", "شكر", "توكل", "إيمان"}

DUAL_SOURCE_SIGNALS= frozenset({
    "في القرآن والحديث", "في القرآن والسنة", "في الكتاب والسنة",
    "quran and hadith", "quran and sunnah", "quran and seerah",
    "يتناول القرآن والحديث", "يتناول القرآن والسنة",
    "في المصدرين", "في الكتاب والحديث",
    "القرآن والسنة", "الكتاب والسنة",})

CONNECTORS= {"او", "مع", "في", "عن", "على"}


SURAH_AYAHH_PATTERN= [
    re.compile(r"^\s*(\d{1,3})\s*[:/\s]\s*(\d{1,3})\s*$"),
    re.compile(r"sura[h]?\s+(\d{1,3})\s+(?:ayah|ayat|verse|aya)\s+(\d{1,3})", re.IGNORECASE),
    re.compile(r"\bQ\s*(\d{1,3})\s*:\s*(\d{1,3})\b", re.IGNORECASE),
]

# If any of these appear alongside a Surah name, the query is asking ABOUT
# the topic -> not requesting the Surah directly.
THEMATIC_SURAH_NAME_GUARDS= frozenset({
    # Arabic interrogative / thematic framing
    "ما يقوله", "ما يقول", "يتحدث", "يقول القرآن", "ما قاله", "ما جاء",
    "ما ذكر", "ما ورد", "يذكر", "آيات عن", "آيات في", "آيات تتعلق",
    "موضوع", "في موضوع", "عن موضوع", "ما قيل", "آيات", "أحاديث",
    # English equivalents
    "what does", "what do", "what does the quran say", "verses about",
    "verses on", "regarding", "concerning", "topic of", "about",
    "surah about", "what is said about", "what is mentioned",
})

STORY_INTENT_SIGNALS= frozenset({
    # Arabic story/event signals
    "قصة", "قصص", "أصحاب", "أهل", "حادثة", "حادثه", "واقعة", "واقعه",
    "حكاية", "حكايه", "سيرة", "سيره", "ما حدث", "ما جرى", "ما وقع",
    "ماذا حدث", "ماذا جرى", "كيف", "غزوة", "غزوه", "معركة", "معركه",
    "هجرة", "هجره", "فتح", "إسراء", "معراج", "مولد",
    # English story/event signals
    "story", "story of", "tale", "tale of", "what happened", "event",
    "incident", "account", "narrative", "journey", "battle",
    "migration", "conquest", "people of",})

STORY_SURAH_NAMES: frozenset= frozenset({
    "الكهف", "يوسف", "مريم", "هود", "نوح", "يونس", "إبراهيم",
    "الأنبياء", "القصص", "طه", "الفيل",
    "kahf", "al-kahf", "yusuf", "maryam", "hud", "nuh", "yunus", "ibrahim",
    "anbiya", "qasas", "taha",
})

HADITH_PATTERN= re.compile(
    r"(?:hadith\s+)?(?P<book>bukhari|muslim|tirmidhi|abudawud|abu\s*dawud)"
    r"\s+(?P<number>\d+)"
    r"|(?P<number2>\d+)\s+(?P<book2>bukhari|muslim|tirmidhi|abudawud|abu\s*dawud)",
    re.IGNORECASE,
)

BOOK_TO_EDITION= {
    "bukhari":  "eng-bukhari",
    "muslim":   "eng-muslim",
    "tirmidhi": "eng-tirmidhi",
    "abudawud": "eng-abudawud",
    "abu dawud": "eng-abudawud",}

QURAN_KEYWORDS= {
    # English -> phrases
    "quran", "quranic", "ayah", "ayat", "verse", "surah", "sura",
    "chapter of quran", "in the quran", "quranic verse", "tafsir",
    "what does allah say", "what does god say", "recitation",
    "what should i read", "what to read when", "what to recite",
    "allah is with", "god is with", "the patient", "be patient",
    "seek comfort", "verses for",
    # Arabic
    "قرآن", "القرآن", "آية", "سورة", "تفسير", "قرآنية", "الآية", "قرأ",}

QURAN_EMOTIONAL_KEYWORDS= frozenset({
    "hopeless", "despair", "despairing", "grieving", "mourning", "bereavement",
    "depressed", "depression", "miserable", "anxious", "anxiety", "afraid",
    "scared", "comfort", "comforting", "consolation", "reassurance", "reassure",
    "hopelessness", "overwhelmed",})

HADITH_KEYWORDS= {
    # English
    "hadith", "hadeeth", "narrated", "prophet said", "messenger said",
    "sunnah", "bukhari", "muslim", "tirmidhi", "abu dawud", "abudawud",
    "ibn majah", "nasai", "ruling", "fiqh", "fatwa", "scholarly opinion",
    # Arabic
    "حديث", "الحديث", "سنة", "السنة", "صحيح", "رواه", "روى", "قال النبي",
    "قال رسول", "البخاري", "مسلم", "الترمذي", "أبو داود", "حكم",
}

PRAYER_TIME_SIGNALS= frozenset({
    "صلاة الفجر", "صلاة العصر", "صلاة الظهر", "صلاة المغرب", "صلاة العشاء",
    "وقت الفجر", "وقت العصر", "وقت الظهر", "وقت المغرب", "وقت العشاء",
    "fajr prayer", "asr prayer", "dhuhr prayer", "maghrib prayer", "isha prayer",
    "fajr time", "asr time", "dhuhr time", "maghrib time", "isha time",
    "صلوات", "أوقات الصلاة", "prayer times", "prayer time",})

ENGLISH_CONECTORS= frozenset({
    "about", "of", "in", "for", "on", "with", "the", "a", "an",
    "is", "are", "was", "and", "or", "to", "from", "by", "at",
    "into", "that", "this", "it",})


NARRATIVE_QURAN_BM25_EXPANSIONS: dict[str, str]= {
    # Ashab al-Kahf
    "الكهف":   "الكهف فتيه الرقيم ثلاثمائه سنين",
    "اصحاب":  "الكهف فتيه الرقيم مدينه",
    "كهف":    "الكهف فتيه الرقيم",
    # Yusuf
    "يوسف":   "يوسف اخوته الجب السجن عزيز مصر",
    # Musa / Fir'awn
    "موسي":   "موسي فرعون بني اسرائيل البحر العصا",
    "فرعون":  "موسي فرعون هامان البحر سحر",
    # Ayyub
    "ايوب":   "ايوب الضر صابر كشفنا رحمه",
    # Ibrahim
    "ابراهيم":"ابراهيم النار اسماعيل الكعبه",
    # Nuh
    "نوح":    "نوح الطوفان السفينه قوم نوح",
    # Yunus
    "يونس":   "يونس الحوت الظلمات سبح",
    # Maryam
    "مريم":   "مريم عيسي ولدت المسيح",
    # Isra / Miraj
    "اسراء":  "اسري بعبده ليلا المسجد الحرام المسجد الاقصي سبحان",
    "معراج":  "عرج بي سدره المنتهي راي من ايات ربه الكبري",
    "اسري":   "اسري بعبده ليلا المسجد الحرام المسجد الاقصي سبحان",}

EVENT_BM25_EXPANSIONS: dict[str, str]= {
    "هجره": "غار ثور سراقه ثاني اثنين ابو بكر الصديق قباء انصار مهاجرون",
    "اسراء": "البراق سدره المنتهي المسجد الاقصي اسري بعبده ليلا",
    "معراج": "البراق سدره المنتهي فرضت الصلوات عرج بي جبريل السماوات",
    "فتح": "عام الفتح دخل مكه المغفر خالد بن الوليد الاصنام ابن خطل",
    "بدر": "يوم بدر الانفال يوم الفرقان العدوه الدنيا قتلي ثلاثمائه وخمسه عشر قريش ابو جهل",
    "غزوهاحد": "يوم احد جبل احد حمزه الرماه المشركون شيبه",
    "خندق": "غزوه الخندق الاحزاب حفر الخندق سلمان الفارسي",
    "حديبيه": "صلح الحديبيه بيعه الرضوان عمره القضاء الشجره",
    "خيبر": "غزوه خيبر اليهود علي بن ابي طالب حصون",
}


############ tokenizer ##################
# Arabic proclitics come in a fixed order: conjunction (و/ف) -> preposition (ب/ك/ل) -> article (ال).
# light_stem strips at most one of each, in that order, so a root letter that happens
# to look like a prefix is not eaten (الكتاب -> كتاب, never تاب).
ARABIC_CONJUNCTIONS= ('و', 'ف')
# longest-first so "بال" is tried before "ال"
ARABIC_ARTICLES= ('وال', 'فال', 'بال', 'كال', 'لل', 'ال')
# single-letter conjunctions/prepositions are only stripped when >= 4 letters remain
# (فرضه stays فرضه, بركه stays بركه)
ARABIC_PREPOSITIONS= ('ب', 'ل', 'ك')

ARABIC_SUFFIXES= [
    'ونها', 'ونه', 'ونك',
    'تها', 'تهم', 'تكم',
    'يها', 'يهم',
    'ها', 'هم', 'كم', 'نا',
    'وا', 'ون', 'ين', 'ان',
    'ات', 'يت',
    'ت', 'ي', 'ه',]
# plural/dual endings need a longer remainder: رمضان must not become رمض, عثمان not عثم
ARABIC_LONG_REMAINDER_SUFFIXES= frozenset({'ون', 'ين', 'ان', 'ات', 'وا', 'يت'})

PUNCT_PATTERN= re.compile(r'[^\w\s\u0621-\u063A\u0641-\u064A\u0660-\u0669]')

ARABIC_STOPWORDS= frozenset({
    # question words
    'ما', 'ماذا', 'كيف', 'هل', 'اين', 'متي', 'لماذا', 'لم',
    # spelled-out numbers
    'خمسا', 'اربع', 'اربعة', 'ثلاث', 'ثلاثة',
    'اثنان', 'اثنتان', 'واحد', 'واحدة', 'عشر', 'عشرة', 'عشرون',
    'مئة', 'مائة', 'الف', 'سبع', 'سبعة', 'ست', 'ستة',
    'تسع', 'تسعة', 'ثمان', 'ثمانية', 'كثير', 'بعض', 'كل',
    # prepositions and conjunctions
    'في', 'علي', 'الي', 'عن', 'مع', 'حتي', 'اذا', 'ان', 'انه',
    'اني', 'انها', 'انهم', 'انهن', 'انكم', 'انا', 'نحن',
    # pronouns
    'هو', 'هي', 'هم', 'هن', 'انت', 'انتم',
    # demonstratives
    'هذا', 'هذه', 'ذلك', 'تلك', 'هؤلاء', 'اولئك',
    # relative pronouns
    'الذي', 'التي', 'الذين',
    # negation/particles
    'لا', 'لم', 'لن', 'قد', 'لقد',
    # verbs of being
    'كان', 'كانت', 'كانوا', 'يكون', 'تكون', 'ليس', 'ليست',
    # adverbs/prepositions
    'غير', 'سوي', 'بعد', 'قبل', 'حين', 'عند', 'لدي', 'خلال', 'اثناء',
    # conjunctions
    'لان', 'لكي', 'كي', 'اما', 'او', 'ثم', 'بل', 'لكن',
    'الا', 'حيث', 'كما', 'مما', 'عما', 'فيما',
    # hadith isnad markers — narrator chain vocab, useless for retrieval
    'حدثنا', 'حدثني', 'اخبرنا', 'اخبرني', 'اخبره', 'روي', 'رواه',
    'قال', 'قالت', 'قالوا', 'يقول', 'سمعت', 'سمعنا', 'سمعه',
    # conjunction forms the stemmer keeps whole (single-letter و/ف need >= 4 letters left)
    'وقال', 'وقالت', 'وقالوا', 'فقالت', 'فقالوا', 'فلما', 'ولما', 'وكان', 'فكان',
    # generic Islamic phrases that add noise
    'رضي', 'رضوان', 'صلي', 'وسلم', 'عليه',
    'الله', 'رسول', 'نبي', 'النبي', 'الرسول',
    'ابو', 'ابن', 'بن', 'بنت', 'عبد',
    'حدث', 'اسناد', 'راو', 'رواة',
    'ذكر', 'ورد', 'جاء', 'فقال', 'فقالت',
    # 'كتاب' and 'صلوات' are NOT stopwords: الكتاب (2:2, اهل الكتاب) and الصلوات (2:238) are real search terms
    'باب', 'فصل', 'قوله',
    'اجره', 'اجرهم', 'اجرها',})

# lighter set for queries — keeps more meaning so search terms aren't dropped
QUERY_STOPWORDS= frozenset({
    'ما', 'ماذا', 'كيف', 'هل', 'اين', 'متي', 'لماذا', 'لم',
    'في', 'علي', 'الي', 'عن', 'مع', 'حتي', 'اذا', 'ان', 'انه',
    'اني', 'انها', 'انهم', 'انهن', 'انكم', 'انا', 'نحن',
    'هو', 'هي', 'هم', 'هن', 'انت', 'انتم',
    'هذا', 'هذه', 'ذلك', 'تلك', 'هؤلاء', 'اولئك',
    'الذي', 'التي', 'الذين',
    'لا', 'لم', 'لن', 'قد', 'لقد',
    'كان', 'كانت', 'كانوا', 'يكون', 'تكون', 'ليس', 'ليست',
    'غير', 'سوي', 'بعد', 'قبل', 'حين', 'عند', 'لدي', 'خلال', 'اثناء',
    'لان', 'لكي', 'كي', 'اما', 'او', 'ثم', 'بل', 'لكن',
    'الا', 'حيث', 'كما', 'مما', 'عما', 'فيما',
})

# passage indexing uses this bigger set to reduce index noise
PASSAGE_EXTRA_STOPWORDS= ARABIC_STOPWORDS | frozenset({'يوم', 'قوم', 'عمل', 'عملوا', 'عملت','شيء', 'اتي', 'يات', 'ذهب', 'اخذ','قلن', 'قلت', 'ناس',})

ENGLISH_STOPWORDS= frozenset({'the', 'a', 'an', 'is', 'are', 'was', 'were', 'in', 'on', 'at', 'to', 'for',
                             'of', 'and', 'or', 'but', 'with', 'what', 'how', 'why', 'who', 'which',
                             'this', 'that', 'it', 'be', 'has', 'have', 'had', 'do', 'does', 'did',
                             'not', 'no', 'from', 'by', 'as', 'its', 'his', 'her', 'their', 'our',
                             'he', 'she', 'they', 'we', 'you', 'i', 'my', 'your',})

######## helpers ################
# phrases that mark where the actual hadith text (matn) starts
MATN_MARKERS= ['قال رسول الله', 'قال النبي',
            'قال صلى الله عليه وسلم', 'قال صلي الله عليه وسلم',
            'يقول رسول الله', 'يقول النبي صلى',]
# compiler grading notes at the end of a hadith (normalized + raw spellings)
GRADING_TAIL_RE= re.compile(r'(قال\s+(ابو|أبو)\s+(عيسي|عيسى)|قال\s+(ابو|أبو)\s+داود|هذا\s+حديث\s+(حسن|صحيح|غريب)|وفي\s+الباب\s+عن)')
CHAIN_WORDS= {'عن', 'بن', 'ابن', 'ابو', 'أبو', 'عبد', 'انه', 'أنّه',
              'قال', 'عنه', 'انها', 'حدثنا', 'أخبرنا', 'اخبرنا', 'سمعت', 'حدثني'}

# strips the narrator prefix from English hadith translations
ENGLISH_ISNAD_RE= re.compile(
    r'^(Narrated\s+[\w\s\'`\.]+?:|[\w\s\'`\.]+?\s+reported\s*:|[\w\s\'`\.]+?\s+said\s*:)\s*',
    re.IGNORECASE
)

# matches inline Quran citation patterns inside hadith text
QURAN_CITATION_RE= re.compile(
    r'(اقرء|يقول|قال|وذلك قوله|كما قال|في قوله|قوله تعالى|قال تعالى)'
    r'\s*[\u0600-\u06FF\s]{0,20}'
    r'(سورة|آية|ال[^\s]+)',
    re.UNICODE
)


################### fusion #################
MILITARY_TOKENS= frozenset({"غزوه", "معركه", "هجره", "فتح", "سريه",
                            "خندق", "حنين", "تبوك", "خيبر", "حديبيه",
                            "battle", "expedition", "migration", "conquest", "hijra", "ghazwa", "ghazwah",})

EVENT_INTENT_TOKENS = frozenset({
    "غزوه",      # غزوة — battle
    "معركه",     # معركة
    "هجره",      # هجرة — Hijra
    "فتح",       # conquest
    "سريه",      # سرية — military expedition
    "بدر", "خندق", "حنين", "تبوك", "خيبر", "حديبيه",
    "مكه", "يثرب", "اسراء", "معراج", "مولد", "وفاه",
    "بيعه",
    "battle", "expedition", "migration", "conquest", "hijra", "isra",
    "miraj", "ghazwa", "ghazwah",})

# eclipse tokens — used to filter false-positive eclipse hadiths in Isra/Miraj queries
ECLIPSE_TOKENS = frozenset({
    "كسوف", "خسوف", "شمس", "قمر", "كسفت", "خسفت",
    "eclipse", "solar", "lunar",
})

PROPHET_NAMES= frozenset({"ايوب", "يوسف", "موسي", "عيسي", "ابراهيم", "نوح", "لوط",
                            "داود", "سليمان", "يونس", "هود", "صالح", "شعيب", "ادريس",
                            "اسماعيل", "اسحاق", "يعقوب", "زكريا", "يحيي", "مريم", "ادم",
                            "فرعون", "هامان", "قارون", "الكهف", "كهف", "فتيه", "الرقيم",
                            "لقمان", "ذوالقرنين",})


################### reranker query #################
# framing the cross-encoder should not see (scope is enforced by retrieval / filters)
RERANK_FRAME_PREFIXES_AR= ("ما يقوله القرآن عن", "ماذا يقول القرآن عن", "ماذا يقول الإسلام عن", "ماذا تقول السنة عن",
                           "كيف تتحدث السنة عن", "كيف يتحدث القرآن عن", "كيف يتناول القرآن والحديث موضوع",
                           "كيف يتناول القرآن والسنة موضوع", "كيف يتناول القرآن موضوع", "كيف يتناول الحديث موضوع",
                           "آيات وأحاديث عن", "آيات وأحاديث في", "آيات تتعلق ب", "آيات عن", "آيات في", "آيات",
                           "أحاديث عن", "أحاديث في", "الأحاديث المتعلقة ب", "الأحاديث الواردة في", "الأحاديث الواردة عن",
                           "الأحاديث عن", "ما ورد عن", "ما ورد في", "موضوع")
RERANK_FRAME_PREFIXES_EN= ("what does the quran say about", "what does the qur'an say about", "what does islam say about",
                           "what do the hadiths say about", "what does the sunnah say about", "verses about",
                           "quran verses about", "hadiths about", "hadith about", "ayat about")
RERANK_SOURCE_PHRASES_AR= ("في القرآن والسنة", "في القرآن والحديث", "في القرآن الكريم", "في القرآن", "في السنة النبوية",
                           "في السنة", "في الأحاديث", "في الحديث", "في الإسلام")
RERANK_SOURCE_PHRASES_EN= ("in the quran and sunnah", "in the quran and hadith", "in the quran", "in the qur'an",
                           "in islam", "in the hadith", "in hadith", "in the sunnah")

# hadiths whose English is only a cross-reference ("See translation for hadith 484 above"):
# nothing to show the user -> kept out of results (normalize_data_chuncks.py drops them at build time)
REFERENCE_ONLY_EN_RE= re.compile(
    r"\b(as above|see (the )?previous hadith|same as (the )?(above|previous)|see (translation|hadith)\b|"
    r"same as no\.?|as (hadith )?no\.? ?\d+|similarly-*\s*as no|narration about the chain)",
    re.IGNORECASE,
)

# Topic glossary: events and concepts that the query names but the evidence describes in other words
# ("غزوة بدر" vs Q 8:9 "إذ تستغيثون ربكم فاستجاب لكم أني ممدكم بألف من الملائكة"; "حجاب" vs Q 24:31
# "وليضربن بخمرهن على جيوبهن"). When a query matches, the gloss is
#   - appended to the reranker query (Q 17:1 for "حادثة الإسراء والمعراج": bge 0.03 -> 0.62), and
#   - used as an extra dense query and added to the BM25 query, so that evidence is retrieved at all.
# key = words (normalized, without ال) that must all be in the query (prefixes ال/و/ب/ف/ل/لل are ignored);
# English keys match lowercase words. Keep glosses short, factual and in the vocabulary of the sources.
TOPIC_GLOSSES= (
    # events
    (("اسراء",), "رحلة النبي ليلا من المسجد الحرام إلى المسجد الأقصى ثم عروجه إلى السماوات (Night Journey and Ascension)"),
    (("معراج",), "رحلة النبي ليلا من المسجد الحرام إلى المسجد الأقصى ثم عروجه إلى السماوات (Night Journey and Ascension)"),
    (("هجره", "مدينه"), "هجرة النبي وأبي بكر من مكة إلى المدينة، غار ثور، سراقة بن مالك (the Prophet's emigration, Hijra)"),
    (("هجره", "نبي"), "هجرة النبي وأبي بكر من مكة إلى المدينة، غار ثور، سراقة بن مالك (the Prophet's emigration, Hijra)"),
    (("بدر",), "غزوة بدر يوم الفرقان: نصر الله المؤمنين وهم أذلة وأمدهم بالملائكة على قريش (Battle of Badr)"),
    (("غزوه", "احد"), "غزوة أحد: هزيمة المسلمين بعد مخالفة الرماة واستشهاد حمزة وشج وجه النبي (Battle of Uhud)"),
    (("يوم", "احد"), "غزوة أحد: هزيمة المسلمين بعد مخالفة الرماة واستشهاد حمزة وشج وجه النبي (Battle of Uhud)"),
    (("معركه", "احد"), "غزوة أحد: هزيمة المسلمين بعد مخالفة الرماة واستشهاد حمزة وشج وجه النبي (Battle of Uhud)"),
    (("يوم", "حنين"), "غزوة حنين: إعجاب المسلمين بكثرتهم ثم إنزال الله سكينته على رسوله (Battle of Hunayn)"),
    (("خندق",), "غزوة الخندق (الأحزاب): حصار المدينة وحفر الخندق ورد الله الذين كفروا بغيظهم (Battle of the Trench)"),
    (("احزاب", "غزوه"), "غزوة الخندق (الأحزاب): حصار المدينة وحفر الخندق ورد الله الذين كفروا بغيظهم (Battle of the Trench)"),
    (("فتح", "مكه"), "فتح مكة: دخول النبي مكة عام الفتح وتحطيم الأصنام حول الكعبة والعفو عن قريش (Conquest of Mecca)"),
    (("حديبيه",), "صلح الحديبية وبيعة الرضوان تحت الشجرة والفتح المبين (Treaty of Hudaybiyyah)"),
    (("تبوك",), "غزوة تبوك (جيش العسرة) وتخلف المنافقين والثلاثة الذين خلفوا (Expedition of Tabuk)"),
    (("غزوه", "حنين"), "غزوة حنين: إعجاب المسلمين بكثرتهم ثم إنزال الله سكينته على رسوله (Battle of Hunayn)"),
    (("خيبر",), "غزوة خيبر وفتح حصون اليهود وإعطاء الراية لعلي (Battle of Khaybar)"),
    (("حجه", "وداع"), "حجة الوداع وخطبة النبي في عرفة: إن دماءكم وأموالكم حرام عليكم (Farewell Pilgrimage)"),
    # concepts named by a term that the verses rarely use
    (("حجاب",), "ستر المرأة زينتها وضرب الخمار على الجيوب وإدناء الجلابيب، وغض البصر وحفظ الفروج (hijab and modesty)"),
    (("عفه",), "غض البصر وحفظ الفروج والاستعفاف وستر الزينة (chastity and modesty)"),
    (("توحيد",), "إفراد الله بالعبادة: لا إله إلا الله، قل هو الله أحد، وإلهكم إله واحد (Islamic monotheism)"),
    (("شرك",), "عبادة غير الله معه وجعل الأنداد له، إن الله لا يغفر أن يشرك به (associating partners with Allah)"),
    (("نفاق",), "المنافقون يظهرون الإيمان ويبطنون الكفر، آية المنافق إذا حدث كذب (hypocrisy)"),
    (("خشوع",), "حضور القلب وسكون الجوارح في الصلاة والذكر، الذين هم في صلاتهم خاشعون (humility in prayer)"),
    (("بر", "والدين"), "الإحسان إلى الوالدين وطاعتهما وعدم عقوقهما، وبالوالدين إحسانا (kindness to parents)"),
    (("صله", "رحم"), "وصل الأقارب والإحسان إليهم وقطيعة الرحم (ties of kinship)"),
    (("غيبه",), "ذكرك أخاك بما يكره، ولا يغتب بعضكم بعضا (backbiting)"),
    (("night", "journey"), "رحلة النبي ليلا من المسجد الحرام إلى المسجد الأقصى ثم عروجه إلى السماوات (Night Journey and Ascension)"),
    (("badr",), "غزوة بدر يوم الفرقان: نصر الله المؤمنين وهم أذلة وأمدهم بالملائكة على قريش (Battle of Badr)"),
    (("uhud",), "غزوة أحد: هزيمة المسلمين بعد مخالفة الرماة واستشهاد حمزة وشج وجه النبي (Battle of Uhud)"),
    (("hijab",), "ستر المرأة زينتها وضرب الخمار على الجيوب وإدناء الجلابيب، وغض البصر وحفظ الفروج (hijab and modesty)"),
    (("tawhid",), "إفراد الله بالعبادة: لا إله إلا الله، قل هو الله أحد، وإلهكم إله واحد (Islamic monotheism)"),
)

# Surahs named after a person: a bare name ("يوسف", "Mary") asks about the person, not for the
# opening ayahs of the surah, so the surah-name early exit needs an explicit "سورة"/"surah" for these.
PERSON_NAME_SURAHS= frozenset({
    "يوسف", "مريم", "هود", "نوح", "يونس", "ابراهيم", "محمد", "لقمان",
    "yusuf", "yousuf", "joseph", "maryam", "mary", "hud", "nuh", "noah", "yunus", "jonah",
    "ibrahim", "abraham", "muhammad", "luqman",
})

# Person glossary: when the query is just a name (optionally "قصة"/"النبي"/"story of"...), the name alone
# matches every hadith whose matn mentions a narrator with that name ("قال أحمد", "Abu Musa reported").
# The gloss says who is meant, the same way TOPIC_GLOSSES does for events.
# entry = (required words, other allowed words, gloss); words are normalized (ا for أإآ, ي for ى, ه for ة, ء for ئ).
PERSON_FILLER_WORDS= frozenset({
    "قصه", "قصص", "سيره", "حياه", "النبي", "نبي", "نبيه", "الرسول", "رسول", "سيدنا", "سيدتنا", "عليه", "عليها",
    "عليهم", "السلام", "رضي", "الله", "عنه", "عنها", "من", "هو", "هي", "عن", "ما", "فضل", "فضائل", "صلي", "وسلم",
    "prophet", "story", "stories", "of", "the", "who", "was", "is", "about", "life", "virtues", "pbuh",
})
PERSON_GLOSSES= (
    (("احمد",), (), "أحمد اسم من أسماء النبي محمد ﷺ، بشّر به عيسى: ومبشرا برسول يأتي من بعدي اسمه أحمد (Ahmad, a name of Prophet Muhammad)"),
    (("محمد",), ("بن", "عبد"), "النبي محمد ﷺ رسول الله وخاتم النبيين (Prophet Muhammad, the Messenger of Allah)"),
    (("موسي",), ("عمران",), "النبي موسى عليه السلام كليم الله، أرسله إلى فرعون وبني إسرائيل وآتاه التوراة (Prophet Moses)"),
    (("عيسي",), ("ابن", "مريم", "مسيح"), "النبي عيسى ابن مريم عليه السلام المسيح، كلمة الله وروح منه، آتاه الإنجيل (Prophet Jesus)"),
    (("مسيح",), ("ابن", "مريم"), "النبي عيسى ابن مريم عليه السلام المسيح، كلمة الله وروح منه، آتاه الإنجيل (Prophet Jesus)"),
    (("مريم",), ("ابنه", "بنت", "عمران", "عذراء"), "مريم ابنة عمران أم عيسى، اصطفاها الله وطهرها على نساء العالمين (Mary, mother of Jesus)"),
    (("ابراهيم",), ("خليل",), "النبي إبراهيم خليل الله عليه السلام، حطّم الأصنام ورفع قواعد البيت مع إسماعيل (Prophet Abraham)"),
    (("يوسف",), ("يعقوب", "بن", "ابن"), "النبي يوسف بن يعقوب عليهما السلام، ألقاه إخوته في الجب ثم جعله الله على خزائن مصر (Prophet Joseph)"),
    (("نوح",), (), "النبي نوح عليه السلام، لبث في قومه ألف سنة إلا خمسين عاما وصنع الفلك ونجا من الطوفان (Prophet Noah)"),
    (("ادم",), ("ابو", "البشر"), "آدم أبو البشر عليه السلام، خلقه الله من طين وأسجد له الملائكة (Adam)"),
    (("هارون",), (), "النبي هارون أخو موسى عليهما السلام ووزيره (Prophet Aaron)"),
    (("داود",), (), "النبي داود عليه السلام، آتاه الله الزبور وألان له الحديد (Prophet David)"),
    (("سليمان",), ("بن", "داود"), "النبي سليمان بن داود عليهما السلام، سخر الله له الريح والجن وعلمه منطق الطير (Prophet Solomon)"),
    (("يونس",), ("ذو", "النون"), "النبي يونس عليه السلام ذو النون صاحب الحوت (Prophet Jonah)"),
    (("ايوب",), (), "النبي أيوب عليه السلام، صبر على البلاء: أني مسني الضر وأنت أرحم الراحمين (Prophet Job)"),
    (("لوط",), (), "النبي لوط عليه السلام، دعا قومه الذين يأتون الفاحشة فأهلكهم الله (Prophet Lot)"),
    (("هود",), (), "النبي هود عليه السلام أرسله الله إلى قوم عاد (Prophet Hud)"),
    (("صالح",), (), "النبي صالح عليه السلام أرسله الله إلى ثمود، وآيته الناقة (Prophet Salih)"),
    (("شعيب",), (), "النبي شعيب عليه السلام أرسله الله إلى مدين، أوفوا الكيل والميزان (Prophet Shuayb)"),
    (("زكريا",), (), "النبي زكريا عليه السلام، دعا ربه فوهب له يحيى (Prophet Zechariah)"),
    (("يحيي",), (), "النبي يحيى بن زكريا عليهما السلام، آتاه الله الحكم صبيا (Prophet John)"),
    (("اسماعيل",), (), "النبي إسماعيل بن إبراهيم عليهما السلام، الذبيح، رفع قواعد البيت مع أبيه (Prophet Ishmael)"),
    (("اسحاق",), (), "النبي إسحاق بن إبراهيم عليهما السلام، بشرت به الملائكة إبراهيم وسارة (Prophet Isaac)"),
    (("يعقوب",), (), "النبي يعقوب (إسرائيل) أبو يوسف عليهما السلام، فصبر جميل (Prophet Jacob)"),
    (("ادريس",), (), "النبي إدريس عليه السلام، ورفعناه مكانا عليا (Prophet Idris)"),
    (("ابو", "بكر"), ("صديق",), "أبو بكر الصديق صاحب النبي في الغار وأول الخلفاء الراشدين (Abu Bakr al-Siddiq)"),
    (("عمر",), ("بن", "خطاب", "فاروق"), "عمر بن الخطاب الفاروق، ثاني الخلفاء الراشدين (Umar ibn al-Khattab)"),
    (("عثمان",), ("بن", "عفان"), "عثمان بن عفان ذو النورين، ثالث الخلفاء الراشدين، جهز جيش العسرة (Uthman ibn Affan)"),
    (("علي",), ("بن", "ابي", "طالب"), "علي بن أبي طالب ابن عم النبي وزوج فاطمة، رابع الخلفاء الراشدين (Ali ibn Abi Talib)"),
    (("عاءشه",), ("ام", "المؤمنين", "مؤمنين", "بنت", "ابي", "بكر"), "عائشة بنت أبي بكر أم المؤمنين زوج النبي ﷺ وفضلها (Aisha, Mother of the Believers)"),
    (("عايشه",), ("ام", "المؤمنين", "مؤمنين"), "عائشة بنت أبي بكر أم المؤمنين زوج النبي ﷺ وفضلها (Aisha, Mother of the Believers)"),
    (("خديجه",), ("ام", "المؤمنين", "مؤمنين", "بنت", "خويلد"), "خديجة بنت خويلد أم المؤمنين، أول زوجات النبي ﷺ وأول من آمن به (Khadija)"),
    (("فاطمه",), ("بنت", "النبي", "زهراء"), "فاطمة الزهراء بنت النبي ﷺ سيدة نساء أهل الجنة (Fatima, daughter of the Prophet)"),
    (("بلال",), ("بن", "رباح"), "بلال بن رباح مؤذن النبي ﷺ، عُذّب في مكة فقال أحد أحد (Bilal ibn Rabah)"),
)


# Transliteration keys that are ordinary English words/phrases ("patience", "mercy", "Day of Judgment"):
# the English translations use them, so the query keeps the English word and gets the Arabic added
# ("patience" -> "patience (الصبر)") instead of losing it. Latin spellings of Arabic words ("sabr", "Musa")
# are still replaced, since the translations don't use them. Built from words that appear lowercase
# >=20 times in the corpus English text, plus hand-picked capitalised/multi-word phrases.
TRANSLIT_KEEP_ENGLISH= frozenset({
    'ablution', 'adhan', 'adultery', 'almsgiving', 'antichrist', 'arrogance', 'asceticism',
    'authentic hadith', 'battle of badr', 'battle of the trench', 'battle of uhud',
    'biography of the prophet', 'blood money', 'bowing', 'bridge over hell', 'brotherhood', 'call to prayer',
    'cave of hira', 'cave of thawr', 'chain of narration', 'creed', 'day of judgment', 'day of resurrection',
    'disbelief', 'disjointed letters', 'divine decree', 'divorce', 'dowry', 'envy', 'exegesis', 'expiation',
    'fabricated hadith', 'faith', 'fasting', 'fear of allah', 'forgiveness', 'god-consciousness',
    'gog and magog', 'grand mosque', 'gratitude', 'grave', 'hadith', 'hajj', 'hell', 'hellfire',
    'hope in allah', 'house of allah', 'humility', 'hypocrisy', 'impurity', 'inheritance',
    'innovation in religion', 'intention', 'intercession', 'interest', 'invitation to islam', 'iqamah',
    'islam', 'jerusalem', 'jurisprudence', 'justice', 'last hour', 'love of allah', 'major signs', 'mecca',
    'medina', 'memorization of quran', 'mercy', 'messenger of allah', 'migration to medina', 'minor signs',
    'monotheism', 'mount arafah', 'night journey', 'night of decree', 'night of power', 'obligatory',
    'oneness of allah', 'ostentation', 'paradise', 'patience', 'people of the cave', 'people of the elephant',
    'piety', 'pilgrimage', 'polytheism', 'pool of kawthar', 'predestination', 'prophet muhammad',
    'prophets mosque', 'prostration', 'provision', 'punishment of the grave', 'purification', 'qiblah',
    'reasons for revelation', 'recitation', 'reckoning', 'reliance on allah', 'remembrance of allah',
    'repentance', 'retribution', 'sadaqah', 'satan', 'scale of deeds', 'seeking forgiveness', 'seerah',
    'self-accountability', 'showing off', 'signs of the hour', 'sincerity', 'sunnah', 'supererogatory',
    'supplication', 'surah', 'tajweed', 'takbir', 'tayammum', 'testimony of faith', 'the prophet', 'trials',
    'umrah', 'usury', 'verse', 'weak hadith', 'witr', 'zakat', 'zamzam water',
})

# English and alternative Arabic keys for the same topic glosses
_GLOSS_BY_KEY= dict(TOPIC_GLOSSES)
TOPIC_GLOSSES= TOPIC_GLOSSES + (
    (("حقوق", "والدين"), _GLOSS_BY_KEY[("بر", "والدين")]),
    (("طاعه", "والدين"), _GLOSS_BY_KEY[("بر", "والدين")]),
    (("عقوق",), _GLOSS_BY_KEY[("بر", "والدين")]),
    (("parents",), _GLOSS_BY_KEY[("بر", "والدين")]),
    (("kinship",), _GLOSS_BY_KEY[("صله", "رحم")]),
    (("backbiting",), _GLOSS_BY_KEY[("غيبه",)]),
    (("chastity",), _GLOSS_BY_KEY[("عفه",)]),
    (("modesty",), _GLOSS_BY_KEY[("حجاب",)]),
    (("trench",), _GLOSS_BY_KEY[("خندق",)]),
    (("hudaybiyyah",), _GLOSS_BY_KEY[("حديبيه",)]),
    (("hudaybiya",), _GLOSS_BY_KEY[("حديبيه",)]),
    (("tabuk",), _GLOSS_BY_KEY[("تبوك",)]),
    (("khaybar",), _GLOSS_BY_KEY[("خيبر",)]),
    (("hunayn",), _GLOSS_BY_KEY[("غزوه", "حنين")]),
    (("conquest", "mecca"), _GLOSS_BY_KEY[("فتح", "مكه")]),
    (("conquest", "makkah"), _GLOSS_BY_KEY[("فتح", "مكه")]),
    (("farewell", "pilgrimage"), _GLOSS_BY_KEY[("حجه", "وداع")]),
)

# Surahs named by a topic people search for on its own ("الحج", "التوبة", "jinn"): the opening ayahs of
# the surah are not about the topic (22:1-4 is about the Hour), so these also need an explicit surah word.
TOPIC_NAME_SURAHS= frozenset({
    "التوبه", "الحج", "الطلاق", "النساء", "الجمعه", "الجن", "القيامه", "الاسراء", "الاخلاص", "الشوري",
    "tawbah", "tawba", "hajj", "talaq", "jinn", "qiyamah", "ikhlas", "jumuah", "jumu'ah", "isra",
    # ordinary English words
    "sad", "tin",
})
SURAHS_NEEDING_SURAH_WORD= PERSON_NAME_SURAHS | TOPIC_NAME_SURAHS
