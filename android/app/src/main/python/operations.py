from __future__ import annotations

from dataclasses import dataclass, field
import re
import alphabet as alph

from alphabet import Phonetics
from load_alphabet import load_phonetics, uthmani_alphabet
from moshaf_rules import MoshafAttributes
from tajweed_rules import (
	AaredMaddRule,
	IdghamKamel,
	LangName,
	LazemMaddRule,
	LeenMaddRule,
	MaddRule,
	MonfaselMaddRule,
	MottaselMaddPauseRule,
	MottaselMaddRule,
	NormalMaddRule,
	Qalqalah,
	TajweedRule,
)
from utils import MapPos, generate_mappings, sub_with_mapping





uth = uthmani_alphabet
ph = load_phonetics(uthmani_alphabet=uth)

# utils.generate_mappings expects these globals under the alphabet module.
alph.uthmani = uth
alph.phonetics = ph





class ConversionOp:
	ops_before: list[ConversionOp] = []
	rules: tuple | list = ()

	def _run_prerequisites(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None,
	) -> tuple[str, list[MapPos] | None]:
		for op in getattr(self, "ops_before", []):
			text, mappings = op.forward(text, moshaf, mappings)
		return text, mappings

	def _apply_registered_rules(
		self,
		text: str,
		mappings: list[MapPos] | None,
	) -> tuple[str, list[MapPos] | None]:
		registered_rules = getattr(self, "rules", ())
		# A single rule may be stored as a 2-tuple (pattern, repl). Normalize it.
		if (
			isinstance(registered_rules, tuple)
			and len(registered_rules) >= 2
			and isinstance(registered_rules[0], str)
			and isinstance(registered_rules[1], str)
		):
			rules_iterable = [registered_rules]
		else:
			rules_iterable = registered_rules

		for reg in rules_iterable:
			pattern = reg[0]
			repl = reg[1]
			tajweed_rule = reg[2] if len(reg) > 2 else None
			text, mappings = sub_with_mapping(pattern, repl, text, mappings, tajweed_rule)
		return text, mappings

	def forward(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None = None,
	) -> tuple[str, list[MapPos]]:
		if mappings is None:
			text, mappings = self._run_prerequisites(text, moshaf, mappings)
		text, mappings = self._apply_registered_rules(text, mappings)

		if mappings is None:
			mappings = generate_mappings(text, text)

		return text, mappings

	def apply(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None = None,
		mode: str = "inference",
		discard_ops: list | None = None,
	) -> tuple[str, list[MapPos]]:
		discard_ops = discard_ops or []

		if mode == "test":
			for op in getattr(self, "ops_before", []):
				if any(isinstance(op, type(discard_op)) for discard_op in discard_ops):
					continue
				text, mappings = op.apply(
					text,
					moshaf,
					mappings,
					mode="test",
					discard_ops=discard_ops,
				)
			return self.forward(text, moshaf, mappings)

		if mode == "inference":
			return self.forward(text, moshaf, mappings)

		raise ValueError(f"Unsupported mode: {mode}")


