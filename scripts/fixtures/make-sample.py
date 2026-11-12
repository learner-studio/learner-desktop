#!/usr/bin/env python3
"""make-sample.py -- builds the synthetic chat-export sample the tests run on.

Run on the owner's Mac (it reads the real ai-vault export) whenever the export's shape
changes:

    python3 -I scripts/fixtures/make-sample.py [--src ~/ai-vault-data] [--out Tests/Fixtures/sample]

What it keeps from the real export is STRUCTURE only: providers, the header fields,
timestamps, message counts and roles, separators, empty and audio-only sections,
attachment blocks and the trailing metadata block. Every word of content is new:
titles, message text, headings inside answers, lists, code, links and file ids are
generated from the made-up vocabulary below (fake people, fake companies, fake
industries). Nothing a person wrote survives, so there is nothing to scrub by hand.

The sample is minimal: a few conversations per shape the parser has to handle (voice
chats, attachments, rules and headings inside answers, code, metadata, empty ones, one
long one), so the tests stay fast. Tests/LightTests/FixtureSampleTests checks every word
of it against vocabulary.txt, which this script writes, so a real word can never slip in
on a later refresh.
"""
import argparse, hashlib, json, os, random, re, shutil, sys, uuid

FIRST = ["Avery", "Jordan", "Riley", "Casey", "Morgan", "Quinn", "Rowan", "Sasha", "Emery", "Harper",
         "Dakota", "Reese", "Parker", "Skyler", "Finley", "Hayden", "Marlowe", "Tobin", "Wren", "Ellis"]
LAST = ["Halvorsen", "Okafor", "Marchetti", "Lindqvist", "Abernathy", "Castellano", "Duvall", "Fairbanks",
        "Kowalczyk", "Nakamura", "Oyelaran", "Pemberton", "Quintero", "Rasmussen", "Thibodeaux", "Vasquez"]
COMPANY = ["Brightwater Logistics", "Quillfern Biotech", "Marrowind Analytics", "Tessellate Foods",
           "Corvane Robotics", "Halvard Textiles", "Saltmarsh Energy", "Pinecrest Insurance",
           "Lumenfield Optics", "Ardent Harbor Shipping", "Copperleaf Media", "Northgale Ceramics",
           "Verity Loom Apparel", "Glasswing Aerospace", "Stonebridge Mortgage", "Juniper Vale Wines"]
INDUSTRY = ["cold chain logistics", "enzyme manufacturing", "regional insurance", "specialty ceramics",
            "satellite optics", "freight brokerage", "artisanal foods", "warehouse robotics",
            "wind turbine servicing", "boutique hospitality", "textile recycling", "community banking"]
TOPIC = ["the quarterly plan", "the pricing model", "a hiring pipeline", "the onboarding guide",
         "a customer survey", "the supplier contract", "a product launch", "the budget review",
         "a training session", "the inventory forecast", "a partnership proposal", "the weekly report",
         "a garden layout", "a weekend trip", "a birthday dinner", "a reading list", "a workout plan",
         "a soup recipe", "a board game night", "a moving checklist"]
VERB = ["review", "draft", "compare", "summarize", "outline", "estimate", "schedule", "organize",
        "rewrite", "check", "plan", "simplify", "prioritize", "explain", "test", "measure"]
FILLER = ("we could start with a short list and then compare the options side by side before "
          "choosing the simplest one that still meets the goal for the team this month and keeps "
          "the costs predictable while leaving room to adjust the details later if the numbers change "
          "so the next step is to write down what matters most and agree on a clear owner for each part").split()
CODE_WORDS = ["let", "value", "total", "items", "count", "result", "return", "def", "for", "in", "if",
              "else", "print", "list", "map", "sum", "name", "price", "rate", "step", "data", "row"]
# The fixed wording of Synth.sentence's templates and Synth.title (kept in step with them).
TEMPLATE_TEXT = ("Can you help me for at asked us to In the usual approach is to first Here is a way "
                 "step by works in and wants soon Thanks that helps with")
STRUCTURAL = ["Provider", "Created", "Updated", "Messages", "User", "Assistant", "System", "Tool",
              "Metadata", "Attachments", "audio", "image", "file", "json", "messageCount",
              "characterCount", "mediaCount", "https", "chatgpt", "claude", "gemini", "backend",
              "api", "files", "download", "com", "media", "example"]

