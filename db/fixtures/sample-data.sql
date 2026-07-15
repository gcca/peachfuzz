INSERT INTO auth_user (username, role, is_active) VALUES
  ('admin', 1, 1),
  ('jill.valentine', 3, 1),
  ('chris.redfield', 1, 1),
  ('barry.burton', 2, 1),
  ('rebecca.chambers', 2, 1),
  ('albert.wesker', 0, 1),
  ('enrico.marini', 3, 0),
  ('forest.speyer', 3, 0);

INSERT INTO auth_session (token, username, expires_at) VALUES
  ('stars-jill-0001', 'jill.valentine', unixepoch() + 604800),
  ('stars-chris-0001', 'chris.redfield', unixepoch() + 604800),
  ('stars-barry-0001', 'barry.burton', unixepoch() + 604800);

INSERT INTO pages_folder (key, name, description, parent) VALUES
  (1, 'Mansion Incident', 'Case files from the July 1998 incident.', NULL),
  (2, 'Spencer Mansion', 'Locations and systems inside the mansion.', 1),
  (3, 'S.T.A.R.S.', 'Personnel and operations records.', 1),
  (4, 'Umbrella Corporation', 'Corporate and research dossiers.', NULL),
  (5, 'B.O.W. Research', 'Bio Organic Weapon research files.', 4);