@dataclass
class ExpandMuqattaLettersOp(ConversionOp):
	rules: tuple[str, str] = ("", "")

	def forward(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None = None,
	) -> tuple[str, list[MapPos]]:
		for word, rep in uth.hroof_muqatta3a.items():
			new_text = re.sub(
				f"(^|{uth.space}){word}({uth.space}|$)", f"\\1{rep}\\2", text
			)
			if len(text) != len(new_text):
				mappings = self._process_mappings(text, word, rep, mappings)
			text = new_text

		if mappings is None:
			return text, generate_mappings(text, text)
		return text, mappings

	def _process_mappings(
		self,
		old_text: str,
		uth_word: str,
		rep: str,
		mappings: list[MapPos] | None,
	) -> list[MapPos]:
		if mappings is None:
			mappings = generate_mappings(old_text, old_text)

		uth_words = uth_word.split(" ")
		if len(uth_words) > 1:
			uth_word = uth_words[0]
			rep = " ".join(rep.split(" ")[:-1])

		re_outs = [re_o for re_o in re.finditer(uth_word, old_text)]
		for re_idx, re_out in enumerate(re_outs):
			disc_map = self._get_single_word_mapping(uth_word=uth_word, rep=rep)
			ptr = 0
			start_offset = re_out.span()[0] + re_idx * (len(rep) - len(uth_word))
			start_idx = re_out.span()[0]
			end_idx = re_out.span()[1]
			last_pos = 0

			for idx in range(start_idx, end_idx):
				mappings[idx].pos = (
					disc_map[ptr].pos[0] + start_offset,
					disc_map[ptr].pos[1] + start_offset,
				)
				mappings[idx].deleted = disc_map[ptr].deleted
				last_pos = mappings[idx].pos[1]
				ptr += 1

			end = len(mappings) if (re_idx + 1) == len(re_outs) else re_outs[re_idx + 1].span()[0]
			offset = None
			for idx in range(end_idx, end):
				if offset is None:
					offset = last_pos - mappings[idx].pos[0]
				mappings[idx].pos = (
					mappings[idx].pos[0] + offset,
					mappings[idx].pos[1] + offset,
				)

		return mappings

	def _get_single_word_mapping(self, uth_word: str, rep: str) -> list[MapPos]:
		chars_with_madd = re.findall(f"[^{uth.madd}]{uth.madd}?", uth_word)
		word_parts = rep.split(" ")
		assert len(word_parts) == len(chars_with_madd)

		mappings: list[MapPos] = []
		ph_start = 0
		for idx, (chars, word_part) in enumerate(zip(chars_with_madd, word_parts)):
			ph_end = ph_start + len(word_part)
			ph_end += 1 if (idx + 1) < len(word_parts) else 0
			mappings.append(MapPos(pos=(ph_start, ph_end)))
			for _ in chars[1:]:
				mappings.append(
					MapPos(pos=(mappings[-1].pos[1], mappings[-1].pos[1]), deleted=True)
				)
			ph_start = ph_end
		return mappings


@dataclass
class ApplySpecialCasesOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [ExpandMuqattaLettersOp()])
	rules: tuple[str, str] = ("", "")

	def forward(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None = None,
	) -> tuple[str, list[MapPos]]:
		for case in uth.special_cases:
			pattern = case.pattern
			if case.position == "start":
				pattern = r"^" + pattern
			elif case.position == "end":
				pattern = pattern + r"$"

			if case.name is not None:
				moshaf_attr = getattr(moshaf, case.name)
				rep_pattern = case.variations[moshaf_attr] if case.variations and moshaf_attr in case.variations else case.pattern
			elif case.target_pronunciation is not None:
				rep_pattern = case.target_pronunciation
			else:
				rep_pattern = case.pattern

			text, mappings = sub_with_mapping(pattern, rep_pattern, text, mappings)

		if mappings is None:
			return text, generate_mappings(text, text)
		return text, mappings


@dataclass
class NormalizeInitialHamzatWaslOp(ConversionOp):
	rules: tuple[str, str] = ("", "")
	ops_before: list[ConversionOp] = field(
		default_factory=lambda: [ExpandMuqattaLettersOp(), ApplySpecialCasesOp()]
	)

	def _get_verb_third_letter_haraka(self, verb: str):
		if verb in uth.hamzat_el_wasl.damma_3arida_verbs:
			return uth.kasra

		letters = f"{uth.pure_letters}{uth.hamazat}"
		match = re.search(
			f"^{uth.hamzat_wasl}(?:{uth.noon}[{uth.noon_ikhfaa_letters}]|[{letters}]{uth.shadda}|(?:{uth.noon}{uth.meem_iqlab}|[{letters}][{uth.harakat}{uth.ras_7aa2}])[{letters}])(.)",
			verb,
		)
		if match:
			haraka = match.group(1)
			if haraka == uth.dama:
				return uth.dama
			if haraka in {uth.kasra, uth.fatha}:
				return uth.kasra
			raise ValueError(
				f"Can no determine haraka exeptected: ضمة أو فتحة أو كسرة got : `{haraka}`"
			)

		raise ValueError("Can not found match to extract harak")

	def forward(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None = None,
	) -> tuple[str, list[MapPos]]:
		new_text = text
		if re.search(f"^{uth.hamzat_wasl}", text):
			words = text.split(uth.space)
			first_word = words[0]
			if (first_word in uth.hamzat_el_wasl.verbs_nouns) or (
				first_word in uth.hamzat_el_wasl.nouns
			):
				first_word = re.sub(f"(^){uth.hamzat_wasl}", f"\\1{uth.hamza_3ala_el_satr}{uth.kasra}", first_word)
			elif first_word in uth.hamzat_el_wasl.verbs:
				third_letter_haraka = self._get_verb_third_letter_haraka(first_word)
				first_word = re.sub(
					f"(^){uth.hamzat_wasl}", f"\\1{uth.hamza_3ala_el_satr}{third_letter_haraka}", first_word
				)

				haraka_to_letter_madd = {uth.kasra: uth.yaa, uth.dama: uth.waw}
				first_word = re.sub(
					f"(^{uth.hamza_3ala_el_satr}.)[{uth.hamazat}]{uth.ras_7aa2}",
					f"\\1{haraka_to_letter_madd[third_letter_haraka]}",
					first_word,
				)
			else:
				first_word = re.sub(f"(^){uth.hamzat_wasl}", f"\\1{uth.hamza_3ala_el_satr}{uth.fatha}", first_word)

			new_text = uth.space.join([first_word] + words[1:])
			mappings = generate_mappings(text=text, new_text=new_text)
		return new_text, mappings


