#!/usr/bin/env python3
"""codex-review-status: Codex GitHub 앱(chatgpt-codex-connector)의 PR 리뷰 상태를 판정한다.

봇은 check run이나 status를 만들지 않아 statusCheckRollup에 나타나지 않는다. 그래서 PR 본문
반응(👀/👍), 요약 코멘트, 리뷰 객체, limit·실패 코멘트를 조합해 상태를 정한다. 판정에는
트리거(PR 생성, draft→ready 전환, 재리뷰 요청 코멘트) 가운데 마지막 시각 이후의 신호만 쓴다.
트리거 뒤에 봇이 새 리뷰를 시작했고(push 리뷰 등) 그 뒤로 결과가 없으면, 그 시작부터 센다.

GitHub에는 조회(GraphQL query)만 보낸다. 쓰기는 하지 않는다.

상태
  draft     draft PR이라 봇이 리뷰하지 않는다
  pending   리뷰 진행 중이거나 트리거 직후라 첫 신호를 기다린다
  reviewed  봇이 리뷰 객체와 인라인 지적을 남겼다
  lgtm      봇이 지적 없이 리뷰를 마쳤다
  limited   Codex 사용 한도 초과로 리뷰하지 않았다
  failed    봇이 리뷰를 수행하지 못했다 (오류, 계정 연결 안내, 요약 코멘트의 실패 상태)
  timeout   리뷰가 시작(트리거) 뒤 PENDING_TIMEOUT_SECONDS 안에 끝나지 않았다
  absent    트리거 뒤 ABSENT_AFTER_SECONDS가 지나도 봇 흔적이 없다

봇 신호의 근거
  - (#1477 실측) 요약 코멘트의 Completed 시각은 리뷰 객체보다 2~4초 늦고 👍보다 2~5초 이르다.
    그래서 Completed인데 트리거 뒤 리뷰 객체가 없으면 지적 없음(lgtm)으로 본다.
  - (#1477 실측) 봇 계정은 표면마다 login이 다르다 (작성자 chatgpt-codex-connector, 반응 사용자
    chatgpt-codex-connector[bot]). databaseId는 모든 표면에서 같으므로 둘을 함께 확인한다.
  - (봇 안내문) 사용 한도 코멘트는 리뷰 종류별로 온다. 보안 리뷰 한도 안내는 코드 리뷰와 따로
    달릴 수 있으므로 코드 리뷰 한도 문구만 limited로 본다.
  - (봇 안내문) 👀는 보안 리뷰를 포함한 모든 리뷰의 진행 표시다. 끝난 코드 리뷰를 대기 한도까지
    pending으로 보는 쪽이 새로 시작한 리뷰를 끝난 것으로 보는 쪽보다 안전해서, 👀도 리뷰 시작
    신호로 센다.
  - 공개 저장소에서는 누구나 코멘트를 달 수 있다. 재리뷰 요청과 스레드 답글은 저장소 권한자
    (OWNER·MEMBER·COLLABORATOR)나 조회 계정·PR 작성자가 쓴 것만 센다.
"""

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

BOT_DATABASE_ID = 199175422
BOT_LOGINS = frozenset({"chatgpt-codex-connector", "chatgpt-codex-connector[bot]"})

PENDING_TIMEOUT_SECONDS = 15 * 60
ABSENT_AFTER_SECONDS = 2 * 60
# 에이전트 셸 명령의 최대 제한 시간(10분) 안에서 끝나도록 한 번의 대기를 제한한다.
MAX_WAIT_SECONDS = 540
DEFAULT_POLL_SECONDS = 15
# 대기 중 진행 상황을 stderr에 알리는 간격. 제한 시간에 걸려 중단돼도 마지막 상태가 남는다.
PROGRESS_EVERY_SECONDS = 60
GH_CALL_TIMEOUT_SECONDS = 60
PAGE_SIZE = 100
# 스레드 안의 코멘트는 루트와 답글 존재만 보면 되므로 첫 페이지만 읽는다.
THREAD_COMMENTS_PAGE_SIZE = 100
MAX_PAGES_PER_CONNECTION = 50

