#!/usr/bin/env python3
"""One-way Firstmate-to-Linear projection with an injected transport."""

import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

ENDPOINT = "https://api.linear.app/graphql"
STAGES = ("implementation", "investigation", "validation", "pr-open", "merged", "complete")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
STAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
PR_RE = re.compile(r"https://github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)")
TASK_RE = re.compile(r"^- \[([ x])\] ([A-Za-z0-9][A-Za-z0-9._-]*) - (.*)$")

DOCS = {
    "CreateIssue": """mutation CreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue { id identifier url } }
}""",
    "UpdateIssue": """mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) { success issue { id identifier url } }
}""",
    "LinkGitHubPr": """mutation LinkGitHubPr($issueId: String!, $url: String!, $title: String, $id: String) {
  attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, id: $id, linkKind: links) {
    success attachment { id url issue { id } }
  }
}""",
    "ArchiveIssue": """mutation ArchiveIssue($id: String!) {
  issueArchive(id: $id) { success }
}""",
}

INTROSPECTION = """query Spec5Schema {
  mutation: __type(name: "Mutation") { fields { name args { name } } }
  create: __type(name: "IssueCreateInput") { inputFields { name } }
  update: __type(name: "IssueUpdateInput") { inputFields { name } }
  issuePayload: __type(name: "IssuePayload") { fields { name } }
  archivePayload: __type(name: "IssueArchivePayload") { fields { name } }
  attachmentPayload: __type(name: "AttachmentPayload") { fields { name } }
  issue: __type(name: "Issue") { fields { name } }
  attachment: __type(name: "Attachment") { fields { name } }
  linkKind: __type(name: "GitLinkKind") { enumValues { name } }
}"""


class ProjectionError(Exception):
    def __init__(self, code, status=None):
        super().__init__(code)
        self.code = code
        self.status = status


def names(container, key="fields"):
    return {item["name"] for item in (container or {}).get(key, [])}


def require_names(actual, required):
    if not set(required).issubset(actual):
        raise ProjectionError("linear_schema_invalid")


def canonical_digest(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def regular_text(path, required=False):
    if not path.exists():
        if required:
            raise ProjectionError(f"missing requirement: {path}")
        return ""
    if path.is_symlink() or not path.is_file():
        raise ProjectionError("source_file_invalid")
    return path.read_text(encoding="utf-8")


def load_config(config_dir):
    if os.environ.get("FM_LINEAR_PROJECTION_ENABLED") != "1":
        raise ProjectionError("missing requirement: FM_LINEAR_PROJECTION_ENABLED=1")
    if not os.environ.get("LINEAR_API_KEY"):
        raise ProjectionError("missing requirement: LINEAR_API_KEY")
    path = Path(os.environ.get("FM_LINEAR_CONFIG", config_dir / "linear-projection.json"))
    try:
        value = json.loads(regular_text(path, required=True))
    except (json.JSONDecodeError, UnicodeError):
        raise ProjectionError("workspace configuration invalid") from None
    expected = {"schema", "workspace_id", "team_id", "untracked_state_id", "stage_state_ids"}
    if not isinstance(value, dict) or set(value) != expected or value.get("schema") != "fm-linear-projection-config.v1":
        raise ProjectionError("workspace configuration invalid")
    try:
        uuid.UUID(value["workspace_id"])
    except (ValueError, TypeError, AttributeError):
        raise ProjectionError("workspace configuration invalid") from None
    mapping = value.get("stage_state_ids")
    ids = [value.get("team_id"), value.get("untracked_state_id")]
    if not isinstance(mapping, dict) or set(mapping) != set(STAGES):
        raise ProjectionError("workspace configuration invalid")
    ids.extend(mapping.values())
    if any(not isinstance(item, str) or not item or "\n" in item for item in ids):
        raise ProjectionError("workspace configuration invalid")
    return value


def child_env(include_token=False):
    value = os.environ.copy()
    if not include_token:
        value.pop("LINEAR_API_KEY", None)
    return value


def linear_raw(operation, query, variables, token):
    request = {"operationName": operation, "query": query, "variables": variables}
    transport = os.environ.get("FM_LINEAR_TRANSPORT")
    if transport:
        env = child_env(include_token=token is not None)
        env["FM_LINEAR_AUTH_MODE"] = "token" if token else "none"
        try:
            result = subprocess.run(
                [transport], input=json.dumps(request), text=True, capture_output=True,
                timeout=30, check=False, env=env,
            )
        except (OSError, subprocess.TimeoutExpired):
            raise ProjectionError("linear_transport_error") from None
        if result.returncode != 0:
            raise ProjectionError("linear_transport_error")
        try:
            envelope = json.loads(result.stdout)
            return int(envelope["status"]), envelope["body"]
        except (ValueError, TypeError, KeyError, json.JSONDecodeError):
            raise ProjectionError("linear_transport_invalid") from None
    with tempfile.TemporaryDirectory(prefix="fm-linear-transport.") as directory:
        request_path, response_path, headers_path = (Path(directory) / name for name in ("request.json", "response.json", "headers"))
        request_path.write_text(json.dumps(request), encoding="utf-8")
        headers_path.write_text("Content-Type: application/json\n" + (f"Authorization: {token}\n" if token else ""), encoding="utf-8")
        os.chmod(request_path, 0o600); os.chmod(headers_path, 0o600)
        command = ["curl", "--silent", "--show-error", "--output", str(response_path), "--write-out", "%{http_code}", "--request", "POST", "--header", f"@{headers_path}", "--data-binary", f"@{request_path}", ENDPOINT]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=30, env=child_env())
            if result.returncode != 0:
                raise ProjectionError("linear_transport_error")
            return int(result.stdout), json.loads(response_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired):
            raise ProjectionError("linear_transport_error") from None