@dataclass
class FixInitialSukunOp(ConversionOp):
	rules: tuple[str, str] = (f"(^.){uth.ras_7aa2}", f"\\1{uth.kasra}")


@dataclass
class NormalizeAlifMaksoraOp(ConversionOp):
	rules: list[tuple[str, str, TajweedRule] | tuple[str, str]] = field(
		default_factory=lambda: [
			(f"({uth.tanween_fath_modgham}|{uth.tanween_fath_iqlab}|{uth.tanween_fath_mothhar}){uth.alif_maksora}", r"\1"),
			(f"({uth.fatha}){uth.alif_maksora}({uth.space}|$)", f"\\1{uth.alif}\\2"),
			(f"{uth.alif_maksora}{uth.small_alef}", f"{uth.alif}"),
			(f"{uth.kasra}{uth.alif_maksora}", f"{uth.kasra}{uth.yaa}"),
			(f"{uth.alif_maksora}([{uth.harakat}{uth.ras_7aa2}{uth.shadda}{uth.tanween_dam}{uth.madd}])", f"{uth.yaa}\\1"),
		]
	)


@dataclass
class DropInitialShaddaOp(ConversionOp):
	rules: tuple[str, str] = (f"(^.){uth.shadda}", r"\1")


@dataclass
class NormalizeHamzatOp(ConversionOp):
	rules: tuple[str, str] = (f"[{uth.hamazat}]", f"{uth.hamza_3ala_el_satr}")


@dataclass
class RestoreYaaInMudariOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [NormalizeAlifMaksoraOp(), NormalizeHamzatOp()])
	rules: tuple[str, str] = (
		f"([{uth.hamza_3ala_el_satr}{uth.noon}{uth.yaa}{uth.taa_mabsoota}]{uth.dama}{uth.haa2}{uth.ras_7aa2}{uth.yaa}{uth.kasra})({uth.space}|$)",
		f"\\1{uth.yaa}\\2",
	)


@dataclass
class RemoveKashidaOp(ConversionOp):
	rules: tuple[str, str] = (f"{uth.kasheeda}", "")


@dataclass
class RemoveMidHamzatWaslOp(ConversionOp):
	rules: tuple[str, str] = (f"(?!^){uth.hamzat_wasl}", r"")


@dataclass
class RemoveSukunMostadeerOp(ConversionOp):
	rules: tuple[str, str] = (f"(.){uth.skoon_mostadeer}", r"")


@dataclass
class NormalizeSukunMostateelOp(ConversionOp):
	rules: list[tuple[str, str, TajweedRule] | tuple[str, str]] = field(
		default_factory=lambda: [
			(f"{uth.alif}{uth.skoon_mostateel}{uth.space}", f"{uth.space}"),
			(f"{uth.alif}{uth.skoon_mostateel}$", f"{uth.alif}"),
		]
	)


@dataclass
class NormalizeMaddAwadOp(ConversionOp):
	rules: list[tuple[str, str, TajweedRule] | tuple[str, str]] = field(
		default_factory=lambda: [
			(f"({uth.tanween_fath_modgham}|{uth.tanween_fath_iqlab}|{uth.tanween_fath_mothhar}){uth.alif}({uth.space}|$)", r"\1\2"),
			(f"({uth.tanween_fath_modgham}|{uth.tanween_fath_iqlab}|{uth.tanween_fath_mothhar})$", f"{uth.fatha}{uth.alif}"),
		]
	)


