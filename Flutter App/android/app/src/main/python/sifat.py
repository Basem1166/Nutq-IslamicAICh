from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Literal

import alphabet as alph
from load_alphabet import load_phonetics, uthmani_alphabet
from moshaf_rules import MoshafAttributes
from operations import (
	AddAlifInAllahNameOp,
	ApplySpecialCasesOp,
	DropInitialShaddaOp,
	ExpandMuqattaLettersOp,
	ExpandSmallLettersOp,
	NormalizeAlifMaksoraOp,
	NormalizeHamzatOp,
	NormalizeMaddAwadOp,
	NormalizeSukunMostateelOp,
	NormalizeTaaMarbootaOp,
	NormalizeWawAlsalahOp,
	NormalizeWordEndOp,
	PrepareGhunnahIdghamIqlabOp,
	RemoveKashidaOp,
	RemoveMidHamzatWaslOp,
	RemoveSukunMostadeerOp,
	ResolveDoubleSukunOp,
)
from pydantic import BaseModel


uth = uthmani_alphabet
ph = load_phonetics(uthmani_alphabet)

alph.uthmani = uth
alph.phonetics = ph


class SifatAnalysisOutput(BaseModel):
	phonemes: str
	hams_or_jahr: Literal["hams", "jahr"]
	shidda_or_rakhawa: Literal["shadeed", "between", "rikhw"]
	tafkheem_or_taqeeq: Literal["mofakham", "moraqaq", "low_mofakham"]
	itbaq: Literal["monfateh", "motbaq"]
	safeer: Literal["safeer", "no_safeer"]
	qalqla: Literal["moqalqal", "not_moqalqal"]
	tikraar: Literal["mokarar", "not_mokarar"]
	tafashie: Literal["motafashie", "not_motafashie"]
	istitala: Literal["mostateel", "not_mostateel"]
	ghonna: Literal["maghnoon", "not_maghnoon"]


@dataclass(frozen=True)
class _PhoneticClassGroups:
	core: str
	residuals: str
	harakat: str
	hams: set[str]
	shidda: set[str]
	between_shidda_rakhawa: set[str]
	tafkheem: set[str]
	itbaaq: set[str]
	safeer: set[str]
	qalqal: set[str]
	tikrar: set[str]
	tafashie: set[str]
	istitala: set[str]
	ghonna: set[str]


def _build_groups() -> _PhoneticClassGroups:
	core_letters = "".join(
		{
			*list(uth.letters),
			ph.hamza,
			ph.alif,
			ph.yaa_madd,
			ph.waw_madd,
			ph.noon_mokhfah,
			ph.meem_mokhfah,
			ph.hamza_mosahala,
			ph.alif_momala,
		}
	)

	return _PhoneticClassGroups(
		core=core_letters,
		residuals=f"{uth.harakat}{ph.qlqla}{ph.sakt}{ph.dama_mokhtalasa}{ph.fatha_momala}",
		harakat=uth.harakat,
		hams={ph.faa, ph.haa_mohmala, ph.haa, ph.khaa, ph.sheen, ph.saad, ph.seen, ph.kaf, ph.taa, ph.thaa},
		shidda={ph.hamza, ph.jeem, ph.daal, ph.qaf, ph.tah, ph.baa, ph.kaf, ph.taa},
		between_shidda_rakhawa={ph.lam, ph.noon, ph.ayn, ph.meem, ph.raa},
		tafkheem={ph.khaa, ph.saad, ph.daad, ph.ghyn, ph.tah, ph.qaf, ph.thah},
		itbaaq={ph.saad, ph.daad, ph.tah, ph.thah},
		safeer={ph.saad, ph.seen, ph.zay},
		qalqal={ph.qaf, ph.tah, ph.baa, ph.jeem, ph.daal},
		tikrar={ph.raa},
		tafashie={ph.sheen},
		istitala={ph.daad},
		ghonna={ph.noon, ph.meem, ph.noon_mokhfah, ph.meem_mokhfah},
	)


PH_GROUPS = _build_groups()


