from dataclasses import dataclass, field
from difflib import SequenceMatcher
from tajweed_rules import TajweedRule
import alphabet as alph
import re


@dataclass
class MapPos:
    # This class is used to map the position of the character in the word to its corresponding phonetic representation.

    pos: tuple[int, int]  # (start_pos, end_pos)
    tajweed_rules: list[TajweedRule] = field(default_factory=list) # the tajweed rules that apply to this character
    deleted: bool = False  # whether this character is deleted or not

    def add_tajweed_rule(self, rule: TajweedRule | list[TajweedRule] | None) -> None:
        if rule is None:
            return
        if isinstance(rule, list):
            self.tajweed_rules.extend([item for item in rule if item is not None])
            return
        self.tajweed_rules.append(rule)

def sub_with_mapping(
	pattern: str,
	repl: str,
	text: str,
	mappings: list[MapPos] | None = None,
	tajweed_rule: TajweedRule | None = None,
) -> tuple[str, list[MapPos]]:
	new_text = re.sub(pattern, repl, text)
	opcodes = _opcodes_from_substitution(pattern, repl, text, new_text)
	new_mappings = generate_mappings(
		text=text,
		new_text=new_text,
		mappings=mappings,
		tajweed_rule=tajweed_rule,
		opcodes=opcodes,
	)
	return new_text, new_mappings

def _opcodes_from_substitution(pattern, repl, text, new_text):
    """Reconstruct SequenceMatcher-style opcodes deterministically from the
    actual regex match spans, diffing only WITHIN each matched region.

    Why this exists: ``generate_mappings`` recovers the per-character old->new
    correspondence so every Uthmani char keeps a phoneme position. Computed
    with a GLOBAL ``SequenceMatcher(text, new_text)`` it mis-aligns whenever a
    substitution inserts a run of repeated characters (madd elongation,
    idghaam ghunna): the matcher pairs an inserted repeat with a far-away
    identical char, emits one giant spurious ``replace`` block, and marks the
    genuinely-unchanged following text as ``delete``. That hands a later char a
    phoneme position far ahead of its neighbours, and downstream a word's
    phoneme span then swallows all following words.

    ``re.sub`` only ever changes the matched spans, so the correspondence is
    actually known exactly: text outside matches is copied verbatim (1:1) and
    each (small, bounded) match is diffed on its own, where cross-region
    repeated-char ambiguity cannot arise.

    Returns opcodes shaped like ``SequenceMatcher.get_opcodes`` or ``None`` if
    the reconstruction does not reproduce ``new_text`` (e.g. zero-width
    matches); the caller then falls back to the global matcher.
    """
    raw = []
    rebuilt = []
    old_cursor = 0
    new_cursor = 0
    for m in re.finditer(pattern, text):
        if m.start() == m.end():
            # Zero-width match: re.sub's empty-match advancing differs from a
            # naive walk, so bail out and let the caller use the global matcher.
            return None
        if m.start() > old_cursor:
            gap = m.start() - old_cursor
            raw.append(("equal", old_cursor, m.start(), new_cursor, new_cursor + gap))
            rebuilt.append(text[old_cursor:m.start()])
            new_cursor += gap
        rep = m.expand(repl)
        old_seg = text[m.start():m.end()]
        # Diff bounded to this match region; offset back into global coords.
        for tag, i1, i2, j1, j2 in SequenceMatcher(None, old_seg, rep).get_opcodes():
            raw.append((tag, m.start() + i1, m.start() + i2,
                        new_cursor + j1, new_cursor + j2))
        rebuilt.append(rep)
        new_cursor += len(rep)
        old_cursor = m.end()
    if old_cursor < len(text):
        gap = len(text) - old_cursor
        raw.append(("equal", old_cursor, len(text), new_cursor, new_cursor + gap))
        rebuilt.append(text[old_cursor:])
        new_cursor += gap

    if "".join(rebuilt) != new_text:
        # Reconstruction diverged from re.sub (overlapping / zero-width edge
        # case): don't risk a wrong mapping, fall back to the global matcher.
        return None

    # Coalesce adjacent 'equal' blocks so the opcode stream matches the shape
    # SequenceMatcher would emit (downstream handlers inspect neighbouring
    # opcodes for the madd-alif / insert special cases).
    merged = []
    for op in raw:
        if (merged and op[0] == "equal" and merged[-1][0] == "equal"
                and merged[-1][2] == op[1] and merged[-1][4] == op[3]):
            tag, i1, _, j1, _ = merged[-1]
            merged[-1] = (tag, i1, op[2], j1, op[4])
        else:
            merged.append(op)
    return merged


