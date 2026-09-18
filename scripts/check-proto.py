#!/usr/bin/env python3
"""P1 proto contract spot-check (stdlib only).

Walks proto/calcar/v1/*.proto and fails nonzero on:
  - missing `syntax = "proto3";`
  - wrong package (must be `calcar.v1`)
  - enum without a zero UNSPECIFIED value
  - duplicate field numbers within a message
  - duplicate message names across files
  - missing envelope fields (protocol version, msg id, sender, sent at, nonce)

Prints one PASS line per file plus a summary count.
"""

import re
import sys
from pathlib import Path

EXPECTED_PACKAGE = "calcar.v1"
SYNTAX_RE = re.compile(r'^\s*syntax\s*=\s*"proto3"\s*;\s*(?://.*)?$', re.MULTILINE)
PACKAGE_RE = re.compile(r'^\s*package\s+([\w.]+)\s*;\s*(?://.*)?$', re.MULTILINE)

# Token scan: message/enum declarations, braces, and `name = number` assignments.
TOKEN_RE = re.compile(
    r"\bmessage\s+(?P<mname>[A-Za-z_]\w*)"
    r"|\benum\s+(?P<ename>[A-Za-z_]\w*)"
    r"|(?P<open>\{)"
    r"|(?P<close>\})"
    r"|(?P<assign>(?P<aname>[A-Za-z_]\w*)\s*=\s*(?P<anum>\d+)\s*(?=[\[;]))"
)

BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
BRACKET_OPTS_RE = re.compile(r"\[[^\[\]]*\]")  # strip [default = 5]-style options


def strip_line_comments(text: str) -> str:
    out = []
    for line in text.splitlines():
        # Naive but fine for proto: cut at first // not inside a string.
        # Protos rarely put // inside string literals; accept the edge.
        idx = line.find("//")
        if idx != -1:
            line = line[:idx]
        out.append(line)
    return "\n".join(out)


def envelope_coverage(field_names):
    """Map the 5 required envelope concepts to a found field name (or None)."""
    lowered = {f.lower(): f for f in field_names}
    keys = list(lowered.keys())

    def find(*preds):
        for k in keys:
            if any(p(k) for p in preds):
                return lowered[k]
        return None

    return {
        "protocol_version": find(
            lambda k: "protocol_version" in k,
            lambda k: "protocolversion" in k,
            lambda k: k == "version",
        ),
        "msg_id": find(
            lambda k: "msg_id" in k,
            lambda k: "message_id" in k,
        ),
        "sender": find(lambda k: "sender" in k),
        "sent_at": find(
            lambda k: "sent_at" in k,
            lambda k: "sentat" in k,
            lambda k: "timestamp" in k,
        ),
        "nonce": find(lambda k: "nonce" in k),
    }