def chunk_phoneme_units(phonetic_text: str) -> list[str]:
	"""Split a phonetic script into phoneme groups."""
	core_pattern = "|".join([f"{re.escape(ch)}+" for ch in PH_GROUPS.core])
	residual_pattern = re.escape(PH_GROUPS.residuals)
	return re.findall(f"((?:{core_pattern})[{residual_pattern}]?)", phonetic_text)



def classify_tafkheem(
	phoneme_chunks: list[str], index: int
) -> Literal["mofakham", "moraqaq", "low_mofakham"]:
	""
	current_chunk = phoneme_chunks[index]

	if current_chunk[0] == ph.noon_mokhfah:
		if index == 0:
			raise ValueError("Noon Mokhfaa comes in the middle not at the start")
		if index == len(phoneme_chunks) - 1:
			raise ValueError("Noon Mokhfaa comes in the middle not at the end")
		return (
			"mofakham"
			if phoneme_chunks[index + 1][0] in PH_GROUPS.tafkheem
			else "moraqaq"
		)

	if current_chunk[0] == ph.alif:
		if index == 0:
			# Alif at the very start of a phoneme script has no preceding
			# letter to derive tafkheem from.  Default to moraqaq.
			return "moraqaq"
		return (
			"mofakham"
			if phoneme_chunks[index - 1][0] in (PH_GROUPS.tafkheem | {ph.raa})
			else "moraqaq"
		)

	if (
		phoneme_chunks[index][0] in {ph.ghyn, ph.khaa, ph.qaf}
		and phoneme_chunks[index][-1] == ph.kasra
	):
		return "low_mofakham"

	return "mofakham" if phoneme_chunks[index][0] in PH_GROUPS.tafkheem else "moraqaq"


def parse_tafkheem_sifa(
	phonemes: list[str], idx: int
) -> Literal["mofakham", "moraqaq", "low_mofakham"]:
	return classify_tafkheem(phonemes, idx)


def lam_tafkheem_tarqeeq_finder(
	phonetic_text_with_space: str,
) -> list[Literal["mofakham", "moraqaq"]]:
	allah_lam_pattern = (
		f"(?<!{ph.jeem})(?<!{ph.daal})(?<!{ph.taa}{ph.fatha}{ph.waw})"
		f"(.{uth.space}?{ph.lam}{{2}}){ph.fatha}{ph.alif}{{2,6}}{ph.haa}"
		f"(?!{ph.dama}{ph.meem}(?!{ph.meem}))"
	)
	lam_pattern = f"({ph.lam}+)[{re.escape(PH_GROUPS.residuals)}]?"

	lam_positions = [m.start(1) for m in re.finditer(lam_pattern, phonetic_text_with_space)]

	preceding_marker_by_pos: dict[int, str] = {}
	for match in re.finditer(allah_lam_pattern, phonetic_text_with_space):
		pos = match.end(1) - 2
		preceding_marker_by_pos[pos] = match.group(1)[0]

	decisions: list[Literal["mofakham", "moraqaq"]] = []
	for lam_pos in lam_positions:
		if lam_pos in preceding_marker_by_pos:
			decisions.append(
				"moraqaq" if preceding_marker_by_pos[lam_pos] == ph.kasra else "mofakham"
			)
		else:
			decisions.append("moraqaq")
	return decisions


def alif_tafkheem_tarqeeq_finder(
	phonetic_text_with_space: str,
) -> list[Literal["mofakham", "moraqaq"] | None]:
	allah_alif_pattern = (
		f"(?<!{ph.jeem})(?<!{ph.daal})(?<!{ph.taa}{ph.fatha}{ph.waw})"
		f"(.){uth.space}?{ph.lam}{{2}}{ph.fatha}({ph.alif}{{2,6}}){ph.haa}"
		f"(?!{ph.dama}{ph.meem}(?!{ph.meem}))"
	)
	alif_pattern = f"{ph.fatha}({ph.alif}{{2,6}})"

	alif_positions = [m.start(1) for m in re.finditer(alif_pattern, phonetic_text_with_space)]

	preceding_marker_by_pos: dict[int, str] = {}
	for match in re.finditer(allah_alif_pattern, phonetic_text_with_space):
		preceding_marker_by_pos[match.start(2)] = match.group(1)

	outputs: list[Literal["mofakham", "moraqaq"] | None] = []
	for alif_pos in alif_positions:
		if alif_pos in preceding_marker_by_pos:
			outputs.append(
				"moraqaq"
				if preceding_marker_by_pos[alif_pos] == ph.kasra
				else "mofakham"
			)
		else:
			outputs.append(None)
	return outputs


