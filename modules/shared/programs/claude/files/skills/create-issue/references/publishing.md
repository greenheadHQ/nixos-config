# 이슈 게시와 결과 처리

작성 기준과 Step 2~4는 [SKILL.md](../SKILL.md), parent 연결(Step 5-B)은 [parent-linking.md](parent-linking.md)가 소유한다. `OWNER`/`REPO`/ID 의미도 parent-linking의 변수 계약을 따른다.

### Step 5 — 등록 및 확인

Step 5는 두 하위 단계로 진행한다. 진행/차단 규칙은 아래 매트릭스 하나로 통합한다 — 각 세부 단계의 실패 처리는 이 표를 참조한다.

진행 상태 매트릭스

| 상태 (Step 5 출력) | Step 5-B 진행 | Step 6 진행 | 사용자/운영자 보고 의무 |
|--------------------|---------------|-------------|--------------------------|
| Step 5-A `gh issue create` 실패 (`ERROR:` + `ISSUE_URL` 미반환) | 차단 | 차단 | 재시도 명령 출력 후 `exit 1` |
| Step 5-A URL validation 실패 (반환값이 `https://github.com/.../issues/N` 형식 아님) | 차단 | 차단 | `ERROR:` + 재시도 유도 |
| Step 5-A 성공 + `--parent` 미지정 | Skip (실행 안 됨) | 진행 | `ISSUE_URL`만 출력 (기존 경로, `SUBISSUE_STATUS` 토큰 없음) |
| Step 5-B `SUBISSUE_STATUS=LINKED` | — | 진행 | 성공 로그 |
| Step 5-B `SUBISSUE_STATUS=FAILED_ID_LOOKUP` | — | 진행 | `SUBISSUE_STATUS` 토큰을 최종 응답에 포함, 재시도 명령 명시 |
| Step 5-B `SUBISSUE_STATUS=FAILED_POST` | — | 진행 | 동일 |

`SUBISSUE_STATUS`의 전달 경로는 `/create-issue`의 최종 응답(사용자에게 출력되는 마지막 메시지) 에 명시하는 것으로 scope을 닫는다. Step 6의 `/write-handoff` 호출은 `<ISSUE_URL>`만 전달하므로 `SUBISSUE_STATUS`는 handoff body에 전달되지 않는다 — 운영자는 `/create-issue` 최종 응답의 토큰을 보고 재시도 여부를 판단한다.

#### Step 5-A — 이슈 등록

실패 시 진행 차단 정책은 위 진행 상태 매트릭스 참조.

1. 등록 전 제목, 라벨 조합을 사용자에게 보여주고 확인을 받는다.
2. 확인 통과 직후, Step 2에서 식별한 명시적 시각 증빙 후보가 있으면 [`using-gh-attach`](../../using-gh-attach/SKILL.md) 스킬의 절차를 여기서 실행한다 — 각 후보의 처리 결과를 반영한 본문 사본을 아래 3단계의 `$ISSUE_BODY`로 사용한다. 성공한 후보의 첨부는 유지하고 실패·skip 후보만 제외한다 (부분 성공 시 성공한 `href`를 버리면 orphan asset이 된다). 업로드·삽입에 성공한 후보가 없을 때만 원래 본문을 사용하고, 정본이 정의한 `ATTACH_STATUS`를 최종 응답에 포함한다. 후보가 없으면 이 단계를 건너뛴다.
   첨부를 삽입했다면 Step 3의 sanitization scan은 이 시점의 최종 본문 사본에 다시 적용한다 — 삽입되는 첨부 라벨의 파일명·설명도 S1 값(개인·회사 식별자 등)을 담을 수 있으므로, 검사한 본문과 게시하는 본문이 반드시 동일 파일이어야 한다 (sanitization checklist S3의 post-render 원칙).