SUMMARY_MARKER = "<!-- codex-pull-request-review-summary -->"
REVIEW_REQUEST_RE = re.compile(r"\A\s*@codex\s+review\b", re.IGNORECASE)
LIMIT_RE = re.compile(r"reached your Codex usage limits for code reviews", re.IGNORECASE)
FAILURE_RE = re.compile(r"something went wrong", re.IGNORECASE)
ACCOUNT_RE = re.compile(r"\bTo use Codex here\b", re.IGNORECASE)
LEGACY_LGTM_RE = re.compile(r"\A\s*Codex Review: Didn't find any major issues", re.IGNORECASE)
REVIEWED_COMMIT_RE = re.compile(r"\*\*Reviewed commit:\*\*\s*`([0-9a-fA-F]{7,40})`")
SHA_RE = re.compile(r"`([0-9a-fA-F]{7,40})`")
BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
DATETIME_ATTR_RE = re.compile(r'datetime="([^"]+)"')
BADGE_RE = re.compile(r"!\[(P\d) Badge\]")
TITLE_RE = re.compile(r"\A\*\*(?:<sub><sub>!\[[^\]]*\]\([^)]*\)</sub></sub>)?\s*(.*?)\*\*\s*\Z")
TIMESTAMP_RE = re.compile(
    r"\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})\Z"
)
PR_URL_RE = re.compile(r"\Ahttps://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)(?:[/?#]\S*)?\Z")
PR_NUMBER_RE = re.compile(r"\A#?(\d+)\Z")
REPO_RE = re.compile(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")

TRIGGER_LABELS = {
    "pr_opened": "PR 생성",
    "ready_for_review": "draft→ready 전환",
    "review_request": "재리뷰 요청 코멘트",
}
MISSING_LABELS = {"reply": "답글", "reaction": "반응", "resolve": "resolve"}
TRUSTED_ASSOCIATIONS = frozenset({"OWNER", "MEMBER", "COLLABORATOR"})
# 요약 코멘트 행 상태 가운데 리뷰 실패를 뜻하는 것. 그 밖의 모르는 상태는 진행 중으로 본다.
FAILED_ROW_RE = re.compile(r"\A(?:fail|error)", re.IGNORECASE)
# --wait 중 조회가 연속으로 이만큼 실패하면 멈춘다. 그 전의 일시 오류는 다음 조회로 넘어간다.
MAX_CONSECUTIVE_FETCH_FAILURES = 3

ACTOR_FIELDS = "__typename login ... on Bot { databaseId } ... on User { databaseId }"
# alias → (필드 호출 형식, 노드 선택). {after}에는 페이지 조회 때만 커서 인자가 들어간다.
CONNECTIONS = {
    "reactions": (
        "reactions(first: %d{after})" % PAGE_SIZE,
        "content createdAt user { login databaseId }",
    ),
    "readyEvents": (
        "timelineItems(first: %d, itemTypes: [READY_FOR_REVIEW_EVENT]{after})" % PAGE_SIZE,
        "... on ReadyForReviewEvent { createdAt }",
    ),
    "comments": (
        "comments(first: %d{after})" % PAGE_SIZE,
        "createdAt body url authorAssociation author { %s }" % ACTOR_FIELDS,
    ),
    "reviews": (
        "reviews(first: %d{after})" % PAGE_SIZE,
        "state submittedAt createdAt url commit { oid } author { %s }" % ACTOR_FIELDS,
    ),
    # 리뷰 코멘트의 databaseId는 64비트 id를 담지 못해 폐기 예정이라 fullDatabaseId(문자열)를 쓴다.
    "reviewThreads": (
        "reviewThreads(first: %d{after})" % PAGE_SIZE,
        "id isResolved isOutdated path line originalLine "
        "comments(first: %d) { nodes { fullDatabaseId createdAt url body authorAssociation author { %s } "
        "reactionGroups { content viewerHasReacted } } }" % (THREAD_COMMENTS_PAGE_SIZE, ACTOR_FIELDS),
    ),
}


class ToolError(Exception):
    """gh 호출이나 응답 해석이 실패했다."""


# ─── 시간 ───


def parse_ts(value):
    """GitHub ISO 8601 시각(소수점 초와 Z 포함)을 UTC aware datetime으로 바꾼다."""
    if not isinstance(value, str):
        return None
    match = TIMESTAMP_RE.match(value.strip())
    if not match:
        return None
    year, month, day, hour, minute, second, fraction, zone = match.groups()
    micro = int((fraction or "0")[:6].ljust(6, "0"))
    try:
        parsed = datetime(
            int(year), int(month), int(day), int(hour), int(minute), int(second), micro,
            tzinfo=timezone.utc,
        )
    except ValueError:
        return None
    if zone != "Z":
        # 오프셋이 붙은 시각은 그만큼 빼서 UTC로 맞춘다 (+09:00이면 9시간 전).
        sign = 1 if zone[0] == "+" else -1
        try:
            parsed -= sign * timedelta(hours=int(zone[1:3]), minutes=int(zone[4:6]))
        except OverflowError:
            return None
    return parsed


def iso(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if value else None


def current_time():
    override = os.environ.get("CODEX_REVIEW_STATUS_NOW")
    if override:
        parsed = parse_ts(override)
        if parsed is None:
            raise ToolError("CODEX_REVIEW_STATUS_NOW는 ISO 8601 UTC 시각이어야 한다: %s" % override)
        return parsed
    return datetime.now(timezone.utc)


def human_duration(seconds):
    seconds = max(0, int(seconds))
    minutes, secs = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    days, hours = divmod(hours, 24)
    if days:
        return "%d일 %d시간" % (days, hours)
    if hours:
        return "%d시간 %d분" % (hours, minutes)
    if minutes:
        return "%d분 %d초" % (minutes, secs)
    return "%d초" % secs


# ─── 봇 식별 ───


def is_bot_actor(actor):
    """Codex 봇인지 login과 databaseId로 함께 확인한다 (login만 같은 조직·사용자를 배제)."""
    if not isinstance(actor, dict):
        return False
    return actor.get("databaseId") == BOT_DATABASE_ID and actor.get("login") in BOT_LOGINS


def is_human_actor(actor):
    return isinstance(actor, dict) and actor.get("__typename") == "User" and not is_bot_actor(actor)


def is_trusted_comment(node, trusted_logins):
    """재리뷰 요청·스레드 답글로 인정하는 코멘트: 저장소 권한자나 조회 계정·PR 작성자가 썼다."""
    author = node.get("author")
    if not is_human_actor(author):
        return False
    return node.get("authorAssociation") in TRUSTED_ASSOCIATIONS or author.get("login") in trusted_logins


# ─── gh 호출 ───


def gh_command():
    """gh 실행 파일을 고른다.

    macOS는 셸 alias가 gh를 무인 인증 wrapper(gh-auth)로 보내지만 alias는 subprocess에 적용되지
    않으므로 PATH의 gh-auth를 직접 찾는다. 없으면(NixOS 등) gh의 저장된 인증을 쓴다.
    CODEX_REVIEW_STATUS_GH는 테스트나 특수 환경에서 실행 파일을 지정한다.
    """
    override = os.environ.get("CODEX_REVIEW_STATUS_GH")
    if override:
        return override
    return shutil.which("gh-auth") or "gh"


def gh_environment():
    """gh 출력이 JSON 그대로 오도록 TTY·색 강제 설정을 뺀다."""
    env = dict(os.environ)
    for key in ("GH_FORCE_TTY", "CLICOLOR_FORCE"):
        env.pop(key, None)
    env["NO_COLOR"] = "1"
    env["GH_PROMPT_DISABLED"] = "1"
    return env


def run_gh(args, deadline=None):
    """gh를 실행한다. deadline(time.monotonic 기준)이 있으면 호출 한도를 남은 시간으로 줄인다."""
    command = [gh_command()] + list(args)
    timeout = GH_CALL_TIMEOUT_SECONDS
    if deadline is not None:
        timeout = min(timeout, max(1.0, deadline - time.monotonic()))
    try:
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=gh_environment(),
        )
    except FileNotFoundError:
        raise ToolError("gh 실행 파일을 찾지 못했다: %s" % command[0]) from None
    except OSError as err:
        raise ToolError("gh 실행 파일을 실행하지 못했다: %s (%s)" % (command[0], err.strerror or err)) from None
    except subprocess.TimeoutExpired:
        raise ToolError("gh %s 호출이 %d초 안에 끝나지 않았다" % (" ".join(args[:2]), math.ceil(timeout))) from None
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise ToolError("gh %s 실패 (exit %d): %s" % (" ".join(args[:2]), proc.returncode, detail))
    return proc.stdout


def graphql(query, variables, deadline=None):
    args = ["api", "graphql", "-f", "query=" + query]
    for key, value in variables.items():
        if value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            raise ToolError("GraphQL 변수 형식을 지원하지 않는다: %s" % key)
        # 정수는 -F로 타입을 살리고, 문자열은 -f로 넘겨 '@'로 시작하는 값이 파일로 해석되지 않게 한다.
        args += ["-F" if isinstance(value, int) else "-f", "%s=%s" % (key, value)]
    output = run_gh(args, deadline)
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        raise ToolError("gh api graphql 응답을 JSON으로 해석하지 못했다") from None
    if not isinstance(payload, dict):
        raise ToolError("gh api graphql 응답 형식이 예상과 다르다")
    errors = payload.get("errors")
    if errors:
        messages = "; ".join(str(err.get("message", err)) if isinstance(err, dict) else str(err) for err in errors)
        raise ToolError("GraphQL 오류: %s" % messages)
    data = payload.get("data")
    if not isinstance(data, dict):
        raise ToolError("GraphQL 응답에 data가 없다")
    return data


def _connection_block(alias, after):
    field, selection = CONNECTIONS[alias]
    call = field.format(after=", after: $after" if after else "")
    return "%s: %s { pageInfo { hasNextPage endCursor } nodes { %s } }" % (alias, call, selection)


def build_main_query():
    blocks = " ".join(_connection_block(alias, after=False) for alias in CONNECTIONS)
    return (
        "query($owner: String!, $name: String!, $number: Int!) { "
        "viewer { login } "
        "repository(owner: $owner, name: $name) { nameWithOwner owner { login } "
        "pullRequest(number: $number) { number url state isDraft createdAt headRefOid "
        "author { login } %s } } }" % blocks
    )


def build_page_query(alias):
    return (
        "query($owner: String!, $name: String!, $number: Int!, $after: String!) { "
        "repository(owner: $owner, name: $name) { pullRequest(number: $number) { %s } } }"
        % _connection_block(alias, after=True)
    )


def fetch_snapshot(owner, name, number, deadline=None):
    variables = {"owner": owner, "name": name, "number": number}
    data = graphql(build_main_query(), variables, deadline)
    repo = data.get("repository")
    if not isinstance(repo, dict):
        raise ToolError("저장소를 찾지 못했다: %s/%s" % (owner, name))
    pr = repo.get("pullRequest")
    if not isinstance(pr, dict):
        raise ToolError("PR을 찾지 못했다: %s/%s#%d" % (owner, name, number))
    for alias in CONNECTIONS:
        connection = pr.get(alias) or {}
        nodes = list(connection.get("nodes") or [])
        page_info = connection.get("pageInfo") or {}
        pages = 1
        while page_info.get("hasNextPage"):
            cursor = page_info.get("endCursor")
            if not cursor:
                raise ToolError("%s 페이지 커서가 없다" % alias)
            pages += 1
            if pages > MAX_PAGES_PER_CONNECTION:
                raise ToolError("%s 페이지가 %d개를 넘는다" % (alias, MAX_PAGES_PER_CONNECTION))
            more = graphql(build_page_query(alias), dict(variables, after=cursor), deadline)
            next_connection = (((more.get("repository") or {}).get("pullRequest") or {}).get(alias)) or {}
            nodes.extend(next_connection.get("nodes") or [])
            page_info = next_connection.get("pageInfo") or {}
        pr[alias] = [node for node in nodes if isinstance(node, dict)]
    return {
        "viewer": (data.get("viewer") or {}).get("login"),
        "owner": (repo.get("owner") or {}).get("login"),
        "repo": repo.get("nameWithOwner") or "%s/%s" % (owner, name),
        "pr": pr,
    }


# ─── 판정 ───


def parse_summary_rows(body):
    """요약 코멘트 표의 행을 읽는다. 머리글과 구분선은 건너뛴다."""
    rows = []
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if len(cells) < 4:
            continue
        kind_match = BOLD_RE.search(cells[0])
        status_match = BOLD_RE.search(cells[1])
        if not kind_match or not status_match:
            continue
        at_match = DATETIME_ATTR_RE.search(cells[1])
        sha_match = SHA_RE.search(cells[2])
        rows.append(
            {
                "kind": kind_match.group(1).strip(),
                "status": status_match.group(1).strip(),
                "at": parse_ts(at_match.group(1)) if at_match else None,
                "commit": sha_match.group(1).lower() if sha_match else None,
                "trigger": cells[3],
            }
        )
    return rows


def code_review_rows(comments):
    """봇 요약 코멘트 전부에서 Code Review 행을 모은다.

    트리거가 몰리면 요약 코멘트가 둘 이상 생기고, 한쪽에 지난 주기의 행이 그대로 남기도 한다.
    그래서 한 코멘트만 고르지 않고 모든 행을 모아 판정에서 함께 본다.
    """
    rows = []
    for c in comments:
        if not is_bot_actor(c.get("author")) or SUMMARY_MARKER not in (c.get("body") or ""):
            continue
        rows.extend(row for row in parse_summary_rows(c.get("body") or "") if row["kind"].lower() == "code review")
    return rows


def compute_trigger(pr, trusted_logins):
    candidates = []
    created = parse_ts(pr.get("createdAt"))
    if created:
        candidates.append((created, "pr_opened"))
    for event in pr.get("readyEvents") or []:
        at = parse_ts(event.get("createdAt"))
        if at:
            candidates.append((at, "ready_for_review"))
    requests = [
        c for c in pr.get("comments") or []
        if is_trusted_comment(c, trusted_logins) and REVIEW_REQUEST_RE.search(c.get("body") or "")
    ]
    for comment in requests:
        at = parse_ts(comment.get("createdAt"))
        if at:
            candidates.append((at, "review_request"))
    if not candidates:
        raise ToolError("PR 생성 시각을 해석하지 못했다")
    at, kind = max(candidates, key=lambda item: item[0])
    return kind, at, len(requests)


def _after(at, trigger_at):
    return at is not None and at >= trigger_at


def _comment_id(node):
    """리뷰 코멘트의 REST id. fullDatabaseId는 GraphQL BigInt라 문자열로 온다."""
    value = node.get("fullDatabaseId")
    if isinstance(value, str) and value.isdigit():
        return int(value)
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    return None


def _thread_title(body):
    first_line = (body or "").strip().splitlines()[0] if (body or "").strip() else ""
    match = TITLE_RE.match(first_line)
    title = match.group(1).strip() if match and match.group(1).strip() else first_line
    return title[:120]


def collect_threads(pr, trusted_logins):
    threads = []
    for thread in pr.get("reviewThreads") or []:
        comments = [c for c in ((thread.get("comments") or {}).get("nodes") or []) if isinstance(c, dict)]
        if not comments or not is_bot_actor(comments[0].get("author")):
            continue
        root = comments[0]
        replied = any(is_trusted_comment(c, trusted_logins) for c in comments[1:])
        reacted = any(
            group.get("viewerHasReacted") and group.get("content") in ("THUMBS_UP", "THUMBS_DOWN")
            for group in root.get("reactionGroups") or []
        )
        missing = []
        if not replied:
            missing.append("reply")
        if not reacted:
            missing.append("reaction")
        if not thread.get("isResolved"):
            missing.append("resolve")
        badge = BADGE_RE.search(root.get("body") or "")
        threads.append(
            {
                "thread_id": thread.get("id"),
                "comment_id": _comment_id(root),
                "url": root.get("url"),
                "path": thread.get("path"),
                "line": thread.get("line") if thread.get("line") is not None else thread.get("originalLine"),
                "priority": badge.group(1) if badge else None,
                "title": _thread_title(root.get("body")),
                "outdated": bool(thread.get("isOutdated")),
                "created_at": root.get("createdAt"),
                "missing": missing,
            }
        )
    threads.sort(key=lambda t: t.get("created_at") or "")
    return threads


def _stale(head, commit):
    if not commit or not head:
        return None
    return not head.lower().startswith(commit.lower())


def _latest(times):
    times = [t for t in times if t is not None]
    return max(times) if times else None


def evaluate(snapshot, now):
    pr = snapshot["pr"]
    head = pr.get("headRefOid") or ""
    trusted_logins = {login for login in (snapshot.get("viewer"), (pr.get("author") or {}).get("login")) if login}
    kind, trigger_at, request_count = compute_trigger(pr, trusted_logins)
    comments = pr.get("comments") or []
    bot_comments = [c for c in comments if is_bot_actor(c.get("author"))]
    reactions = [r for r in pr.get("reactions") or [] if is_bot_actor(r.get("user"))]
    rows = code_review_rows(comments)
    running_rows = [row for row in rows if row["status"].lower() == "running"]
    eyes = [r for r in reactions if r.get("content") == "EYES"]

    def review_time(review):
        return parse_ts(review.get("submittedAt")) or parse_ts(review.get("createdAt"))

    bot_reviews = [r for r in pr.get("reviews") or [] if is_bot_actor(r.get("author"))]
    thumbs = [r for r in reactions if r.get("content") == "THUMBS_UP"]
    completed_rows = [row for row in rows if row["status"].lower() == "completed"]
    legacy_comments = [c for c in bot_comments if LEGACY_LGTM_RE.search(c.get("body") or "")]

    # 리뷰 주기의 시작. 보통은 트리거지만, 트리거 뒤에 봇이 새 리뷰를 시작했고(👀·Running) 그 뒤로
    # 결과 신호가 없으면 그 시작부터 센다. push로 다시 도는 리뷰에서 지난 주기의 결과를 이번 결과로
    # 읽거나, PR 생성 시각부터 재서 곧바로 timeout을 내지 않기 위해서다. 👀는 보안 리뷰에도 달려
    # 끝난 코드 리뷰를 대기 한도까지 pending으로 둘 수 있지만, 그쪽이 새 리뷰를 놓치는 것보다 안전하다.
    result_times = (
        [review_time(r) for r in bot_reviews]
        + [parse_ts(r.get("createdAt")) for r in thumbs]
        + [row["at"] for row in completed_rows]
        + [parse_ts(c.get("createdAt")) for c in legacy_comments]
    )
    newest_start = _latest([row["at"] for row in running_rows] + [parse_ts(r.get("createdAt")) for r in eyes])
    cycle_start = trigger_at
    if newest_start is not None and newest_start > trigger_at and not any(_after(t, newest_start) for t in result_times):
        cycle_start = newest_start
    since_label = "트리거" if cycle_start == trigger_at else "봇의 리뷰 시작"
    elapsed = (now - cycle_start).total_seconds()

    reviews_after = sorted((r for r in bot_reviews if _after(review_time(r), cycle_start)), key=review_time)
    thumbs_after = any(_after(parse_ts(r.get("createdAt")), cycle_start) for r in thumbs)
    completed_after = sorted((row for row in completed_rows if _after(row["at"], cycle_start)), key=lambda row: row["at"])
    unknown_after = sorted(
        (row for row in rows if row["status"].lower() not in ("running", "completed") and _after(row["at"], cycle_start)),
        key=lambda row: row["at"],
    )
    failed_rows = [row for row in unknown_after if FAILED_ROW_RE.match(row["status"])]
    # 처음 보는 요약 상태는 리뷰가 아직 도는 중일 수 있어 실패로 치지 않고 대기 한도까지 기다린다.
    unrecognized_rows = [row for row in unknown_after if not FAILED_ROW_RE.match(row["status"])]
    # 트리거 뒤에 시작한 Running 행은 이번 리뷰가 도는 중이라는 뜻이다. 트리거 전부터 멈춰 있는 행과
    # 👀는 지난 주기의 흔적일 수 있어 한도·오류 코멘트보다 뒤에서 본다.
    fresh_running = any(_after(row["at"], trigger_at) for row in running_rows)

    def comments_after(items, pattern=None):
        return [
            c for c in items
            if (pattern is None or pattern.search(c.get("body") or "")) and _after(parse_ts(c.get("createdAt")), cycle_start)
        ]

    legacy_lgtm = comments_after(legacy_comments)
    limit = comments_after(bot_comments, LIMIT_RE)
    failure = comments_after(bot_comments, FAILURE_RE)
    account = comments_after(bot_comments, ACCOUNT_RE)

    # 트리거 뒤 리뷰 주기가 둘 이상이면 가장 늦은 결과로 판정한다. 지적 없음 표시(👍, 지적 없음
    # 코멘트)가 마지막 리뷰 객체보다 늦으면 마지막 주기는 지적 없이 끝났다.
    lgtm_marks = [parse_ts(r.get("createdAt")) for r in thumbs] + [parse_ts(c.get("createdAt")) for c in legacy_lgtm]
    latest_lgtm = _latest([t for t in lgtm_marks if _after(t, cycle_start)])
    if reviews_after and latest_lgtm is not None and latest_lgtm > review_time(reviews_after[-1]):
        reviews_after = []

    threads = collect_threads(pr, trusted_logins)
    status = None
    reason = None
    reviewed_commit = None

    def waiting():
        if elapsed > PENDING_TIMEOUT_SECONDS:
            return "timeout", "%s부터 %s 지나도 리뷰가 끝나지 않았다" % (since_label, human_duration(elapsed))
        return "pending", "봇 리뷰 진행 중 (%s부터 %s 지남, %s까지 기다린다)" % (
            since_label, human_duration(elapsed), human_duration(PENDING_TIMEOUT_SECONDS))

    if pr.get("isDraft"):
        status, reason = "draft", "draft PR이라 봇이 리뷰하지 않는다. ready로 바꾸면 리뷰가 시작된다"
    elif reviews_after:
        latest = reviews_after[-1]
        reviewed_commit = ((latest.get("commit") or {}).get("oid") or "").lower() or None
        # 마지막 리뷰의 지적만 센다. 그 전 리뷰 뒤에 생긴 스레드가 마지막 리뷰의 것이다.
        previous = [t for t in (review_time(r) for r in bot_reviews) if t is not None and t < review_time(latest)]
        floor = max(previous) if previous else None
        new_threads = [
            t for t in threads
            if _after(parse_ts(t.get("created_at")), cycle_start)
            and (floor is None or parse_ts(t.get("created_at")) > floor)
        ]
        status, reason = "reviewed", "봇이 리뷰를 남겼다 (마지막 리뷰의 인라인 지적 %d개)" % len(new_threads)
    elif thumbs_after or completed_after or legacy_lgtm:
        with_commit = [row for row in completed_after if row["commit"]]
        if with_commit:
            reviewed_commit = with_commit[-1]["commit"]
        elif legacy_lgtm:
            match = REVIEWED_COMMIT_RE.search(legacy_lgtm[-1].get("body") or "")
            reviewed_commit = match.group(1).lower() if match else None
        status, reason = "lgtm", "봇이 지적 없이 리뷰를 마쳤다"
    elif fresh_running:
        status, reason = waiting()
    elif limit:
        status, reason = "limited", "Codex 코드 리뷰 사용 한도 초과로 리뷰하지 않았다"
    elif failure:
        status, reason = "failed", "봇이 오류로 리뷰를 수행하지 못했다"
    elif account:
        status, reason = "failed", "봇이 계정 연결 안내를 남기고 리뷰하지 않았다"
    elif failed_rows:
        status, reason = "failed", "요약 코멘트가 리뷰 실패를 알렸다: %s" % failed_rows[-1]["status"]
    elif unrecognized_rows or running_rows or eyes:
        status, reason = waiting()
        if unrecognized_rows and status == "pending":
            reason = "요약 코멘트의 리뷰 상태(%s)를 알 수 없어 진행 중으로 본다. %s" % (unrecognized_rows[-1]["status"], reason)
    elif elapsed <= ABSENT_AFTER_SECONDS:
        status, reason = "pending", "트리거 직후라 봇의 첫 신호를 기다린다 (트리거부터 %s 지남, %s 안에 흔적이 없으면 absent)" % (
            human_duration(elapsed), human_duration(ABSENT_AFTER_SECONDS))
    else:
        status, reason = "absent", "트리거부터 %s 지나도 봇 흔적이 없다" % human_duration(elapsed)

    settings_warning = None
    if status == "absent":
        author = (pr.get("author") or {}).get("login")
        viewer = snapshot.get("viewer")
        if kind == "review_request":
            settings_warning = "재리뷰 요청 코멘트에 봇이 반응하지 않았다. 요청 문구가 정확히 한 줄인지 확인한다"
        elif viewer and snapshot.get("owner") == viewer and author == viewer:
            settings_warning = "내 저장소의 내 PR인데 봇 흔적이 없다. Codex 코드 리뷰 설정(자동 검토, 트리거)을 확인한다"

    unhandled = [t for t in threads if t["missing"]]
    return {
        "repo": snapshot.get("repo"),
        "pr": pr.get("number"),
        "url": pr.get("url"),
        "pr_state": pr.get("state"),
        "is_draft": bool(pr.get("isDraft")),
        "head": head or None,
        "viewer": snapshot.get("viewer"),
        "status": status,
        "reason": reason,
        "trigger": {"kind": kind, "at": iso(trigger_at), "elapsed_seconds": int(max(0, (now - trigger_at).total_seconds()))},
        "reviewed_commit": reviewed_commit,
        "stale": _stale(head, reviewed_commit),
        "rereview_requests": request_count,
        "bot_threads": len(threads),
        "unhandled_threads": unhandled,
        "settings_warning": settings_warning,
        "pending_timeout_seconds": PENDING_TIMEOUT_SECONDS,
        "absent_after_seconds": ABSENT_AFTER_SECONDS,
    }


# ─── 출력 ───


def render_text(result):
    lines = []
    head = (result.get("head") or "")[:7]
    lines.append("%s#%s (%s) head %s" % (result["repo"], result["pr"], result.get("pr_state"), head or "?"))
    lines.append("상태: %s — %s" % (result["status"], result["reason"]))
    trigger = result["trigger"]
    lines.append(
        "트리거: %s %s (%s 전)"
        % (TRIGGER_LABELS.get(trigger["kind"], trigger["kind"]), trigger["at"], human_duration(trigger["elapsed_seconds"]))
    )
    if result.get("reviewed_commit"):
        stale = result.get("stale")
        note = "head와 같음" if stale is False else "head와 다름 (리뷰 뒤 커밋이 추가됨)" if stale else "head 비교 불가"
        lines.append("리뷰 커밋: %s — %s" % (result["reviewed_commit"][:10], note))
    lines.append("재리뷰 요청: %d회" % result["rereview_requests"])
    unhandled = result["unhandled_threads"]
    lines.append("봇 스레드: %d개 중 처리 안 됨 %d개" % (result["bot_threads"], len(unhandled)))
    for thread in unhandled:
        location = thread.get("path") or "?"
        if thread.get("line") is not None:
            location += ":%s" % thread["line"]
        flags = " (outdated)" if thread.get("outdated") else ""
        lines.append("  - [%s] %s %s%s" % (thread.get("priority") or "?", location, thread.get("title") or "", flags))
        lines.append("    빠진 처리: %s" % ", ".join(MISSING_LABELS[m] for m in thread["missing"]))
        lines.append("    thread %s · comment %s · %s" % (thread.get("thread_id"), thread.get("comment_id"), thread.get("url")))
    if result.get("settings_warning"):
        lines.append("경고: %s" % result["settings_warning"])
    return "\n".join(lines)


# ─── CLI ───


def parse_args(argv):
    parser_options = {}
    if sys.version_info >= (3, 14):
        # 에이전트가 읽는 출력이라 FORCE_COLOR가 켜진 환경에서도 도움말·오류에 색 제어 문자를 넣지 않는다.
        parser_options["color"] = False
    parser = argparse.ArgumentParser(
        prog="codex-review-status",
        description="Codex GitHub 앱(chatgpt-codex-connector)의 PR 리뷰 상태를 조회만으로 판정한다.",
        epilog=(
            "상태: draft, pending, reviewed, lgtm, limited, failed, timeout, absent. "
            "리뷰 시작(보통 트리거) 뒤 %d초가 지나도 진행 중이면 timeout, 트리거 뒤 %d초가 지나도 봇 흔적이 없으면 absent다."
            % (PENDING_TIMEOUT_SECONDS, ABSENT_AFTER_SECONDS)
        ),
        **parser_options,
    )
    parser.add_argument("pr", nargs="?", help="PR 번호 또는 URL. 생략하면 현재 브랜치의 PR")
    parser.add_argument("-R", "--repo", help="OWNER/REPO. 생략하면 PR URL이나 현재 저장소")
    parser.add_argument(
        "--wait",
        type=int,
        default=0,
        metavar="SECONDS",
        help="상태가 pending이면 최대 이 시간(초)까지 다시 조회한다. 상한 %d초" % MAX_WAIT_SECONDS,
    )
    parser.add_argument("--json", action="store_true", help="JSON으로 출력한다")
    args = parser.parse_args(argv)
    if args.wait < 0:
        parser.error("--wait는 0 이상이어야 한다")
    if args.wait > MAX_WAIT_SECONDS:
        print(
            "codex-review-status: --wait %d초를 상한 %d초로 줄인다. 더 기다리려면 다시 호출한다"
            % (args.wait, MAX_WAIT_SECONDS),
            file=sys.stderr,
        )
        args.wait = MAX_WAIT_SECONDS
    if args.repo is not None and not REPO_RE.match(args.repo):
        parser.error("--repo는 OWNER/REPO 형식이어야 한다: %s" % args.repo)
    if args.pr is not None and not (PR_NUMBER_RE.match(args.pr) or PR_URL_RE.match(args.pr)):
        parser.error("PR은 번호나 https://github.com/OWNER/REPO/pull/N URL이어야 한다: %s" % args.pr)
    if args.pr is None and args.repo is not None:
        parser.error("--repo를 쓰면 PR 번호도 지정해야 한다")
    return args


def resolve_target(args):
    """(owner, name, number)를 정한다. URL의 저장소와 --repo가 다르면 거부한다."""
    raw = args.pr
    if raw is None:
        raw = run_gh(["pr", "view", "--json", "url", "-q", ".url"]).strip()
        if not PR_URL_RE.match(raw):
            raise ToolError("현재 브랜치의 PR URL을 해석하지 못했다: %s" % raw)
    url_match = PR_URL_RE.match(raw)
    if url_match:
        owner, name, number = url_match.group(1), url_match.group(2), int(url_match.group(3))
        if args.repo and args.repo.lower() != ("%s/%s" % (owner, name)).lower():
            raise ToolError("--repo %s와 PR URL의 저장소 %s/%s가 다르다" % (args.repo, owner, name))
    else:
        number = int(PR_NUMBER_RE.match(raw).group(1))
        repo = args.repo or run_gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).strip()
        if not REPO_RE.match(repo):
            raise ToolError("현재 저장소를 해석하지 못했다: %s" % repo)
        owner, name = repo.split("/", 1)
    if number <= 0:
        raise ToolError("PR 번호는 1 이상이어야 한다: %d" % number)
    return owner, name, number


