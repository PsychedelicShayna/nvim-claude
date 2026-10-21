"""Pure request policy. Byte bounds deliberately overcount ordinary text tokens."""
import copy
import difflib
import hashlib
import json
import re

EFFORTS = ("low", "medium", "high", "xhigh", "max")
PRESETS = [50, 90, 100, 124, 150, 164, 200, 224, 256, 258, 274, 278, 300,
           374, 378, 384, 412, 456, 500, 512, 600, 650, 700, 750, 800, 850, 900, 950, 980]
# A runtime allowance, not a claim that get_context_usage is an exact tokenizer.
OVERHEAD = 16384
OUTPUT_RESERVE = 8192
COMPACT_RESERVE = 16384
PUNCTUATION = {"\u2014": "-", "\u2013": "-", "\u2018": "'", "\u2019": "'",
               "\u201c": '"', "\u201d": '"', "\u2026": "...", "\u00a0": " "}


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def byte_bound(text):
    return len(text.encode("utf-8"))


def parse_model(expression, current, native_selectors=()):
    result = dict(current)
    model = expression.strip()
    if not model:
        raise ValueError("A model ID is required")
    head, colon, tail = model.rpartition(":")
    if colon and tail in EFFORTS:
        model, result["effort"] = head, tail
    explicit = re.search(r"\[limit=(default|\d+(?:\.\d+)?[km]?)\]$", model, re.I)
    numeric = re.search(r"\[(\d+(?:\.\d+)?[km]?)\]$", model, re.I)
    match = explicit or numeric
    if match and (explicit or model not in native_selectors):
        value = match.group(1).lower()
        if value == "default":
            result["context_limit_tokens"] = None
        else:
            factor = 1000 if value.endswith("k") else 1000000 if value.endswith("m") else 1
            limit = float(value.rstrip("km")) * factor
            if not limit.is_integer() or limit < 1:
                raise ValueError("Context limit must be a positive whole token count")
            result["context_limit_tokens"] = int(limit)
        model = model[:match.start()]
    elif numeric and model in native_selectors:
        result["context_limit_tokens"] = None
    if not model:
        raise ValueError("A model ID is required")
    result["model"] = model
    return result


def normalize(text, mode, mapping=None):
    mapping = PUNCTUATION if mapping is None else mapping
    if mode == "allow":
        return text
    return "".join(("" if mode == "remove" else mapping[c]) if c in mapping else c for c in text)


def edit_result(raw, targets):
    def no_duplicates(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError(f"Duplicate JSON field: {key}")
            obj[key] = value
        return obj
    value = json.loads(raw, object_pairs_hook=no_duplicates)
    if not isinstance(value, dict):
        raise ValueError("Edit result must be a JSON object")
    if value.get("status") == "needs_input":
        if not isinstance(value.get("message"), str) or "replacements" in value:
            raise ValueError("Invalid clarification result")
        return value
    if value.get("status") != "ok" or not isinstance(value.get("replacements"), list):
        raise ValueError("Edit result needs status=ok and replacements")
    expected = {t["id"]: t for t in targets}
    found = set()
    for replacement in value["replacements"]:
        if not isinstance(replacement, dict):
            raise ValueError("Replacement must be an object")
        key, text = replacement.get("id"), replacement.get("text")
        if not isinstance(key, str) or key not in expected or key in found or not isinstance(text, str):
            raise ValueError("Unknown, duplicate, missing, or non-string replacement")
        if expected[key].get("blockwise") and ("\n" in text or "\r" in text):
            raise ValueError("Blockwise replacements must stay on one row")
        if "\x00" in text:
            raise ValueError("NUL output cannot be represented literally in a Neovim line")
        found.add(key)
    if found != set(expected):
        raise ValueError("Result does not contain every target exactly once")
    return value


def make_context(request, baselines):
    """Lua sends current text; only the bridge decides which baseline is confirmed."""
    payload = copy.deepcopy(request)
    text = payload.pop("buffer_text", None)
    if text is None:
        return payload, None
    doc = payload["document"]["id"]
    revision = hashlib.sha256(text.encode()).hexdigest()[:16]
    baseline = baselines.get(doc)
    context = {"kind": "snapshot", "revision": revision, "text": text}
    if baseline:
        old_revision, old_text = baseline
        if old_text == text:
            context = {"kind": "unchanged", "revision": revision}
        else:
            delta = "".join(difflib.unified_diff(old_text.splitlines(True), text.splitlines(True),
                                               fromfile=old_revision, tofile=revision))
            if delta and old_text.endswith("\n") and text.endswith("\n") and byte_bound(delta) < byte_bound(text):
                context = {"kind": "diff", "base_revision": old_revision,
                           "revision": revision, "format": "unified", "text": delta}
    payload["context"] = context
    return payload, (doc, revision, text)


def excerpt(request, available):
    """Keep all targets intact. Whole-document requests cannot become excerpts."""
    payload = copy.deepcopy(request)
    context = payload.get("context")
    if not context or context["kind"] != "snapshot" or payload.get("whole_document"):
        return payload
    text = context["text"]
    lines = text.splitlines(True)
    targets = payload.get("targets", [])
    if not targets:
        return payload
    lo = min(t["start"][0] for t in targets)
    hi = max(t["end"][0] for t in targets) + 1
    lo, hi = max(0, lo - 3), min(len(lines), hi + 3)
    context.update(kind="excerpt", text="".join(lines[lo:hi]), start_row=lo,
                   omitted_before=lo > 0, omitted_after=hi < len(lines))
    if byte_bound(encode(payload)) > available:
        # Dropping supporting context is explicit; exact targets remain mandatory.
        context.update(text="", start_row=min(t["start"][0] for t in targets),
                       omitted_before=True, omitted_after=True)
    return payload


def prompt_bound(system, history, prompt):
    # Text-only model input has no media/tool schemas. A byte-fallback tokenizer
    # cannot emit more ordinary text tokens than UTF-8 bytes. Per-message framing,
    # runtime instructions and metadata are covered separately by OVERHEAD.
    retained = history if isinstance(history, int) else sum(byte_bound(x) + 128 for x in history)
    return byte_bound(system) + retained + byte_bound(prompt) + OVERHEAD


def enforce_budget(system, history, prompt, limit, physical):
    bound = prompt_bound(system, history, prompt)
    effective = min(limit or physical - OUTPUT_RESERVE, physical - OUTPUT_RESERVE)
    if bound > effective:
        raise ValueError(f"Request refused before dispatch: conservative prompt bound {bound:,} "
                         f"exceeds {effective:,} tokens. Reduce the instruction/target or choose a budget explicitly.")
    return bound