def linear_call(operation, variables, token):
    status, body = linear_raw(operation, DOCS[operation], variables, token)
    if status < 200 or status >= 300:
        raise ProjectionError("linear_http_error", status)
    if not isinstance(body, dict) or body.get("errors") or not isinstance(body.get("data"), dict):
        raise ProjectionError("linear_graphql_error", status)
    return body["data"]


def parse_backlog(path):
    section = None
    items = {}
    current = None
    for line in regular_text(path, required=True).splitlines():
        if line == "## In flight":
            section, current = "in_flight", None
            continue
        if line == "## Queued":
            section, current = "queued", None
            continue
        if line == "## Done":
            section, current = "done", None
            continue
        if line.startswith("## "):
            section, current = None, None
            continue
        match = TASK_RE.match(line) if section else None
        if match:
            task_id, tail = match.group(2), match.group(3)
            if task_id in items:
                raise ProjectionError("duplicate backlog identity")
            repo = re.search(r"\(repo: ([^)]+)\)", tail)
            kind = re.search(r"\(kind: ([^)]+)\)", tail)
            title = re.split(r" blocked-by: | \((?:repo|kind|priority|since|done|merged|reported|closed)[: ]", tail, maxsplit=1)[0]
            items[task_id] = {
                "id": task_id, "title": title[:240], "repo": repo.group(1) if repo else "",
                "kind": kind.group(1) if kind else "task", "local_state": section, "source": [tail],
            }
            current = items[task_id]
        elif current is not None and (line.startswith(" ") or line == ""):
            current["source"].append(line)
    return items


def parse_archive(path):
    archived = set()
    for line in regular_text(path).splitlines():
        match = TASK_RE.match(line)
        if match and match.group(1) == "x":
            archived.add(match.group(2))
    return archived


def parse_stages(path):
    current = {}
    for line in regular_text(path).splitlines():
        fields = line.split("\t")
        if len(fields) != 3:
            continue
        task_id, stage, at = fields
        if ID_RE.fullmatch(task_id) and stage in STAGES and STAMP_RE.fullmatch(at):
            current[task_id] = stage
    return current


def captain_queue(root, home):
    command = os.environ.get("FM_CAPTAIN_QUEUE_BIN", str(root / "bin/fm-captain-queue.sh"))
    env = child_env()
    env["FM_HOME"] = str(home)
    try:
        result = subprocess.run([command, "--json"], text=True, capture_output=True, timeout=30, env=env)
        value = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        raise ProjectionError("captain queue unavailable") from None
    if result.returncode != 0 or value.get("schema") != "fm-captain-queue.v1" or not isinstance(value.get("items"), list):
        raise ProjectionError("captain queue unavailable")
    return value["items"]