ROLE = re.compile(r"^## (User|Assistant|System|Tool|Metadata)\s*$")
STAMP = re.compile(r"^[*_]\d{4}-\d{2}-\d{2}T[^*_\s]+[*_]$")
HEADER = re.compile(r"^\*\*(Provider|Created|Updated|Messages):\*\*")
ATTACH = re.compile(r"^(\s*- \[)(audio|image|file|video)(: )[^\]]*\]\(([^)]*)\)\s*$")
PREFIX = re.compile(r"^(\s*(?:[-*+] \[[ xX]\] |[-*+] |\d+[.)] |>+ ?|#{1,6} )?)")


class Synth:
    def __init__(self, seed):
        self.r = random.Random(seed)

    def hexid(self, n):
        return "".join(self.r.choice("0123456789abcdef") for _ in range(n))

    def sentence(self):
        t = self.r.randrange(6)
        a, b = self.r.choice(FIRST), self.r.choice(LAST)
        c, i, topic, v = self.r.choice(COMPANY), self.r.choice(INDUSTRY), self.r.choice(TOPIC), self.r.choice(VERB)
        return [f"Can you help me {v} {topic} for {c}?",
                f"{a} {b} at {c} asked us to {v} {topic}.",
                f"In {i}, the usual approach is to {v} {topic} first.",
                f"Here is a way to {v} {topic} step by step.",
                f"{c} works in {i} and wants to {v} {topic} soon.",
                f"Thanks {a}, that helps with {topic}."][t]

    def text(self, length):
        """Prose of about `length` characters (at least one sentence)."""
        out = self.sentence()
        while len(out) < length:
            out += " " + (self.sentence() if self.r.random() < 0.5 else " ".join(self.r.sample(FILLER, 8)) + ".")
        # Whole words only (vocabulary.txt is checked word by word): cut at a space.
        cut = out.rfind(" ", 0, length + 1)
        return out[:cut] if length > 0 and cut > 0 else out

    def code(self, length):
        out = f"{self.r.choice(CODE_WORDS)} {self.r.choice(CODE_WORDS)} = {self.r.randrange(1000)}"
        while len(out) < length:
            out += f"; {self.r.choice(CODE_WORDS)} = {self.r.choice(CODE_WORDS)}({self.r.randrange(100)})"
        return out

    def title(self):
        return f"{self.r.choice(VERB).capitalize()} {self.r.choice(TOPIC)} for {self.r.choice(COMPANY)}"


def synthesize(raw, s):
    """The conversation with every content line replaced; structure kept exactly."""
    lines = raw.split("\n")
    out, in_code, in_attach, in_meta, i = [], False, False, False, 0
    meta = {}
    for idx, line in enumerate(lines):
        if idx == 0 and line.startswith("# "):
            out.append("# " + s.title()); continue
        if HEADER.match(line) or line.strip() == "---" or STAMP.match(line) or line.strip() == "":
            out.append(line.rstrip() if line.strip() == "---" else line)
            if line.strip() == "---": in_attach = False
            continue
        if ROLE.match(line):
            in_meta = line.startswith("## Metadata"); in_attach = False
            out.append(line); continue
        if in_meta:
            # The trailing metadata block: only its numbers, rebuilt.
            m = re.match(r'^\s*"(messageCount|characterCount|mediaCount)":\s*(\d+)', line)
            if m: meta[m.group(1)] = int(m.group(2))
            if line.strip() == "```" and meta:
                body = json.dumps(meta, indent=2).split("\n")
                out.extend(body); out.append("```"); meta = {}; continue
            if line.strip().startswith("```json"): out.append("```json")
            continue
        if line.strip() == "**Attachments:**":
            in_attach = True; out.append(line); continue
        a = ATTACH.match(line)
        if in_attach and a:
            fid = "file_" + s.hexid(24)
            url = f"https://chatgpt.com/backend-api/files/download/{fid}" if "chatgpt.com" in a.group(4) else f"https://example.com/media/{fid}"
            out.append(f"{a.group(1)}{a.group(2)}{a.group(3)}{fid}]({url})"); continue
        if line.lstrip().startswith("```"):
            in_code = not in_code
            out.append(line[:len(line) - len(line.lstrip())] + "```"); continue
        indent = line[:len(line) - len(line.lstrip())]
        if in_code:
            out.append(indent + s.code(len(line.strip()))); continue
        p = PREFIX.match(line).group(1)
        rest = line[len(p):]
        trail = "  " if line.endswith("  ") else ""
        out.append(p + s.text(len(rest.strip())) + trail)
    return "\n".join(out)