def generate_mappings(
    text: str,
    new_text: str,
    mappings: list[MapPos] | None = None,
    tajweed_rule: TajweedRule | None = None,
    opcodes: list | None = None,
) -> list[MapPos]:
    """Generate character position mappings between original and transformed text."""

    if text == "":
        return []

    ops = opcodes if opcodes is not None else SequenceMatcher(None, text, new_text).get_opcodes()
    new_mappings: list[MapPos] = [None] * len(text)
    to_del_poses = set()

    for op_idx, curr_op in enumerate(ops):
        last_op = ops[op_idx - 1] if op_idx > 0 else None
        next_op = ops[op_idx + 1] if op_idx < len(ops) - 1 else None

        op_type = curr_op[0]

        if op_type == "equal":
            _handle_equal(new_mappings, curr_op)
        
        elif op_type == "insert":
            _handle_insert(new_mappings, curr_op, last_op, next_op, text, new_text, tajweed_rule, to_del_poses)
        
        elif op_type == "replace":
            _handle_replace(new_mappings, curr_op, text, new_text, tajweed_rule, to_del_poses)
        
        elif op_type == "delete":
            _handle_delete(new_mappings, curr_op, tajweed_rule)

    # Validate all mappings were created
    assert all(m is not None for m in new_mappings), "Some mappings remain None"

    # Post-processing: special case handling
    _process_leen_madd(new_mappings, new_text)
    _process_idgham_tanween(new_mappings, text, new_text)
    _process_complete_idgham(new_mappings, text, new_text)
    _process_qalqalah_signs(new_mappings, new_text)

    # Merge with existing mappings
    new_mappings = merge_mappings(mappings, new_mappings)

    # Validate continuity
    _validate_mapping_continuity(new_mappings, new_text, text)

    return new_mappings


def merge_mappings(
    previous_mappings: list[MapPos] | None,
    current_mappings: list[MapPos],
) -> list[MapPos]:
    
    if previous_mappings is None:
        return current_mappings

    if not current_mappings:
        raise ValueError("current_mappings cannot be empty")

    for idx, prev_mapping in enumerate(previous_mappings):
        if prev_mapping is None:
            raise ValueError(f"previous_mappings[{idx}] is None - all mappings must be initialized")

        _merge_single_mapping(
            prev_mapping,
            current_mappings,
        )

    return previous_mappings


def _merge_single_mapping(
    prev_mapping: MapPos,
    current_mappings: list[MapPos],
) -> None:
    
    span_start = prev_mapping.pos[0]
    span_end = prev_mapping.pos[1]

    # Handle deleted mappings: they may have been shifted in current transformation
    if prev_mapping.deleted:
        if span_start < len(current_mappings):
            final_pos = current_mappings[span_start].pos[0]
        else:
            final_pos = current_mappings[-1].pos[1]
        prev_mapping.pos = (final_pos, final_pos)
    else:
        # Non-deleted mapping: span from first character's start to last character's end
        first_char_start = current_mappings[span_start].pos[0]
        last_char_end = current_mappings[span_end - 1].pos[1]
        prev_mapping.pos = (first_char_start, last_char_end)

    # Merge tajweed rules from all characters in the span
    for curr_idx in range(span_start, span_end):
        prev_mapping.add_tajweed_rule(current_mappings[curr_idx].tajweed_rules)

    # Mark as deleted only if ALL characters in span were deleted
    all_deleted = all(
        current_mappings[i].deleted
        for i in range(span_start, span_end)
    )
    prev_mapping.deleted = all_deleted


