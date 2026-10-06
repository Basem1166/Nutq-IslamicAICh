import json
from pathlib import Path

from alphabet import HamzatElWasl, Phonetics, SpecialCase, UthmaniAlphabet


CONFIG_PATH = Path(__file__).with_name("config.json")


def _build_hamzat_el_wasl(config: dict) -> HamzatElWasl:
    hamzat_wasl_cfg = config["hamzat_wasl"]
    return HamzatElWasl(
        verbs_nouns=set(hamzat_wasl_cfg["verbs_nouns_inter"]),
        verbs=set(hamzat_wasl_cfg["verbs"]),
        damma_3arida_verbs=set(hamzat_wasl_cfg["damma_aarida_verbs"]),
        nouns=set(hamzat_wasl_cfg["nouns"]),
    )


def _build_special_cases(uthmani_cfg: dict) -> list[SpecialCase]:
    return [
        SpecialCase(
            name=item.get("attr_name"),
            pattern=item["pattern"],
            variations=item.get("opts"),
            target_pronunciation=item.get("target_pattern"),
            position=item.get("pos"),
        )
        for item in uthmani_cfg["special_patterns"]
    ]


def load_uthmani_alphabet() -> UthmaniAlphabet:
    with CONFIG_PATH.open("r", encoding="utf-8") as config_file:
        config = json.load(config_file)

    uthmani_cfg = config["uthmani"]
    hamzat_el_wasl = _build_hamzat_el_wasl(config)
    special_cases = _build_special_cases(uthmani_cfg)

    ikhfaa_letters = uthmani_cfg["noon_ikhfaa_group"]
    ikhfaa_letters = ikhfaa_letters.replace(uthmani_cfg["taa_marboota"], uthmani_cfg["taa"])
    if uthmani_cfg["taa"] not in ikhfaa_letters:
        ikhfaa_letters += uthmani_cfg["taa"]
    if uthmani_cfg["thah"] not in ikhfaa_letters:
        ikhfaa_letters += uthmani_cfg["thah"]


    alphabet = UthmaniAlphabet(
        alif=uthmani_cfg["alif"],
        alif_maksora=uthmani_cfg["alif_maksora"],
        baa=uthmani_cfg["baa"],
        taa=uthmani_cfg["taa"],
        taa_marboota=uthmani_cfg["taa_marboota"],
        thaa=uthmani_cfg["thaa"],
        jeem=uthmani_cfg["jeem"],
        haa2=uthmani_cfg["haa2"],
        khaa=uthmani_cfg["khaa"],
        daal=uthmani_cfg["daal"],
        thaal=uthmani_cfg["thaal"],
        raa=uthmani_cfg["raa"],
        zay=uthmani_cfg["zay"],
        seen=uthmani_cfg["seen"],
        sheen=uthmani_cfg["sheen"],
        saad=uthmani_cfg["saad"],
        daad=uthmani_cfg["daad"],
        tah=uthmani_cfg["tah"],
        thah=uthmani_cfg["thah"],
        ayn=uthmani_cfg["ayn"],
        ghyn=uthmani_cfg["ghyn"],
        faa=uthmani_cfg["faa"],
        qaf=uthmani_cfg["qaf"],
        kaf=uthmani_cfg["kaf"],
        lam=uthmani_cfg["lam"],
        meem=uthmani_cfg["meem"],
        noon=uthmani_cfg["noon"],
        haa=uthmani_cfg["haa"],
        waw=uthmani_cfg["waw"],
        yaa=uthmani_cfg["yaa"],
        hamza_3ala_el_satr=uthmani_cfg["hamza_3ala_el_satr"],
        hamza_above_alif=uthmani_cfg["hamza_above_alif"],
        hamza_below_alif=uthmani_cfg["hamza_below_alif"],
        hamza_above_waw=uthmani_cfg["hamza_above_waw"],
        hamza_above_yaa=uthmani_cfg["hamza_above_yaa"],
        hamza_mamdoda=uthmani_cfg["hamza_mamdoda"],
        tanween_fath=uthmani_cfg["tanween_fath"],
        tanween_dam=uthmani_cfg["tanween_dam"],
        tanween_kasr=uthmani_cfg["tanween_kasr"],
        fatha=uthmani_cfg["fatha"],
        dama=uthmani_cfg["dama"],
        kasra=uthmani_cfg["kasra"],
        shadda=uthmani_cfg["shadda"],
        ras_7aa2=uthmani_cfg["ras_7aa2"],
        madd=uthmani_cfg["madd"],
        hamzat_wasl=uthmani_cfg["hamzat_wasl"],
        small_alef=uthmani_cfg["small_alef"],
        small_seen_above=uthmani_cfg["small_seen_above"],
        small_seen_below=uthmani_cfg["small_seen_below"],
        small_waw=uthmani_cfg["small_waw"],
        small_yaa_sila=uthmani_cfg["small_yaa_sila"],
        small_yaa=uthmani_cfg["small_yaa"],
        small_noon=uthmani_cfg["small_noon"],
        skoon_mostadeer=uthmani_cfg["skoon_mostadeer"],
        skoon_mostateel=uthmani_cfg["skoon_mostateel"],
        meem_iqlab=uthmani_cfg["meem_iqlab"],
        imala_sign=uthmani_cfg["imala_sign"],
        ishmam_sign=uthmani_cfg["ishmam_sign"],
        tasheel_sign=uthmani_cfg["tasheel_sign"],
        tanween_idhaam_dterminer=uthmani_cfg["tanween_idhaam_dterminer"],
        kasheeda=uthmani_cfg["kasheeda"],
        space=uthmani_cfg["space"],
        hroof_muqatta3a=uthmani_cfg["hrof_moqtaa_disassemble"],
        special_cases=special_cases,
        hamzat_el_wasl=hamzat_el_wasl,
        tanween_fath_mothhar=uthmani_cfg["tanween_fath_mothhar"],
        tanween_dam_mothhar=uthmani_cfg["tanween_dam_mothhar"],
        tanween_kasr_mothhar=uthmani_cfg["tanween_kasr_mothhar"],
        tanween_fath_modgham=uthmani_cfg["tanween_fath_modgham"],
        tanween_dam_modgham=uthmani_cfg["tanween_dam_modgham"],
        tanween_kasr_modgham=uthmani_cfg["tanween_kasr_modgham"],
        tanween_fath_iqlab=uthmani_cfg["tanween_fath_iqlab"],
        tanween_dam_iqlab=uthmani_cfg["tanween_dam_iqlab"],
        tanween_kasr_iqlab=uthmani_cfg["tanween_kasr_iqlab"],
        madd_alif=uthmani_cfg["alif"] + uthmani_cfg["madd"],
        madd_waw=uthmani_cfg["waw"] + uthmani_cfg["madd"],
        madd_yaa=uthmani_cfg["yaa"] + uthmani_cfg["madd"],
        harakat=uthmani_cfg["harakat_group"],
        noon_ikhfaa_letters=ikhfaa_letters,
        noon_idghaam_letters=uthmani_cfg["noon_idghaam_group"],
        qlqla_letters=uthmani_cfg["qlqla_group"],
        hamazat=uthmani_cfg["hamazat_group"],
        letters=uthmani_cfg["letters_group"],
        pure_letters=uthmani_cfg["pure_letters_group"],
        pure_letters_without_yaa_waw=uthmani_cfg["pure_letters_group"].replace(uthmani_cfg["yaa"], "").replace(
            uthmani_cfg["waw"], ""
        ),
    )

    return alphabet

