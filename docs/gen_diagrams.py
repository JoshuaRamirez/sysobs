#!/usr/bin/env python3
"""Generate the sysobs logical diagram set as one self-contained HTML page.

Every diagram here is LOGICAL: it describes roles, responsibilities and the
shape of the flow, not files, hosts or deployment. Coordinates are computed
rather than hand-placed so that a box can be renamed or moved without
re-drawing every edge that touches it.
"""
from __future__ import annotations
import html, math, pathlib

OUT = pathlib.Path(__file__).resolve().parent / "sysobs-diagrams.html"

# ---------------------------------------------------------------- palette
BG, PANEL, LINE, INK, MUTE = "#0d1117", "#161b22", "#30363d", "#e6edf3", "#8b949e"

# Pathway types. Each is a colour AND a glyph, so the diagram survives being
# printed in greyscale or read by someone who cannot separate red from green.
KINDS = {
    "ctl":     ("#8b949e", "solid",   "tri",     "Control",      "invoke / dispatch / orchestrate"),
    "sched":   ("#39d0d8", "dash",    "clock",   "Schedule",     "a launchd timer fires"),
    "exec":    ("#f0a020", "solid",   "tri",     "Process exec", "fork a probe, read its stdout"),
    "syscall": ("#a371f7", "solid",   "diamond", "Syscall",      "sysctl / libproc through ctypes"),
    "write":   ("#3fb950", "solid",   "square",  "Store write",  "append or rewrite a CSV table"),
    "read":    ("#56d364", "dash",    "circle",  "Store read",   "parse a CSV table into memory"),
    "sql":     ("#58a6ff", "solid",   "circle",  "SQL",          "load into / query the mirror"),
    "spool":   ("#db61a2", "solid",   "diamond", "Spool",        "NDJSON append, resume at offset"),
    "lock":    ("#d29922", "dot",     "square",  "Exclusion",    "flock — one writer at a time"),
    "net":     ("#f85149", "dashdot", "tri",     "Egress",       "DNS PTR / HTTP — opt-in only"),
}
DASH = {"solid": "", "dash": "7 5", "dot": "2 5", "dashdot": "10 4 2 4"}

NODE_CLASS = {
    "actor":  ("#1f2937", "#9ca3af", INK),
    "cli":    ("#1d2b3a", "#58a6ff", "#cfe6ff"),
    "ctrl":   ("#2a2140", "#a371f7", "#e5d9ff"),
    "probe":  ("#33240f", "#f0a020", "#ffe2b0"),
    "store":  ("#10281a", "#3fb950", "#c6f6d5"),
    "data":   ("#0f2233", "#58a6ff", "#cfe6ff"),
    "ext":    ("#3a1417", "#f85149", "#ffd0cd"),
    "out":    ("#1c1c22", "#8b949e", INK),
    "lock":   ("#332810", "#d29922", "#ffe9b0"),
    "spool":  ("#33172a", "#db61a2", "#ffd3ec"),
}


def esc(s):
    return html.escape(str(s), quote=True)


