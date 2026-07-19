#!/usr/bin/env python3
"""Generate a synthetic Knopo graph for performance testing: a heavy "Hub"
page (~24KB, ~300 blocks, ~160 outgoing [[refs]], TODOs, tags, a code fence,
a quote), 76 pages referencing it, 120 topic pages, and 60 filler pages
mentioning "Hub" as plain text (unlinked-reference candidates).

Usage: gen_testgraph.py [output-dir]   (default: ~/Documents/KnopoTestGraph)

Seeded — regenerating produces the identical graph. Bench against it with:
    KNOPO_BENCH=1 KNOPO_GRAPH=~/Documents/KnopoTestGraph swift run Knopo
"""
import os, random, shutil, sys

random.seed(42)
ROOT = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1
                          else "~/Documents/KnopoTestGraph")
PAGES = os.path.join(ROOT, "pages")
if os.path.exists(ROOT):
    shutil.rmtree(ROOT)
os.makedirs(PAGES)

WORDS = ("planning discussion review architecture deployment metrics latency "
         "throughput backlog roadmap estimate design draft feedback release "
         "monitoring incident retro sprint proposal budget hiring onboarding "
         "analytics migration schema index query cache render editor outline").split()

def sentence(n):
    return " ".join(random.choice(WORDS) for _ in range(n)).capitalize()

def page_file(name):
    # PageName.fileName percent-encodes; these names are plain ASCII w/o slashes.
    return os.path.join(PAGES, name + ".md")

# --- Hub page: ~300 blocks, ~160 outgoing refs, depths 0-2 ---
topics = [f"Topic {i:03d}" for i in range(1, 121)]
ref_pool = topics * 2  # ~170 draws from 120 topics
random.shuffle(ref_pool)
ref_iter = iter(ref_pool)

lines = []
blocks = 0
refs_out = 0
todo_count = 0
for section in range(1, 13):  # 12 top-level sections
    lines.append(f"- ## {sentence(3)} {section}")
    blocks += 1
    for child in range(random.randint(10, 14)):
        parts = [sentence(random.randint(6, 12))]
        drew = random.random()
        if drew < 0.85 and refs_out < 170:
            parts.append(f"see [[{next(ref_iter)}]]")
            refs_out += 1
            if random.random() < 0.35 and refs_out < 170:
                parts.append(f"and [[{next(ref_iter)}]]")
                refs_out += 1
        body = " ".join(parts)
        if todo_count < 15 and random.random() < 0.12:
            body = "TODO " + body
            todo_count += 1
        if random.random() < 0.08:
            body += " #project"
        lines.append(f"  - {body}")
        blocks += 1
        for grand in range(random.randint(0, 2)):
            lines.append(f"    - {sentence(random.randint(5, 10))}")
            blocks += 1
        if random.random() < 0.06:
            lines.append("    status:: open")

# one code block and one quote, realistic mixed content
lines.append("- ```swift")
lines.append("  func measure() -> CGFloat {")
lines.append("      return layout.usageBounds.height")
lines.append("  }")
lines.append("  ```")
lines.append("- > A quoted remark about the hub page for rendering variety.")
blocks += 2

hub = "\n".join(lines) + "\n"
with open(page_file("Hub"), "w") as f:
    f.write(hub)

# --- 76 referrer pages (incoming refs) ---
for i in range(1, 77):
    body = [f"- {sentence(8)}",
            f"- notes on [[Hub]] from meeting {i}",
            f"  - {sentence(6)}",
            f"- {sentence(7)}"]
    with open(page_file(f"Ref {i:02d}"), "w") as f:
        f.write("\n".join(body) + "\n")

# --- 120 topic pages (targets of hub's outgoing refs) ---
for t in topics:
    body = [f"- {sentence(9)}", f"- {sentence(7)}", f"  - {sentence(5)}"]
    with open(page_file(t), "w") as f:
        f.write("\n".join(body) + "\n")

# --- 60 filler pages mentioning "Hub" as plain text (unlinked-ref candidates) ---
for i in range(1, 61):
    body = [f"- {sentence(8)}",
            f"- the Hub concept came up in {sentence(3).lower()}",
            f"- {sentence(6)}"]
    with open(page_file(f"Note {i:03d}"), "w") as f:
        f.write("\n".join(body) + "\n")

print(f"graph: {ROOT}")
print(f"hub: {len(hub)} bytes, {blocks} blocks, {refs_out} outgoing refs, {todo_count} TODOs")
print(f"pages: {len(os.listdir(PAGES))}")
