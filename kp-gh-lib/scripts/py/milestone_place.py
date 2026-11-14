import json
import os
import re
import subprocess
import sys

gate_script, milestone_of_script, project, repo, cache, origin, parent = sys.argv[1:]

MILESTONE_ID = re.compile(r"M(\d+)")
ITEM_REF = re.compile(r"[^/\s]+/[^/\s#]+#\d+")


def fail(message):
    print(f"milestone-place.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run(*command):
    """The command's stdout; exit 1 when it fails. Its stderr passes straight through."""
    result = subprocess.run(command, stdout=subprocess.PIPE, text=True)
    if result.returncode != 0:
        fail(f"{os.path.basename(command[0])} exited {result.returncode}")
    return result.stdout


def is_current_shape(value):
    if not isinstance(value, dict) or not isinstance(value.get("epics"), list):
        return False
    if not all(isinstance(epic, str) and ITEM_REF.fullmatch(epic) for epic in value["epics"]):
        return False
    milestone = value.get("milestone", "")
    if milestone is None:
        return True
    return isinstance(milestone, str) and bool(MILESTONE_ID.fullmatch(milestone)) \
        and bool(value["epics"])


def current_milestone():
    if os.path.exists(cache):
        try:
            with open(cache) as cached:
                current = json.load(cached)
        except (OSError, ValueError) as error:
            fail(f"cannot read --cache {cache}: {error}")
        if not is_current_shape(current):
            fail(f"--cache {cache} is not milestone-gate.sh --current output")
        return current
    output = run(gate_script, "--project", project, "--current")
    current = json.loads(output)
    with open(cache, "w") as cached:
        cached.write(output)
    return current


def milestone_of(item):
    item_repo, number = item.split("#")
    return json.loads(run(milestone_of_script, item_repo, number))


def place():
    current = current_milestone()
    if current["milestone"] is None:
        return {"milestone": None, "epic": None, "link": "none"}

    parent_found = milestone_of(parent) if parent else None
    if parent_found and parent_found["milestone"]:
        return {"milestone": parent_found["milestone"], "epic": parent_found["epic"], "link": "none"}
    link = parent_found["root"] if parent_found else "item"

    # An item with no placed parent never goes into a milestone earlier than the current one.
    current_rank = int(MILESTONE_ID.fullmatch(current["milestone"]).group(1))
    origin_found = milestone_of(origin) if origin else None
    if origin_found and origin_found["milestone"] and origin_found["rank"] >= current_rank:
        return {"milestone": origin_found["milestone"], "epic": origin_found["epic"], "link": link}

    in_repo = [epic for epic in current["epics"] if epic.split("#")[0] == repo]
    epic = (in_repo or current["epics"])[0]
    return {"milestone": current["milestone"], "epic": epic, "link": link}


print(json.dumps(place()))