def meta_pr(state_dir, task_id):
    source = regular_text(state_dir / f"{task_id}.meta")
    values = [line[3:] for line in source.splitlines() if line.startswith("pr=")]
    return values[-1] if values and PR_RE.fullmatch(values[-1]) else ""


def find_pr(item, state_dir):
    return meta_pr(state_dir, item["id"])


def github_status(url):
    transport = os.environ.get("FM_GITHUB_STATUS_TRANSPORT")
    if transport:
        command = [transport, url]
    else:
        match = PR_RE.fullmatch(url)
        if not match:
            raise ProjectionError("github status unavailable")
        command = ["gh-axi", "pr", "view", match.group(2), "--repo", match.group(1)]
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=30, env=child_env())
    except (OSError, subprocess.TimeoutExpired):
        raise ProjectionError("github status unavailable") from None
    if result.returncode != 0:
        raise ProjectionError("github status unavailable")
    if transport:
        try:
            value = json.loads(result.stdout)
            state, checks = value["state"], value["checks"]
        except (json.JSONDecodeError, KeyError, TypeError):
            raise ProjectionError("github status unavailable") from None
    else:
        state_match = re.search(r"^  state: ([A-Za-z_-]+)$", result.stdout, re.MULTILINE)
        draft_match = re.search(r"^  draft: (yes|no)$", result.stdout, re.MULTILINE)
        checks_match = re.search(r'^  checks: "([^"]+)"$', result.stdout, re.MULTILINE)
        if not state_match or not draft_match:
            raise ProjectionError("github status unavailable")
        state = "draft" if draft_match.group(1) == "yes" else state_match.group(1).lower()
        raw_checks = checks_match.group(1) if checks_match else ""
        failed = re.search(r"(\d+) failed", raw_checks)
        passed = re.search(r"(\d+) passed", raw_checks)
        checks = "failing" if failed and int(failed.group(1)) else "green" if passed and int(passed.group(1)) else "none"
    if state not in {"open", "closed", "merged", "draft"} or checks not in {"green", "failing", "pending", "none"}:
        raise ProjectionError("github status unavailable")
    return {"state": state, "checks": checks}


def build_entities(items, queue, stages, state_dir):
    decisions = {entry["id"]: entry for entry in queue if isinstance(entry, dict) and ID_RE.fullmatch(str(entry.get("id", "")))}
    for task_id, entry in decisions.items():
        if task_id not in items:
            items[task_id] = {
                "id": task_id, "title": str(entry.get("title", ""))[:240],
                "repo": str(entry.get("repo", "")), "kind": "captain",
                "local_state": "queued", "source": [str(entry.get("title", ""))],
            }
    for item in items.values():
        item["stage"] = stages.get(item["id"])
        item["entity_type"] = "decision" if item["id"] in decisions else "work"
        item["pr_url"] = find_pr(item, state_dir)
    for item in items.values():
        if item["entity_type"] != "decision" or item["pr_url"]:
            continue
        origin = decisions[item["id"]].get("origin")
        if isinstance(origin, str) and ID_RE.fullmatch(origin) and origin in items:
            item["pr_url"] = items[origin]["pr_url"]
    statuses = {}
    for url in sorted({item["pr_url"] for item in items.values() if item["pr_url"]}):
        statuses[url] = github_status(url)
    for item in items.values():
        item["pr_status"] = statuses.get(item["pr_url"], {"state": "none", "checks": "none"})
    return [items[key] for key in sorted(items)]


def load_state(path, workspace_id):
    if not path.exists():
        return {"schema": "fm-linear-projection-state.v1", "revision": 0, "workspace_id": workspace_id, "items": {}}
    try:
        value = json.loads(regular_text(path, required=True))
    except json.JSONDecodeError:
        raise ProjectionError("projection journal invalid") from None
    if value.get("schema") != "fm-linear-projection-state.v1" or value.get("workspace_id") != workspace_id or not isinstance(value.get("items"), dict):
        raise ProjectionError("projection journal invalid")
    return value


