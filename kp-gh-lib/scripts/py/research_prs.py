import json
import re
import subprocess
import sys

repo, issue, project_id = sys.argv[1], int(sys.argv[2]), sys.argv[3]
CLOSING = re.compile(r"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#([0-9]+)")
REFERENCE = re.compile(rf"#{issue}(?![0-9])")
ADD_ITEM = ("mutation($project:ID!,$content:ID!){ addProjectV2ItemById("
            "input:{projectId:$project,contentId:$content}){ item{ id } } }")

listed = subprocess.run(
    ["gh", "pr", "list", "-R", repo, "--state", "open", "--limit", "100",
     "--json", "number,id,headRefName,body,url"],
    capture_output=True, text=True)
if listed.returncode != 0:
    sys.stderr.write(listed.stderr)
    print(f"research-prs.sh: `gh pr list -R {repo}` failed", file=sys.stderr)
    sys.exit(1)


def is_research_pr(pr):
    body = pr.get("body") or ""
    if not (pr["headRefName"].startswith(f"research/{issue}-") or REFERENCE.search(body)):
        return False
    return all(int(closed) == issue for closed in CLOSING.findall(body))


def board_add(pr):
    added = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={ADD_ITEM}",
         "-f", f"project={project_id}", "-f", f"content={pr['id']}"],
        capture_output=True, text=True)
    try:
        return json.loads(added.stdout)["data"]["addProjectV2ItemById"]["item"]["id"]
    except (ValueError, KeyError, TypeError):
        print(f"research-prs.sh: board add failed for PR #{pr['number']} ({pr['url']}): "
              f"{added.stderr.strip() or added.stdout.strip()}", file=sys.stderr)
        return None


research_prs = sorted(filter(is_research_pr, json.loads(listed.stdout)),
                      key=lambda pr: pr["number"])
print(json.dumps([{"number": pr["number"], "url": pr["url"], "boardItem": board_add(pr)}
                  for pr in research_prs]))