INSERT INTO pages_view (name, title, description, engine, body, folder) VALUES
  ('mansion', 'Spencer Mansion', 'Overview of the mansion in the Arklay Mountains.', 3,
'print("<h2>Spencer Mansion</h2>")
print("<p>A palatial mansion in the Arklay Mountains, built by Umbrella as a front over a hidden underground laboratory.</p>")', 2),

  ('stars', 'S.T.A.R.S. Roster', 'Active members of the Special Tactics and Rescue Service.', 3,
'print("<h2>S.T.A.R.S. Roster</h2>")
print("<ul>")
print("<li>Albert Wesker - Alpha Team Captain</li>")
print("<li>Chris Redfield - Alpha Team, point man</li>")
print("<li>Jill Valentine - Alpha Team, tactics expert</li>")
print("<li>Barry Burton - Alpha Team, weapons specialist</li>")
print("<li>Rebecca Chambers - Bravo Team, medic</li>")
print("<li>Enrico Marini - Bravo Team, squad leader</li>")
print("<li>Forest Speyer - Bravo Team, sharpshooter</li>")
print("</ul>")', 3),

  ('umbrella', 'Umbrella Corporation', 'Corporate dossier on the pharmaceutical company behind the outbreak.', 3,
'print("<h2>Umbrella Corporation</h2>")
print("<p>A pharmaceutical giant conducting covert bio-weapons research under the Arklay Mountains laboratory.</p>")', 4),

  ('tyrant', 'B.O.W. File: Tyrant', 'Classified file on Bio Organic Weapon designation T-002.', 3,
'print("<h2>B.O.W. File: Tyrant</h2>")
print("<p>Designation T-002. An engineered bio-organic weapon grown from Umbrella t-Virus research, deployed as a self-destruct failsafe for the laboratory.</p>")', 5),

  ('incident', 'Mansion Incident Timeline', 'Timeline of events during the July 1998 mansion incident.', 3,
'print("<h2>Mansion Incident Timeline</h2>")
print("<ul>")
print("<li>Bravo Team helicopter crashes near the mansion.</li>")
print("<li>Alpha Team is dispatched and finds the wrecked helicopter.</li>")
print("<li>Alpha Team is attacked by feral dogs and takes shelter inside the mansion.</li>")
print("<li>Survivors uncover the underground laboratory beneath the mansion.</li>")
print("</ul>")', 1),

  ('itembox', 'Item Box', 'Shared storage system linking every chest in the mansion.', 3,
'print("<h2>Item Box</h2>")
print("<p>A storage chest that shares its contents with every other item box in the mansion, letting survivors stash gear between rooms.</p>")', 2),

  ('herbs', 'Herb Combination', 'Combine herbs and preview the healing effect (parameterized page).', 3,
'import sys

params = {}
for a in sys.argv[1:]:
    if "=" in a:
        k, v = a.split("=", 1)
        params.setdefault(k, []).append(v)

mix_values = params.get("mix", [])
mix = mix_values[-1] if mix_values else ""

effects = {
    "G": "Green herb: restores a small amount of health.",
    "GG": "Green + Green: restores a moderate amount of health.",
    "GGG": "Green + Green + Green: fully restores health.",
    "GR": "Green + Red: fully restores health.",
    "GB": "Green + Blue: cures poison and restores some health.",
    "GRB": "Green + Red + Blue: full heal and cures poison.",
}

options = ["", "G", "GG", "GGG", "GR", "GB", "GRB"]

print("<h2>Herb Combination</h2>")
print("<form method=\"get\" action=\"/peachfuzz/analyst/pages/herbs\" class=\"flex flex-wrap gap-2 items-end mb-4\">")
print("<label class=\"form-control\"><span class=\"label-text\">Mix</span>")
print("<select name=\"mix\" class=\"select select-bordered\">")
for key in options:
    selected = " selected" if key == mix else ""
    label = key if key else "-- choose --"
    print(f"<option value=\"{key}\"{selected}>{label}</option>")
print("</select></label>")
print("<button class=\"btn btn-primary\" type=\"submit\">Combine</button>")
print("</form>")

if mix:
    effect = effects.get(mix, "Unknown combination.")
    print(f"<div class=\"alert\">{effect}</div>")', 2),

  ('mission-log', 'S.T.A.R.S. Mission Log', 'Filter the mission log by date range and member name (parameterized page).', 3,
'import sys
from datetime import date

params = {}
for a in sys.argv[1:]:
    if "=" in a:
        k, v = a.split("=", 1)
        params.setdefault(k, []).append(v)

def one(key):
    vals = params.get(key, [])
    return vals[-1] if vals else ""

def esc(s):
    s = s.replace("&", "&amp;")
    s = s.replace("<", "&lt;")
    s = s.replace(">", "&gt;")
    s = s.replace("\"", "&quot;")
    return s

def parse_date(s):
    try:
        return date.fromisoformat(s)
    except ValueError:
        return None

date_from = one("from")
date_to = one("to")
member = one("member")

lo = parse_date(date_from)
hi = parse_date(date_to)
needle = member.strip().lower()

log = [
    ("2026-04-23", "Bravo Team", "Helicopter engine failure over the Arklay forest."),
    ("2026-05-24", "Alpha Team", "Dispatched to locate the downed Bravo Team."),
    ("2026-05-24", "Jill Valentine", "Entered the Spencer Mansion through the dining hall."),
    ("2026-06-25", "Chris Redfield", "Discovered the underground laboratory."),
    ("2026-06-25", "Rebecca Chambers", "Recovered the V-JOLT chemical formula."),
    ("2026-07-26", "Alpha Team", "Activated the self-destruct and escaped by helicopter."),
]

rows = []
for d, who, note in log:
    entry = date.fromisoformat(d)
    if lo and entry < lo:
        continue
    if hi and entry > hi:
        continue
    if needle and needle not in who.lower():
        continue
    rows.append((d, who, note))

from_attr = esc(date_from)
to_attr = esc(date_to)
member_attr = esc(member)
count = len(rows)
total = len(log)

print("<h2>S.T.A.R.S. Mission Log</h2>")
print("<form method=\"get\" action=\"/peachfuzz/analyst/pages/mission-log\" class=\"flex flex-wrap gap-2 items-end mb-4\">")
print("<label class=\"form-control\"><span class=\"label-text\">From</span>")
print(f"<input type=\"date\" name=\"from\" value=\"{from_attr}\" class=\"input input-bordered\"></label>")
print("<label class=\"form-control\"><span class=\"label-text\">To</span>")
print(f"<input type=\"date\" name=\"to\" value=\"{to_attr}\" class=\"input input-bordered\"></label>")
print("<label class=\"form-control\"><span class=\"label-text\">Member</span>")
print(f"<input type=\"text\" name=\"member\" value=\"{member_attr}\" placeholder=\"name contains\" class=\"input input-bordered\"></label>")
print("<button class=\"btn btn-primary\" type=\"submit\">Filter</button>")
print("</form>")

print(f"<p class=\"text-sm opacity-70\">Showing {count} of {total} entries.</p>")
print("<table class=\"table\"><thead><tr><th>Date</th><th>Member</th><th>Note</th></tr></thead><tbody>")
for d, who, note in rows:
    who_c = esc(who)
    note_c = esc(note)
    print(f"<tr><td>{d}</td><td>{who_c}</td><td>{note_c}</td></tr>")
print("</tbody></table>")', 3),

  ('bow-registry', 'B.O.W. Threat Registry', 'List Bio Organic Weapons filtered by a numeric threat-level range (parameterized page).', 3,
'import sys

params = {}
for a in sys.argv[1:]:
    if "=" in a:
        k, v = a.split("=", 1)
        params.setdefault(k, []).append(v)

def one(key):
    vals = params.get(key, [])
    return vals[-1] if vals else ""

def esc(s):
    s = s.replace("&", "&amp;")
    s = s.replace("<", "&lt;")
    s = s.replace(">", "&gt;")
    s = s.replace("\"", "&quot;")
    return s

def to_int(s, default):
    try:
        return int(s)
    except ValueError:
        return default

min_raw = one("min")
max_raw = one("max")
lo = to_int(min_raw, 0)
hi = to_int(max_raw, 10)

registry = [
    ("Zombie", 2, "Reanimated staff exposed to the t-Virus."),
    ("Cerberus", 4, "Doberman pack infected by the t-Virus."),
    ("Web Spinner", 5, "Mutated arachnid grown to enormous size."),
    ("Hunter", 7, "Reptilian humanoid bred from a human embryo."),
    ("Chimera", 7, "Insect-human gene splice that clings to ceilings."),
    ("Tyrant", 9, "Designation T-002, the laboratory self-destruct failsafe."),
]

rows = [r for r in registry if lo <= r[1] <= hi]

min_attr = esc(min_raw)
max_attr = esc(max_raw)
count = len(rows)
total = len(registry)

print("<h2>B.O.W. Threat Registry</h2>")
print("<form method=\"get\" action=\"/peachfuzz/analyst/pages/bow-registry\" class=\"flex flex-wrap gap-2 items-end mb-4\">")
print("<label class=\"form-control\"><span class=\"label-text\">Min threat</span>")
print(f"<input type=\"number\" name=\"min\" min=\"0\" max=\"10\" value=\"{min_attr}\" class=\"input input-bordered\"></label>")
print("<label class=\"form-control\"><span class=\"label-text\">Max threat</span>")
print(f"<input type=\"number\" name=\"max\" min=\"0\" max=\"10\" value=\"{max_attr}\" class=\"input input-bordered\"></label>")
print("<button class=\"btn btn-primary\" type=\"submit\">Filter</button>")
print("</form>")

print(f"<p class=\"text-sm opacity-70\">Threat level {lo} to {hi}: {count} of {total} B.O.W.s.</p>")
print("<table class=\"table\"><thead><tr><th>Designation</th><th>Threat</th><th>Notes</th></tr></thead><tbody>")
for name, threat, note in rows:
    name_c = esc(name)
    note_c = esc(note)
    print(f"<tr><td>{name_c}</td><td>{threat}</td><td>{note_c}</td></tr>")
print("</tbody></table>")', 5),

  ('surveillance', 'Mansion Surveillance', 'Query the surveillance archive by a date-and-time value and see it relative to the outbreak (parameterized page).', 3,
'import sys
from datetime import datetime

params = {}
for a in sys.argv[1:]:
    if "=" in a:
        k, v = a.split("=", 1)
        params.setdefault(k, []).append(v)

def one(key):
    vals = params.get(key, [])
    return vals[-1] if vals else ""

def esc(s):
    s = s.replace("&", "&amp;")
    s = s.replace("<", "&lt;")
    s = s.replace(">", "&gt;")
    s = s.replace("\"", "&quot;")
    return s

def parse_dt(s):
    s = s.strip()
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None

outbreak = datetime.fromisoformat("1998-07-24T00:00:00")
at_raw = one("at")
at = parse_dt(at_raw)
at_attr = esc(at_raw)

print("<h2>Mansion Surveillance</h2>")
print("<form method=\"get\" action=\"/peachfuzz/analyst/pages/surveillance\" class=\"flex flex-wrap gap-2 items-end mb-4\">")
print("<label class=\"form-control\"><span class=\"label-text\">Timestamp</span>")
print(f"<input type=\"datetime-local\" name=\"at\" value=\"{at_attr}\" class=\"input input-bordered\"></label>")
print("<button class=\"btn btn-primary\" type=\"submit\">Look up</button>")
print("</form>")

if at is None:
    print("<div class=\"alert\">Enter a date and time to query the surveillance archive.</div>")
else:
    day = at.date().isoformat()
    clock = at.strftime("%H:%M")
    weekday = at.strftime("%A")
    total = (at - outbreak).total_seconds()
    sign = "after" if total >= 0 else "before"
    mins_total = int(abs(total)) // 60
    rel_h = mins_total // 60
    rel_m = mins_total % 60
    print("<table class=\"table\">")
    print(f"<tr><th>Date</th><td>{day} ({weekday})</td></tr>")
    print(f"<tr><th>Time</th><td>{clock}</td></tr>")
    print(f"<tr><th>Relative to outbreak</th><td>{rel_h}h {rel_m}m {sign} the mansion outbreak (1998-07-24 00:00)</td></tr>")
    print("</table>")', 2);
