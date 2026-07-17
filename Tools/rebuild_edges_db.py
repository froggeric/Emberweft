#!/usr/bin/env python3
"""Rebuild genomes/electric-sheep/edges.sqlite from the sheep/ and edges/ trees.

Resolves every edge's two endpoints to sheep by content hash (normalized:
edit lineage + time stripped), so it works for named AND unnamed (historic)
edges. Idempotent — run after fetching new genomes (fetch-sheep / sync-sheep)
or any time the trees change. sim_score / curated columns reserved for future
enhancement (similarity-based pair selection).
"""
import os, re, hashlib, sqlite3

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "genomes", "electric-sheep"))
DBPATH = os.path.join(ROOT, "edges.sqlite")

BLOCK_RE = re.compile(r'<flame\b.*?</flame>', re.S)
EDIT_RE = re.compile(r'<edit\b.*?</edit>', re.S)
TIME_RE = re.compile(r'\stime="[^"]*"')
WS_RE = re.compile(r'\s+')
TIMEVAL_RE = re.compile(r'time="(\d+)"')
NAME_RE = re.compile(r'name="electricsheep\.(\d+)\.(\d+)"')
PATH_RE = re.compile(r'/gen-(\d+)/[^/]*?\.(\d+)\.flam3$')

def norm(b):
    return WS_RE.sub('', TIME_RE.sub('', EDIT_RE.sub('', b)))
def fhash(b):
    return hashlib.sha256(norm(b).encode('utf-8', 'ignore')).hexdigest()[:16]
def walk_flam3(subdir):
    base = os.path.join(ROOT, subdir)
    if not os.path.isdir(base):
        return
    out = []
    for dp, _, fns in os.walk(base):
        for fn in fns:
            if fn.endswith('.flam3'):
                out.append(os.path.join(dp, fn))
    out.sort()                      # deterministic order -> byte-reproducible DB
    for p in out:
        yield p

# 1. index sheep by content hash AND by name (gen,id)
sheep_index = {}      # content hash -> (gen, id)
sheep_names = set()   # (gen, id) of every standalone sheep file
nsheep = 0
for p in walk_flam3("sheep"):
    m = PATH_RE.search(p); gi = (m.group(1), m.group(2)) if m else ('0', '0')
    sheep_names.add(gi)
    blocks = BLOCK_RE.findall(open(p, encoding='utf-8', errors='ignore').read())
    if len(blocks) == 1:
        sheep_index.setdefault(fhash(blocks[0]), gi); nsheep += 1

# 2. resolve edges, write DB
if os.path.exists(DBPATH):
    os.remove(DBPATH)
con = sqlite3.connect(DBPATH); cur = con.cursor()
cur.execute("""CREATE TABLE edge_pairs (
  edge_gen TEXT, edge_id TEXT, a_gen TEXT, a_id TEXT, b_gen TEXT, b_id TEXT,
  frames INTEGER, resolved INTEGER, sim_score REAL, curated INTEGER)""")
cur.execute("CREATE INDEX idx_a ON edge_pairs(a_gen, a_id)")
cur.execute("CREATE INDEX idx_b ON edge_pairs(b_gen, b_id)")

def endpoint(block, edge_gen):
    """Return (gen, id, has_sheep) for an edge endpoint flame.
    Resolve by content hash; else by name if a standalone sheep with that
    (gen,id) exists (handles content-variant endpoints); else unresolved."""
    h = fhash(block)
    if h in sheep_index:
        g, i = sheep_index[h]; return g, i, True
    nm = NAME_RE.search(block)
    if nm:
        gi = (nm.group(1), nm.group(2)); return gi[0], gi[1], gi in sheep_names
    return edge_gen, None, False

nedge = resolved = 0
for p in walk_flam3("edges"):
    txt = open(p, encoding='utf-8', errors='ignore').read()
    blocks = BLOCK_RE.findall(txt)
    if len(blocks) != 2:
        continue
    m = PATH_RE.search(p); gen, eid = (m.group(1), m.group(2)) if m else ('0', '0')
    times = TIMEVAL_RE.findall(txt)
    frames = int(times[-1]) if times else None
    ag, ai, ha = endpoint(blocks[0], gen)
    bg, bi, hb = endpoint(blocks[1], gen)
    ok = ha and hb
    cur.execute("INSERT INTO edge_pairs VALUES (?,?,?,?,?,?,?,?,NULL,NULL)",
                (gen, eid, ag, ai, bg, bi, frames, 1 if ok else 0))
    nedge += 1; resolved += ok
con.commit(); con.close()
print(f"rebuilt {DBPATH}: {nsheep} sheep indexed, {nedge} edges ({resolved} resolved, {nedge - resolved} unresolved)")
