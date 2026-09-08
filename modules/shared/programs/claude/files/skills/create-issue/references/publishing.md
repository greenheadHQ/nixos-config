# 이슈 게시와 결과 처리

작성 기준과 Step 2~4는 [SKILL.md](../SKILL.md), parent 연결(Step 5-B)은 [parent-linking.md](parent-linking.md)가 소유한다. `OWNER`/`REPO`/ID 의미도 parent-linking의 변수 계약을 따른다.

## Step 5 — 등록 및 확인

Step 5는 두 하위 단계로 진행한다. 진행/차단 규칙은 아래 매트릭스 하나로 통합한다 — 각 세부 단계의 실패 처리는 이 표를 참조한다.

진행 상태 매트릭스

| 상태 (Step 5 출력) | Step 5-B 진행 | Step 6 진행 | 사용자/운영자 보고 의무 |
|--------------------|---------------|-------------|--------------------------|
| Step 5-A `gh issue create` 실패 (`ERROR:` + `ISSUE_URL` 미반환) | 차단 | 차단 | 원격 게시 여부 확인 전 재시도 금지, 본문 보존 후 `exit 1` |
| Step 5-A nonzero 종료와 함께 URL 반환 | 원격 게시 확인 후 진행 | 원격 게시 확인 후 진행 | 첨부 일부 실패 가능성 보고, 기존 URL 재사용 |
| Step 5-A URL validation 실패 (반환값이 `https://github.com/.../issues/N` 형식 아님) | 차단 | 차단 | `ERROR:` + 원격 게시 여부 확인 |
| Step 5-A 성공 + `--parent` 미지정 | Skip (실행 안 됨) | 진행 | `ISSUE_URL`만 출력 (기존 경로, `SUBISSUE_STATUS` 토큰 없음) |
| Step 5-B `SUBISSUE_STATUS=LINKED` | — | 진행 | 성공 로그 |
| Step 5-B `SUBISSUE_STATUS=FAILED_ID_LOOKUP` | — | 진행 | `SUBISSUE_STATUS` 토큰을 최종 응답에 포함, 재시도 명령 명시 |
| Step 5-B `SUBISSUE_STATUS=FAILED_POST` | — | 진행 | 동일 |

`SUBISSUE_STATUS`의 전달 경로는 `/create-issue`의 최종 응답(사용자에게 출력되는 마지막 메시지) 에 명시하는 것으로 scope을 닫는다. Step 6의 `/write-handoff` 호출은 `<ISSUE_URL>`만 전달하므로 `SUBISSUE_STATUS`는 handoff body에 전달되지 않는다 — 운영자는 `/create-issue` 최종 응답의 토큰을 보고 재시도 여부를 판단한다.

### Step 5-A — 이슈 등록

실패 시 진행 차단 정책은 위 진행 상태 매트릭스 참조.

1. 등록 전 제목, 라벨 조합을 사용자에게 보여주고 확인을 받는다.
2. 명시적 이미지·영상이 있으면 [공식 첨부 절차](../../attaching-github-media/SKILL.md)에 따라 본문 참조를 준비하고 아래 `ATTACH_ARGS`를 `(--attach "<파일>")`로 채운다. 첨부가 없으면 빈 배열을 유지한다.
   파일명·설명까지 포함한 최종 본문에 Step 3의 sanitization scan을 적용한다.