@dataclass
class NormalizeWawAlsalahOp(ConversionOp):
	rules: tuple[str, str] = (f"{uth.waw}{uth.small_alef}", f"{uth.alif}")


@dataclass
class ExpandSmallLettersOp(ConversionOp):
	rules: list[tuple[str, str, TajweedRule] | tuple[str, str]] = field(
		default_factory=lambda: [
			(uth.small_alef, uth.alif),
			(uth.small_noon, uth.noon),
			(f"{uth.haa}{uth.dama}{uth.small_waw}{uth.madd}?$", f"{uth.haa}{uth.dama}"),
			(uth.small_waw, uth.waw),
			(uth.small_yaa, uth.small_yaa_sila),
			(f"{uth.haa}{uth.kasra}{uth.small_yaa_sila}{uth.madd}?$", f"{uth.haa}{uth.kasra}"),
			(uth.small_yaa_sila, uth.yaa),
		]
	)


@dataclass
class NormalizeWordEndOp(ConversionOp):
	ops_before: list[ConversionOp] = field(
		default_factory=lambda: [
			NormalizeAlifMaksoraOp(),
			NormalizeHamzatOp(),
			RestoreYaaInMudariOp(),
			RemoveKashidaOp(),
			RemoveSukunMostadeerOp(),
			NormalizeSukunMostateelOp(),
			NormalizeMaddAwadOp(),
			NormalizeWawAlsalahOp(),
			ExpandSmallLettersOp(),
		]
	)
	rules: tuple[str, str] = (
		f"({'|'.join([uth.fatha, uth.dama, uth.kasra, uth.tanween_dam_modgham, uth.tanween_dam_iqlab, uth.tanween_dam_mothhar, uth.tanween_kasr_modgham, uth.tanween_kasr_iqlab, uth.tanween_kasr_mothhar, uth.madd])})$",
		r"",
	)


@dataclass
class NormalizeTaaMarbootaOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [NormalizeWordEndOp()])
	rules: list[tuple[str, str, TajweedRule] | tuple[str, str]] = field(
		default_factory=lambda: [
			(f"{uth.taa_marboota}$", f"{uth.haa}"),
			(f"{uth.taa_marboota}", f"{uth.taa_mabsoota}"),
		]
	)


@dataclass
class AddAlifInAllahNameOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [NormalizeWordEndOp(), NormalizeTaaMarbootaOp()])
	rules: tuple[str, str] = (
		f"({uth.lam}{uth.kasra}?{uth.lam}{uth.shadda}{uth.fatha})({uth.haa}(?:.|$)(?![{uth.baa}{uth.waw}]))",
		f"\\1{uth.alif}\\2",
	)


@dataclass
class PrepareGhunnahIdghamIqlabOp(ConversionOp):
	ops_before: list[ConversionOp] = field(
		default_factory=lambda: [ApplySpecialCasesOp(), RemoveMidHamzatWaslOp(), NormalizeWordEndOp(), NormalizeTaaMarbootaOp(), AddAlifInAllahNameOp()]
	)
	rules: list[tuple[str, str, TajweedRule] | tuple[str, str]] = field(
		default_factory=lambda: [
			(f"{uth.noon}{uth.meem_iqlab}", f"{uth.meem}"),
			(f"{uth.tanween_fath}.({uth.space}{uth.baa})", f"{uth.fatha}{uth.meem}\\1"),
			(f"{uth.tanween_dam}.({uth.space}{uth.baa})", f"{uth.dama}{uth.meem}\\1"),
			(f"{uth.tanween_kasr}.({uth.space}{uth.baa})", f"{uth.kasra}{uth.meem}\\1"),
			(f"{uth.tanween_fath}.({uth.space}[{uth.noon_ikhfaa_letters}{uth.noon_idghaam_letters}])", f"{uth.fatha}{uth.noon}\\1"),
			(f"{uth.tanween_dam}.({uth.space}[{uth.noon_ikhfaa_letters}{uth.noon_idghaam_letters}])", f"{uth.dama}{uth.noon}\\1"),
			(f"{uth.tanween_kasr}.({uth.space}[{uth.noon_ikhfaa_letters}{uth.noon_idghaam_letters}])", f"{uth.kasra}{uth.noon}\\1"),
			(f"{uth.tanween_fath_mothhar}", f"{uth.fatha}{uth.noon}{uth.ras_7aa2}"),
			(f"{uth.tanween_dam_mothhar}", f"{uth.dama}{uth.noon}{uth.ras_7aa2}"),
			(f"{uth.tanween_kasr_mothhar}", f"{uth.kasra}{uth.noon}{uth.ras_7aa2}"),
			(f"([{uth.fatha}{uth.dama}]{uth.yaa}|[{uth.fatha}{uth.kasra}]{uth.waw}|[{uth.pure_letters_without_yaa_waw}]){uth.space}?([{uth.pure_letters}]{uth.shadda})", r"\2", IdghamKamel()),
		]
	)