def poll_seconds():
    raw = os.environ.get("CODEX_REVIEW_STATUS_POLL_SECONDS")
    if not raw:
        return DEFAULT_POLL_SECONDS
    try:
        value = float(raw)
    except ValueError:
        raise ToolError("CODEX_REVIEW_STATUS_POLL_SECONDS는 양수여야 한다: %s" % raw) from None
    if not math.isfinite(value) or value <= 0:
        raise ToolError("CODEX_REVIEW_STATUS_POLL_SECONDS는 양수여야 한다: %s" % raw)
    return value


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        # 비 UTF-8 로케일에서도 한국어 출력이 인코딩 오류로 끝나지 않게 한다.
        sys.stdout.reconfigure(errors="backslashreplace")
    args = parse_args(sys.argv[1:] if argv is None else argv)
    # 대기 한도는 PR 확인에 쓴 시간까지 포함한다. 조회 한 번이 남은 시간보다 길면 더 조회하지 않고,
    # 대기 중 조회는 남은 시간 안에서만 기다려 전체 실행 시간이 --wait를 크게 넘지 않게 한다.
    deadline = time.monotonic() + args.wait
    last_progress = None
    result = None
    failures = 0
    try:
        owner, name, number = resolve_target(args)
        interval = poll_seconds()
        while True:
            started = time.monotonic()
            try:
                snap = fetch_snapshot(owner, name, number, deadline if result is not None else None)
            except ToolError as err:
                # 첫 조회가 실패하면 낼 결과가 없다. 대기 중의 일시 오류는 다음 조회로 넘긴다.
                if result is None:
                    raise
                failures += 1
                print("codex-review-status: 조회 실패 %d/%d — %s" % (failures, MAX_CONSECUTIVE_FETCH_FAILURES, err),
                      file=sys.stderr, flush=True)
                if failures >= MAX_CONSECUTIVE_FETCH_FAILURES:
                    raise
            else:
                result = evaluate(snap, current_time())
                failures = 0
            fetch_seconds = time.monotonic() - started
            remaining = deadline - time.monotonic()
            if result["status"] != "pending" or remaining <= fetch_seconds:
                break
            if last_progress is None or time.monotonic() - last_progress >= PROGRESS_EVERY_SECONDS:
                print("codex-review-status: 대기 중 — %s" % result["reason"], file=sys.stderr, flush=True)
                last_progress = time.monotonic()
            time.sleep(min(interval, remaining - fetch_seconds))
    except ToolError as err:
        print("codex-review-status: %s" % err, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(render_text(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