class Svg:
    """A tiny retained-mode SVG builder with a box registry for edge anchoring."""

    def __init__(self, w, h):
        self.w, self.h, self.parts, self.boxes = w, h, [], {}
        self.labels = []

    def raw(self, s):
        self.parts.append(s)
        return self

    def text(self, x, y, s, size=13, fill=INK, anchor="start", weight=400,
             family="ui-sans-serif,-apple-system,Segoe UI,Roboto,sans-serif",
             style="", opacity=1):
        self.raw(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" '
                 f'text-anchor="{anchor}" font-weight="{weight}" font-family="{family}" '
                 f'opacity="{opacity}" {style}>{esc(s)}</text>')
        return self

    def rect(self, x, y, w, h, fill="none", stroke=LINE, rx=8, sw=1.5, dash="", op=1):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.raw(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{rx}" '
                 f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d} opacity="{op}"/>')
        return self

    # ---- nodes -----------------------------------------------------------
    def box(self, nid, x, y, w, h, title, sub="", cls="ctrl", rx=8, tsize=13, ssize=10.5):
        fill, stroke, ink = NODE_CLASS[cls]
        self.boxes[nid] = (x, y, w, h)
        self.rect(x, y, w, h, fill=fill, stroke=stroke, rx=rx)
        if sub:
            self.text(x + w / 2, y + h / 2 - 2, title, tsize, ink, "middle", 650)
            self.text(x + w / 2, y + h / 2 + 13, sub, ssize, MUTE, "middle")
        else:
            self.text(x + w / 2, y + h / 2 + 4.5, title, tsize, ink, "middle", 650)
        return self

    def group(self, x, y, w, h, label, colour=LINE, pad_label=True):
        self.rect(x, y, w, h, fill="#ffffff04", stroke=colour, rx=12, sw=1.2, dash="6 5")
        if pad_label:
            self.labels.append((x, y, label, colour))
            self._draw_label(x, y, label, colour)
        return self

    def _draw_label(self, x, y, label, colour):
        self.rect(x + 8, y + 7, len(label) * 7.4 + 12, 18, fill=BG, stroke="none", rx=4)
        self.text(x + 14, y + 19, label, 11.5, colour, "start", 700,
                  style='letter-spacing="1.2"')

    def relabel(self):
        """Group titles are drawn before the edges, so edges routed into a group
        paint over them. Redraw the titles last."""
        for x, y, label, colour in self.labels:
            self._draw_label(x, y, label, colour)
        return self

    # ---- anchors ---------------------------------------------------------
    def a(self, nid, side, t=0.5):
        x, y, w, h = self.boxes[nid]
        return {"t": (x + w * t, y), "b": (x + w * t, y + h),
                "l": (x, y + h * t), "r": (x + w, y + h * t)}[side]

    # ---- edges -----------------------------------------------------------
    def edge(self, p0, p1, kind="ctl", label="", route="auto", mid=None,
             label_side="mid", sw=2.0, arrow=True, both=False, pts=None, label_xy=None):
        """both=True marks a request/response pathway: the call goes one way,
        the data comes back the other, over the same channel."""
        colour, style, _g, *_ = KINDS[kind]
        pts = pts or self._route(p0, p1, route, mid)
        d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        dash = f' stroke-dasharray="{DASH[style]}"' if DASH[style] else ""
        head = f' marker-end="url(#ah-{kind})"' if arrow else ""
        if both:
            head += f' marker-start="url(#ah-{kind})"' 
        self.raw(f'<polyline points="{d}" fill="none" stroke="{colour}" stroke-width="{sw}" '
                 f'stroke-linejoin="round" stroke-linecap="round"{dash}{head}/>')
        self._glyph(pts, kind, colour)
        if label:
            lx, ly = label_xy or self._label_pos(pts, label_side)
            tw = len(label) * 5.6 + 12
            self.rect(lx - tw / 2, ly - 9, tw, 17, fill=BG, stroke="none", rx=4)
            self.text(lx, ly + 3.5, label, 10, colour, "middle", 600)
        return self

    def _route(self, p0, p1, route, mid):
        x0, y0 = p0
        x1, y1 = p1
        if route == "line":
            return [p0, p1]
        if route == "v":                      # vertical elbow through a midline
            ym = mid if mid is not None else (y0 + y1) / 2
            return [p0, (x0, ym), (x1, ym), p1]
        if route == "h":                      # horizontal elbow
            xm = mid if mid is not None else (x0 + x1) / 2
            return [p0, (xm, y0), (xm, y1), p1]
        if route == "lz":                     # out sideways, then across
            xm = mid if mid is not None else x0 - 40
            return [p0, (xm, y0), (xm, y1), p1]
        if abs(x0 - x1) < 2 or abs(y0 - y1) < 2:
            return [p0, p1]
        ym = mid if mid is not None else (y0 + y1) / 2
        return [p0, (x0, ym), (x1, ym), p1]

    @staticmethod
    def _label_pos(pts, side):
        if side == "start":
            i = 0
        elif side == "end":
            i = len(pts) - 2
        else:
            i = len(pts) // 2 - 1
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        return ((ax + bx) / 2, (ay + by) / 2)

    def _glyph(self, pts, kind, colour):
        """Drop the type glyph at the geometric middle of the longest segment."""
        best, bl = None, -1
        for (ax, ay), (bx, by) in zip(pts, pts[1:]):
            L = math.hypot(bx - ax, by - ay)
            if L > bl:
                bl, best = L, ((ax + bx) / 2, (ay + by) / 2)
        if bl < 26:
            return
        cx, cy = best
        g = KINDS[kind][2]
        self.rect(cx - 6.5, cy - 6.5, 13, 13, fill=BG, stroke="none", rx=3)
        if g == "circle":
            self.raw(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="4.2" fill="{BG}" stroke="{colour}" stroke-width="2"/>')
        elif g == "square":
            self.raw(f'<rect x="{cx-4:.1f}" y="{cy-4:.1f}" width="8" height="8" fill="{BG}" stroke="{colour}" stroke-width="2"/>')
        elif g == "diamond":
            self.raw(f'<path d="M{cx:.1f},{cy-5.2:.1f} L{cx+5.2:.1f},{cy:.1f} L{cx:.1f},{cy+5.2:.1f} L{cx-5.2:.1f},{cy:.1f} Z" fill="{BG}" stroke="{colour}" stroke-width="2"/>')
        elif g == "clock":
            self.raw(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="5" fill="{BG}" stroke="{colour}" stroke-width="1.8"/>'
                     f'<path d="M{cx:.1f},{cy-3:.1f} L{cx:.1f},{cy:.1f} L{cx+2.6:.1f},{cy+1.6:.1f}" fill="none" stroke="{colour}" stroke-width="1.6"/>')
        else:
            self.raw(f'<path d="M{cx-4.6:.1f},{cy-4.6:.1f} L{cx+5:.1f},{cy:.1f} L{cx-4.6:.1f},{cy+4.6:.1f} Z" fill="{colour}" stroke="none"/>')

    # ---- output ----------------------------------------------------------
    def defs(self):
        out = ['<defs>']
        for k, (c, *_r) in KINDS.items():
            out.append(f'<marker id="ah-{k}" viewBox="0 0 10 10" refX="9" refY="5" '
                       f'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                       f'<path d="M0,1 L10,5 L0,9 z" fill="{c}"/></marker>')
        out.append(f'<marker id="ah-open" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="9" '
                   f'markerHeight="9" orient="auto-start-reverse">'
                   f'<path d="M0,1 L10,5 L0,9" fill="none" stroke="{INK}" stroke-width="1.6"/></marker>')
        for name, c in (("inh", INK), ("agg", INK)):
            out.append(f'<marker id="m-{name}" viewBox="0 0 12 12" refX="11" refY="6" markerWidth="13" '
                       f'markerHeight="13" orient="auto-start-reverse">'
                       + (f'<path d="M0,1 L12,6 L0,11 z" fill="{BG}" stroke="{c}" stroke-width="1.5"/>'
                          if name == "inh" else
                          f'<path d="M0,6 L6,1 L12,6 L6,11 z" fill="{BG}" stroke="{c}" stroke-width="1.5"/>')
                       + '</marker>')
        out.append(f'<marker id="m-comp" viewBox="0 0 12 12" refX="11" refY="6" markerWidth="13" '
                   f'markerHeight="13" orient="auto-start-reverse">'
                   f'<path d="M0,6 L6,1 L12,6 L6,11 z" fill="{INK}" stroke="{INK}" stroke-width="1.5"/></marker>')
        out.append('</defs>')
        return "".join(out)

    def render(self, cls="dg"):
        return (f'<svg class="{cls}" viewBox="0 0 {self.w} {self.h}" '
                f'preserveAspectRatio="xMidYMin meet" role="img">'
                + self.defs() + "".join(self.parts) + "</svg>")


# ================================================================ D1 pathways
def d1_pathways() -> str:
    """Every distinct communication pathway, typed by colour + glyph."""
    s = Svg(1470, 1275)
    A, E = s.a, s.edge

    # ---- band 1: what starts anything ------------------------------------
    s.group(40, 34, 1390, 86, "TRIGGERS — NOTHING IN THIS SYSTEM SELF-STARTS", "#9ca3af")
    s.box("op",      60, 56, 236, 50, "Operator", "interactive shell", "actor")
    s.box("t_snap", 312, 56, 300, 50, "launchd · local.sysobs", "StartInterval 300 s · RunAtLoad", "actor")
    s.box("t_watch",628, 56, 300, 50, "launchd · …-procwatch", "continuous · 0.1 s poll", "actor")
    s.box("t_prune",944, 56, 230, 50, "launchd · …-prune", "Sunday 04:15", "actor")
    s.box("analyst",1190,56, 220, 50, "Analyst", "ad-hoc SQL", "actor")

    # ---- band 2: the one front door --------------------------------------
    s.box("cli", 40, 166, 1390, 58, "sysobs  —  single entry point, command dispatch",
          "13 subcommands   ·   --json on every reading command   ·   exit 0 ok / 1 finding / 2 usage", "cli")

    # ---- band 3: acquisition ---------------------------------------------
    s.box("cap", 120, 268, 270, 66, "Capture", "orchestrates 12 collectors", "ctrl")
    s.box("pw",  440, 268, 250, 66, "ProcWatch", "diffs the live PID set", "ctrl")
    s.box("ing", 740, 268, 230, 66, "Ingestor", "spool → process_event", "ctrl")

    # ---- band 4: the observation surface ---------------------------------
    s.group(64, 386, 876, 204, "MACOS OBSERVATION SURFACE — READ-ONLY, NO INSTRUMENTATION", "#f0a020")
    r1 = [("sysctl", 78, 112, "sysctl", "kern / hw / vm"),
          ("vmstat", 200, 112, "vm_stat", "page accounting"),
          ("topcmd", 322, 100, "top -l 1", "cpu + mem"),
          ("iostat", 432, 100, "iostat", "device i/o"),
          ("dfmnt",  542, 124, "df · mount", "volumes"),
          ("ioreg",  676, 110, "ioreg", "AppleSmartBattery"),
          ("libproc",796, 128, "libproc", "ctypes · task_info")]
    for nid, x, w, t, sub in r1:
        s.box(nid, x, 428, w, 48, t, sub, "probe", tsize=12, ssize=9.5)
    r2 = [("ps",      78, 126, "ps -Ao", "identity · cpu · rss"),
          ("lsofnet",214, 148, "lsof -nP -i", "sockets per pid"),
          ("lsoffile",372,140, "lsof (files)", "open paths"),
          ("nsanv",  522, 140, "netstat -anv", "per-socket bytes"),
          ("nsibn",  672, 140, "netstat -ibn", "per-interface"),
          ("nettop", 822, 102, "nettop", "per-pid bytes")]
    for nid, x, w, t, sub in r2:
        s.box(nid, x, 500, w, 48, t, sub, "probe", tsize=12, ssize=9.5)
    s.text(78, 572, "every probe is a fork/exec of a stock macOS binary — the pathway carries a request down and stdout back up",
           10.5, MUTE)

    # ---- band 4b: off-box ------------------------------------------------
    s.group(1040, 386, 390, 204, "OFF-BOX — OPT-IN, DEFAULT OFF", "#f85149")
    s.box("resolver", 1058, 428, 354, 48, "System resolver", "PTR lookups  ·  --rdns", "ext", tsize=12, ssize=9.5)
    s.box("geoapi",   1058, 500, 354, 48, "ip-api.com", "public addresses only  ·  --geo online", "ext", tsize=12, ssize=9.5)
    s.text(1058, 568, "private, loopback and link-local", 10, MUTE)
    s.text(1058, 581, "are never transmitted", 10, MUTE)

    # ---- band 5: normalisation ------------------------------------------
    s.box("refs",  100, 648, 270, 66, "Refs", "path→file_id · addr→address_id", "ctrl")
    s.box("store", 410, 648, 270, 66, "Store", "dedupe dims · buffer facts", "ctrl")
    s.box("slock", 720, 648, 250, 66, "StoreLock", "one writer at a time", "lock")

    # ---- band 6: durable state -------------------------------------------
    s.group(40, 766, 1390, 136, "DURABLE STATE — THE LOG ITSELF", "#3fb950")
    s.box("csv",   70, 808, 300, 62, "tables/ *.csv", "9 dimensions + 13 facts", "store")
    s.box("spool", 396, 808, 236, 62, "spool/ *.ndjson", "hourly · append-only", "spool")
    s.box("offs",  658, 808, 232, 62, "spool/offsets.json", "resume cursor", "spool")
    s.box("lockf", 916, 808, 170, 62, ".store.lock", "advisory flock", "lock")
    s.box("db",   1112, 808, 288, 62, "sysobs.sqlite", "derived mirror · FKs ON", "data")

    # ---- band 7: consumption --------------------------------------------
    s.box("verify", 60,  950, 210, 66, "Verifier", "7 integrity checks", "ctrl")
    s.box("mirror", 296, 950, 250, 66, "MirrorBuilder", "fingerprint → sync", "ctrl")
    s.box("pruner", 572, 950, 190, 66, "Pruner", "age-out + GC dims", "ctrl")
    s.box("reads",  788, 950, 300, 66, "list · show · top · events", "CSV-direct readers", "ctrl")
    s.box("query", 1114, 950, 286, 66, "query", "SQL, auto-syncing", "ctrl")
    s.box("out",    480,1080, 500, 56, "stdout — aligned table or --json", "exit 0 ok · 1 finding · 2 usage", "out")

    # ================= edges =================
    # triggers -> cli
    E(A("op", "b"),      A("cli", "t", 0.06), "ctl",   "argv")
    E(A("t_snap", "b"),  A("cli", "t", 0.26), "sched", "snapshot --files none")
    E(A("t_watch", "b"), A("cli", "t", 0.50), "sched", "procwatch")
    E(A("t_prune", "b"), A("cli", "t", 0.72), "sched", "prune --days 14 --go")
    E(A("analyst", "b"), A("cli", "t", 0.93), "ctl",   "query")

    # cli -> acquisition
    E(A("cli", "b", 0.16), A("cap", "t"), "ctl")
    E(A("cli", "b", 0.39), A("pw", "t"),  "ctl")
    E(None, None, "ctl", "then, under the same lock", sw=1.8, label_xy=(609, 344),
      pts=[(363, 334), (363, 354), (855, 354), (855, 334)])

    # cli -> read & maintenance commands, down the right margin and back along a rail
    s.raw(f'<polyline points="1430,195 1450,195 1450,1044 150,1044" fill="none" '
          f'stroke="{MUTE}" stroke-width="1.6" stroke-dasharray="1 4"/>')
    s.text(1240, 1036, "dispatch rail — read & maintenance commands", 10, MUTE, "end", 600)
    for nid in ("verify", "mirror", "pruner", "reads", "query"):
        x, y, w, h = s.boxes[nid]
        E((x + w * 0.22, 1044), (x + w * 0.22, y + h), "ctl", sw=1.4)

    # capture -> probes, over a shared exec rail
    E(A("cap", "b", 0.5), (255, 364), "exec", arrow=False, sw=2.2)
    s.raw(f'<polyline points="88,364 930,364" fill="none" stroke="{KINDS["exec"][0]}" stroke-width="2.2"/>')
    for nid, x, w, *_ in r1:
        if nid == "libproc":
            continue
        E((x + w / 2, 364), (x + w / 2, 428), "exec", both=True, sw=1.8)
    gaps = {"ps": 195, "lsofnet": 317, "lsoffile": 427, "nsanv": 537, "nsibn": 791, "nettop": 930}
    for nid, x, w, *_ in r2:
        g = gaps[nid]
        tx = x + w / 2
        E(None, None, "exec", both=True, sw=1.8,
          pts=[(g, 364), (g, 486), (tx, 486), (tx, 500)])

    # libproc is reached directly, not through a shell
    E(None, None, "syscall", "proc_pidinfo", sw=1.9, label_xy=(520, 374),
      pts=[(363, 334), (363, 374), (846, 374), (846, 428)], both=True)
    E(None, None, "syscall", "proc_listpids", sw=1.9, label_xy=(760, 398),
      pts=[(565, 334), (565, 398), (882, 398), (882, 428)], both=True)

    # capture -> off-box, only when asked
    E(None, None, "net", "--rdns", sw=1.8, both=True,
      pts=[(349, 268), (349, 246), (976, 246), (976, 452), (1058, 452)])
    E(None, None, "net", "--geo online", sw=1.8, both=True, label_side="end",
      pts=[(363, 268), (363, 232), (996, 232), (996, 524), (1058, 524)])

    # acquisition -> normalisation, down the free left margin
    E(None, None, "ctl", "Capture normalises through", sw=1.9, label_xy=(196, 640),
      pts=[(120, 301), (30, 301), (30, 640), (268, 640), (268, 648)])
    E(None, None, "ctl", "Ingestor shares the same Refs", sw=1.9, label_xy=(330, 254),
      pts=[(774, 268), (774, 254), (48, 254), (48, 612), (140, 612), (140, 648)])

    E(A("refs", "r"), A("store", "l"), "ctl", "emits rows into")
    E(A("slock", "l"), A("store", "r"), "lock", "guards every write")
    E(A("slock", "b", 0.5), A("lockf", "t", 0.5), "lock", "flock(LOCK_EX)")

    # store <-> csv
    E(A("store", "b", 0.35), A("csv", "t", 0.4), "write", "append · rewrite", route="v", mid=742)
    E(A("csv", "t", 0.78), A("store", "b", 0.8), "read", "load dims to dedupe", route="v", mid=756)

    # procwatch -> spool, ingestor <-> spool/offsets
    E(None, None, "spool", "procwatch appends here", sw=1.9, label_xy=(200, 886),
      pts=[(565, 268), (565, 240), (16, 240), (16, 886), (462, 886), (462, 870)])
    E(None, None, "spool", "read from offset", sw=1.9, both=True,
      pts=[(970, 301), (1016, 301), (1016, 748), (561, 748), (561, 808)])
    E(None, None, "spool", "advance only after flush", sw=1.9, label_side="end",
      pts=[(890, 334), (890, 770), (774, 770), (774, 808)])

    # persistence -> consumption
    E(A("csv", "b", 0.18), A("verify", "t", 0.5), "read", "all 22 tables", route="v", mid=934)
    E(A("csv", "b", 0.45), A("mirror", "t", 0.3), "read", "prefix fingerprint", route="v", mid=924)
    E(A("csv", "b", 0.95), A("reads", "t", 0.2), "read", "CSV direct — never the mirror", route="v", mid=914)
    E(A("pruner", "t", 0.5), A("csv", "b", 0.75), "write", "rewrite kept rows", route="v", mid=906)
    E(A("mirror", "t", 0.8), A("db", "b", 0.15), "sql", "CREATE + INSERT, FKs ON", route="v", mid=898)
    E(A("query", "t", 0.45), A("db", "b", 0.72), "sql", "SELECT (read-only)", route="v", mid=890, both=True)
    E(None, None, "ctl", "sync if stale", sw=1.7, label_side="mid",
      pts=[(1146, 1016), (1146, 1030), (521, 1030), (521, 1016)])

    # consumption -> stdout
    E(A("verify", "b", 0.8), A("out", "l"), "ctl", route="v", mid=1062, sw=1.6)
    E(A("reads", "b", 0.62), A("out", "t", 0.62), "ctl", route="v", mid=1062, sw=1.6)
    E(A("query", "b", 0.62), A("out", "r"), "ctl", route="v", mid=1068, sw=1.6)

    s.relabel()

    # ---- legend ----------------------------------------------------------
    s.group(40, 1160, 1390, 100, "PATHWAY TYPES — COLOUR AND GLYPH BOTH CARRY THE TYPE", MUTE)
    cx, cy = 62, 1192
    for i, (k, (colour, style, glyph, name, desc)) in enumerate(KINDS.items()):
        col, row = i % 5, i // 5
        x = cx + col * 276
        y = cy + row * 34
        d = f' stroke-dasharray="{DASH[style]}"' if DASH[style] else ""
        s.raw(f'<line x1="{x}" y1="{y}" x2="{x+46}" y2="{y}" stroke="{colour}" '
              f'stroke-width="2.2"{d} marker-end="url(#ah-{k})"/>')
        s._glyph([(x, y), (x + 46, y)], k, colour)
        s.text(x + 56, y - 2, name, 11.5, colour, "start", 700)
        s.text(x + 56, y + 11, desc, 10, MUTE)
    return s.render()


# ================================================================ D2 swimlanes
LANES = [
    ("Trigger",        "actor"),
    ("CLI",            "cli"),
    ("Acquisition",    "ctrl"),
    ("OS probe",       "probe"),
    ("Refs — identity","ctrl"),
    ("Store — buffer", "ctrl"),
    ("Files on disk",  "store"),
    ("SQLite mirror",  "data"),
    ("Output",         "out"),
]
LI = {n: i for i, (n, _c) in enumerate(LANES)}


def wrap(text, n):
    words, out, cur = text.split(), [], ""
    for w in words:
        if len(cur) + len(w) + 1 <= n:
            cur = f"{cur} {w}".strip()
        else:
            out.append(cur)
            cur = w
    if cur:
        out.append(cur)
    return out


def swimlane(title, note, steps):
    """steps: [(lane_name, label, edge_kind_into_this_step)] — one column each."""
    LBL, COL, BH, LH = 168, 156, 54, 78
    n = len(steps)
    W = LBL + COL * n + 26
    H = 76 + LH * len(LANES) + 46
    s = Svg(W, H)

    s.text(LBL - 4, 32, title, 16, INK, "start", 700)
    s.text(LBL - 4, 52, note, 11, MUTE, "start")

    top = 76
    for i, (lane, cls) in enumerate(LANES):
        y = top + i * LH
        fill, stroke, ink = NODE_CLASS[cls]
        s.rect(0, y, W, LH, fill=("#ffffff05" if i % 2 == 0 else "none"), stroke="none", rx=0)
        s.raw(f'<line x1="0" y1="{y}" x2="{W}" y2="{y}" stroke="{LINE}" stroke-width="1"/>')
        s.raw(f'<rect x="0" y="{y+10}" width="5" height="{LH-20}" rx="2.5" fill="{stroke}"/>')
        s.text(18, y + LH / 2 + 4, lane, 12, ink, "start", 650)
    s.raw(f'<line x1="0" y1="{top+LH*len(LANES)}" x2="{W}" y2="{top+LH*len(LANES)}" stroke="{LINE}" stroke-width="1"/>')
    s.raw(f'<line x1="{LBL-14}" y1="{top}" x2="{LBL-14}" y2="{top+LH*len(LANES)}" stroke="{LINE}" stroke-width="1.5"/>')

    centres = []
    for j, (lane, label, kind) in enumerate(steps):
        li = LI[lane]
        x = LBL + j * COL
        y = top + li * LH + (LH - BH) / 2
        w = COL - 22
        fill, stroke, ink = NODE_CLASS[LANES[li][1]]
        s.rect(x, y, w, BH, fill=fill, stroke=stroke, rx=7)
        lines = wrap(label, 21)[:3]
        y0 = y + BH / 2 - (len(lines) - 1) * 6.5 + 4
        for k, ln in enumerate(lines):
            s.text(x + w / 2, y0 + k * 13, ln, 10, ink, "middle", 600 if k == 0 else 400)
        # centred on the corner, so it never sits on top of the first line of text
        s.raw(f'<circle cx="{x}" cy="{y}" r="10" fill="{BG}" stroke="{stroke}" stroke-width="1.4"/>')
        s.text(x, y + 3.5, str(j + 1), 10, stroke, "middle", 700)
        centres.append((x, y, w, BH, kind))

    for j in range(n - 1):
        x0, y0, w0, h0, _k = centres[j]
        x1, y1, w1, h1, kind = centres[j + 1]
        p0 = (x0 + w0, y0 + h0 / 2)
        p1 = (x1, y1 + h1 / 2)
        xm = (p0[0] + p1[0]) / 2
        pts = [p0, p1] if abs(y0 - y1) < 2 else [p0, (xm, p0[1]), (xm, p1[1]), p1]
        s.edge(None, None, kind, sw=1.9, pts=pts)
    return s.render("dg wide")


def d2_swimlanes():
    S = []
    S.append(swimlane(
        "ORDER A — the scheduled snapshot", "fires every 300 s; the only path that writes fact rows for a point in time",
        [("Trigger", "launchd fires local.sysobs", "sched"),
         ("CLI", "snapshot --files none", "sched"),
         ("Acquisition", "Capture takes the store lock", "ctl"),
         ("OS probe", "12 collectors fork stock binaries", "exec"),
         ("Acquisition", "each result recorded as ok / degraded / error", "exec"),
         ("Refs — identity", "paths, addresses, ports resolved to stable ids", "ctl"),
         ("Store — buffer", "dims deduped, facts buffered", "ctl"),
         ("Acquisition", "spooled process events folded in", "spool"),
         ("Files on disk", "one flush: append facts, rewrite dims", "write"),
         ("Output", "rows written per table", "ctl")]))

    S.append(swimlane(
        "ORDER B — a process that lives three seconds", "never visible to a 5-minute sampler; caught by a separate loop and folded in later",
        [("Trigger", "launchd keeps procwatch alive", "sched"),
         ("Acquisition", "ProcWatch polls every 0.1 s", "ctl"),
         ("OS probe", "libproc lists live pids", "syscall"),
         ("Acquisition", "diff against last tick → start / exit", "ctl"),
         ("Acquisition", "parent bound onto the child at first sight", "ctl"),
         ("Files on disk", "batch appended to the hourly NDJSON spool", "spool"),
         ("Trigger", "next snapshot, up to 5 minutes later", "sched"),
         ("Acquisition", "Ingestor resumes at the stored byte offset", "spool"),
         ("Refs — identity", "argv and exe deduped into dimensions", "ctl"),
         ("Store — buffer", "process_event rows keyed by stable event_id", "ctl"),
         ("Files on disk", "rows land, then the offset advances", "write")]))

    S.append(swimlane(
        "ORDER C — an analyst asks a question", "the mirror is derived, so it must prove itself fresh before it may answer",
        [("Trigger", "operator types a query", "ctl"),
         ("CLI", "query \"SELECT …\"", "ctl"),
         ("SQLite mirror", "compare stored fingerprint to each CSV", "sql"),
         ("Files on disk", "size + sha1 of the common prefix", "read"),
         ("SQLite mirror", "prefix same → append; changed → full reload", "sql"),
         ("Files on disk", "read only the unseen tail", "read"),
         ("SQLite mirror", "INSERT with foreign keys enforced", "sql"),
         ("SQLite mirror", "run the query read-only", "sql"),
         ("Output", "aligned table or --json", "ctl")]))

    S.append(swimlane(
        "ORDER D — proving the log is sound", "reads the CSVs directly and ignores the mirror, so the two can disagree out loud",
        [("Trigger", "operator or CI", "ctl"),
         ("CLI", "verify", "ctl"),
         ("Files on disk", "every table read into memory", "read"),
         ("Store — buffer", "headers checked against the schema", "ctl"),
         ("Store — buffer", "primary keys unique and non-blank", "ctl"),
         ("Refs — identity", "declared foreign keys resolve", "ctl"),
         ("Refs — identity", "composite parents exist in the same snapshot", "ctl"),
         ("Store — buffer", "dimension lifetimes and snapshot completeness", "ctl"),
         ("Output", "findings, exit 1 if any", "ctl")]))

    S.append(swimlane(
        "ORDER E — weekly prune", "the only path that removes data; dimensions go last, and only once unreferenced",
        [("Trigger", "launchd, Sunday 04:15", "sched"),
         ("CLI", "prune --days 14 --go", "sched"),
         ("Store — buffer", "take the exclusive lock", "lock"),
         ("Files on disk", "snapshots older than the cutoff identified", "read"),
         ("Files on disk", "dependent fact rows rewritten without them", "write"),
         ("Refs — identity", "which dimension rows are still referenced?", "ctl"),
         ("Files on disk", "unreferenced dimension rows dropped", "write"),
         ("Files on disk", "fully-ingested spool files past the replay window", "spool"),
         ("Output", "rows removed per table", "ctl")]))
    return S


# ================================================================ D3 classes
def _cbox(s, nid, x, y, w, stereo, name, attrs=(), ops=(), cls="ctrl"):
    """A UML class rectangle: stereotype + name, then attributes, then operations."""
    fill, stroke, ink = NODE_CLASS[cls]
    hh = 40 if stereo else 26
    ah = (len(attrs) * 14 + 10) if attrs else 0
    oh = (len(ops) * 14 + 10) if ops else 0
    h = hh + ah + oh
    s.boxes[nid] = (x, y, w, h)
    s.rect(x, y, w, h, fill=fill, stroke=stroke, rx=5)
    if stereo:
        s.text(x + w / 2, y + 15, f"«{stereo}»", 9.5, MUTE, "middle", 600)
        s.text(x + w / 2, y + 31, name, 12.5, ink, "middle", 700)
    else:
        s.text(x + w / 2, y + 18, name, 12.5, ink, "middle", 700)
    yy = y + hh
    if attrs:
        s.raw(f'<line x1="{x}" y1="{yy}" x2="{x+w}" y2="{yy}" stroke="{stroke}" stroke-width="1"/>')
        for i, a in enumerate(attrs):
            s.text(x + 10, yy + 15 + i * 14, a, 9.5, INK, "start", 400,
                   family="ui-monospace,SFMono-Regular,Menlo,monospace", opacity=.85)
        yy += ah
    if ops:
        s.raw(f'<line x1="{x}" y1="{yy}" x2="{x+w}" y2="{yy}" stroke="{stroke}" stroke-width="1"/>')
        for i, o in enumerate(ops):
            s.text(x + 10, yy + 15 + i * 14, o, 9.5, INK, "start", 400,
                   family="ui-monospace,SFMono-Regular,Menlo,monospace", opacity=.85)
    return h


def _rel(s, p0, p1, kind="assoc", label="", pts=None, route="auto", mid=None, card="", label_xy=None):
    styles = {"assoc": ("", "url(#ah-open)", ""), "dep": ("5 4", "url(#ah-open)", ""),
              "gen": ("", "url(#m-inh)", ""), "comp": ("", "url(#m-comp)", ""),
              "agg": ("", "url(#m-agg)", "")}
    dash, head, _ = styles[kind]
    pts = pts or s._route(p0, p1, route, mid)
    d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    da = f' stroke-dasharray="{dash}"' if dash else ""
    s.raw(f'<polyline points="{d}" fill="none" stroke="{INK}" stroke-width="1.4" '
          f'opacity="0.62" stroke-linejoin="round"{da} marker-end="{head}"/>')
    if label:
        lx, ly = label_xy or s._label_pos(pts, "mid")
        tw = len(label) * 5.3 + 10
        s.rect(lx - tw / 2, ly - 8.5, tw, 16, fill=BG, stroke="none", rx=3)
        s.text(lx, ly + 3.5, label, 9.5, MUTE, "middle", 600)
    if card:
        s.text(pts[-2][0] + 6, pts[-1][1] - 6, card, 9, MUTE, "start", 600)


DIMS = ["host", "volume", "disk_device", "interface", "file",
        "argv", "command", "ip_address", "port"]
FACTS = ["snapshot", "collector_run", "host_sample", "power_sample", "process",
         "process_sample", "process_net_sample", "volume_sample", "disk_io_sample",
         "interface_sample", "process_file", "socket", "process_event"]


def d3_classes():
    s = Svg(1820, 1580)
    B, R = lambda *a, **k: _cbox(s, *a, **k), lambda *a, **k: _rel(s, *a, **k)
    A = s.a

    # ---------------- row 1 ----------------
    s.group(30, 60, 420, 372, "«boundary»  ACTORS AND THE ONE ENTRY POINT", "#9ca3af")
    B("Operator",  50, 108, 180, "actor", "Operator", (), ("runs ad-hoc",), "actor")
    B("Scheduler", 250, 108, 180, "actor", "Scheduler", ("launchd agent",), ("fires on time",), "actor")
    B("Analyst",   50, 226, 180, "actor", "Analyst", (), ("asks in SQL",), "actor")
    B("Cli",       50, 320, 380, "boundary", "Cli",
      ("+ version", "+ schema_version"),
      ("+ dispatch(argv) : int", "+ exit: 0 ok | 1 finding | 2 usage"), "cli")

    s.group(480, 60, 560, 372, "«control»  ACQUISITION", "#a371f7")
    B("Capture", 500, 108, 250, "control", "Capture",
      ("- snapshot_id", "- files_mode, rdns, geo"),
      ("+ run() : SnapshotId", "- collect(name, fn)"))
    B("ProcWatch", 770, 108, 250, "control", "ProcWatch",
      ("- live : Map<pid, Record>", "- interval = 0.1 s"),
      ("+ baseline() : int", "+ tick() : Event[]", "- bind_parents(records)"))
    B("Collector", 500, 286, 250, "control", "Collector",
      ("+ name", "+ status : ok|degraded|error"),
      ("+ collect() : (rows, msg)",))
    B("Ingestor", 770, 286, 250, "control", "Ingestor",
      ("- keep_hours = 6",),
      ("+ ingest(store, refs)", "+ commit(offsets)"))

    s.group(1070, 60, 720, 372, "«adapter»  OBSERVATION SURFACE", "#f0a020")
    B("Probe", 1290, 108, 250, "interface", "Probe",
      ("+ kind : exec|syscall|egress",), ("+ read() : Reading",), "probe")
    B("ExecProbe", 1090, 286, 200, None, "ExecProbe",
      ("ps, lsof, netstat,", "nettop, top, vm_stat,", "iostat, df, ioreg, sysctl"), (), "probe")
    B("SyscallProbe", 1310, 286, 210, None, "SyscallProbe",
      ("libproc via ctypes:", "proc_pidinfo, proc_pidpath,", "proc_listpids"), (), "probe")
    B("EgressProbe", 1540, 286, 230, None, "EgressProbe",
      ("system resolver (PTR),", "ip-api.com (HTTP)", "— opt-in, default off"), (), "ext")

    # ---------------- row 2 ----------------
    s.group(30, 462, 560, 370, "«control»  NORMALISATION", "#a371f7")
    B("Refs", 50, 510, 250, "control", "Refs",
      ("- idx : Map<table, rows>",),
      ("+ file(path) : FileId", "+ command(exe) : CommandId", "+ address(a) : AddressId",
       "+ port(proto, n) : PortId", "+ argv(text) : ArgvId"))
    B("Store", 320, 510, 250, "control", "Store",
      ("- dims, facts (buffered)",),
      ("+ dim(table, row, seen)", "+ fact(table, row)", "+ flush() : counts",
       "+ read(table) : rows", "+ replace(table, rows)"))
    B("StoreLock", 50, 700, 250, "control", "StoreLock",
      ("- timeout = 120 s",), ("+ enter() / exit()",), "lock")
    B("SchemaRegistry", 320, 700, 250, "control", "SchemaRegistry",
      ("+ SCHEMA : Map<name, Table>",), ("+ ddl() : str", "+ sql_type(col) : str"), "ctrl")

    s.group(620, 462, 560, 370, "«control»  MAINTENANCE AND ANALYSIS", "#58a6ff")
    B("Verifier", 640, 510, 250, "control", "Verifier",
      ("- findings : Finding[]",),
      ("+ verify(store) : Report", "checks header, pk, fk,", "parent, lifetime, completeness"))
    B("MirrorBuilder", 910, 510, 250, "control", "MirrorBuilder",
      ("- fingerprints",),
      ("+ build(store, rebuild)", "+ is_stale() : bool", "- prefix_sha1(path, n)"))
    B("Pruner", 640, 700, 250, "control", "Pruner",
      ("- days, go",), ("+ prune() : removed", "- gc_dimensions()"))
    B("Reader", 910, 700, 250, "control", "Reader",
      ("list · show · top · events",), ("+ render(as_json) : int",))

    s.group(1210, 462, 580, 370, "«artifact»  DURABLE STATE", "#3fb950")
    B("CsvTable",     1230, 506, 260, "artifact", "CsvTable",
      ("header from the schema",), ("append() / rewrite()",), "store")
    B("SqliteMirror", 1510, 506, 260, "artifact", "SqliteMirror",
      ("PRAGMA foreign_keys = ON",), ("derived — always rebuildable",), "data")
    B("Spool",        1230, 630, 260, "artifact", "Spool",
      ("procwatch-YYYYMMDDTHH",), ("NDJSON, append-only",), "spool")
    B("OffsetCursor", 1510, 630, 260, "artifact", "OffsetCursor",
      ("byte offset per file",), ("advances after flush",), "spool")
    B("LockFile",     1230, 742, 260, "artifact", "LockFile",
      (".store.lock",), ("advisory flock",), "lock")
    B("MirrorSource", 1510, 742, 260, "artifact", "MirrorSource",
      ("size + sha1(prefix)",), ("detects edit vs append",), "data")

    # ---------------- row 3: the schema itself ----------------
    s.group(30, 862, 1760, 600, "«entity»  THE SCHEMA — ONE DECLARATION DRIVES CSV HEADERS, SQL DDL AND THE CHECKER", "#58a6ff")
    B("Table", 730, 906, 340, "abstract", "Table",
      ("+ name", "+ kind : dim | fact", "+ columns[]", "+ pk[]", "+ fks : Map<col,(table,col)>"),
      ("+ path : CsvTable",), "data")
    B("FactParent", 1420, 906, 340, "constraint", "FactParent",
      ("composite parent keys a single",), ("column cannot express:",
       "process_sample, process_net_sample,", "process_file, socket → process"), "data")
    B("Provenance", 60, 906, 340, "note", "Provenance",
      ("collector_run records what each",), ("collector managed to see —",
       "a gap is recorded, never implied"), "out")
    B("Dimension", 470, 1058, 300, "entity", "Dimension",
      ("deduped across all time", "+ first_seen  + last_seen"), (), "store")
    B("Fact", 1070, 1058, 300, "entity", "Fact",
      ("one set per snapshot", "append-only"), (), "data")

    dy, dw, dg = 1200, 176, 12
    for i, n in enumerate(DIMS):
        x = 70 + i * (dw + dg)
        s.box(f"d_{n}", x, dy, dw, 38, n, "", "store", rx=5, tsize=11)
    fy1, fw, fg = 1290, 220, 14
    for i, n in enumerate(FACTS[:7]):
        s.box(f"f_{n}", 100 + i * (fw + fg), fy1, fw, 38, n, "", "data", rx=5, tsize=11)
    fy2 = 1360
    for i, n in enumerate(FACTS[7:]):
        s.box(f"f_{n}", 215 + i * (fw + fg), fy2, fw, 38, n, "", "data", rx=5, tsize=11)
    s.text(70, 1428, "9 dimensions  ·  13 facts  ·  every foreign key declared in the schema is checked by the Verifier and enforced again by SQLite",
           11, MUTE)

    # ---------------- relationships ----------------
    R(A("Operator", "b"), A("Cli", "t", 0.18), "assoc")
    R(A("Scheduler", "b"), A("Cli", "t", 0.72), "assoc")
    R(A("Analyst", "r"), A("Cli", "t", 0.45), "assoc", pts=[(230, 260), (330, 260), (330, 320)])
    for tgt, t in (("Capture", 0.30), ("ProcWatch", 0.30), ("Ingestor", 0.18)):
        R(A("Cli", "r"), A(tgt, "l", t), "dep", route="h",
          mid=465 if tgt != "Ingestor" else 470)
    R(A("Capture", "b", 0.5), A("Collector", "t", 0.5), "comp", card="1..12")
    R(A("Collector", "r"), A("Ingestor", "l"), "assoc", label="", pts=[(750, 330), (770, 330)])
    R(A("Collector", "b", 0.5), A("Probe", "l"), "dep", label="uses",
      pts=[(625, 388), (625, 424), (1052, 424), (1052, 151), (1290, 151)])
    for sub in ("ExecProbe", "SyscallProbe", "EgressProbe"):
        x, y, w, h = s.boxes[sub]
        R((x + w / 2, y), A("Probe", "b", 0.5), "gen", route="v", mid=262)

    R(A("Capture", "b", 0.18), A("Refs", "t", 0.8), "assoc", label="normalises through",
      pts=[(545, 396), (545, 444), (280, 444), (280, 510)])
    R(A("Ingestor", "b", 0.5), A("Refs", "t", 0.68), "assoc", label="shares the same Refs",
      pts=[(895, 420), (895, 478), (254, 478), (254, 510)])
    R(A("Refs", "r"), A("Store", "l"), "assoc", card="1")
    R(A("Store", "b", 0.3), A("SchemaRegistry", "t", 0.55), "dep", label="headers from",
      pts=[(395, 662), (395, 700)])
    R(A("StoreLock", "r"), A("Store", "b", 0.12), "assoc", label="guards",
      pts=[(300, 724), (310, 724), (310, 662)])
    R(A("StoreLock", "r"), A("LockFile", "l"), "assoc",
      pts=[(300, 760), (600, 760), (600, 844), (1200, 844), (1200, 778), (1230, 778)])
    R(A("Store", "r"), A("CsvTable", "l"), "assoc", label="writes",
      pts=[(570, 545), (1200, 545), (1200, 545), (1230, 545)])
    R(A("ProcWatch", "r"), A("Spool", "t", 0.25), "assoc", label="appends",
      pts=[(1020, 140), (1195, 140), (1195, 612), (1295, 612), (1295, 630)])
    R(A("Ingestor", "r"), A("Spool", "t", 0.75), "assoc", label="drains",
      pts=[(1020, 340), (1186, 340), (1186, 604), (1425, 604), (1425, 630)])
    R(A("Ingestor", "b", 0.9), A("OffsetCursor", "t", 0.5), "assoc", label="commits",
      pts=[(998, 420), (1177, 420), (1177, 596), (1640, 596), (1640, 630)])

    for src, t0, tgt, lab in (("Verifier", 0.5, "CsvTable", "reads all"),
                              ("Pruner", 0.85, "CsvTable", "rewrites"),
                              ("Reader", 0.9, "CsvTable", "reads")):
        x, y, w, h = s.boxes[src]
        R((x + w, y + h * t0), A("CsvTable", "b", 0.2 if src == "Verifier" else (0.5 if src == "Pruner" else 0.8)),
          "assoc", label=lab, route="h", mid=1196)
    R(A("MirrorBuilder", "r"), A("SqliteMirror", "l"), "assoc", label="builds", route="h", mid=1196)
    R(A("MirrorBuilder", "b", 0.7), A("MirrorSource", "b"), "assoc", label="fingerprints",
      pts=[(1085, 626), (1085, 848), (1640, 848), (1640, 830)])
    R(A("Verifier", "b", 0.2), A("SchemaRegistry", "r"), "dep", label="checks against",
      pts=[(690, 626), (690, 745), (570, 745)])

    R(A("SchemaRegistry", "b", 0.5), A("Table", "t", 0.18), "comp", label="declares", card="1..*",
      pts=[(445, 806), (445, 880), (791, 880), (791, 906)], label_xy=(445, 843))
    R(A("Dimension", "t", 0.5), A("Table", "b", 0.32), "gen", route="v", mid=1020)
    R(A("Fact", "t", 0.5), A("Table", "b", 0.7), "gen", route="v", mid=1020)
    R(A("FactParent", "b", 0.3), A("Fact", "r"), "dep", label="constrains",
      pts=[(1522, 1010), (1522, 1088), (1370, 1088)])
    R(A("Table", "l"), A("Provenance", "r"), "dep", pts=[(730, 960), (400, 960)])

    # generalisation buses down to the concrete tables
    s.raw(f'<polyline points="620,1130 620,1168 1596,1168" fill="none" stroke="{INK}" '
          f'stroke-width="1.3" opacity="0.5"/>')
    R(A("Dimension", "b", 0.5), (620, 1130), "gen", pts=[(620, 1168), (620, 1130)])
    for i, n in enumerate(DIMS):
        x = 70 + i * (dw + dg) + dw / 2
        s.raw(f'<line x1="{x}" y1="1168" x2="{x}" y2="{dy}" stroke="{INK}" stroke-width="1.1" opacity="0.45"/>')
    s.raw(f'<polyline points="1192,1130 1192,1258 210,1258" fill="none" stroke="{INK}" '
          f'stroke-width="1.3" opacity="0.5"/>')
    R(A("Fact", "b", 0.5), (1192, 1130), "gen", pts=[(1192, 1258), (1192, 1130)])
    for i, n in enumerate(FACTS[:7]):
        x = 100 + i * (fw + fg) + fw / 2
        s.raw(f'<line x1="{x}" y1="1258" x2="{x}" y2="{fy1}" stroke="{INK}" stroke-width="1.1" opacity="0.45"/>')
    s.raw(f'<polyline points="210,1258 210,1330 1720,1330" fill="none" stroke="{INK}" '
          f'stroke-width="1.3" opacity="0.5"/>')
    for i, n in enumerate(FACTS[7:]):
        x = 215 + i * (fw + fg) + fw / 2
        s.raw(f'<line x1="{x}" y1="1330" x2="{x}" y2="{fy2}" stroke="{INK}" stroke-width="1.1" opacity="0.45"/>')

    s.relabel()

    # legend
    s.group(30, 1490, 1760, 70, "RELATIONSHIP NOTATION", MUTE)
    items = [("assoc", "association — holds and uses"), ("dep", "dependency — calls, does not hold"),
             ("gen", "generalisation — is a kind of"), ("comp", "composition — owns the lifetime")]
    for i, (k, desc) in enumerate(items):
        x = 60 + i * 440
        y = 1530
        _rel(s, (x, y), (x + 60, y), k)
        s.text(x + 72, y + 4, desc, 11, MUTE, "start", 500)
    return s.render()


# ================================================================ D4 use cases
def _stick(s, cx, cy, name, role):
    c = "#9ca3af"
    s.raw(f'<circle cx="{cx}" cy="{cy-26}" r="11" fill="none" stroke="{c}" stroke-width="2"/>'
          f'<line x1="{cx}" y1="{cy-15}" x2="{cx}" y2="{cy+10}" stroke="{c}" stroke-width="2"/>'
          f'<line x1="{cx-16}" y1="{cy-6}" x2="{cx+16}" y2="{cy-6}" stroke="{c}" stroke-width="2"/>'
          f'<line x1="{cx}" y1="{cy+10}" x2="{cx-13}" y2="{cy+30}" stroke="{c}" stroke-width="2"/>'
          f'<line x1="{cx}" y1="{cy+10}" x2="{cx+13}" y2="{cy+30}" stroke="{c}" stroke-width="2"/>')
    s.text(cx, cy + 48, name, 12.5, INK, "middle", 700)
    s.text(cx, cy + 63, role, 9.5, MUTE, "middle")


def _uc(s, nid, cx, cy, label, rx=152, ry=33, colour="#a371f7"):
    s.boxes[nid] = (cx - rx, cy - ry, rx * 2, ry * 2)
    s.raw(f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="#2a2140" stroke="{colour}" stroke-width="1.6"/>')
    lines = wrap(label, 26)[:2]
    y0 = cy - (len(lines) - 1) * 7 + 4.5
    for i, ln in enumerate(lines):
        s.text(cx, y0 + i * 14, ln, 11.5, "#e5d9ff", "middle", 600)


def d4_usecases():
    s = Svg(1470, 960)
    R = lambda *a, **k: _rel(s, *a, **k)
    s.rect(330, 50, 820, 880, fill="#ffffff04", stroke="#58a6ff", rx=14, sw=1.6)
    s.text(740, 906, "s y s o b s", 14, "#58a6ff", "middle", 800, style='letter-spacing="5"')
    s.text(740, 922, "system boundary", 9.5, MUTE, "middle")

    _stick(s, 120, 170, "Operator", "runs it by hand")
    _stick(s, 120, 430, "Scheduler", "launchd, unattended")
    _stick(s, 120, 690, "Analyst", "asks questions of the log")
    _stick(s, 1330, 300, "macOS kernel", "supporting — the source of truth")
    _stick(s, 1330, 660, "ip-api.com", "supporting — opt-in only")

    _uc(s, "u_cap",   540, 175, "Capture a snapshot")
    _uc(s, "u_watch", 540, 275, "Watch process lifecycles")
    _uc(s, "u_look",  540, 420, "Inspect recent snapshots")
    _uc(s, "u_query", 540, 520, "Query the log in SQL")
    _uc(s, "u_verify",540, 650, "Prove the log is sound")
    _uc(s, "u_prune", 540, 745, "Reclaim space")
    _uc(s, "u_self",  540, 840, "Prove the parsers still parse")

    _uc(s, "u_norm",  950, 210, "Normalise identities", 140, 31, "#3fb950")
    _uc(s, "u_fold",  950, 320, "Fold live events into the log", 140, 31, "#3fb950")
    _uc(s, "u_geo",   950, 100, "Resolve names and geography", 140, 31, "#f85149")
    _uc(s, "u_sync",  950, 520, "Refresh the derived mirror", 140, 31, "#3fb950")

    def fan(ax, ay, spine, targets):
        """One vertical spine per actor, so six associations read as a comb
        rather than as one shared bus."""
        for nid in targets:
            x, y, w, h = s.boxes[nid]
            _rel(s, (ax, ay), (x, y + h / 2), "assoc", route="h", mid=spine)
    fan(158, 176, 238, ["u_cap", "u_look", "u_query", "u_verify", "u_prune", "u_self"])
    fan(158, 436, 296, ["u_cap", "u_watch", "u_prune"])
    fan(158, 696, 350, ["u_query", "u_look"])

    _rel(s, (692, 175), (1290, 296), "assoc", pts=[(692, 160), (1200, 160), (1200, 296), (1290, 296)])
    _rel(s, (692, 275), (1290, 310), "assoc", pts=[(692, 290), (1168, 290), (1168, 316), (1290, 316)])
    _rel(s, (1090, 100), (1290, 640), "assoc", pts=[(1090, 100), (1244, 100), (1244, 640), (1290, 640)])

    R(s.a("u_cap", "r"), s.a("u_norm", "l"), "dep", label="«include»")
    R(s.a("u_cap", "r", 0.8), s.a("u_fold", "l", 0.3), "dep", label="«include»", route="h", mid=760)
    R(s.a("u_fold", "t", 0.35), s.a("u_norm", "b", 0.5), "dep", label="«include»")
    R(s.a("u_geo", "l"), s.a("u_cap", "t", 0.62), "dep", label="«extend» — only when asked for",
      pts=[(810, 100), (634, 100), (634, 142)], label_xy=(722, 92))
    R(s.a("u_query", "r"), s.a("u_sync", "l"), "dep", label="«include»")
    s.text(950, 572, "the mirror may only answer once it has proved itself fresh", 10, MUTE, "middle")
    return s.render()


# ================================================================ D5 activity
def _a_start(s, cx, cy):
    s.raw(f'<circle cx="{cx}" cy="{cy}" r="10" fill="{INK}"/>')


def _a_end(s, cx, cy, label=""):
    s.raw(f'<circle cx="{cx}" cy="{cy}" r="13" fill="none" stroke="{INK}" stroke-width="2"/>'
          f'<circle cx="{cx}" cy="{cy}" r="7.5" fill="{INK}"/>')
    if label:
        s.text(cx + 22, cy + 4, label, 10, MUTE, "start", 600)


def _a_act(s, nid, cx, cy, w, label, cls="ctrl", h=None):
    lines = wrap(label, int(w / 6.4))
    h = h or max(46, 22 + len(lines) * 14)
    x, y = cx - w / 2, cy - h / 2
    s.boxes[nid] = (x, y, w, h)
    fill, stroke, ink = NODE_CLASS[cls]
    s.rect(x, y, w, h, fill=fill, stroke=stroke, rx=14)
    y0 = cy - (len(lines) - 1) * 7 + 4
    for i, ln in enumerate(lines):
        s.text(cx, y0 + i * 14, ln, 10.5, ink, "middle", 500)
    return h


def _a_dec(s, nid, cx, cy, label, w=190, h=76):
    s.boxes[nid] = (cx - w / 2, cy - h / 2, w, h)
    s.raw(f'<path d="M{cx},{cy-h/2} L{cx+w/2},{cy} L{cx},{cy+h/2} L{cx-w/2},{cy} Z" '
          f'fill="#332810" stroke="#d29922" stroke-width="1.6"/>')
    lines = wrap(label, 20)[:3]
    y0 = cy - (len(lines) - 1) * 6.5 + 4
    for i, ln in enumerate(lines):
        s.text(cx, y0 + i * 13, ln, 9.5, "#ffe9b0", "middle", 600)


def _a_flow(s, p0, p1, label="", pts=None, route="auto", mid=None, dashed=False):
    pts = pts or s._route(p0, p1, route, mid)
    d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    da = ' stroke-dasharray="5 4"' if dashed else ""
    s.raw(f'<polyline points="{d}" fill="none" stroke="{INK}" stroke-width="1.7" opacity="0.7" '
          f'stroke-linejoin="round"{da} marker-end="url(#ah-open)"/>')
    if label:
        lx, ly = s._label_pos(pts, "mid")
        tw = len(label) * 5.4 + 10
        s.rect(lx - tw / 2, ly - 8.5, tw, 16, fill=BG, stroke="none", rx=3)
        s.text(lx, ly + 3.5, label, 9.5, "#d29922", "middle", 700)


def _activity(title, note, W, H, build):
    s = Svg(W, H)
    s.text(20, 30, title, 14.5, INK, "start", 700)
    s.text(20, 49, note, 10.5, MUTE, "start")
    build(s)
    return s.render("dg act")


def d5_activities():
    out = []

    # ---- A1 ---------------------------------------------------------------
    def a1(s):
        _a_start(s, 300, 92)
        _a_act(s, "n1", 300, 152, 360, "take the exclusive store lock — one writer, 120 s timeout", "lock")
        _a_act(s, "n2", 300, 226, 300, "mint a snapshot id")
        _a_act(s, "n3", 300, 300, 380, "next collector, in the declared order — volumes register mounts before any path is resolved")
        _a_dec(s, "d1", 300, 412, "collector raised?", 180, 78)
        _a_act(s, "ne", 575, 412, 210, "record status = error with the exception text", "ext")
        _a_act(s, "no", 300, 512, 380, "record status = ok or degraded, with rows and duration")
        _a_dec(s, "d2", 300, 606, "more collectors?", 190, 78)
        _a_act(s, "n5", 300, 700, 380, "write the snapshot and collector_run fact rows")
        _a_act(s, "n6", 300, 774, 380, "fold in whatever procwatch spooled since last time", "spool")
        _a_act(s, "n7", 300, 848, 380, "single flush — append facts, rewrite dimensions", "store")
        _a_dec(s, "d3", 300, 946, "events ingested?", 190, 78)
        _a_act(s, "n8", 575, 946, 210, "advance offsets, drop fully-replayed spool files", "spool")
        _a_act(s, "n9", 300, 1046, 300, "release the lock", "lock")
        _a_end(s, 300, 1118)
        F = lambda *a, **k: _a_flow(s, *a, **k)
        F((300, 102), (300, 129))
        F((300, 175), (300, 203)); F((300, 249), (300, 264))
        F((300, 336), (300, 373))
        F((390, 412), (470, 412), "yes")
        F((300, 451), (300, 486), "no")
        F(None, None, pts=[(575, 443), (575, 512), (490, 512)])
        F((300, 538), (300, 567))
        F(None, None, "yes — loop", pts=[(205, 606), (60, 606), (60, 300), (110, 300)])
        F((300, 645), (300, 677), "no")
        F((300, 723), (300, 751)); F((300, 797), (300, 825)); F((300, 871), (300, 907))
        F((395, 946), (470, 946), "yes")
        F((300, 985), (300, 1023), "no")
        F(None, None, pts=[(575, 977), (575, 1004), (300, 1004), (300, 1023)])
        F((300, 1069), (300, 1105))
    out.append(("Capture a snapshot",
                "the only path that writes a point-in-time fact row — and it records its own failures rather than hiding them",
                _activity("Capture a snapshot",
                          "the only path that writes a point-in-time reading; a collector that fails is recorded, not silently skipped",
                          700, 1170, a1)))

    # ---- A2 ---------------------------------------------------------------
    def a2(s):
        _a_start(s, 300, 92)
        _a_act(s, "n1", 300, 152, 340, "sleep for the poll interval (0.1 s)")
        _a_act(s, "n2", 300, 226, 340, "proc_listpids() — the set of pids alive right now", "probe")
        _a_dec(s, "d1", 300, 324, "pid absent from the live map?", 210, 86)
        _a_act(s, "n3", 585, 250, 200, "describe it: proc_pidinfo, proc_pidpath, argv", "probe")
        _a_act(s, "n4", 585, 340, 200, "bind the parent's identity onto the child now")
        _a_act(s, "n5", 585, 424, 200, "emit a start event")
        _a_dec(s, "d2", 300, 470, "in the map but no longer listed?", 210, 86)
        _a_act(s, "n6", 585, 524, 200, "emit an exit event with lifetime and the parent captured at birth")
        _a_act(s, "n7", 300, 626, 340, "buffer the event")
        _a_dec(s, "d3", 300, 730, "200 events buffered, or the flush interval elapsed?", 250, 96)
        _a_act(s, "n8", 585, 730, 200, "append the batch to the hourly NDJSON spool", "spool")
        F = lambda *a, **k: _a_flow(s, *a, **k)
        F((300, 102), (300, 129)); F((300, 175), (300, 203))
        F((300, 249), (300, 281))
        F(None, None, "yes", pts=[(405, 324), (470, 324), (470, 250), (485, 250)])
        F((585, 276), (585, 314)); F((585, 366), (585, 400))
        F(None, None, pts=[(585, 448), (585, 470), (405, 470)])
        F((300, 367), (300, 427), "no")
        F((405, 470), (485, 524), "yes", pts=[(405, 470), (455, 470), (455, 524), (485, 524)])
        F((300, 513), (300, 601), "no")
        F(None, None, pts=[(585, 566), (585, 596), (300, 596), (300, 601)])
        F((300, 649), (300, 682))
        F((425, 730), (485, 730), "yes")
        F(None, None, "not yet — keep buffering",
          pts=[(300, 778), (300, 812), (52, 812), (52, 152), (130, 152)])
        F(None, None, pts=[(585, 762), (585, 812), (300, 812)])
        s.text(20, 868, "99.2% of all processes on this machine die inside a single 5-minute sampling interval.",
               10.5, "#d29922", "start", 600)
        s.text(20, 884, "Without this loop they would never appear in the log at all.", 10.5, MUTE)
    out.append(("Watch process lifecycles", "",
                _activity("Watch process lifecycles",
                          "a 5-minute sampler cannot see a process that lives three seconds; this loop can",
                          700, 910, a2)))

    # ---- A3 ---------------------------------------------------------------
    def a3(s):
        _a_start(s, 300, 92)
        _a_act(s, "n1", 300, 152, 360, "list spool files in the order they were written", "spool")
        _a_act(s, "n2", 300, 226, 360, "seek to the stored byte offset for this file", "spool")
        _a_act(s, "n3", 300, 300, 360, "read whole lines only")
        _a_dec(s, "d1", 300, 396, "trailing partial line?", 200, 82)
        _a_act(s, "ny", 578, 396, 210, "leave it — the writer is mid-append; next run takes it")
        _a_act(s, "n5", 300, 494, 360, "event_id = hash(event, pid, started_at) — stable across replays")
        _a_dec(s, "d2", 300, 596, "already in process_event?", 210, 84)
        _a_act(s, "n6", 578, 596, 210, "skip — re-ingestion must be idempotent")
        _a_act(s, "n7", 300, 694, 360, "resolve argv and exe path through Refs")
        _a_act(s, "n8", 300, 768, 360, "buffer the process_event row", "store")
        _a_act(s, "n9", 300, 842, 360, "flush every buffered row to disk", "store")
        _a_act(s, "n10", 300, 916, 360, "only now write the new offsets", "spool")
        _a_dec(s, "d3", 300, 1014, "fully read, and older than the replay window?", 230, 92)
        _a_act(s, "n11", 578, 1014, 210, "delete the spool file", "spool")
        _a_end(s, 300, 1108)
        F = lambda *a, **k: _a_flow(s, *a, **k)
        for a, b in ((102, 129), (175, 203), (249, 277), (336, 355), (517, 554),
                     (717, 745), (791, 819), (865, 893), (939, 968)):
            F((300, a), (300, b))
        F((400, 396), (473, 396), "yes")
        F((300, 437), (300, 471), "no")
        F(None, None, pts=[(578, 424), (578, 471), (490, 471)])
        F((405, 596), (473, 596), "yes")
        F((300, 638), (300, 671), "no")
        F(None, None, pts=[(578, 624), (578, 671), (490, 671)])
        F((415, 1014), (473, 1014), "yes")
        F((300, 1060), (300, 1095), "no")
        F(None, None, pts=[(578, 1040), (578, 1078), (300, 1078), (300, 1095)])
        s.text(20, 1148, "The offset advances only after the rows it describes are on disk. A crash between the two replays events; it never loses them.",
               10.5, "#d29922", "start", 600)
    out.append(("Fold live events into the log", "",
                _activity("Fold live events into the log",
                          "the snapshot job is the store's single writer, so it is also where the spool is drained",
                          700, 1180, a3)))

    # ---- A4 ---------------------------------------------------------------
    def a4(s):
        _a_start(s, 320, 92)
        _a_act(s, "n1", 320, 156, 380, "for each table: current size, and sha1 of the first N bytes", "data")
        _a_dec(s, "d1", 320, 268, "prefix identical to the stored fingerprint?", 250, 96)
        _a_act(s, "n2", 600, 268, 200, "a stored row was edited — drop and reload in full", "ext")
        _a_dec(s, "d2", 320, 410, "file grown?", 180, 76)
        _a_act(s, "nn", 95, 410, 150, "nothing to do")
        _a_act(s, "n3", 320, 512, 300, "insert only the unseen tail", "data")
        _a_act(s, "n5", 320, 618, 340, "record the new fingerprint in _mirror_source", "data")
        _a_dec(s, "d3", 320, 716, "more tables?", 190, 78)
        _a_act(s, "n6", 320, 812, 340, "PRAGMA foreign_key_check", "data")
        _a_end(s, 320, 886)
        F = lambda *a, **k: _a_flow(s, *a, **k)
        F((320, 102), (320, 131)); F((320, 181), (320, 220))
        F((445, 268), (500, 268), "no")
        F((320, 316), (320, 372), "yes")
        F((230, 410), (170, 410), "no")
        F((320, 448), (320, 489), "yes")
        F(None, None, pts=[(600, 296), (600, 570), (320, 570), (320, 595)])
        F(None, None, pts=[(95, 434), (95, 570), (320, 570)])
        F((320, 535), (320, 570))
        F((320, 641), (320, 677))
        F(None, None, "yes", pts=[(225, 716), (45, 716), (45, 156), (130, 156)])
        F((320, 755), (320, 789), "no")
        F((320, 835), (320, 873))
        s.text(20, 924, "Exact, not a heuristic: an identical prefix proves nothing before that offset changed, so the tail is safe to append.",
               10.5, "#d29922", "start", 600)
    out.append(("Refresh the derived mirror", "",
                _activity("Refresh the derived mirror",
                          "incremental where it is provably safe, full reload the moment it is not",
                          760, 950, a4)))

    # ---- A5 ---------------------------------------------------------------
    def a5(s):
        _a_start(s, 300, 92)
        _a_act(s, "n1", 300, 152, 400, "read all 22 CSV tables — the mirror is never consulted", "store")
        _a_act(s, "n2", 300, 228, 400, "every header matches the schema, column for column")
        _a_act(s, "n3", 300, 302, 400, "primary keys unique, and no component blank")
        _a_act(s, "n4", 300, 390, 400, "declared foreign keys resolve — an empty value is an allowed absence, a wrong one is not")
        _a_act(s, "n5", 300, 486, 400, "composite parents exist in the same snapshot")
        _a_act(s, "n6", 300, 560, 400, "no dimension whose last_seen precedes its first_seen")
        _a_act(s, "n7", 300, 646, 400, "every snapshot carries the fact rows it is required to have")
        _a_dec(s, "d1", 300, 748, "any findings?", 190, 78)
        _a_act(s, "n8", 570, 748, 210, "print table, column and the offending value", "ext")
        _a_end(s, 570, 858, "exit 1 — a finding")
        _a_end(s, 300, 858, "exit 0 — sound")
        F = lambda *a, **k: _a_flow(s, *a, **k)
        for a, b in ((102, 129), (175, 205), (251, 279), (325, 353), (427, 463),
                     (509, 537), (583, 617), (675, 709)):
            F((300, a), (300, b))
        F((395, 748), (465, 748), "yes")
        F((300, 787), (300, 843), "no")
        F((570, 776), (570, 843))
        s.text(20, 908, "ppid pointing at a process that already exited is recorded as a note, not a finding — the machine really does produce orphans.",
               10.5, "#d29922", "start", 600)
    out.append(("Prove the log is sound", "",
                _activity("Prove the log is sound",
                          "checked against the schema rather than a hand-kept list, so a new table cannot be forgotten",
                          700, 936, a5)))
    return out


# ================================================================ D6 components
def _comp(s, x, y, w, h, name, stereo="component", cls="ctrl"):
    fill, stroke, ink = NODE_CLASS[cls]
    s.rect(x, y, w, h, fill=fill, stroke=stroke, rx=9, sw=1.6)
    if stereo:
        s.text(x + 14, y + 19, f"«{stereo}»", 9, MUTE, "start", 600)
        s.text(x + 14, y + 34, name, 12.5, ink, "start", 700)
    else:
        s.text(x + 14, y + 22, name, 12, ink, "start", 700)


def _leaves(s, x, y, w, names, cols, bw, bh, gx, gy, cls="out", fs=9.5):
    for i, n in enumerate(names):
        c, r = i % cols, i // cols
        bx, by = x + c * (bw + gx), y + r * (bh + gy)
        fill, stroke, ink = NODE_CLASS[cls]
        s.rect(bx, by, bw, bh, fill=fill, stroke=stroke, rx=4, sw=1.1)
        s.text(bx + bw / 2, by + bh / 2 + 3.5, n, fs, ink, "middle", 500,
               family="ui-monospace,SFMono-Regular,Menlo,monospace")


def d6_components():
    out = []

    # ---- CD1: the executable ---------------------------------------------
    s = Svg(1470, 700)
    _comp(s, 20, 46, 1430, 620, "sysobs", "executable", "cli")
    s.text(1436, 66, "one file · no third-party imports · Python 3 stdlib only", 10, MUTE, "end")

    _comp(s, 48, 106, 330, 222, "Command dispatch", "component")
    _leaves(s, 64, 146, 298, ["snapshot", "watch", "procwatch", "events", "list", "show",
                              "top", "verify", "db", "query", "schema", "prune", "selftest"],
            3, 92, 28, 11, 8, "cli")

    _comp(s, 398, 106, 350, 222, "Acquisition", "component")
    _leaves(s, 414, 146, 320, ["Capture", "ProcWatch", "Ingestor"], 3, 100, 28, 10, 8, "ctrl")
    _comp(s, 414, 190, 320, 130, "Collectors — 12, in declared order", None, "out")
    _leaves(s, 422, 214, 304, ["host", "volume", "power", "host_sample", "disk_io", "interface",
                               "process", "process_net", "socket", "file", "rdns", "geo"],
            3, 96, 20, 8, 5, "probe", 8.5)

    _comp(s, 768, 106, 300, 222, "Normalisation and write control", "component")
    _leaves(s, 784, 152, 268, ["Refs", "Store", "StoreLock", "SchemaRegistry"], 2, 129, 34, 10, 12, "ctrl")

    _comp(s, 1088, 106, 334, 222, "Analysis and maintenance", "component")
    _leaves(s, 1104, 152, 302, ["Verifier", "MirrorBuilder", "Pruner", "Readers",
                                "QueryEngine", "SelfTest"], 2, 146, 34, 10, 10, "ctrl")

    _comp(s, 48, 350, 700, 290, "Observation adapters — stock macOS, nothing installed", "component", "probe")
    _leaves(s, 64, 396, 668, ["ps", "lsof", "netstat", "nettop", "top",
                              "vm_stat", "iostat", "df", "mount", "ioreg",
                              "sysctl", "pgrep", "libproc", "resolver (PTR)", "ip-api.com"],
            5, 128, 34, 7, 12, "probe")
    s.text(64, 600, "the last two are off-box and opt-in; the rest read only what the kernel already publishes", 10, MUTE)

    _comp(s, 768, 350, 654, 290, "Schema — one declaration, three consumers", "component", "data")
    _leaves(s, 784, 390, 622, ["Table", "Dimension", "Fact", "FactParent"], 4, 151, 30, 6, 6, "data")
    _comp(s, 784, 434, 304, 196, "Dimensions — 9", None, "out")
    _leaves(s, 792, 460, 288, DIMS, 2, 140, 21, 8, 3, "store", 8.5)
    _comp(s, 1102, 434, 304, 196, "Facts — 13", None, "out")
    _leaves(s, 1110, 460, 288, FACTS, 2, 140, 21, 8, 3, "data", 8.5)
    out.append(("The executable", "nesting only — what contains what, with no claim about who calls whom", s.render()))

    # ---- CD2: durable state ----------------------------------------------
    s = Svg(720, 470)
    _comp(s, 16, 40, 688, 410, "~/.local/state/sysobs", "artifact store", "store")
    _comp(s, 40, 100, 400, 250, "tables/", "directory", "out")
    _comp(s, 56, 146, 176, 188, "9 dimension tables", None, "store")
    _leaves(s, 66, 172, 156, DIMS, 1, 156, 17, 0, 2, "store", 8.5)
    _comp(s, 248, 146, 176, 188, "13 fact tables", None, "data")
    _leaves(s, 258, 172, 156, FACTS, 1, 156, 11.5, 0, 1.5, "data", 7.5)
    _comp(s, 460, 100, 226, 120, "spool/", "directory", "spool")
    _leaves(s, 476, 146, 194, ["procwatch-YYYYMMDDTHH.ndjson", "offsets.json"], 1, 194, 26, 0, 8, "spool", 8.5)
    _comp(s, 460, 236, 226, 114, "derived — rebuildable", None, "data")
    _leaves(s, 476, 276, 194, ["sysobs.sqlite", "_mirror_source"], 1, 194, 26, 0, 8, "data", 9)
    _comp(s, 40, 368, 646, 62, "coordination", None, "lock")
    _leaves(s, 56, 394, 300, [".store.lock"], 1, 300, 24, 0, 0, "lock", 9)
    s.text(372, 411, "advisory flock — the snapshot job is the store's single writer", 9.5, MUTE)
    out.append(("Durable state", "the log, the replay window, and the one derived artefact that may be deleted at any time", s.render("dg half")))

    # ---- CD3: scheduling --------------------------------------------------
    s = Svg(720, 470)
    _comp(s, 16, 40, 688, 410, "launchd — user domain, gui/501", "runtime surface", "actor")
    agents = [("local.sysobs", "snapshot --files none", "StartInterval 300 s · RunAtLoad", 100),
              ("local.sysobs-procwatch", "procwatch", "RunAtLoad · KeepAlive", 186),
              ("local.sysobs-prune", "prune --days 14 --go", "StartCalendarInterval Sun 04:15", 272),
              ("local.example-agent", "setenv OLLAMA_MAX_LOADED_MODELS 1", "RunAtLoad · one-shot", 358)]
    for name, cmd, when, y in agents:
        _comp(s, 40, y, 420, 74, name, None, "ctrl")
        s.text(56, y + 44, cmd, 9.5, MUTE, "start", 400, family="ui-monospace,Menlo,monospace")
        s.text(56, y + 60, when, 9, "#39d0d8", "start", 600)
    _comp(s, 480, 100, 206, 332, "~/.config/svc/services.d/", "registry", "out")
    _leaves(s, 496, 146, 174, ["local.sysobs.json", "…-prune.json", "…-procwatch.json",
                               "ollama-env.json"], 1, 174, 30, 0, 10, "out", 8.5)
    s.text(496, 340, "svc list / show / logs / health", 9.5, "#58a6ff", "start", 600)
    s.text(496, 356, "is the console for everything", 9, MUTE)
    s.text(496, 370, "launchd runs for this user", 9, MUTE)
    out.append(("Scheduling and registration", "containment only: which agent holds which invocation, and where each is declared", s.render("dg half")))

    # ---- CD4: observable domains -----------------------------------------
    s = Svg(1470, 400)
    _comp(s, 16, 40, 1438, 340, "What the log can account for, grouped by the question it answers", "domain map", "data")
    groups = [("Who is running", ["process", "process_sample", "process_event", "command", "argv"], 40),
              ("Where it lives", ["file", "process_file", "volume", "volume_sample"], 328),
              ("What it moved", ["socket", "process_net_sample", "ip_address", "port", "interface_sample"], 616),
              ("What it cost", ["host_sample", "disk_io_sample", "disk_device", "interface"], 904),
              ("What it was given", ["power_sample", "snapshot", "collector_run", "host"], 1192)]
    for title, tables, x in groups:
        _comp(s, x, 100, 262, 258, title, None, "out")
        _leaves(s, x + 14, 140, 234, tables, 1, 234, 30, 0, 8, "data", 9)
    s.text(40, 392, "every one of these is reachable from snapshot_id, and every cross-reference is a declared foreign key",
           10.5, MUTE)
    out.append(("Observable domains", "the same 22 tables, contained by the question each answers rather than by module", s.render()))
    return out


# ================================================================ page
CSS = """
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:#0d1117;color:#e6edf3;
  font:15px/1.6 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:#58a6ff;text-decoration:none}
header{padding:56px 40px 30px;border-bottom:1px solid #30363d;
  background:radial-gradient(1200px 320px at 12% -10%,#1b2a3a 0%,#0d1117 68%)}
header h1{margin:0;font-size:34px;letter-spacing:-.6px;font-weight:800}
header .sub{color:#8b949e;margin-top:10px;max-width:960px;font-size:15px}
header .meta{margin-top:20px;display:flex;flex-wrap:wrap;gap:10px}
header .meta span{border:1px solid #30363d;border-radius:999px;padding:5px 13px;
  font-size:11.5px;color:#8b949e;background:#161b22}
nav{position:sticky;top:0;z-index:20;background:#0d1117ee;backdrop-filter:blur(10px);
  border-bottom:1px solid #30363d;padding:11px 40px;display:flex;gap:9px;flex-wrap:wrap}
nav a{font-size:12px;color:#8b949e;border:1px solid #30363d;border-radius:7px;padding:6px 12px}
nav a:hover{color:#e6edf3;border-color:#58a6ff;background:#161b22}
main{padding:0 40px 90px;max-width:1900px;margin:0 auto}
section{padding-top:56px}
h2{font-size:24px;margin:0 0 6px;letter-spacing:-.3px}
h2 .n{color:#58a6ff;font-variant-numeric:tabular-nums;margin-right:12px;font-weight:800}
.lede{color:#8b949e;max-width:1080px;margin:0 0 22px;font-size:14.5px}
.card{background:#0f141b;border:1px solid #30363d;border-radius:14px;padding:20px;margin-bottom:22px;overflow:hidden}
.card h3{margin:0 0 4px;font-size:15px;font-weight:700}
.card .cap{color:#8b949e;font-size:12.5px;margin:0 0 14px}
svg.dg{display:block;width:100%;height:auto}
.scroll{overflow-x:auto;overflow-y:hidden}
.scroll svg.wide{min-width:1180px}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(430px,1fr));gap:22px}
.grid3{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:22px}
.note{border-left:3px solid #d29922;background:#1a1610;padding:12px 16px;border-radius:0 8px 8px 0;
  color:#d6c9a8;font-size:13px;margin:16px 0}
.note b{color:#f0c674}
footer{border-top:1px solid #30363d;padding:28px 40px 60px;color:#8b949e;font-size:12.5px}
@media print{
  body{background:#fff;color:#111}
  nav{display:none}
  .card{break-inside:avoid;border-color:#bbb}
  section{break-before:page}
}
"""

SECTIONS = [
    ("pathways",  "01", "Communication pathways",
     "Every distinct channel in the system, with its direction and its type. Type is carried twice — once as "
     "colour and once as a glyph on the line — so the diagram still reads in greyscale. A double-headed line is a "
     "request going one way and data returning the other over the same channel."),
    ("swimlanes", "02", "Flow orders, in swimlanes",
     "The same nine participants, five times over. What changes between them is the order in which the lanes are "
     "visited — which is the whole design: a scheduled snapshot, a process too short-lived for one, an analyst's "
     "question, a proof of soundness, and the only path that deletes anything."),
    ("classes",   "03", "One logical class model",
     "Every element that appears in any other diagram on this page appears here once, with its responsibilities and "
     "its relationships. This is the vocabulary the rest of the page is drawn from."),
    ("usecases",  "04", "Use cases",
     "Who wants what from the system, and which behaviours are always included versus only sometimes extended. "
     "Note that two of the five actors are supporting actors: the system depends on them, they never initiate."),
    ("activity",  "05", "Activity — five scenarios",
     "The control flow inside the five behaviours that carry the most risk. Each one's decision points are where a "
     "naive implementation would quietly lose or corrupt data."),
    ("components","06", "Component containment",
     "Structure with the connections deliberately removed. No interfaces, no dependencies, no arrows — only what "
     "contains what. Read alongside diagram 01, which supplies everything omitted here."),
]


def page():
    d1 = d1_pathways()
    d2 = d2_swimlanes()
    d3 = d3_classes()
    d4 = d4_usecases()
    d5 = d5_activities()
    d6 = d6_components()

    nav = "".join(f'<a href="#{sid}">{n} · {t}</a>' for sid, n, t, _d in SECTIONS)
    h = [f'<!doctype html><html lang="en"><head><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         '<title>sysobs — logical architecture</title>',
         f'<style>{CSS}</style></head><body>',
         '<header><h1>sysobs — logical architecture</h1>',
         '<p class="sub">A per-PID system telemetry recorder: processes, CPU, memory, disk, network, open files, '
         'ports, addresses and power delivery, normalised into a star schema with enforced referential integrity. '
         'Every diagram below is logical — it describes roles and responsibilities, never hosts, processes or files '
         'on a particular machine.</p>',
         '<div class="meta">'
         '<span>6 diagram families</span><span>9 dimensions · 13 facts</span>'
         '<span>12 collectors</span><span>13 subcommands</span>'
         '<span>single file · stdlib only</span><span>schema is the single source of truth</span>'
         '</div></header>',
         f'<nav>{nav}</nav><main>']

    def sec(sid):
        n, t, d = next((a, b, c) for s, a, b, c in SECTIONS if s == sid)
        return f'<section id="{sid}"><h2><span class="n">{n}</span>{t}</h2><p class="lede">{d}</p>'

    h.append(sec("pathways"))
    h.append(f'<div class="card"><h3>All pathways, typed</h3>'
             f'<p class="cap">Triggers at the top; the observation surface and the durable state are the only two '
             f'places data crosses a boundary.</p><div class="scroll">{d1}</div></div>')
    h.append('<div class="note"><b>Read the arrowheads.</b> The probe pathways are double-headed on purpose: '
             'sysobs never instruments anything, so every reading is a question asked of a stock macOS binary and an '
             'answer parsed back out of its stdout. The two red pathways are the only ones that leave the machine, '
             'and both are off unless explicitly asked for.</div></section>')

    h.append(sec("swimlanes"))
    for svg in d2:
        h.append(f'<div class="card"><div class="scroll">{svg}</div></div>')
    h.append('<div class="note"><b>Why five.</b> Orders A and B write; C reads; D proves; E deletes. '
             'Every lane exists in every diagram, so the difference between them is purely the path — which is what '
             'makes the sequencing constraints visible. In order B, note that the offset advances <i>after</i> the '
             'rows land, and in order E that dimensions are collected last.</div></section>')

    h.append(sec("classes"))
    h.append(f'<div class="card"><h3>Every element, once</h3>'
             f'<p class="cap">Actors and entry, acquisition, the observation adapters, normalisation and write '
             f'control, maintenance and analysis, durable state, and the schema itself.</p>'
             f'<div class="scroll">{d3}</div></div></section>')

    h.append(sec("usecases"))
    h.append(f'<div class="card"><div class="scroll">{d4}</div></div>')
    h.append('<div class="note"><b>The two dashed relationships are not interchangeable.</b> '
             '«include» means the behaviour always happens — capturing a snapshot always normalises identities. '
             '«extend» means it happens only under a condition — names and geography are resolved only when asked '
             'for, and geography sends public addresses off the machine, which is why it is never the default.'
             '</div></section>')

    h.append(sec("activity"))
    h.append('<div class="grid2">')
    for title, _n, svg in d5:
        h.append(f'<div class="card"><h3>{title}</h3><div class="scroll">{svg}</div></div>')
    h.append('</div></section>')

    h.append(sec("components"))
    h.append(f'<div class="card"><h3>{d6[0][0]}</h3><p class="cap">{d6[0][1]}</p>'
             f'<div class="scroll">{d6[0][2]}</div></div>')
    h.append('<div class="grid2">')
    for title, cap, svg in d6[1:3]:
        h.append(f'<div class="card"><h3>{title}</h3><p class="cap">{cap}</p><div class="scroll">{svg}</div></div>')
    h.append('</div>')
    h.append(f'<div class="card"><h3>{d6[3][0]}</h3><p class="cap">{d6[3][1]}</p>'
             f'<div class="scroll">{d6[3][2]}</div></div>')
    h.append('</section>')

    h.append('</main><footer>Generated from <code>docs/gen_diagrams.py</code>, which reads its element names from '
             'the same schema declaration the CSV headers, the SQLite DDL and the integrity checker are generated '
             'from. Regenerate with <code>python3 docs/gen_diagrams.py</code>.</footer></body></html>')
    return "".join(h)


if __name__ == "__main__":
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(page(), encoding="utf-8")
    print(f"wrote {OUT}  ({OUT.stat().st_size/1024:.0f} KB)")