@dataclass
class ResolveDoubleSukunOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [PrepareGhunnahIdghamIqlabOp()])
	rules: list[tuple[str, str] | tuple[str, str, TajweedRule]] = field(
		default_factory=lambda: [
			(f"({uth.noon}){uth.ras_7aa2}({uth.space}.[{uth.ras_7aa2}{uth.shadda}])", f"\\1{uth.kasra}\\2"),
			(f"{uth.fatha}{uth.alif}({uth.space}.[{uth.ras_7aa2}{uth.shadda}])", f"{uth.fatha}\\1"),
			(f"{uth.dama}{uth.waw}({uth.space}.[{uth.ras_7aa2}{uth.shadda}])", f"{uth.dama}\\1"),
			(f"{uth.kasra}{uth.yaa}({uth.space}.[{uth.ras_7aa2}{uth.shadda}])", f"{uth.kasra}\\1"),
			(f"{uth.madd_alif}({uth.space}.[{uth.ras_7aa2}{uth.shadda}])", f"{uth.fatha}\\1"),
			(f"{uth.madd_waw}({uth.space}.[{uth.ras_7aa2}{uth.shadda}])", f"{uth.dama}\\1"),
			(f"{uth.madd_yaa}({uth.space}.[{uth.ras_7aa2}{uth.shadda}])", f"{uth.kasra}\\1"),
		]
	)


@dataclass
class ApplyGhunnahOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [ResolveDoubleSukunOp(), DropInitialShaddaOp()])
	rules: tuple[str, str] = ("", "")
	ghonna_len: int = 3
	idgham_yaa_waw_len: int = 2

	def forward(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None = None,
	) -> tuple[str, list[MapPos]]:
		if moshaf.meem_mokhfah == "meem":
			meem_mokhfah = ph.meem
		elif moshaf.meem_mokhfah == "ikhfaa":
			meem_mokhfah = ph.meem_mokhfah
		else:
			raise ValueError()

		text, mappings = sub_with_mapping(
			f"{uth.meem}{uth.space}?{uth.baa}",
			f"{meem_mokhfah * self.ghonna_len}{uth.baa}",
			text,
			mappings,
		)

		text, mappings = sub_with_mapping(
			f"{uth.noon}{uth.space}([{uth.yaa}{uth.waw}])",
			r"\1" * (self.idgham_yaa_waw_len + 1),
			text,
			mappings,
		)

		text, mappings = sub_with_mapping(
			f"{uth.noon}{uth.space}?([{uth.noon_ikhfaa_letters}])",
			f"{ph.noon_mokhfah * self.ghonna_len}\\1",
			text,
			mappings,
		)

		text, mappings = sub_with_mapping(
			f"([{uth.meem}{uth.noon}]){uth.shadda}$",
			r"\1" * self.ghonna_len,
			text,
			mappings,
		)
		text, mappings = sub_with_mapping(
			f"([{uth.meem}{uth.noon}]){uth.shadda}",
			r"\1" * (self.ghonna_len + 1),
			text,
			mappings,
		)

		return text, mappings


@dataclass
class ApplyTasheelOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [ApplySpecialCasesOp()])
	rules: tuple[str, str] = (f"{uth.alif}{uth.tasheel_sign}", f"{ph.hamza_mosahala}")


@dataclass
class ApplyImalaOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [NormalizeAlifMaksoraOp(), ExpandSmallLettersOp()])
	rules: tuple[str, str] = (f"{uth.imala_sign}{uth.alif}", f"{ph.fatha_momala}{ph.alif_momala}{ph.alif_momala}")


@dataclass
class MaddPattern:
	pattern: str
	target: str
	madd: str
	name: str