def check_file(path: Path, global_messages: dict):
    """Returns (errors, message_count, enum_count, fields_by_message)."""
    errors = []
    text = path.read_text(encoding="utf-8")

    if not SYNTAX_RE.search(text):
        errors.append(f'{path}: missing `syntax = "proto3";`')

    pkg_match = PACKAGE_RE.search(text)
    if not pkg_match:
        errors.append(f"{path}: missing package declaration (want `package {EXPECTED_PACKAGE};`)")
    elif pkg_match.group(1) != EXPECTED_PACKAGE:
        errors.append(
            f"{path}: wrong package `{pkg_match.group(1)}` (want `{EXPECTED_PACKAGE}`)"
        )

    # Remove block comments, line comments, and [...] option blocks so that
    # `[default = 5]` style options never look like field assignments.
    no_block = BLOCK_COMMENT_RE.sub("", text)
    clean = strip_line_comments(no_block)
    scannable = BRACKET_OPTS_RE.sub("", clean)

    # Per-line option guard: skip assignments on lines starting with `option`.
    option_lines = set()
    for i, line in enumerate(clean.splitlines(), start=1):
        if re.match(r"\s*option\b", line):
            option_lines.add(i)

    def line_of(pos):
        return scannable.count("\n", 0, pos) + 1

    depth = 0
    pending = []  # [(kind, name)]
    stack = []  # [{kind, name, depth, fields: {num: (fname, line)}, values: [(name, num)]}]
    fields_by_message = {}  # message name -> [field names]
    msg_count = 0
    enum_count = 0

    for m in TOKEN_RE.finditer(scannable):
        lineno = line_of(m.start())
        if m.group("mname") is not None:
            pending.append(("message", m.group("mname")))
        elif m.group("ename") is not None:
            pending.append(("enum", m.group("ename")))
        elif m.group("open") is not None:
            depth += 1
            if pending:
                kind, name = pending.pop(0)
                stack.append(
                    {
                        "kind": kind,
                        "name": name,
                        "depth": depth,
                        "fields": {},
                        "values": [],
                        "decl_line": lineno,
                    }
                )
                if kind == "message":
                    msg_count += 1
                    fields_by_message.setdefault(name, [])
                    if name in global_messages:
                        prev = global_messages[name]
                        errors.append(
                            f"{path}:{lineno}: duplicate message name `{name}` "
                            f"(also defined in {prev})"
                        )
                    else:
                        global_messages[name] = f"{path}:{lineno}"
                else:
                    enum_count += 1
            else:
                stack.append(
                    {
                        "kind": "block",
                        "name": "",
                        "depth": depth,
                        "fields": {},
                        "values": [],
                        "decl_line": lineno,
                    }
                )
        elif m.group("close") is not None:
            if stack and stack[-1]["depth"] == depth:
                closed = stack.pop()
                if closed["kind"] == "enum":
                    has_zero_unspecified = any(
                        num == 0 and "UNSPECIFIED" in name
                        for name, num in closed["values"]
                    )
                    if not has_zero_unspecified:
                        errors.append(
                            f"{path}:{closed['decl_line']}: enum `{closed['name']}` "
                            f"has no zero UNSPECIFIED value (proto3 enums must start at 0)"
                        )
            if depth > 0:
                depth -= 1
        elif m.group("assign") is not None:
            if lineno in option_lines:
                continue
            aname = m.group("aname")
            anum = int(m.group("anum"))
            # Innermost named scope decides meaning; anonymous blocks don't hold fields.
            scope = None
            for frame in reversed(stack):
                if frame["kind"] in ("message", "enum"):
                    scope = frame
                    break
                if frame["kind"] == "block":
                    continue
            if scope is None:
                continue
            if scope["kind"] == "enum":
                scope["values"].append((aname, anum))
            else:
                if anum in scope["fields"]:
                    prev_name, prev_line = scope["fields"][anum]
                    errors.append(
                        f"{path}:{lineno}: duplicate field number {anum} in message "
                        f"`{scope['name']}` (fields `{prev_name}` line {prev_line} "
                        f"and `{aname}` line {lineno})"
                    )
                else:
                    scope["fields"][anum] = (aname, lineno)
                    fields_by_message.setdefault(scope["name"], []).append(aname)

    return errors, msg_count, enum_count, fields_by_message


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    proto_dir = root / "proto" / "calcar" / "v1"
    files = sorted(proto_dir.glob("*.proto")) if proto_dir.is_dir() else []

    if not files:
        print(f"FAIL: no proto files found under {proto_dir} (want proto/calcar/v1/*.proto)")
        return 1

    all_errors = []
    all_fields = {}  # message name -> [field names]
    total_msgs = 0
    total_enums = 0
    per_file_ok = []

    global_messages = {}
    for f in files:
        rel = f.relative_to(root).as_posix()
        errors, n_msg, n_enum, fields = check_file(f, global_messages)
        total_msgs += n_msg
        total_enums += n_enum
        for name, flds in fields.items():
            all_fields.setdefault(name, []).extend(flds)
        if errors:
            all_errors.extend(errors)
            print(f"FAIL {rel} ({n_msg} messages, {n_enum} enums, {len(errors)} error(s))")
            for e in errors:
                print(f"  - {e}")
        else:
            per_file_ok.append(rel)
            print(f"PASS {rel} ({n_msg} messages, {n_enum} enums)")

    # Envelope check: at least one *Envelope* message carrying all 5 concepts.
    envelopes = {k: v for k, v in all_fields.items() if "envelope" in k.lower()}
    if not envelopes:
        all_errors.append("missing envelope message (want a message named *Envelope*)")
        print("FAIL envelope: no message named *Envelope* found")
    else:
        best = None
        for name, flds in envelopes.items():
            cov = envelope_coverage(flds)
            missing = [k for k, v in cov.items() if v is None]
            if not missing:
                best = (name, cov)
                break
        if best is None:
            # Report coverage of the first envelope candidate.
            name = sorted(envelopes)[0]
            cov = envelope_coverage(envelopes[name])
            missing = [k for k, v in cov.items() if v is None]
            all_errors.append(
                f"envelope `{name}` missing required field(s): {', '.join(missing)} "
                f"(want protocol version, msg id, sender, sent at, nonce)"
            )
            print(f"FAIL envelope `{name}`: missing {', '.join(missing)}")
        else:
            print(f"PASS envelope `{best[0]}` (protocol_version, msg_id, sender, sent_at, nonce)")

    print(
        f"summary: {len(per_file_ok)}/{len(files)} files passed, "
        f"{total_msgs} messages, {total_enums} enums"
    )
    if all_errors:
        print(f"RESULT: FAIL ({len(all_errors)} error(s))")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