def _handle_equal(new_mappings: list, op: tuple) -> None:
    """Handle 'equal' operations: characters unchanged."""
    for old_idx, new_idx in zip(range(op[1], op[2]), range(op[3], op[4])):
        if new_mappings[old_idx] is None:
            new_mappings[old_idx] = MapPos(pos=(new_idx, new_idx + 1))


def _handle_insert(
    new_mappings: list, 
    curr_op: tuple, 
    last_op: tuple | None, 
    next_op: tuple | None,
    text: str,
    new_text: str,
    tajweed_rule: TajweedRule | None,
    to_del_poses: set
) -> None:
    """Handle 'insert' operations: characters added to new_text."""
    
    # Case 1: Insert follows equal with same character (e.g., Madd Alif)
    if last_op and last_op[0] == "equal":
        if new_text[last_op[4] - 1] == new_text[curr_op[3]]:
            _extend_mapping(new_mappings[last_op[2] - 1], curr_op[4], tajweed_rule)
            return

    # Case 2: Insert + Replace + Equal (Madd Alif with tashkeel)
    if next_op:
        if next_op[0] == "replace":
            _create_replacement_mapping(
                new_mappings, curr_op, next_op, tajweed_rule, to_del_poses
            )
        elif next_op[0] == "equal":
            _create_insert_equal_mapping(
                new_mappings, curr_op, next_op, new_text, tajweed_rule
            )


def _handle_replace(
    new_mappings: list,
    op: tuple,
    text: str,
    new_text: str,
    tajweed_rule: TajweedRule | None,
    to_del_poses: set
) -> None:
    """Handle 'replace' operations: characters substituted."""

    old_start, old_end = op[1], op[2]
    new_start, new_end = op[3], op[4]
    new_len = new_end - new_start

    # Assign a mapping for EVERY old index in the replace span. Using zip() over
    # the old/new ranges silently drops trailing old indices whenever the span
    # deletes more characters than it inserts (old_len > new_len), leaving them
    # None and tripping the assertion below. Iterate the full old span instead;
    # surplus old chars collapse (deleted) onto the end of the new span.
    for offset, old_idx in enumerate(range(old_start, old_end)):
        if new_mappings[old_idx] is not None or old_idx in to_del_poses:
            continue

        if offset >= new_len:
            # No corresponding new character: collapse onto end of new span.
            new_mappings[old_idx] = MapPos(pos=(new_end, new_end), deleted=True)
            continue

        new_idx = new_start + offset
        if text[old_idx] != alph.uthmani.space:
            new_map = MapPos(pos=(new_idx, new_idx + 1))
            new_map.add_tajweed_rule(tajweed_rule)
            new_mappings[old_idx] = new_map
        else:
            # Space handling: move previous mapping forward
            new_mappings[old_idx] = MapPos(pos=(new_idx + 1, new_idx + 1), deleted=True)
            if old_idx > 0 and new_mappings[old_idx - 1] is not None:
                new_mappings[old_idx - 1].pos = (
                    new_mappings[old_idx - 1].pos[0],
                    new_idx + 1,
                )


def _handle_delete(
    new_mappings: list,
    op: tuple,
    tajweed_rule: TajweedRule | None
) -> None:
    """Handle 'delete' operations: characters removed."""
    
    for old_idx in range(op[1], op[2]):
        new_map = MapPos(pos=(op[3], op[3]), deleted=True)
        new_map.add_tajweed_rule(tajweed_rule)
        new_mappings[old_idx] = new_map


def _extend_mapping(mapping: MapPos, new_end: int, tajweed_rule: TajweedRule | None) -> None:
    """Extend a mapping's end position."""
    mapping.pos = (mapping.pos[0], new_end)
    mapping.add_tajweed_rule(tajweed_rule)


def _create_replacement_mapping(
    new_mappings: list,
    insert_op: tuple,
    replace_op: tuple,
    tajweed_rule: TajweedRule | None,
    to_del_poses: set
) -> None:
    """Create mapping for insert + replace pattern."""
    new_map = MapPos(pos=(insert_op[3], replace_op[4]))
    new_map.add_tajweed_rule(tajweed_rule)
    new_mappings[replace_op[1]] = new_map
    
    for old_idx in range(replace_op[1] + 1, replace_op[2]):
        new_mappings[old_idx] = MapPos(pos=(replace_op[4], replace_op[4]), deleted=True)
        to_del_poses.add(old_idx)