@dataclass
class ApplyMaddOp(ConversionOp):
	ops_before: list[ConversionOp] = field(default_factory=lambda: [ApplyGhunnahOp(), ApplyTasheelOp(), ApplyImalaOp()])
	rules: tuple[str, str] = ("", "")
	madd_map: dict = field(
		default_factory=lambda: {
			"fath": MaddPattern(pattern=f"({uth.fatha}){uth.alif}", target=ph.alif, madd=uth.alif, name="alif"),
			"dam": MaddPattern(pattern=f"({uth.dama}){uth.waw}", target=ph.waw_madd, madd=uth.waw, name="waw"),
			"kasr": MaddPattern(pattern=f"({uth.kasra}){uth.yaa}", target=ph.yaa_madd, madd=uth.yaa, name="yaa"),
		}
	)

	def _for_each_madd(
		self,
		text: str,
		mappings: list[MapPos] | None,
		pattern_builder,
		repl_builder,
		rule_builder,
	) -> tuple[str, list[MapPos] | None]:
		for madd_patt in self.madd_map.values():
			text, mappings = sub_with_mapping(
				pattern_builder(madd_patt),
				repl_builder(madd_patt),
				text,
				mappings,
				rule_builder(madd_patt),
			)
		return text, mappings

	def _apply_monfasel(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None,
	) -> tuple[str, list[MapPos] | None]:
		text, mappings = sub_with_mapping(
			f"((?:^|{uth.space}|(?:(?:^|{uth.space})[{uth.faa}{uth.waw}{uth.hamza_3ala_el_satr}]{uth.fatha}))[{uth.yaa}{uth.haa}]{uth.fatha}){uth.alif}{uth.madd}({uth.hamza_3ala_el_satr}.(?!{uth.space}))",
			r"\1" + ph.alif * moshaf.madd_monfasel_len + r"\2",
			text,
			mappings,
			MonfaselMaddRule(golden_len=moshaf.madd_monfasel_len, tag="alif"),
		)

		return self._for_each_madd(
			text,
			mappings,
			pattern_builder=lambda m: f"{m.pattern}{uth.madd}({uth.space}{uth.hamza_3ala_el_satr})",
			repl_builder=lambda m: r"\1" + moshaf.madd_monfasel_len * m.target + r"\2",
			rule_builder=lambda m: MonfaselMaddRule(
				golden_len=moshaf.madd_monfasel_len,
				tag=m.name,
			),
		)

	def _apply_mottasel(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None,
	) -> tuple[str, list[MapPos] | None]:
		text, mappings = self._for_each_madd(
			text,
			mappings,
			pattern_builder=lambda m: f"{m.pattern}{uth.madd}({uth.hamza_3ala_el_satr}$)",
			repl_builder=lambda m: r"\1"
			+ max(moshaf.madd_mottasel_waqf, moshaf.madd_aared_len) * m.target
			+ r"\2",
			rule_builder=lambda m: MottaselMaddPauseRule(
				golden_len=max(moshaf.madd_mottasel_waqf, moshaf.madd_aared_len),
				tag=m.name,
			),
		)

		return self._for_each_madd(
			text,
			mappings,
			pattern_builder=lambda m: f"{m.pattern}{uth.madd}({uth.hamza_3ala_el_satr})",
			repl_builder=lambda m: r"\1" + moshaf.madd_mottasel_len * m.target + r"\2",
			rule_builder=lambda m: MottaselMaddRule(
				golden_len=moshaf.madd_mottasel_len,
				tag=m.name,
			),
		)

	def _apply_lazem(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None,
	) -> tuple[str, list[MapPos] | None]:
		text, mappings = sub_with_mapping(
			f"({uth.fatha}){uth.yaa}{uth.madd}",
			r"\1" + (moshaf.madd_yaa_alayn_alharfy - 1) * ph.yaa,
			text,
			mappings,
			LeenMaddRule(golden_len=moshaf.madd_yaa_alayn_alharfy, tag="yaa"),
		)

		meem_aal_imran_taj_rule = LazemMaddRule(tag="alif")
		if moshaf.meem_aal_imran == "wasl_2":
			meema_len = 2
			meem_aal_imran_taj_rule = NormalMaddRule(tag="alif")
		elif moshaf.meem_aal_imran == "wasl_6":
			meema_len = 6
		else:
			meema_len = 6

		text, mappings = sub_with_mapping(
			f"({uth.meem}{uth.kasra}){uth.yaa}{uth.madd}({uth.meem}{uth.fatha})",
			r"\1" + ph.yaa_madd * meema_len + r"\2",
			text,
			mappings,
			meem_aal_imran_taj_rule,
		)

		return self._for_each_madd(
			text,
			mappings,
			pattern_builder=lambda m: f"{m.pattern}{uth.madd}(.(?:{uth.shadda}|{uth.ras_7aa2}|[{ph.noon}{ph.meem}{ph.noon_mokhfah}]{{2,3}}))",
			repl_builder=lambda m: r"\1" + 6 * m.target + r"\2",
			rule_builder=lambda m: LazemMaddRule(tag=m.name),
		)

	def _apply_aared_and_leen(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None,
	) -> tuple[str, list[MapPos] | None]:
		text, mappings = self._for_each_madd(
			text,
			mappings,
			pattern_builder=lambda m: f"{m.pattern}([^{uth.shadda}](?:{uth.ras_7aa2}$|$|{ph.sakt}))",
			repl_builder=lambda m: r"\1" + moshaf.madd_aared_len * m.target + r"\2",
			rule_builder=lambda m: AaredMaddRule(golden_len=moshaf.madd_aared_len, tag=m.name),
		)

		return sub_with_mapping(
			f"({uth.fatha})([{uth.yaa}{uth.waw}]){uth.ras_7aa2}?([^{uth.shadda}]{uth.ras_7aa2}?$)",
			r"\1" + (moshaf.madd_alleen_len - 1) * r"\2" + r"\3",
			text,
			mappings,
			LeenMaddRule(golden_len=moshaf.madd_alleen_len),
		)

	def _apply_normal(
		self,
		text: str,
		mappings: list[MapPos] | None,
	) -> tuple[str, list[MapPos] | None]:
		return self._for_each_madd(
			text,
			mappings,
			pattern_builder=lambda m: f"{m.pattern}(?![{m.madd}{uth.ras_7aa2}{uth.shadda}{uth.harakat}])",
			repl_builder=lambda m: r"\1" + 2 * m.target,
			rule_builder=lambda m: NormalMaddRule(tag=m.name),
		)

	def forward(
		self,
		text: str,
		moshaf: MoshafAttributes,
		mappings: list[MapPos] | None = None,
	) -> tuple[str, list[MapPos]]:
		text, mappings = self._apply_monfasel(text, moshaf, mappings)
		text, mappings = self._apply_mottasel(text, moshaf, mappings)
		text, mappings = self._apply_lazem(text, moshaf, mappings)
		text, mappings = self._apply_aared_and_leen(text, moshaf, mappings)
		text, mappings = self._apply_normal(text, mappings)

		return text, mappings


