#!/usr/bin/env python3
"""codex-review-status의 봇 신호 판정과 CLI 계약을 합성 GitHub 응답으로 검사한다 (네트워크 없음).

판정 로직은 모듈을 직접 불러 evaluate()에 합성 PR을 넣어 검사한다. CLI는 PATH에 둔 가짜 gh가
시나리오 JSON으로 응답하고 호출 인자를 기록하므로, 페이지 넘김·--wait·오류 처리와 함께
GitHub에 조회만 보낸다는 계약도 확인한다.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone

SCRIPT = Path(__file__).resolve().parents[1] / "modules/shared/scripts/codex-review-status.py"


def load_module():
    spec = importlib.util.spec_from_file_location("codex_review_status", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


M = load_module()

BOT = {"__typename": "Bot", "login": "chatgpt-codex-connector", "databaseId": 199175422}
BOT_REACTOR = {"login": "chatgpt-codex-connector[bot]", "databaseId": 199175422}
ME = {"__typename": "User", "login": "owner-user", "databaseId": 1001}
OTHER_USER = {"__typename": "User", "login": "someone-else", "databaseId": 1002}
OTHER_BOT = {"__typename": "Bot", "login": "coderabbitai", "databaseId": 136622811}
# login만 봇과 같은 계정 (REST users/chatgpt-codex-connector는 별개 조직이다).
IMPOSTOR = {"__typename": "User", "login": "chatgpt-codex-connector", "databaseId": 261883814}
IMPOSTOR_REACTOR = {"login": "chatgpt-codex-connector[bot]", "databaseId": 42}

HEAD = "a" * 40
OLD = "b" * 40
T0 = datetime(2026, 9, 27, 3, 0, 0, tzinfo=timezone.utc)
LIMIT_BODY = (
    "You have reached your Codex usage limits for code reviews. You can see your limits in the "
    "[Codex usage dashboard](https://chatgpt.com/codex/cloud/settings/usage)."
)
ACCOUNT_BODY = (
    "To use Codex here, [create a Codex account and connect to github]"
    "(https://chatgpt.com/codex/cloud/settings/connectors)."
)
FAILURE_BODY = "Something went wrong. Try again later by commenting \u201c@codex review\u201d."
LEGACY_LGTM_BODY = "Codex Review: Didn't find any major issues. Chef's kiss.\n\n**Reviewed commit:** `%s`\n" % HEAD[:10]
SECURITY_LIMIT_BODY = (
    "You have reached your Codex usage limits for security reviews. You can see your limits in the "
    "[Codex usage dashboard](https://chatgpt.com/codex/cloud/settings/usage)."
)
REVIEW_BODY = "\n### \U0001F4A1 Codex Review\n\n**Reviewed commit:** `%s`\n" % HEAD[:10]


def ts(seconds, fraction=False):
    value = T0 + timedelta(seconds=seconds)
    if fraction:
        return value.strftime("%Y-%m-%dT%H:%M:%S.276216Z")
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def summary_body(status, at_s, commit=HEAD[:7], trigger="PR opened", extra_rows=()):
    icon = {"Running": "\U0001F504", "Completed": "\u2705"}.get(status, "\u274C")
    since = " since" if status == "Running" else ""
    row = '| \U0001F4DD **Code Review** | %s **%s**%s <relative-time datetime="%s">%s</relative-time> | `%s` | %s |' % (
        icon, status, since, ts(at_s, True), ts(at_s, True), commit, trigger)
    lines = [
        "<!-- codex-pull-request-review-summary -->",
        "",
        "## Codex Review Summary",
        "",
        "| Review | Status | Commit | Review trigger |",
        "| --- | --- | --- | --- |",
        *extra_rows,
        row,
        "",
        '<details> <summary>About</summary> Comment "@codex review" or "@codex security review". </details>',
    ]
    return "\n".join(lines)


def comment(body, at_s, author=BOT, association=None):
    node = {"databaseId": 5000 + at_s, "createdAt": ts(at_s), "body": body, "url": "https://example.test/c/%d" % at_s, "author": author}
    if association:
        node["authorAssociation"] = association
    return node


def reaction(content, at_s, user=BOT_REACTOR):
    return {"content": content, "createdAt": ts(at_s), "user": user}


def review(at_s, oid=HEAD, author=BOT):
    return {"databaseId": 7000 + at_s, "state": "COMMENTED", "submittedAt": ts(at_s), "createdAt": ts(at_s),
            "url": "https://example.test/r/%d" % at_s, "commit": {"oid": oid}, "body": REVIEW_BODY, "author": author}


def thread(at_s=100, priority="P1", title="Fix the race", replies=(), reaction_groups=(), resolved=False,
           outdated=False, root_author=BOT, path="modules/x.sh", line=42):
    root_body = (
        "**<sub><sub>![%s Badge](https://img.shields.io/badge/%s-red?style=flat)</sub></sub>  %s**\n\nDetails.\n\n"
        "Useful? React with \U0001F44D / \U0001F44E." % (priority, priority, title)
    )
    root = {"fullDatabaseId": str(4113266958 + at_s), "createdAt": ts(at_s), "url": "https://example.test/t/%d" % at_s,
            "body": root_body, "author": root_author, "reactionGroups": list(reaction_groups)}
    # replies의 항목은 작성자, 또는 (작성자, authorAssociation)이다.
    reply_nodes = []
    for i, entry in enumerate(replies):
        author, association = entry if isinstance(entry, tuple) else (entry, None)
        node = {"databaseId": 9500 + at_s + i, "createdAt": ts(at_s + 10 + i), "url": "u", "body": "reply",
                "author": author, "reactionGroups": []}
        if association:
            node["authorAssociation"] = association
        reply_nodes.append(node)
    return {"id": "PRRT_%d" % at_s, "isResolved": resolved, "isOutdated": outdated, "path": path,
            "line": line, "originalLine": 40, "comments": {"nodes": [root] + reply_nodes}}


def pr(**overrides):
    base = {
        "number": 7, "url": "https://github.com/owner-user/repo/pull/7", "state": "OPEN", "isDraft": False,
        "createdAt": ts(0), "headRefOid": HEAD, "author": {"login": "owner-user"},
        "reactions": [], "readyEvents": [], "comments": [], "reviews": [], "reviewThreads": [],
    }
    base.update(overrides)
    return base


def snapshot(pull, viewer="owner-user", owner="owner-user"):
    return {"viewer": viewer, "owner": owner, "repo": "%s/repo" % owner, "pr": pull}


def judge(pull, now_s, **kwargs):
    return M.evaluate(snapshot(pull, **kwargs), T0 + timedelta(seconds=now_s))


class TimestampTests(unittest.TestCase):
    def test_parses_z_fraction_and_offsets(self):
        self.assertEqual(M.parse_ts("2026-09-27T03:00:00Z"), T0)
        self.assertEqual(M.parse_ts("2026-09-27T03:00:00.276216Z"), T0.replace(microsecond=276216))
        self.assertEqual(M.parse_ts("2026-09-27T12:00:00+09:00"), T0)
        self.assertEqual(M.parse_ts("2026-09-26T22:00:00-05:00"), T0)
        self.assertEqual(M.parse_ts("2026-09-27T03:00:00.1234567Z"), T0.replace(microsecond=123456))

    def test_rejects_malformed_values(self):
        for value in (None, "", "2026-09-27", "2026-09-27T03:00:00", "2026-13-01T00:00:00Z", 12):
            self.assertIsNone(M.parse_ts(value), value)

    def test_human_duration_units(self):
        self.assertEqual(M.human_duration(59), "59초")
        self.assertEqual(M.human_duration(61), "1분 1초")
        self.assertEqual(M.human_duration(3 * 3600 + 120), "3시간 2분")
        self.assertEqual(M.human_duration(2 * 86400 + 3600), "2일 1시간")
        self.assertEqual(M.human_duration(-5), "0초")


class SummaryParsingTests(unittest.TestCase):
    def test_running_and_completed_rows(self):
        running = M.parse_summary_rows(summary_body("Running", 20))
        self.assertEqual(len(running), 1)
        self.assertEqual(running[0]["kind"], "Code Review")
        self.assertEqual(running[0]["status"], "Running")
        self.assertEqual(running[0]["commit"], HEAD[:7])
        self.assertEqual(running[0]["trigger"], "PR opened")
        self.assertEqual(running[0]["at"], (T0 + timedelta(seconds=20)).replace(microsecond=276216))
        completed = M.parse_summary_rows(summary_body("Completed", 90, trigger="Draft marked ready"))
        self.assertEqual(completed[0]["status"], "Completed")
        self.assertEqual(completed[0]["trigger"], "Draft marked ready")

    def test_header_and_separator_rows_are_ignored(self):
        rows = M.parse_summary_rows("| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n")
        self.assertEqual(rows, [])

    def test_code_review_row_is_selected_among_other_reviews(self):
        security = '| \U0001F512 **Security Review** | \U0001F504 **Running** since <relative-time datetime="%s">x</relative-time> | `%s` | Comment |' % (
            ts(30, True), HEAD[:7])
        body = summary_body("Completed", 90, extra_rows=(security,))
        rows = M.code_review_rows([comment(body, 10)])
        self.assertEqual([(row["kind"], row["status"]) for row in rows], [("Code Review", "Completed")])

    def test_rows_from_every_summary_comment_are_collected(self):
        rows = M.code_review_rows([
            comment(summary_body("Running", 2001, trigger="Manual request"), 1999),
            comment(summary_body("Failed", 2002), 2000),
            comment("noise", 2003),
        ])
        self.assertEqual(sorted(row["status"] for row in rows), ["Failed", "Running"])

    def test_summary_from_non_bot_author_is_ignored(self):
        self.assertEqual(M.code_review_rows([comment(summary_body("Completed", 90), 10, author=IMPOSTOR)]), [])


class StateTests(unittest.TestCase):
    def test_draft_pr_is_not_reviewed(self):
        result = judge(pr(isDraft=True), 600)
        self.assertEqual(result["status"], "draft")

    def test_no_signal_right_after_trigger_is_pending(self):
        result = judge(pr(), 30)
        self.assertEqual(result["status"], "pending")
        self.assertIn("첫 신호", result["reason"])

    def test_no_signal_after_absent_window_is_absent_with_settings_warning_for_own_pr(self):
        result = judge(pr(), M.ABSENT_AFTER_SECONDS + 1)
        self.assertEqual(result["status"], "absent")
        self.assertIn("설정", result["settings_warning"])

    def test_absent_boundary_is_inclusive_pending(self):
        self.assertEqual(judge(pr(), M.ABSENT_AFTER_SECONDS)["status"], "pending")

    def test_absent_warning_only_for_own_pr_in_own_repo(self):
        other_author = judge(pr(author={"login": "someone-else"}), 600)
        self.assertEqual(other_author["status"], "absent")
        self.assertIsNone(other_author["settings_warning"])
        org_repo = judge(pr(), 600, owner="some-org")
        self.assertIsNone(org_repo["settings_warning"])

    def test_eyes_reaction_means_pending_until_timeout(self):
        # 대기 한도는 봇이 이번 리뷰를 시작한 시각(Running 21초)부터 잰다.
        pull = pr(reactions=[reaction("EYES", 20)], comments=[comment(summary_body("Running", 21), 21)])
        self.assertEqual(judge(pull, 300)["status"], "pending")
        self.assertEqual(judge(pull, 21 + M.PENDING_TIMEOUT_SECONDS)["status"], "pending")
        timed_out = judge(pull, 22 + M.PENDING_TIMEOUT_SECONDS)
        self.assertEqual(timed_out["status"], "timeout")
        self.assertIn("봇의 리뷰 시작부터", timed_out["reason"])
        self.assertNotIn("분가", timed_out["reason"])

    def test_running_summary_without_eyes_is_pending(self):
        pull = pr(comments=[comment(summary_body("Running", 21), 21)])
        self.assertEqual(judge(pull, 300)["status"], "pending")
        self.assertEqual(judge(pull, M.PENDING_TIMEOUT_SECONDS + 60)["status"], "timeout")

    def test_thumbs_up_without_summary_is_lgtm_with_unknown_commit(self):
        result = judge(pr(reactions=[reaction("THUMBS_UP", 120)]), 600)
        self.assertEqual(result["status"], "lgtm")
        self.assertIsNone(result["reviewed_commit"])
        self.assertIsNone(result["stale"])

    def test_completed_summary_without_review_is_lgtm_before_thumbs_arrive(self):
        # 실측: Completed는 👍보다 2~5초 먼저 찍힌다.
        pull = pr(comments=[comment(summary_body("Completed", 118), 21)])
        result = judge(pull, 119)
        self.assertEqual(result["status"], "lgtm")
        self.assertEqual(result["reviewed_commit"], HEAD[:7])
        self.assertIs(result["stale"], False)

    def test_lgtm_on_older_commit_is_stale(self):
        pull = pr(comments=[comment(summary_body("Completed", 118, commit=OLD[:7]), 21)],
                  reactions=[reaction("THUMBS_UP", 121)])
        result = judge(pull, 600)
        self.assertEqual(result["status"], "lgtm")
        self.assertIs(result["stale"], True)

    def test_review_object_after_trigger_is_reviewed(self):
        pull = pr(reviews=[review(115)], reviewThreads=[thread(at_s=115)],
                  comments=[comment(summary_body("Completed", 118), 21)])
        result = judge(pull, 600)
        self.assertEqual(result["status"], "reviewed")
        self.assertEqual(result["reviewed_commit"], HEAD)
        self.assertIs(result["stale"], False)
        self.assertIn("1개", result["reason"])

    def test_review_on_older_commit_is_stale(self):
        result = judge(pr(reviews=[review(115, oid=OLD)]), 600)
        self.assertEqual(result["status"], "reviewed")
        self.assertIs(result["stale"], True)

    def test_review_takes_precedence_over_other_signals(self):
        pull = pr(reviews=[review(115)], reactions=[reaction("EYES", 20)], comments=[comment(LIMIT_BODY, 5)])
        self.assertEqual(judge(pull, 600)["status"], "reviewed")

    def test_limit_comment_is_limited(self):
        self.assertEqual(judge(pr(comments=[comment(LIMIT_BODY, 5)]), 600)["status"], "limited")

    def test_failure_and_account_comments_are_failed(self):
        failed = judge(pr(comments=[comment(FAILURE_BODY, 30)]), 600)
        self.assertEqual(failed["status"], "failed")
        self.assertIn("오류", failed["reason"])
        account = judge(pr(comments=[comment(ACCOUNT_BODY, 30)]), 600)
        self.assertEqual(account["status"], "failed")
        self.assertIn("계정", account["reason"])

    def test_failed_summary_status_is_failed_with_raw_status(self):
        result = judge(pr(comments=[comment(summary_body("Failed", 60), 21)]), 600)
        self.assertEqual(result["status"], "failed")
        self.assertIn("Failed", result["reason"])

    def test_unrecognized_summary_status_waits_until_timeout(self):
        # 처음 보는 상태는 실패로 단정하지 않는다(실패로 보면 봇 리뷰 없이 머지로 이어진다).
        pull = pr(comments=[comment(summary_body("Queued", 60), 21)])
        waiting = judge(pull, 600)
        self.assertEqual(waiting["status"], "pending")
        self.assertIn("Queued", waiting["reason"])
        self.assertEqual(judge(pull, M.PENDING_TIMEOUT_SECONDS + 1)["status"], "timeout")

    def test_legacy_lgtm_comment_reports_commit(self):
        result = judge(pr(comments=[comment(LEGACY_LGTM_BODY, 90)]), 600)
        self.assertEqual(result["status"], "lgtm")
        self.assertEqual(result["reviewed_commit"], HEAD[:10])
        self.assertIs(result["stale"], False)

    def test_signals_from_impostors_are_ignored(self):
        pull = pr(
            comments=[comment(LIMIT_BODY, 5, author=IMPOSTOR), comment(summary_body("Completed", 90), 21, author=IMPOSTOR)],
            reactions=[reaction("THUMBS_UP", 90, user=IMPOSTOR_REACTOR), reaction("EYES", 20, user={"login": "owner-user", "databaseId": 1001})],
            reviews=[review(90, author=IMPOSTOR), review(91, author=OTHER_BOT)],
        )
        self.assertEqual(judge(pull, 600)["status"], "absent")

    def test_ready_for_review_resets_trigger(self):
        # 생성 직후 👍를 받았더라도 draft로 되돌렸다가 ready로 바꾸면 그 뒤 신호만 본다.
        pull = pr(reactions=[reaction("THUMBS_UP", 100)], readyEvents=[{"createdAt": ts(1000)}])
        pending = judge(pull, 1030)
        self.assertEqual(pending["status"], "pending")
        self.assertEqual(pending["trigger"]["kind"], "ready_for_review")
        self.assertEqual(judge(pull, 1000 + M.ABSENT_AFTER_SECONDS + 1)["status"], "absent")

    def test_review_request_comment_starts_new_cycle(self):
        base = dict(
            reviews=[review(115, oid=OLD)],
            reviewThreads=[thread(at_s=115)],
            comments=[comment(summary_body("Completed", 118, commit=OLD[:7]), 21), comment("@codex review", 2000, author=ME)],
        )
        waiting = judge(pr(**base), 2030)
        self.assertEqual(waiting["status"], "pending")
        self.assertEqual(waiting["trigger"]["kind"], "review_request")
        self.assertEqual(waiting["rereview_requests"], 1)
        ignored = judge(pr(**base), 2000 + M.ABSENT_AFTER_SECONDS + 1)
        self.assertEqual(ignored["status"], "absent")
        self.assertIn("재리뷰", ignored["settings_warning"])

    def test_review_request_completed_without_findings_is_lgtm(self):
        comments = [comment(summary_body("Completed", 2100, trigger="Comment"), 21), comment("@codex review", 2000, author=ME)]
        pull = pr(reviews=[review(115, oid=OLD)], comments=comments, reactions=[reaction("THUMBS_UP", 500)])
        result = judge(pull, 2200)
        self.assertEqual(result["status"], "lgtm")
        self.assertIs(result["stale"], False)

    def test_review_request_with_new_findings_is_reviewed(self):
        pull = pr(reviews=[review(115, oid=OLD), review(2100)], comments=[comment("@codex review", 2000, author=ME)])
        result = judge(pull, 2200)
        self.assertEqual(result["status"], "reviewed")
        self.assertEqual(result["reviewed_commit"], HEAD)

    def test_review_request_matching_rules(self):
        comments = [
            comment("@Codex Review", 100, author=ME),
            comment("@codex review\n\nFocus on the parser.", 200, author=OTHER_USER, association="COLLABORATOR"),
            comment("@codex security review", 300, author=ME),
            comment("> @codex review", 400, author=ME),
            comment("please @codex review", 500, author=ME),
            comment("@codex reviews", 600, author=ME),
            comment("@codex review", 700, author=OTHER_BOT),
        ]
        result = judge(pr(comments=comments), 800)
        self.assertEqual(result["rereview_requests"], 2)
        self.assertEqual(result["trigger"]["at"], ts(200))

    def test_outsider_request_does_not_move_trigger_or_budget(self):
        # 공개 저장소에서는 권한 없는 사람도 코멘트할 수 있다. 그 요청은 트리거와 요청 횟수에 넣지 않는다.
        base = dict(reviews=[review(115, oid=OLD)], reviewThreads=[thread(at_s=115)])
        outsider = judge(pr(comments=[comment("@codex review", 2000, author=OTHER_USER, association="NONE")], **base), 2500)
        self.assertEqual(outsider["status"], "reviewed")
        self.assertEqual(outsider["trigger"]["kind"], "pr_opened")
        self.assertEqual(outsider["rereview_requests"], 0)
        self.assertIs(outsider["stale"], True)
        member = judge(pr(comments=[comment("@codex review", 2000, author=OTHER_USER, association="MEMBER")], **base), 2030)
        self.assertEqual(member["trigger"]["kind"], "review_request")
        self.assertEqual(member["rereview_requests"], 1)

    def test_latest_result_wins_when_two_cycles_follow_the_trigger(self):
        # 요청 뒤 옛 커밋 리뷰 객체가 오고, 그 뒤 head를 지적 없이 리뷰했다.
        comments = [comment("@codex review", 2000, author=ME), comment(LEGACY_LGTM_BODY, 2399),
                    comment(summary_body("Completed", 2400, trigger="Comment"), 21)]
        newer_lgtm = judge(pr(reviews=[review(2100, oid=OLD)], comments=comments), 2500)
        self.assertEqual(newer_lgtm["status"], "lgtm")
        self.assertIs(newer_lgtm["stale"], False)
        newer_review = judge(pr(reviews=[review(2400)], comments=[comment("@codex review", 2000, author=ME),
                                                                  comment(LEGACY_LGTM_BODY, 2100)]), 2500)
        self.assertEqual(newer_review["status"], "reviewed")

    def test_stale_eyes_from_older_cycle_still_waits_until_timeout(self):
        pull = pr(reactions=[reaction("EYES", 20)], comments=[comment("@codex review", 2000, author=ME)])
        self.assertEqual(judge(pull, 2000 + 300)["status"], "pending")
        self.assertEqual(judge(pull, 2000 + M.PENDING_TIMEOUT_SECONDS + 1)["status"], "timeout")

    def test_signals_before_trigger_are_ignored(self):
        pull = pr(comments=[comment(LIMIT_BODY, 5), comment("@codex review", 2000, author=ME)])
        self.assertEqual(judge(pull, 2030)["status"], "pending")

    def test_signal_at_exact_trigger_time_counts(self):
        self.assertEqual(judge(pr(reactions=[reaction("THUMBS_UP", 0)]), 600)["status"], "lgtm")

    def test_security_review_limit_is_not_a_code_review_limit(self):
        running = pr(comments=[comment(summary_body("Running", 3), 1), comment(SECURITY_LIMIT_BODY, 5)],
                     reactions=[reaction("EYES", 2)])
        self.assertEqual(judge(running, 60)["status"], "pending")
        self.assertEqual(judge(pr(comments=[comment(SECURITY_LIMIT_BODY, 5)]), 60)["status"], "pending")
        self.assertEqual(judge(pr(comments=[comment(SECURITY_LIMIT_BODY, 5)]), 600)["status"], "absent")

    def test_notice_during_fresh_running_review_keeps_waiting(self):
        pull = pr(comments=[comment(summary_body("Running", 3), 1), comment(ACCOUNT_BODY, 40), comment(FAILURE_BODY, 41)])
        self.assertEqual(judge(pull, 120)["status"], "pending")

    def test_limit_after_new_trigger_beats_stuck_running_row_from_old_cycle(self):
        pull = pr(comments=[comment(summary_body("Running", 3), 1), comment("@codex review", 2000, author=ME),
                            comment(LIMIT_BODY, 2005)],
                  reactions=[reaction("EYES", 2)])
        self.assertEqual(judge(pull, 2060)["status"], "limited")

    def test_new_review_cycle_after_lgtm_is_pending_from_its_start(self):
        # push로 다시 도는 리뷰: 지난 👍는 이번 결과가 아니고, 대기 한도는 새 리뷰 시작부터 잰다.
        pull = pr(reactions=[reaction("THUMBS_UP", 183), reaction("EYES", 5000)],
                  comments=[comment(summary_body("Running", 5001, trigger="New commits"), 21)])
        waiting = judge(pull, 5100)
        self.assertEqual(waiting["status"], "pending")
        self.assertIn("봇의 리뷰 시작부터", waiting["reason"])
        # 대기는 봇의 리뷰 시작부터 재도, trigger 필드는 트리거 기준 경과를 낸다.
        self.assertEqual(waiting["trigger"]["elapsed_seconds"], 5100)
        self.assertEqual(judge(pull, 5001 + M.PENDING_TIMEOUT_SECONDS)["status"], "pending")
        self.assertEqual(judge(pull, 5002 + M.PENDING_TIMEOUT_SECONDS)["status"], "timeout")

    def test_new_review_cycle_after_findings_ignores_old_review(self):
        pull = pr(reviews=[review(115, oid=OLD)], reviewThreads=[thread(at_s=115)],
                  comments=[comment(summary_body("Running", 4000, trigger="New commits"), 21)])
        self.assertEqual(judge(pull, 4100)["status"], "pending")
        finished = pr(reviews=[review(115, oid=OLD), review(4200)], reviewThreads=[thread(at_s=115), thread(at_s=4200)],
                      comments=[comment(summary_body("Completed", 4203, trigger="New commits"), 21)])
        result = judge(finished, 4300)
        self.assertEqual(result["status"], "reviewed")
        self.assertEqual(result["reviewed_commit"], HEAD)
        self.assertIn("1개", result["reason"])

    def test_running_indicator_older_than_result_does_not_hide_result(self):
        # 👀가 남아 있어도 그 뒤에 리뷰 객체가 왔으면 리뷰는 끝났다.
        pull = pr(reactions=[reaction("EYES", 3)], reviews=[review(180)])
        self.assertEqual(judge(pull, 185)["status"], "reviewed")

    def test_duplicate_summaries_prefer_the_live_running_row(self):
        comments = [
            comment("@codex review", 2000, author=ME),
            comment(summary_body("Running", 2001, trigger="Manual request"), 1999),
            comment(summary_body("Failed", 2001), 2000),
        ]
        self.assertEqual(judge(pr(comments=comments), 2100)["status"], "pending")
        done = comments[:1] + [comment(summary_body("Completed", 2200, trigger="Manual request"), 1999), comments[2]]
        self.assertEqual(judge(pr(comments=done), 2300)["status"], "lgtm")

    def test_legacy_phrase_must_open_the_comment(self):
        quoted = "Earlier note: Codex Review: Didn't find any major issues.\n"
        self.assertEqual(judge(pr(comments=[comment(quoted, 90)]), 600)["status"], "absent")

    def test_closed_pr_is_still_judged(self):
        result = judge(pr(state="MERGED", comments=[comment(LIMIT_BODY, 5)]), 600)
        self.assertEqual(result["status"], "limited")
        self.assertEqual(result["pr_state"], "MERGED")

    def test_invalid_created_at_raises_tool_error(self):
        with self.assertRaises(M.ToolError):
            judge(pr(createdAt="not-a-time"), 10)


class ThreadTests(unittest.TestCase):
    def test_missing_items_are_reported_per_thread(self):
        threads = [
            thread(at_s=100, title="Needs all"),
            thread(at_s=200, replies=[ME], reaction_groups=[{"content": "THUMBS_UP", "viewerHasReacted": True}], resolved=True, title="Done"),
            thread(at_s=300, replies=[ME], resolved=True, title="No reaction", priority="P2"),
            thread(at_s=400, replies=[OTHER_BOT], reaction_groups=[{"content": "HEART", "viewerHasReacted": True}], title="Bot reply only"),
            thread(at_s=500, root_author=ME, title="Human thread"),
            thread(at_s=600, reaction_groups=[{"content": "THUMBS_DOWN", "viewerHasReacted": True},
                                              {"content": "THUMBS_UP", "viewerHasReacted": False}], replies=[(OTHER_USER, "COLLABORATOR")], resolved=True, outdated=True, line=None, title="Rejected"),
        ]
        result = judge(pr(reviewThreads=threads, reviews=[review(100)]), 1000)
        self.assertEqual(result["bot_threads"], 5)
        by_title = {t["title"]: t for t in result["unhandled_threads"]}
        self.assertEqual(set(by_title), {"Needs all", "No reaction", "Bot reply only"})
        self.assertEqual(by_title["Needs all"]["missing"], ["reply", "reaction", "resolve"])
        self.assertEqual(by_title["No reaction"]["missing"], ["reaction"])
        self.assertEqual(by_title["No reaction"]["priority"], "P2")
        self.assertEqual(by_title["Bot reply only"]["missing"], ["reply", "reaction", "resolve"])
        self.assertEqual(by_title["Needs all"]["path"], "modules/x.sh")
        self.assertEqual(by_title["Needs all"]["line"], 42)
        self.assertEqual(by_title["Needs all"]["thread_id"], "PRRT_100")

    def test_outsider_reply_does_not_count_but_pr_author_does(self):
        outsider = judge(pr(reviewThreads=[thread(replies=[(OTHER_USER, "NONE")])]), 1000)
        self.assertIn("reply", outsider["unhandled_threads"][0]["missing"])
        # 외부 기여 PR의 작성자는 저장소 권한이 없어도 자기 PR의 봇 스레드에 답할 수 있다.
        contributor = {"__typename": "User", "login": "contributor", "databaseId": 1003}
        own = pr(author={"login": "contributor"}, reviewThreads=[thread(replies=[(contributor, "CONTRIBUTOR")])])
        self.assertNotIn("reply", judge(own, 1000, viewer="contributor")["unhandled_threads"][0]["missing"])

    def test_others_reactions_do_not_count_as_mine(self):
        groups = [{"content": content, "viewerHasReacted": False}
                  for content in ("THUMBS_UP", "THUMBS_DOWN", "LAUGH", "HOORAY", "CONFUSED", "HEART", "ROCKET", "EYES")]
        result = judge(pr(reviewThreads=[thread(replies=[ME], resolved=True, reaction_groups=groups)]), 1000)
        self.assertEqual(result["unhandled_threads"][0]["missing"], ["reaction"])

    def test_comment_id_comes_from_full_database_id(self):
        result = judge(pr(reviewThreads=[thread(at_s=100)]), 1000)
        self.assertEqual(result["unhandled_threads"][0]["comment_id"], 4113267058)
        legacy = thread(at_s=100)
        legacy["comments"]["nodes"][0].pop("fullDatabaseId")
        self.assertIsNone(judge(pr(reviewThreads=[legacy]), 1000)["unhandled_threads"][0]["comment_id"])

    def test_outdated_thread_falls_back_to_original_line(self):
        result = judge(pr(reviewThreads=[thread(line=None, outdated=True)]), 1000)
        entry = result["unhandled_threads"][0]
        self.assertEqual(entry["line"], 40)
        self.assertIs(entry["outdated"], True)

    def test_title_falls_back_to_first_line(self):
        plain = thread()
        plain["comments"]["nodes"][0]["body"] = "Plain first line\nmore"
        result = judge(pr(reviewThreads=[plain]), 1000)
        self.assertEqual(result["unhandled_threads"][0]["title"], "Plain first line")
        self.assertIsNone(result["unhandled_threads"][0]["priority"])


def as_connection(nodes, has_next=False, cursor=None):
    return {"pageInfo": {"hasNextPage": has_next, "endCursor": cursor}, "nodes": nodes}


def graphql_response(pull, viewer="owner-user", owner="owner-user", pages=None):
    """evaluate() 입력 형태의 PR을 GraphQL 응답 형태로 바꾼다. pages에 있는 alias는 다음 페이지가 있다."""
    pages = pages or {}
    node = {key: value for key, value in pull.items()
            if key not in ("reactions", "readyEvents", "comments", "reviews", "reviewThreads")}
    for alias in ("reactions", "readyEvents", "comments", "reviews", "reviewThreads"):
        node[alias] = as_connection(pull[alias], has_next=alias in pages, cursor="c1" if alias in pages else None)
    return {"data": {"viewer": {"login": viewer},
                     "repository": {"nameWithOwner": "%s/repo" % owner, "owner": {"login": owner}, "pullRequest": node}}}


def page_response(alias, nodes, has_next=False, cursor=None):
    return {"data": {"repository": {"pullRequest": {alias: as_connection(nodes, has_next, cursor)}}}}


FAKE_GH = r'''#!{python}
import json, os, re, sys
scenario = json.load(open(os.environ["FAKE_GH_SCENARIO"], encoding="utf-8"))
args = sys.argv[1:]
import time
time.sleep(float(os.environ.get("FAKE_GH_DELAY", "0")))
env = {{key: os.environ.get(key) for key in ("GH_FORCE_TTY", "CLICOLOR_FORCE", "NO_COLOR", "GH_PROMPT_DISABLED")}}
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({{"bin": os.path.basename(sys.argv[0]), "args": args, "env": env}}) + "\n")
def reply(value):
    if isinstance(value, dict) and "__delay__" in value:
        time.sleep(value["__delay__"])
        value = value["payload"]
    if isinstance(value, dict) and "__exit__" in value:
        sys.stderr.write(value.get("stderr", ""))
        sys.exit(value["__exit__"])
    sys.stdout.write(value if isinstance(value, str) else json.dumps(value))
    sys.exit(0)
if args[:2] == ["repo", "view"]:
    reply(scenario["repo"] + "\n")
if args[:2] == ["pr", "view"]:
    reply(scenario["pr_url"] + "\n")
if args[:2] == ["api", "graphql"]:
    fields = {{}}
    i = 2
    while i < len(args):
        if args[i] in ("-f", "-F"):
            key, _, value = args[i + 1].partition("=")
            fields[key] = value
            i += 2
        else:
            i += 1
    if "after" in fields:
        alias = re.search(r"pullRequest\(number: \$number\) \{{ (\w+):", fields["query"]).group(1)
        reply(scenario["pages"][alias][fields["after"]])
    state = os.environ["FAKE_GH_STATE"]
    count = int(open(state).read()) if os.path.exists(state) else 0
    with open(state, "w") as handle:
        handle.write(str(count + 1))
    mains = scenario["main"]
    reply(mains[min(count, len(mains) - 1)])
sys.stderr.write("unexpected gh call: %r\n" % (args,))
sys.exit(97)
'''


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        self.fake = self.bin / "gh"
        self.fake.write_text(FAKE_GH.format(python=sys.executable), encoding="utf-8")
        self.fake.chmod(0o755)
        self.scenario_path = root / "scenario.json"
        self.log = root / "calls.jsonl"
        self.state = root / "state"

    def run_cli(self, *args, scenario, env_extra=None, use_override=True):
        self.scenario_path.write_text(json.dumps(scenario), encoding="utf-8")
        env = {
            "PATH": "%s:/usr/bin:/bin" % self.bin,
            "HOME": self.tmp.name,
            "FAKE_GH_SCENARIO": str(self.scenario_path),
            "FAKE_GH_LOG": str(self.log),
            "FAKE_GH_STATE": str(self.state),
            "CODEX_REVIEW_STATUS_NOW": ts(600),
            "CODEX_REVIEW_STATUS_POLL_SECONDS": "0.05",
        }
        if use_override:
            env["CODEX_REVIEW_STATUS_GH"] = str(self.fake)
        env.update(env_extra or {})
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=60)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def assert_read_only(self):
        for call in self.calls():
            args = call["args"]
            self.assertIn(args[:2], (["api", "graphql"], ["repo", "view"], ["pr", "view"]), args)
            if args[:2] == ["api", "graphql"]:
                query = next(a for a in args if a.startswith("query="))
                self.assertTrue(query.startswith("query=query("), query[:40])
                self.assertNotIn("mutation", query)
                self.assertNotIn("-X", args)
                self.assertNotIn("--method", args)

    def test_json_output_for_reviewed_pr(self):
        pull = pr(reviews=[review(115)], reviewThreads=[thread(at_s=115)], comments=[comment(summary_body("Completed", 118), 21)])
        proc = self.run_cli("7", "-R", "owner-user/repo", "--json", scenario={"main": [graphql_response(pull)]})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["status"], "reviewed")
        self.assertEqual(result["repo"], "owner-user/repo")
        self.assertEqual(len(result["unhandled_threads"]), 1)
        graphql_calls = [c for c in self.calls() if c["args"][:2] == ["api", "graphql"]]
        self.assertEqual(len(graphql_calls), 1)
        args = graphql_calls[0]["args"]
        self.assertIn("owner=owner-user", args)
        self.assertIn("name=repo", args)
        self.assertEqual(args[args.index("number=7") - 1], "-F")
        self.assert_read_only()

    def test_text_output_lists_unhandled_threads(self):
        pull = pr(reviews=[review(115, oid=OLD)], reviewThreads=[thread(at_s=115, title="Fix the race")])
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": [graphql_response(pull)]})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("상태: reviewed", proc.stdout)
        self.assertIn("head와 다름", proc.stdout)
        self.assertIn("[P1] modules/x.sh:42 Fix the race", proc.stdout)
        self.assertIn("빠진 처리: 답글, 반응, resolve", proc.stdout)

    def test_paginated_connections_are_merged(self):
        first_comments = [comment(summary_body("Completed", 118, commit=OLD[:7]), 21)]
        pull = pr(reviews=[review(115, oid=OLD)], comments=first_comments, reviewThreads=[thread(at_s=115)])
        scenario = {
            "main": [graphql_response(pull, pages={"comments": True, "reviewThreads": True})],
            "pages": {
                "comments": {"c1": page_response("comments", [comment("@codex review", 2000, author=ME)], True, "c2"),
                             "c2": page_response("comments", [comment("noise", 2001, author=ME)])},
                "reviewThreads": {"c1": page_response("reviewThreads", [thread(at_s=116, title="Second page")])},
            },
        }
        proc = self.run_cli("7", "-R", "owner-user/repo", "--json", scenario=scenario, env_extra={"CODEX_REVIEW_STATUS_NOW": ts(2030)})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["trigger"]["kind"], "review_request")
        self.assertEqual(result["status"], "pending")
        self.assertEqual(result["bot_threads"], 2)
        page_calls = [c for c in self.calls() if any(a.startswith("after=") for a in c["args"])]
        self.assertEqual(sorted(a for c in page_calls for a in c["args"] if a.startswith("after=")), ["after=c1", "after=c1", "after=c2"])
        self.assert_read_only()

    def test_wait_polls_until_state_leaves_pending(self):
        pending = pr(reactions=[reaction("EYES", 20)])
        done = pr(reactions=[reaction("THUMBS_UP", 120)])
        scenario = {"main": [graphql_response(pending), graphql_response(pending), graphql_response(done)]}
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "30", "--json", scenario=scenario)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["status"], "lgtm")
        self.assertEqual(len([c for c in self.calls() if c["args"][:2] == ["api", "graphql"]]), 3)

    def test_wait_budget_returns_pending(self):
        scenario = {"main": [graphql_response(pr(reactions=[reaction("EYES", 20)]))]}
        started = time.monotonic()
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "1", "--json", scenario=scenario)
        elapsed = time.monotonic() - started
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["status"], "pending")
        self.assertLess(elapsed, 20)
        self.assertGreaterEqual(len(self.calls()), 2)

    def test_wait_does_not_start_a_fetch_it_cannot_finish(self):
        scenario = {"main": [graphql_response(pr(reactions=[reaction("EYES", 20)]))]}
        started = time.monotonic()
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "1", "--json", scenario=scenario,
                            env_extra={"FAKE_GH_DELAY": "0.6"})
        elapsed = time.monotonic() - started
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["status"], "pending")
        # --wait 1에 조회 한 번 0.6초: 두 번째 조회는 한도 안에 끝나지 않으므로 시작하지 않는다.
        self.assertEqual(len(self.calls()), 1)
        self.assertLess(elapsed, 5)

    def test_wait_survives_a_transient_fetch_error(self):
        pending = graphql_response(pr(reactions=[reaction("EYES", 20)]))
        done = graphql_response(pr(reactions=[reaction("THUMBS_UP", 120)]))
        failure = {"__exit__": 1, "stderr": "HTTP 502: Bad Gateway"}
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "30", "--json",
                            scenario={"main": [pending, failure, done]})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["status"], "lgtm")
        self.assertIn("조회 실패 1/3", proc.stderr)
        self.assertIn("HTTP 502", proc.stderr)

    def test_wait_stops_after_consecutive_fetch_failures(self):
        pending = graphql_response(pr(reactions=[reaction("EYES", 20)]))
        failure = {"__exit__": 1, "stderr": "HTTP 502: Bad Gateway"}
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "30", "--json",
                            scenario={"main": [pending, failure]})
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        self.assertIn("조회 실패 3/3", proc.stderr)
        self.assertEqual(len(self.calls()), 4)

    def test_wait_fetch_is_bounded_by_the_remaining_budget(self):
        # 두 번째 조회가 느려도 --wait 한도에서 끊고 마지막 결과를 낸다.
        pending = graphql_response(pr(reactions=[reaction("EYES", 20)]))
        slow = {"__delay__": 20, "payload": pending}
        started = time.monotonic()
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "2", "--json", scenario={"main": [pending, slow]})
        elapsed = time.monotonic() - started
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["status"], "pending")
        self.assertLess(elapsed, 8)
        self.assertIn("조회 실패 1/3", proc.stderr)

    def test_output_survives_a_non_utf8_stdout(self):
        pull = pr(reviews=[review(115)], reviewThreads=[thread(at_s=115)])
        for extra in ([], ["--json"]):
            proc = self.run_cli("7", "-R", "owner-user/repo", *extra, scenario={"main": [graphql_response(pull)]},
                                env_extra={"PYTHONIOENCODING": "ascii"})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("Traceback", proc.stderr)
            self.assertIn("reviewed", proc.stdout)

    def test_wait_reports_progress_on_stderr(self):
        scenario = {"main": [graphql_response(pr(reactions=[reaction("EYES", 20)]))]}
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "1", scenario=scenario)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stderr.count("대기 중"), 1, proc.stderr)
        self.assertIn("봇 리뷰 진행 중", proc.stderr)

    def test_page_cap_and_missing_cursor_fail_cleanly(self):
        endless = {
            "main": [graphql_response(pr(), pages={"comments": True})],
            "pages": {"comments": {"c1": page_response("comments", [], True, "c1")}},
        }
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario=endless)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("페이지가 %d개를 넘는다" % M.MAX_PAGES_PER_CONNECTION, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)
        no_cursor = graphql_response(pr())
        no_cursor["data"]["repository"]["pullRequest"]["reviews"]["pageInfo"] = {"hasNextPage": True, "endCursor": None}
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": [no_cursor]})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("커서가 없다", proc.stderr)

    def test_gh_runs_without_forced_tty_or_color(self):
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": [graphql_response(pr())]},
                            env_extra={"GH_FORCE_TTY": "1", "CLICOLOR_FORCE": "1"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        env = self.calls()[0]["env"]
        self.assertIsNone(env["GH_FORCE_TTY"])
        self.assertIsNone(env["CLICOLOR_FORCE"])
        self.assertEqual(env["NO_COLOR"], "1")
        self.assertEqual(env["GH_PROMPT_DISABLED"], "1")

    def test_unusable_inputs_fail_without_traceback(self):
        not_executable = self.bin / "not-executable"
        not_executable.write_text("#!/bin/sh\n", encoding="utf-8")
        not_executable.chmod(0o644)
        cases = [
            {"CODEX_REVIEW_STATUS_GH": str(not_executable)},
            {"CODEX_REVIEW_STATUS_POLL_SECONDS": "nan"},
            {"CODEX_REVIEW_STATUS_NOW": "0001-01-01T00:00:00+09:00"},
        ]
        for env_extra in cases:
            proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "1", scenario={"main": [graphql_response(pr())]},
                                env_extra=env_extra)
            self.assertEqual(proc.returncode, 1, (env_extra, proc.stderr))
            self.assertNotIn("Traceback", proc.stderr, env_extra)
            self.assertTrue(proc.stderr.startswith("codex-review-status: "), (env_extra, proc.stderr))

    def test_no_wait_queries_once_even_when_pending(self):
        scenario = {"main": [graphql_response(pr(reactions=[reaction("EYES", 20)]))]}
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario=scenario)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_wait_above_cap_is_clamped_with_notice(self):
        scenario = {"main": [graphql_response(pr(reactions=[reaction("THUMBS_UP", 120)]))]}
        proc = self.run_cli("7", "-R", "owner-user/repo", "--wait", "100000", scenario=scenario)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("540", proc.stderr)

    def test_pr_url_sets_repository(self):
        scenario = {"main": [graphql_response(pr(), owner="other-owner")]}
        proc = self.run_cli("https://github.com/other-owner/repo/pull/7/files", "--json", scenario=scenario)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        args = self.calls()[0]["args"]
        self.assertIn("owner=other-owner", args)
        self.assertEqual(json.loads(proc.stdout)["repo"], "other-owner/repo")

    def test_missing_pr_argument_uses_current_branch(self):
        scenario = {"pr_url": "https://github.com/owner-user/repo/pull/7", "main": [graphql_response(pr())]}
        proc = self.run_cli("--json", scenario=scenario)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.calls()[0]["args"][:2], ["pr", "view"])
        self.assert_read_only()

    def test_number_without_repo_uses_current_repository(self):
        scenario = {"repo": "owner-user/repo", "main": [graphql_response(pr())]}
        proc = self.run_cli("#7", "--json", scenario=scenario)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.calls()[0]["args"][:2], ["repo", "view"])

    def test_usage_errors_exit_2(self):
        for args in (["abc"], ["-R", "owner-user/repo"], ["7", "-R", "not-a-repo"], ["7", "--wait", "-1"]):
            proc = self.run_cli(*args, scenario={"main": [graphql_response(pr())]})
            self.assertEqual(proc.returncode, 2, (args, proc.stderr))
        self.assertEqual(self.calls(), [])

    def test_repo_mismatch_with_url_fails(self):
        proc = self.run_cli("https://github.com/a/b/pull/7", "-R", "c/d", scenario={"main": [graphql_response(pr())]})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("다르다", proc.stderr)
        self.assertEqual(self.calls(), [])

    def test_gh_failure_exits_1_with_detail(self):
        scenario = {"main": [{"__exit__": 4, "stderr": "HTTP 401: Bad credentials"}]}
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario=scenario)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Bad credentials", proc.stderr)
        self.assertEqual(proc.stdout, "")

    def test_graphql_errors_and_missing_pr_exit_1(self):
        errors = {"main": [{"errors": [{"message": "Something broke"}], "data": None}]}
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario=errors)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Something broke", proc.stderr)
        missing = {"main": [{"data": {"viewer": {"login": "owner-user"},
                                      "repository": {"nameWithOwner": "owner-user/repo", "owner": {"login": "owner-user"}, "pullRequest": None}}}]}
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario=missing)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("PR을 찾지 못했다", proc.stderr)

    def test_non_json_response_exits_1(self):
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": ["not json"]})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("JSON", proc.stderr)

    def test_invalid_now_override_exits_1(self):
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": [graphql_response(pr())]},
                            env_extra={"CODEX_REVIEW_STATUS_NOW": "yesterday"})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("CODEX_REVIEW_STATUS_NOW", proc.stderr)

    def test_gh_auth_wrapper_is_preferred_on_path(self):
        wrapper = self.bin / "gh-auth"
        wrapper.write_text(FAKE_GH.format(python=sys.executable), encoding="utf-8")
        wrapper.chmod(0o755)
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": [graphql_response(pr())]}, use_override=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual({c["bin"] for c in self.calls()}, {"gh-auth"})

    def test_plain_gh_is_used_without_wrapper(self):
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": [graphql_response(pr())]}, use_override=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual({c["bin"] for c in self.calls()}, {"gh"})

    def test_missing_gh_binary_exits_1(self):
        proc = self.run_cli("7", "-R", "owner-user/repo", scenario={"main": []},
                            env_extra={"CODEX_REVIEW_STATUS_GH": str(self.bin / "does-not-exist")})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("찾지 못했다", proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