def load_phonetics(uthmani_alphabet: UthmaniAlphabet) -> Phonetics:
    # This function will load the phonetic representation of the uthmani alphabet from the config file
    # and return a dictionary of the phonetic representation of each character in the uthmani alphabet
    phonetics = Phonetics(
        hamza=uthmani_alphabet.hamza_3ala_el_satr,
        baa=uthmani_alphabet.baa,
        taa=uthmani_alphabet.taa,
        thaa=uthmani_alphabet.thaa,
        jeem=uthmani_alphabet.jeem,
        haa_mohmala=uthmani_alphabet.haa2,
        khaa=uthmani_alphabet.khaa,
        daal=uthmani_alphabet.daal,
        thaal=uthmani_alphabet.thaal,
        raa=uthmani_alphabet.raa,
        zay=uthmani_alphabet.zay,
        seen=uthmani_alphabet.seen,
        sheen=uthmani_alphabet.sheen,
        saad=uthmani_alphabet.saad,
        daad=uthmani_alphabet.daad,
        tah=uthmani_alphabet.tah,
        thah=uthmani_alphabet.thah,
        ayn=uthmani_alphabet.ayn,
        ghyn=uthmani_alphabet.ghyn,
        faa=uthmani_alphabet.faa,
        qaf=uthmani_alphabet.qaf,
        kaf=uthmani_alphabet.kaf,
        lam=uthmani_alphabet.lam,
        meem=uthmani_alphabet.meem,
        noon=uthmani_alphabet.noon,
        haa=uthmani_alphabet.haa,
        waw=uthmani_alphabet.waw,
        yaa=uthmani_alphabet.yaa,
        alif=uthmani_alphabet.alif,
        yaa_madd=uthmani_alphabet.small_yaa_sila,
        waw_madd=uthmani_alphabet.small_waw,
        fatha=uthmani_alphabet.fatha,
        dama=uthmani_alphabet.dama,
        kasra=uthmani_alphabet.kasra,
        fatha_momala=uthmani_alphabet.imala_sign,
        alif_momala=uthmani_alphabet.kasheeda,
        hamza_mosahala="\u0672",  # hamza above with two dots below 
        qlqla="\u0687",  # geem small above 
        noon_mokhfah="\u06ba",  # noon with small circle above 
        meem_mokhfah="\u06fe",
        sakt=uthmani_alphabet.small_seen_above,
        dama_mokhtalasa="\u0619",
    )

    return phonetics




uthmani_alphabet = load_uthmani_alphabet()
    



    