@dataclass
class ApplyQalqalahOp(ConversionOp):
	rules: tuple[str, str, TajweedRule] = (
		f"([{uth.qlqla_letters}](?:{uth.shadda}$|{uth.ras_7aa2}|$))",
		r"\1" + ph.qlqla,
		Qalqalah(),
	)
	ops_before: list[ConversionOp] = field(default_factory=lambda: [NormalizeWordEndOp()])


@dataclass
class FinalizeShaddaSukunOp(ConversionOp):
	rules: list[tuple[str, str, TajweedRule] | tuple[str, str]] = field(
		default_factory=lambda: [
			(f"(.){uth.shadda}", r"\1\1"),
			(f"{uth.ras_7aa2}", r""),
		]
	)
	ops_before: list[ConversionOp] = field(default_factory=lambda: [NormalizeWordEndOp()])


OPS = [
	ExpandMuqattaLettersOp(),
	ApplySpecialCasesOp(),
	NormalizeInitialHamzatWaslOp(),
	FixInitialSukunOp(),
	NormalizeAlifMaksoraOp(),
	NormalizeHamzatOp(),
	RestoreYaaInMudariOp(),
	RemoveKashidaOp(),
	RemoveMidHamzatWaslOp(),
	RemoveSukunMostadeerOp(),
	NormalizeSukunMostateelOp(),
	NormalizeMaddAwadOp(),
	NormalizeWawAlsalahOp(),
	ExpandSmallLettersOp(),
	NormalizeWordEndOp(),
	NormalizeTaaMarbootaOp(),
	AddAlifInAllahNameOp(),
	PrepareGhunnahIdghamIqlabOp(),
	ResolveDoubleSukunOp(),
	DropInitialShaddaOp(),
	ApplyGhunnahOp(),
	ApplyTasheelOp(),
	ApplyImalaOp(),
	ApplyMaddOp(),
	ApplyQalqalahOp(),
	FinalizeShaddaSukunOp(),
]