def features(raw, provider):
    body = raw.split("\n## Metadata")[0]
    f = set([provider])
    if "[audio:" in raw: f.add("voice")
    if "[image:" in raw or "[file:" in raw: f.add("attachments")
    if "```" in body: f.add("code")
    if "\n## Metadata" in raw: f.add("metadata")
    if re.search(r"\n#{1,6} (?!User|Assistant|System|Tool|Metadata)", body): f.add("inner-heading")
    if raw.count("\n---\n") > 2 * max(1, raw.count("\n## User")) + 2: f.add("inner-rule")
    if re.search(r"^\s*[-*+] \[[ xX]\] ", raw, re.M): f.add("checklist")
    if "\r" in raw: f.add("crlf")
    if not re.search(r"^## (User|Assistant)", raw, re.M): f.add("no-messages")
    if re.search(r"^## (User|Assistant)\s*\n[*_]\d{4}[^\n]*\n\s*\n\s*\n\s*(\*\*Attachments|---)", raw, re.M): f.add("empty-section")
    if len(raw) > 30000: f.add("long")
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.expanduser("~/ai-vault-data"))
    ap.add_argument("--out", default="Tests/Fixtures/sample")
    ap.add_argument("--per-shape", type=int, default=3)
    ap.add_argument("--map", help="write original -> sample paths here (outside the repo; for the fidelity check)")
    a = ap.parse_args()

    files = []
    for provider in ("chatgpt", "claude", "gemini"):
        d = os.path.join(a.src, provider, "conversations")
        if not os.path.isdir(d): continue
        for cid in sorted(os.listdir(d)):
            p = os.path.join(d, cid, "conversation.md")
            if os.path.isfile(p):
                raw = open(p, encoding="utf-8", newline="").read()
                files.append((provider, p, raw, features(raw, provider)))
    if not files: sys.exit(f"no conversations under {a.src}")

    # The smallest examples of each shape, a few per shape; one long one at most.
    chosen, counts = {}, {}
    shapes = sorted(set().union(*(f for _, _, _, f in files)))
    for shape in shapes:
        want = 1 if shape == "long" else a.per_shape
        for provider, p, raw, f in sorted(files, key=lambda x: len(x[2])):
            if shape in f and (shape == "long" or len(raw) < 30000):
                if p not in chosen and counts.get(shape, 0) < want:
                    chosen[p] = (provider, raw)
                if p in chosen: counts[shape] = counts.get(shape, 0) + (0 if counts.get(shape, 0) >= want else 1)
            if counts.get(shape, 0) >= want: break

    root = os.path.join(a.out, "ai-vault-data")
    shutil.rmtree(root, ignore_errors=True)
    shapes_out, mapping = {}, []
    for p, (provider, raw) in sorted(chosen.items()):
        seed = hashlib.sha256(p.encode()).hexdigest()   # stable across refreshes; never written out
        s = Synth(seed)
        cid = str(uuid.UUID(seed[:32]))
        text = synthesize(raw.replace("\r\n", "\n"), s)
        if "crlf" in features(raw, provider): text = text.replace("\n", "\r\n")
        d = os.path.join(root, provider, "conversations", cid)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "conversation.md"), "w", encoding="utf-8", newline="") as fh: fh.write(text)
        for shape in features(raw, provider): shapes_out.setdefault(shape, []).append(f"{provider}/conversations/{cid}")
        if a.map: mapping.append({"original": p, "sample": os.path.join(d, "conversation.md")})

    words = set(STRUCTURAL)
    for group in (FIRST, LAST, COMPANY, INDUSTRY, TOPIC, VERB, FILLER, CODE_WORDS, [TEMPLATE_TEXT]):
        for item in group: words.update(re.findall(r"[A-Za-z]+", item))
    with open(os.path.join(a.out, "vocabulary.txt"), "w") as fh:
        fh.write("# Every word the synthetic sample may contain (scripts/fixtures/make-sample.py).\n")
        fh.write("\n".join(sorted(words, key=str.lower)) + "\n")
    with open(os.path.join(a.out, "shapes.json"), "w") as fh:
        json.dump({k: sorted(v) for k, v in sorted(shapes_out.items())}, fh, indent=2); fh.write("\n")
    if a.map:
        with open(a.map, "w") as fh: json.dump(mapping, fh)
    size = sum(len(r) for _, r in chosen.values())
    print(f"{len(chosen)} synthetic conversations from {len(files)} ({size // 1024} KB of source shapes) into {root}")
    for k, v in sorted(shapes_out.items()): print(f"  {k}: {len(v)}")


if __name__ == "__main__":
    main()
