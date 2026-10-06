from dataclasses import dataclass
from typing import Literal



@dataclass
class HamzatElWasl:
    '''class to represent all cases where hamzat el wasl is in the beggining of a word'''
    verbs_nouns: set[str]  # verb when in beggining of a sentence, noun when in the middle of a sentence
    verbs: set[str]  
    damma_3arida_verbs: set[str]  # verbs that have a damma 3arida when in the beggining of a sentence
    nouns: set[str]

@dataclass
class SpecialCase:
    pattern: str
    name: str | None = None
    variations : dict[str, str] | None = None  # dict of variations for the special case, if any
    target_pronunciation: str | None = None  # the target pronunciation for this special case, if any
    position: Literal['start', 'middle', 'end'] | None = None  # the position of the special case in the word, if any


@dataclass
class UthmaniAlphabet:

    # alphabet + alif_maksora + taa_marboota
    alif: str
    alif_maksora: str
    baa: str
    taa: str
    taa_marboota: str
    thaa: str
    jeem: str
    haa2: str # 7aa2
    khaa: str
    daal: str
    thaal: str
    raa: str
    zay: str
    seen: str
    sheen: str
    saad: str
    daad: str
    tah: str
    thah: str
    ayn: str
    ghyn: str
    faa: str
    qaf: str
    kaf: str
    lam: str
    meem: str
    noon: str
    haa: str
    waw: str
    yaa: str

    # hmazat
    hamza_3ala_el_satr: str
    hamza_above_alif: str
    hamza_below_alif: str
    hamza_above_waw: str
    hamza_above_yaa: str
    hamza_mamdoda: str  

    # harakat
    tanween_fath: str
    tanween_dam: str
    tanween_kasr: str
    fatha: str
    dama: str
    kasra: str
    shadda: str  
    ras_7aa2: str  
    madd: str  

    hamzat_wasl: str

    # small letters
    small_alef: str  
    small_seen_above: str  
    small_seen_below: str  
    small_waw: str  
    small_yaa_sila: str  
    small_yaa: str  
    small_noon: str  

    # dabt letters
    skoon_mostadeer: str  
    skoon_mostateel: str  
    meem_iqlab: str  
    imala_sign: str  # majreha 
    ishmam_sign: str  
    tasheel_sign: str  

    # special cases and letters
    tanween_idhaam_dterminer: str  # misaligned tanween
    kasheeda: str  # used for elongating a word
    space: str

    hroof_muqatta3a: dict[str, str]  # dict of strings for the hroof muqatta3a combinations
    special_cases: list[SpecialCase]  # list of special cases where the pronounciation doesnt follow the normal rules of the alphabet.
    hamzat_el_wasl: HamzatElWasl  # class to represent all cases where hamzat el wasl is in the beggining of a word

    # diffrent tanween variations
    tanween_fath_mothhar: str = ""
    tanween_dam_mothhar: str = ""
    tanween_kasr_mothhar: str = ""
    tanween_fath_modgham: str = ""
    tanween_dam_modgham: str = ""
    tanween_kasr_modgham: str = ""
    tanween_fath_iqlab: str = ""
    tanween_dam_iqlab: str = ""
    tanween_kasr_iqlab: str = ""

    # el madd
    madd_alif: str = ""
    madd_waw: str = ""
    madd_yaa: str = ""

    # harakat
    harakat: str = ""  # string of all harakat characters

    # special groups of letters for tagweed
    noon_ikhfaa_letters: str = ""  # letters that cause the noon to be pronounced with ikhfaa
    noon_idghaam_letters: str = ""  # letters that cause the noon to be pronounced with idghaam
    qlqla_letters: str = ""  # letters  to be pronounced with qlqala
    hamazat: str = ""  # string of all hamzat characters
    letters: str = ""  # string of all letters in the alphabet, including hmazat and special letters
    pure_letters: str = ""  # string of all pure letters in the alphabet, excluding hmazat and special letters
    pure_letters_without_yaa_waw: str = ""  # string of all pure letters in the alphabet, excluding hmazat and special letters and yaa and waw

    @property
    def taa_mabsoota(self) -> str:
        return self.taa

    @property
    def ras_haaa(self) -> str:
        return self.ras_7aa2

    @property
    def hamza(self) -> str:
        return self.hamza_3ala_el_satr

    @property
    def hamazat_group(self) -> str:
        return self.hamazat

    @property
    def letters_group(self) -> str:
        return self.letters

    @property
    def pure_letters_group(self) -> str:
        return self.pure_letters

    @property
    def harakat_group(self) -> str:
        return self.harakat

    @property
    def noon_ikhfaa_group(self) -> str:
        return self.noon_ikhfaa_letters

    @property
    def noon_idghaam_group(self) -> str:
        return self.noon_idghaam_letters

    @property
    def qlqla_group(self) -> str:
        return self.qlqla_letters


    
@dataclass
class Phonetics:
    hamza: str
    baa: str
    taa: str
    thaa: str
    jeem: str
    haa_mohmala: str
    khaa: str
    daal: str
    thaal: str
    raa: str
    zay: str
    seen: str
    sheen: str
    saad: str
    daad: str
    tah: str
    thah: str
    ayn: str
    ghyn: str
    faa: str
    qaf: str
    kaf: str
    lam: str
    meem: str
    noon: str
    haa: str
    waw: str
    yaa: str

    # Madd group
    alif: str
    yaa_madd: str
    waw_madd: str

    # Harakat
    fatha: str
    dama: str
    kasra: str

    # special charcters
    fatha_momala: str
    alif_momala: str
    hamza_mosahala: str
    qlqla: str
    noon_mokhfah: str
    meem_mokhfah: str
    sakt: str
    dama_mokhtalasa: str