def save_state(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    value["revision"] += 1
    fd, name = tempfile.mkstemp(prefix=".linear-projection.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def response_id(data, field, nested):
    payload = data.get(field)
    entity = payload.get(nested) if isinstance(payload, dict) else None
    if not payload or payload.get("success") is not True or not isinstance(entity, dict) or not entity.get("id"):
        raise ProjectionError("linear_response_invalid")
    return entity["id"]


def description(item):
    status = item["pr_status"]
    return "\n".join([
        "Firstmate projection (read-only)", f"Local id: {item['id']}", f"Type: {item['entity_type']}",
        f"Repository: {item['repo'] or 'unrecorded'}", f"Backlog state: {item['local_state']}",
        f"Stage: {item['stage'] or 'unrecorded'}", f"GitHub PR: {item['pr_url'] or 'none'}",
        f"GitHub PR status: {status['state']}; checks={status['checks']}", f"Projection key: fm-linear-v1:{item['id']}",
    ])


def sync(root, home, data_dir, state_dir, config_dir):
    config = load_config(config_dir)
    backlog = data_dir / "backlog.md"
    ledger = state_dir / "stage-transitions.tsv"
    archived = parse_archive(data_dir / "done-archive.md")
    items = parse_backlog(backlog)
    conflict = set(items).intersection(archived)
    if conflict:
        raise ProjectionError("live/archive identity conflict")
    queue = captain_queue(root, home)
    stages = parse_stages(ledger)
    journal_path = state_dir / "linear-projection.json"
    journal = load_state(journal_path, config["workspace_id"])
    entities = build_entities(items, queue, stages, state_dir)
    token = os.environ["LINEAR_API_KEY"]
    namespace = uuid.UUID(config["workspace_id"])
    summary = {"schema": "fm-linear-projection-run.v1", "source_count": len(entities), "created": 0, "updated": 0, "linked": 0, "archived": 0, "unchanged": 0, "absent": 0}
    live_ids = {item["id"] for item in entities}
    for item in entities:
        issue_id = str(uuid.UUID(bytes=uuid.uuid5(namespace, f"issue:{item['id']}").bytes, version=4))
        record = journal["items"].get(item["id"])
        if record and record.get("archived"):
            raise ProjectionError("archived projection identity returned live")
        if record is None:
            record = {"remote_issue_id": issue_id, "issue_digest": "", "pr_url": "", "attachment_id": "", "archived": False, "revision": 0}
            journal["items"][item["id"]] = record
        if record.get("remote_issue_id") != issue_id:
            raise ProjectionError("projection journal invalid")
        issue_input = {
            "id": issue_id, "teamId": config["team_id"], "title": item["title"],
            "description": description(item),
            "stateId": config["stage_state_ids"].get(item["stage"], config["untracked_state_id"]),
        }
        digest = canonical_digest(issue_input)
        changed = False
        if not record["issue_digest"]:
            data = linear_call("CreateIssue", {"input": issue_input}, token)
            if response_id(data, "issueCreate", "issue") != issue_id:
                raise ProjectionError("linear_response_invalid")
            record["issue_digest"], record["revision"] = digest, record["revision"] + 1
            save_state(journal_path, journal)
            summary["created"], changed = summary["created"] + 1, True
        elif record["issue_digest"] != digest:
            update = {key: issue_input[key] for key in ("title", "description", "stateId")}
            data = linear_call("UpdateIssue", {"id": issue_id, "input": update}, token)
            if response_id(data, "issueUpdate", "issue") != issue_id:
                raise ProjectionError("linear_response_invalid")
            record["issue_digest"], record["revision"] = digest, record["revision"] + 1
            save_state(journal_path, journal)
            summary["updated"], changed = summary["updated"] + 1, True
        if item["pr_url"] and record["pr_url"] != item["pr_url"]:
            attachment_id = str(uuid.UUID(bytes=uuid.uuid5(namespace, f"attachment:{item['id']}").bytes, version=4))
            variables = {"issueId": issue_id, "url": item["pr_url"], "title": "Linked GitHub pull request", "id": attachment_id}
            data = linear_call("LinkGitHubPr", variables, token)
            if response_id(data, "attachmentLinkGitHubPR", "attachment") != attachment_id:
                raise ProjectionError("linear_response_invalid")
            record.update({"pr_url": item["pr_url"], "attachment_id": attachment_id, "revision": record["revision"] + 1})
            save_state(journal_path, journal)
            summary["linked"], changed = summary["linked"] + 1, True
        if not changed:
            summary["unchanged"] += 1
    for task_id, record in sorted(journal["items"].items()):
        if task_id in live_ids or record.get("archived"):
            continue
        if task_id not in archived:
            summary["absent"] += 1
            continue
        data = linear_call("ArchiveIssue", {"id": record["remote_issue_id"]}, token)
        payload = data.get("issueArchive")
        if not isinstance(payload, dict) or payload.get("success") is not True:
            raise ProjectionError("linear_response_invalid")
        record.update({"archived": True, "revision": record["revision"] + 1})
        save_state(journal_path, journal)
        summary["archived"] += 1
    return summary


def schema_check():
    status, body = linear_raw("Spec5Schema", INTROSPECTION, {}, None)
    if status != 200 or not isinstance(body, dict) or body.get("errors") or not isinstance(body.get("data"), dict):
        raise ProjectionError("linear_schema_unavailable", status)
    schema = body["data"]
    require_names(names(schema["mutation"]), ["issueCreate", "issueUpdate", "attachmentLinkGitHubPR", "issueArchive"])
    require_names(names(schema["create"], "inputFields"), ["id", "title", "description", "teamId", "stateId"])
    require_names(names(schema["update"], "inputFields"), ["title", "description", "stateId"])
    require_names(names(schema["issuePayload"]), ["success", "issue"])
    require_names(names(schema["archivePayload"]), ["success"])
    require_names(names(schema["attachmentPayload"]), ["success", "attachment"])
    require_names(names(schema["issue"]), ["id", "identifier", "url"])
    require_names(names(schema["attachment"]), ["id", "url", "issue"])
    require_names(names(schema["linkKind"], "enumValues"), ["links"])
    dummy = "00000000-0000-4000-8000-000000000001"
    variables = {
        "CreateIssue": {"input": {"id": dummy, "teamId": dummy, "title": "schema-check", "description": "schema-check", "stateId": dummy}},
        "UpdateIssue": {"id": dummy, "input": {"title": "schema-check", "description": "schema-check", "stateId": dummy}},
        "LinkGitHubPr": {"issueId": dummy, "url": "https://github.com/example/example/pull/1", "title": "schema-check", "id": dummy},
        "ArchiveIssue": {"id": dummy},
    }
    for operation, document in DOCS.items():
        probe_status, probe = linear_raw(operation, document, variables[operation], None)
        if probe_status not in {200, 401} or not isinstance(probe, dict):
            raise ProjectionError("linear_schema_invalid", probe_status)
        for error in probe.get("errors", []):
            code = (error.get("extensions") or {}).get("code") if isinstance(error, dict) else None
            if code == "GRAPHQL_VALIDATION_FAILED":
                raise ProjectionError("linear_schema_invalid")
    return {"schema": "fm-linear-projection-schema-check.v1", "documents": len(DOCS), "valid": True}


def main():
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command not in {"sync", "schema-check"}:
        print("usage: fm-linear-projection.sh sync|schema-check", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", root)))
    data_dir = Path(os.environ.get("FM_DATA_OVERRIDE", home / "data"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", home / "state"))
    config_dir = Path(os.environ.get("FM_CONFIG_OVERRIDE", home / "config"))
    try:
        if command == "schema-check":
            result = schema_check()
        else:
            state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            lock_path = state_dir / ".linear-projection.lock"
            with lock_path.open("a+", encoding="utf-8") as lock:
                os.chmod(lock_path, 0o600)
                fcntl.flock(lock, fcntl.LOCK_EX)
                result = sync(root, home, data_dir, state_dir, config_dir)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except ProjectionError as error:
        suffix = f" status={error.status}" if error.status is not None else ""
        print(f"fm-linear-projection: {error.code}{suffix}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