3. `gh issue create`를 `--body-file`로 실행한다. 본문은 임시 파일에 저장 후 전달.
   ```bash
   # BSD/macOS mktemp는 템플릿 끝(trailing)에 XXXXXX가 와야 랜덤 치환함.
   # 전용 private 디렉터리만 만들고 본문 target은 첫 편집 전까지 존재하지 않게 둔다.
   # parent 유무와 무관하게 현재 게시 대상 조회. 기존 환경변수는 사용하지 않는다.
   if ! ISSUE_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || [ -z "$ISSUE_REPO" ]; then
     echo "ERROR: 게시 대상 저장소 조회 실패"
     exit 1
   fi
   umask 077
   ISSUE_BODY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/issue-body.XXXXXX") \
     || { echo "ERROR: 본문 임시 디렉터리 생성 실패"; exit 1; }
   chmod 700 "$ISSUE_BODY_DIR" \
     || { echo "ERROR: 본문 임시 디렉터리 권한 설정 실패: $ISSUE_BODY_DIR"; exit 1; }
   ISSUE_BODY="$ISSUE_BODY_DIR/body.md"
   if [ -e "$ISSUE_BODY" ] || [ -L "$ISSUE_BODY" ]; then
     echo "ERROR: 첫 편집 전 본문 target이 이미 존재함: $ISSUE_BODY"
     exit 1
   fi
   # <작성된 본문>을 $ISSUE_BODY에 기록 (파일 편집 도구)

   # 게시 경계에서는 regular file만 허용하고, 편집 도구의 기본 mode와 무관하게 0600으로 고정한다.
   if [ ! -f "$ISSUE_BODY" ] || [ -L "$ISSUE_BODY" ]; then
     echo "ERROR: 본문이 regular non-symlink file이 아님"
     printf 'ISSUE_BODY=%q  # 게시하지 않고 보존됨\n' "$ISSUE_BODY"
     exit 1
   fi
   if ! chmod 600 "$ISSUE_BODY"; then
     echo "ERROR: 본문 파일 권한 설정 실패"
     printf 'ISSUE_BODY=%q  # 게시하지 않고 보존됨\n' "$ISSUE_BODY"
     exit 1
   fi

   ATTACH_ARGS=() # 첨부가 있으면 (--attach "<파일>")로 채운다.
   # 종료 코드와 무관하게 대상 저장소의 URL 및 원격 게시를 확인한다.
   ISSUE_CREATE_RC=0
   ISSUE_URL=$(gh issue create -R "$ISSUE_REPO" --title "<제목>" --label "<라벨>" --body-file "$ISSUE_BODY" "${ATTACH_ARGS[@]}") || ISSUE_CREATE_RC=$?
   echo "ISSUE_URL=$ISSUE_URL"
   ISSUE_CONFIRMED=false
   ISSUE_NUMBER="${ISSUE_URL#"https://github.com/$ISSUE_REPO/issues/"}"
   if [[ "$ISSUE_URL" == "https://github.com/$ISSUE_REPO/issues/$ISSUE_NUMBER" && "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]] &&
      REMOTE_URL=$(gh issue view "$ISSUE_URL" -R "$ISSUE_REPO" --json url -q .url) &&
      [[ "$REMOTE_URL" == "$ISSUE_URL" ]]; then
     ISSUE_CONFIRMED=true
   fi
   if [[ "$ISSUE_CONFIRMED" == true && "$ISSUE_CREATE_RC" == 0 ]]; then
     # GitHub write 성공과 로컬 cleanup 성공을 혼동하지 않는다. 정확한 파일과 빈 디렉터리만 제거한다.
     if ! rm -f "$ISSUE_BODY"; then
       echo "WARN: 이슈는 등록됐지만 본문 파일 정리 실패: $ISSUE_BODY"
     elif ! rmdir "$ISSUE_BODY_DIR"; then
       echo "WARN: 이슈는 등록됐지만 본문 임시 디렉터리 정리 실패: $ISSUE_BODY_DIR"
     fi
   else
     echo "본문 보존: gh issue create exit $ISSUE_CREATE_RC, 원격 확인 $ISSUE_CONFIRMED"
     # 새 셸에서도 같은 파일을 재사용할 수 있는 shell-safe 할당문을 출력한다.
     printf 'ISSUE_BODY=%q\n' "$ISSUE_BODY"
     printf 'ISSUE_BODY_DIR=%q\n' "$ISSUE_BODY_DIR"
     # 본문은 stdout으로 덤프하지 않는다 — 사용자가 실수로 시크릿을 포함한 경우 세션/운영 로그에 남을 위험.
     # 필요 시 로컬 shell에서 직접 확인: `sed -n '1,20p' "$ISSUE_BODY"` 또는 에디터로 열기.
     echo "본문 미리보기는 보안상 stdout 덤프하지 않음. 확인 명령: sed -n '1,20p' \"\$ISSUE_BODY\""
     echo "본문을 수정했다면 게시할 최종 파일에 SKILL.md Step 3의 sanitization checklist S3를 다시 적용한다."
     echo "원격 게시 확인 전 재시도하지 않는다. 이미 등록됐다면 기존 URL을 재사용한다."
     echo "본문 재검사 (새 셸에서는 위 ISSUE_BODY 할당문부터 복사):"
     # 편집기가 파일을 재생성할 수 있으므로 재시도에서도 게시 경계 검사를 통과해야 한다.
     echo "  [ -f \"\$ISSUE_BODY\" ] && [ ! -L \"\$ISSUE_BODY\" ] && chmod 600 \"\$ISSUE_BODY\" || exit 1"
     if [[ "$ISSUE_CONFIRMED" != true ]]; then
       echo "ERROR: 유효한 URL의 원격 게시가 미확인. parent 연결과 handoff를 진행하지 않는다."
       exit 1
     fi
     echo "WARN: 이슈는 등록됐지만 첨부 일부 실패 가능성이 있다. 기존 URL로 후속 단계를 계속하고 누락 첨부만 처리한다."
     echo "첨부 복구를 마친 뒤 보존 본문 파일과 빈 ISSUE_BODY_DIR을 정리한다."
   fi
   ```
4. 위 명령은 대상 저장소의 URL 형식과 원격 게시를 검증한다. nonzero 종료라도 게시가 확인되면 기존 URL로 후속 단계를 계속하고, [첨부 재시도 규칙](../../attaching-github-media/SKILL.md#실패와-재시도)에 따라 누락 첨부만 처리한다. 보존 본문은 복구 후 정리한다. 형식 불일치·원격 조회 실패는 본문을 보존하고 중단한다.

## Step 6 — LLM 이행 가이드 연계

진입 가드: 위 Step 5 진행 상태 매트릭스의 "Step 6 진행" 열을 따른다. 요약하면 유효한 URL의 원격 게시가 확인되지 않은 Step 5-A는 Step 6 차단, Step 5-B `SUBISSUE_STATUS` 부분 실패는 Step 6 진행 허용. 존재하지 않는 이슈 번호로 `/write-handoff`를 호출하면 handoff comment가 엉뚱한 곳에 게시되거나 오류로 중단되므로 전자의 차단이 필수다.

이슈 생성이 완료되면, 질문 도구로 사용자에게 묻는다:

"LLM 이행 가이드를 작성할까요?"

- 사용자가 승인 → `/write-handoff <생성된 ISSUE_URL>` 스킬을 실행한다 (bare 번호 대신 Step 5의 `ISSUE_URL`을 전달해 cwd-dependent bare-number 모호성을 회피한다).
- 사용자가 거부 → 이슈 URL 반환 후 종료한다.
