from dataclasses import asdict, dataclass, is_dataclass

import alphabet as alph
import operations
from pydantic import BaseModel

from moshaf_rules import MoshafAttributes
from sifat import SifatAnalysisOutput, analyze_sifat
from utils import sub_with_mapping


_DEFAULT_MOSHAF_ATTR = {
    "rewaya": "hafs",
    "madd_monfasel_len": 4,
    "madd_mottasel_len": 4,
    "madd_mottasel_waqf": 4,
    "madd_aared_len": 4,
}


@dataclass
class PhonetizerOutput:
    phonemes: str
    sifat: list[SifatAnalysisOutput]
    mappings: list | None = None


def _to_jsonable(value):
    if isinstance(value, BaseModel):
        if hasattr(value, "model_dump"):
            return _to_jsonable(value.model_dump())
        return _to_jsonable(value.dict())
    if is_dataclass(value):
        return _to_jsonable(asdict(value))
    if isinstance(value, dict):
        return {str(key): _to_jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_to_jsonable(item) for item in value]
    return value


def _normalize_mapping(value):
    if isinstance(value, dict):
        return value
    if value is None:
        return {}
    if hasattr(value, "items"):
        return {str(key): item for key, item in value.items()}
    try:
        return dict(value)
    except Exception:
        return {}


def phonetizer(
    uthmani_text,
    moshaf_attr: MoshafAttributes,
    remove_spaces: bool = False,
) -> PhonetizerOutput:

    unchanged_uthmani_text = uthmani_text
    # This function will convert the uthmani text to phonetic representation
    # and then compare it with the quranic text to find the differences
    # and return the phonetic representation of the uthmani text
    uthmani_text, mappings = sub_with_mapping(r"\s+", rf"{alph.uthmani.space}", uthmani_text)
    uthmani_text, mappings = sub_with_mapping(r"(\s$|^\s)", r"", uthmani_text, mappings)

    # do operations to convert the uthmani text to phonetic representation
    for op in operations.OPS:
        uthmani_text, mappings = op.forward(uthmani_text, moshaf_attr, mappings)

    if remove_spaces:
        uthmani_text, mappings = sub_with_mapping(rf"{alph.uthmani.space}", "", uthmani_text, mappings)

    sifat = analyze_sifat(unchanged_uthmani_text, uthmani_text, moshaf_attr)

    return PhonetizerOutput(phonemes=uthmani_text, sifat=sifat, mappings=mappings)


def phonetize_payload(uthmani_text, moshaf_attr, remove_spaces: bool = False):
    moshaf_attr = _normalize_mapping(moshaf_attr)
    merged_moshaf_attr = {**_DEFAULT_MOSHAF_ATTR, **moshaf_attr}

    if not isinstance(moshaf_attr, MoshafAttributes):
        if hasattr(MoshafAttributes, "model_validate"):
            moshaf_attr = MoshafAttributes.model_validate(merged_moshaf_attr)
        else:
            moshaf_attr = MoshafAttributes.parse_obj(merged_moshaf_attr)

    return _to_jsonable(phonetizer(uthmani_text, moshaf_attr, remove_spaces))


    