RAA_NORMALIZATION_PIPELINE = [
	ExpandMuqattaLettersOp(),
	ApplySpecialCasesOp(),
	NormalizeAlifMaksoraOp(),
	NormalizeHamzatOp(),
	RemoveKashidaOp(),
	RemoveMidHamzatWaslOp(),
	RemoveSukunMostadeerOp(),
	NormalizeSukunMostateelOp(),
	NormalizeMaddAwadOp(),
	NormalizeWawAlsalahOp(),
	ExpandSmallLettersOp(),
	NormalizeWordEndOp(),
	NormalizeTaaMarbootaOp(),
	PrepareGhunnahIdghamIqlabOp(),
	ResolveDoubleSukunOp(),
	DropInitialShaddaOp(),
]


@dataclass(frozen=True)
class RaaSpecialCase:
	regex: str
	moshaf_attr: str


SPECIAL_RAA_CASES = [
	RaaSpecialCase(
		regex=f"{ph.faa}{ph.kasra}({ph.raa}){uth.ras_7aa2}{ph.qaf}{ph.kasra}{ph.noon}",
		moshaf_attr="raa_firq",
	),
	RaaSpecialCase(
		regex=(
			f"{uth.hamzat_wasl}{uth.lam}{uth.ras_7aa2}{uth.qaf}{uth.kasra}"
			f"{uth.tah}{uth.ras_7aa2}({uth.raa})$"
		),
		moshaf_attr="raa_alqitr",
	),
	RaaSpecialCase(
		regex=f"{uth.meem}{uth.kasra}{uth.saad}{uth.ras_7aa2}({uth.raa})$",
		moshaf_attr="raa_misr",
	),
	RaaSpecialCase(
		regex=f"{uth.waw}{uth.fatha}{uth.noon}{uth.dama}{uth.thaal}{uth.dama}({uth.raa})$",
		moshaf_attr="raa_nudhur",
	),
	RaaSpecialCase(
		regex=f"[{uth.hamza_3ala_el_satr}{uth.yaa}]{uth.fatha}{uth.seen}{uth.ras_7aa2}({uth.raa})$",
		moshaf_attr="raa_yasr",
	),
]


def raa_tafkheem_tarqeeq_finder(
	uthamni_text: str,
	moshaf: MoshafAttributes,
) -> list[Literal["mofakham", "moraqaq"]]:
	normalized_script = uthamni_text
	running_mappings = None
	for operation in RAA_NORMALIZATION_PIPELINE:
		normalized_script, running_mappings = operation.forward(
			normalized_script,
			moshaf,
			running_mappings,
		)

	tafkheem_chars_class = re.escape("".join(PH_GROUPS.tafkheem))

	raa_pattern = f"({uth.raa})[{uth.harakat}{uth.shadda}{uth.ras_7aa2}{uth.imala_sign}]?"

	tarqeeq_patterns = [
		f"({uth.raa}){uth.shadda}?[{uth.kasra}{uth.imala_sign}]",
		f"{uth.kasra}({uth.raa})(?:{uth.ras_7aa2}|$)(?![{tafkheem_chars_class}])",
		f"{uth.kasra}[^{tafkheem_chars_class}]{uth.ras_7aa2}({uth.raa})(?:{uth.ras_7aa2}|$)",
		f"{uth.kasra}{uth.yaa}({uth.raa})(?:{uth.ras_7aa2}|$)",
		f"{uth.fatha}{uth.yaa}{uth.ras_7aa2}({uth.raa})(?:{uth.ras_7aa2}|$)",
	]
	tarqeeq_patterns = [f"(?:{p})" for p in tarqeeq_patterns]
	tarqeeq_regex = re.compile("|".join(tarqeeq_patterns))

	all_raa_positions = [m.start(1) for m in re.finditer(raa_pattern, normalized_script)]

	forced_tafkheem_positions: set[int] = set()
	forced_tarqeeq_positions: set[int] = set()
	for special_case in SPECIAL_RAA_CASES:
		match = re.search(special_case.regex, normalized_script)
		if not match:
			continue
		selected = getattr(moshaf, special_case.moshaf_attr)
		pos = match.start(1)
		if selected == "tafkheem":
			forced_tafkheem_positions.add(pos)
		elif selected == "tarqeeq":
			forced_tarqeeq_positions.add(pos)

	for match in tarqeeq_regex.finditer(normalized_script):
		for group_idx in range(1, len(tarqeeq_patterns) + 1):
			if match.group(group_idx):
				pos = match.start(group_idx)
				if pos not in forced_tafkheem_positions:
					forced_tarqeeq_positions.add(pos)
					break

	return [
		"moraqaq" if pos in forced_tarqeeq_positions else "mofakham"
		for pos in all_raa_positions
	]