def _create_insert_equal_mapping(
    new_mappings: list,
    insert_op: tuple,
    equal_op: tuple,
    new_text: str,
    tajweed_rule: TajweedRule | None
) -> None:
    """Create mapping for insert + equal pattern."""
    new_map = MapPos(pos=(insert_op[3], equal_op[3] + 1))
    new_map.add_tajweed_rule(tajweed_rule)
    new_mappings[equal_op[1]] = new_map


def _process_leen_madd(new_mappings: list, new_text: str) -> None:
    """Special handling for Leen Madd tajweed rule."""
    for mapping in new_mappings:
        if mapping.tajweed_rules:
            for taj_rule in mapping.tajweed_rules:
                if taj_rule.name.en == "Leen Madd" and taj_rule.tag is None:
                    tag = taj_rule._madd_to_tag[new_text[mapping.pos[0]]]
                    taj_rule.tag = tag


def _process_idgham_tanween(new_mappings: list, text: str, new_text: str) -> None:
    """Handle tanween idgham special case."""
    for match in re.finditer(f"{alph.uthmani.tanween_idhaam_dterminer}[^$]", text):
        idx = match.span()[0]
        new_pos = new_mappings[idx].pos[0]
        # When the determiner char was deleted/collapsed, its mapping can point at
        # (or past) the end of new_text. Treat that as "changed" — the character was
        # consumed by idgham — instead of indexing new_text out of range.
        changed = new_pos >= len(new_text) or text[idx] != new_text[new_pos]
        if changed:
            new_mappings[idx - 1].pos = (
                new_mappings[idx - 1].pos[0],
                new_mappings[idx].pos[1],
            )
            new_mappings[idx].pos = (new_mappings[idx].pos[1], new_mappings[idx].pos[1])
            new_mappings[idx].deleted = True


def _process_complete_idgham(new_mappings: list, text: str, new_text: str) -> None:
    """Handle complete idgham (e.g., 'لكم ما' → 'لكمَّا')."""
    pattern = f"([^{alph.uthmani.space}]){alph.uthmani.space}?\\1{alph.uthmani.shadda}"
    for match in re.finditer(pattern, text):
        first = match.span()[0]
        second = match.span()[1] - 2
        
        if not new_mappings[first].deleted and new_mappings[second].deleted:
            new_mappings[second] = new_mappings[first]
            for idx in range(first, second):
                new_mappings[idx] = MapPos(
                    pos=(new_mappings[second].pos[0], new_mappings[second].pos[0]),
                    deleted=True,
                )


def _process_qalqalah_signs(new_mappings: list, new_text: str) -> None:
    """Associate qalqalah signs with their letters."""
    pattern = f"[^{alph.uthmani.ras_haaa}{alph.uthmani.shadda}]({alph.phonetics.qlqla})"
    
    for match in re.finditer(pattern, new_text):
        qlq_pos = match.span(1)[0]
        
        m_idx = next((i for i, m in enumerate(new_mappings) if m.pos[0] == qlq_pos), None)
        if m_idx is None or m_idx == 0:
            continue
        
        prev_mapping = new_mappings[m_idx - 1]
        curr_mapping = new_mappings[m_idx]
        
        if prev_mapping.tajweed_rules is None:
            prev_mapping.pos = (prev_mapping.pos[0], curr_mapping.pos[1])
            prev_mapping.tajweed_rules = curr_mapping.tajweed_rules
            curr_mapping.pos = (curr_mapping.pos[1], curr_mapping.pos[1])
            curr_mapping.deleted = True
            curr_mapping.tajweed_rules = None


def _validate_mapping_continuity(new_mappings: list, new_text: str, text: str) -> None:
    """Best-effort continuity check; do not abort on sparse-gap mappings."""
    for idx in range(len(new_mappings)):
        curr = new_mappings[idx]
        next_m = next((m for m in new_mappings[idx + 1:] if m is not None), None)
        
        if next_m is None:
            next_pos = len(new_text)
        else:
            next_pos = next_m.pos[0]
        
        if curr.pos[1] != next_pos:
            return



    
    
