# 이슈 코멘트 이행 가이드

[guide-template.md](guide-template.md)의 구조 중 작업에 필요한 항목으로 작성한다. 공개 게시 전 [sanitization-checklist.md](sanitization-checklist.md)를 전체 적용하고, 확인한 동일 이슈 참조에 파일로 게시한다.

## Step 1: 이슈 내용 읽기 + 컨텍스트 확보

이슈 번호 또는 URL을 파싱한다. 기본 모드에서 수신한 인자가 비어있으면 런타임 도구 매핑 표의 질문 도구로 이슈 번호 또는 URL을 요청한다.

```bash
# 이슈 번호인 경우
gh issue view <number> --json title,body,labels,assignees,comments

# URL인 경우
gh issue view <url> --json title,body,labels,assignees,comments
```

bare 번호 입력 시 cwd 확인 필수: 전달된 값이 `123`, `#123` 같은 bare 번호이고 `gh repo view --json nameWithOwner -q .nameWithOwner`로 확인한 cwd repo가 handoff 대상 repo와 다를 가능성이 있으면, 질문 도구로 사용자에게 이슈 URL(`https://github.com/owner/repo/issues/N` 형태)을 재확인받은 뒤 그 URL로 `gh issue view`를 재실행한다. 확인 없이 진행하면 cwd repo의 동일 번호 이슈에 잘못 코멘트가 게시될 수 있다.

이슈 본문, 라벨, 기존 코멘트를 분석하여 작업 범위를 파악한다.

## 기본 모드: 이슈 코멘트 게시

작성한 가이드를 이슈 코멘트로 게시한다. `--body-file`만 허용한다. 본문에는 `$HOME`, `$(...)`, 백틱, 큰따옴표, 내부 `EOF` 등 셸 해석 토큰이 포함될 수 있으며, 재현이나 명령 예시 안에 `cat <<'EOF'...EOF`가 들어갈 수도 있다. 따라서 `$(cat <<'EOF' ... EOF)` 래퍼는 inner `EOF`에서 조기 종료되어 본문이 잘리거나 명령이 실행된다. `--body "<본문>"` 직접 전달과 quoted HEREDOC 모두 금지.

```bash
# 필수: 본문을 파일에 저장한 뒤 --body-file로 전달.
# 게시 대상은 처음 이슈를 읽을 때의 참조를 그대로 쓴다 — URL로 받았으면 URL을 그대로 전달한다.
# bare number만 쓰면 cwd origin의 동번 이슈로 게시되어, sanitization에서 검사한 대상과
# 실제 write sink가 어긋날 수 있다 (sanitization checklist S3의 게시 대상 결합 규칙).
gh issue comment <이슈 참조(URL 또는 number)> --body-file <path-to-guide.md>
```

참고: `gh issue comment --body-file -`로 stdin도 허용되지만, 생성된 가이드를 파일로 저장하는 워크플로가 디버깅·재실행에 유리하다.