def analyze_sifat(
	uthamni_text: str,
	phonetic_text: str,
	moshaf: MoshafAttributes,
) -> list[SifatAnalysisOutput]:
	phoneme_chunks = chunk_phoneme_units(phonetic_text)

	lam_states = lam_tafkheem_tarqeeq_finder(phonetic_text)
	alif_states = alif_tafkheem_tarqeeq_finder(phonetic_text)
	raa_states = raa_tafkheem_tarqeeq_finder(uthamni_text, moshaf)

	lam_cursor = 0
	alif_cursor = 0
	raa_cursor = 0
	results: list[SifatAnalysisOutput] = []

	for idx, chunk in enumerate(phoneme_chunks):
		primary = chunk[0]

		hams_state: Literal["hams", "jahr"] = "hams" if primary in PH_GROUPS.hams else "jahr"
		shidda_state: Literal["shadeed", "between", "rikhw"] = (
			"shadeed"
			if primary in PH_GROUPS.shidda
			else "between"
			if primary in PH_GROUPS.between_shidda_rakhawa
			else "rikhw"
		)

		tafkheem_state = classify_tafkheem(phoneme_chunks, idx)
		if primary == ph.lam:
			if lam_cursor < len(lam_states):
				tafkheem_state = lam_states[lam_cursor]
				lam_cursor += 1
		elif primary == ph.alif:
			if alif_cursor < len(alif_states):
				alif_state = alif_states[alif_cursor]
				if alif_state is not None:
					tafkheem_state = alif_state
				alif_cursor += 1
		elif primary == ph.raa:
			if raa_cursor < len(raa_states):
				tafkheem_state = raa_states[raa_cursor]
				raa_cursor += 1

		itbaq_state: Literal["monfateh", "motbaq"] = (
			"motbaq" if primary in PH_GROUPS.itbaaq else "monfateh"
		)
		safeer_state: Literal["safeer", "no_safeer"] = (
			"safeer" if primary in PH_GROUPS.safeer else "no_safeer"
		)
		qalqla_state: Literal["moqalqal", "not_moqalqal"] = (
			"moqalqal"
			if chunk[-1] not in PH_GROUPS.harakat and primary in PH_GROUPS.qalqal
			else "not_moqalqal"
		)
		tikraar_state: Literal["mokarar", "not_mokarar"] = (
			"mokarar" if primary in PH_GROUPS.tikrar else "not_mokarar"
		)
		tafashie_state: Literal["motafashie", "not_motafashie"] = (
			"motafashie" if primary in PH_GROUPS.tafashie else "not_motafashie"
		)
		istitala_state: Literal["mostateel", "not_mostateel"] = (
			"mostateel" if primary in PH_GROUPS.istitala else "not_mostateel"
		)
		ghonna_state: Literal["maghnoon", "not_maghnoon"] = (
			"maghnoon" if primary in PH_GROUPS.ghonna else "not_maghnoon"
		)

		results.append(
			SifatAnalysisOutput(
				phonemes=chunk,
				hams_or_jahr=hams_state,
				shidda_or_rakhawa=shidda_state,
				tafkheem_or_taqeeq=tafkheem_state,
				itbaq=itbaq_state,
				safeer=safeer_state,
				qalqla=qalqla_state,
				tikraar=tikraar_state,
				tafashie=tafashie_state,
				istitala=istitala_state,
				ghonna=ghonna_state,
			)
		)

	return results