3. `gh issue create`를 `--body-file`로 실행한다. 본문은 임시 파일에 저장 후 전달.
   ```bash
   # BSD/macOS mktemp는 템플릿 끝(trailing)에 XXXXXX가 와야 랜덤 치환함.
   # 전용 private 디렉터리만 만들고 본문 target은 첫 편집 전까지 존재하지 않게 둔다.
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
     echo "ISSUE_BODY_PATH=$ISSUE_BODY  # 게시하지 않고 보존됨"
     exit 1
   fi
   if ! chmod 600 "$ISSUE_BODY"; then
     echo "ERROR: 본문 파일 권한 설정 실패"
     echo "ISSUE_BODY_PATH=$ISSUE_BODY  # 게시하지 않고 보존됨"
     exit 1
   fi

   # gh issue create — 성공 시 URL 캡처, 실패 시 본문 경로/미리보기 출력 후 exit 1
   if ISSUE_URL=$(gh issue create --title "<제목>" --label "<라벨>" --body-file "$ISSUE_BODY"); then
     echo "ISSUE_URL=$ISSUE_URL"
     # GitHub write 성공과 로컬 cleanup 성공을 혼동하지 않는다. 정확한 파일과 빈 디렉터리만 제거한다.
     if ! rm -f "$ISSUE_BODY"; then
       echo "WARN: 이슈는 등록됐지만 본문 파일 정리 실패: $ISSUE_BODY"
     elif ! rmdir "$ISSUE_BODY_DIR"; then
       echo "WARN: 이슈는 등록됐지만 본문 임시 디렉터리 정리 실패: $ISSUE_BODY_DIR"
     fi
   else
     rc=$?
     echo "ERROR: gh issue create 실패 (exit $rc)"
     echo "ISSUE_BODY_PATH=$ISSUE_BODY  # 본문 보존됨 (재시도 시 재사용)"
     echo "ISSUE_BODY_DIR=$ISSUE_BODY_DIR  # 성공한 재시도 뒤 빈 디렉터리를 정리"
     # 본문은 stdout으로 덤프하지 않는다 — 사용자가 실수로 시크릿을 포함한 경우 세션/운영 로그에 남을 위험.
     # 필요 시 로컬 shell에서 직접 확인: `sed -n '1,20p' "$ISSUE_BODY_PATH"` 또는 에디터로 열기.
     echo "본문 미리보기는 보안상 stdout 덤프하지 않음. 확인 명령: sed -n '1,20p' \"\$ISSUE_BODY_PATH\""
     echo "재시도 명령 (동일 shell 세션 또는 ISSUE_BODY_PATH 값을 직접 입력):"
     echo "  gh issue create --title '<제목>' --label '<라벨>' --body-file \"\$ISSUE_BODY_PATH\""
     echo "**parent 연결과 handoff는 이슈 등록 완료 전에는 진행하지 않는다.**"
     exit 1
   fi
   ```
4. 반환된 `ISSUE_URL`이 실제 GitHub URL(`https://github.com/.../issues/N`)인지 확인한다. 형식 불일치는 매트릭스의 "URL validation 실패" 행을 따른다.

### Step 6 — LLM 이행 가이드 연계

진입 가드: 위 Step 5 진행 상태 매트릭스의 "Step 6 진행" 열을 따른다. 요약하면 Step 5-A 실패(create 실패 또는 URL validation 실패)는 Step 6 차단, Step 5-B `SUBISSUE_STATUS` 부분 실패는 Step 6 진행 허용. 존재하지 않는 이슈 번호로 `/write-handoff`를 호출하면 handoff comment가 엉뚱한 곳에 게시되거나 오류로 중단되므로 전자의 차단이 필수다.

이슈 생성이 완료되면, 질문 도구로 사용자에게 묻는다:

"LLM 이행 가이드를 작성할까요?"

- 사용자가 승인 → `/write-handoff <생성된 ISSUE_URL>` 스킬을 실행한다 (bare 번호 대신 Step 5의 `ISSUE_URL`을 전달해 cwd-dependent bare-number 모호성을 회피한다).
- 사용자가 거부 → 이슈 URL 반환 후 종료한다.
