---
name: attaching-github-media
description: Attach provided images and videos to GitHub issue or PR bodies and comments with the official gh --attach flag, including attachments requested by a publishing skill.
---

# GitHub 이미지·영상 첨부

공식 `gh --attach`를 사용한다. 최소 버전은 2.99.0이며 지원 명령은 `issue/pr create/edit/comment`다. 현재 실행기의 `--version`과 대상 명령의 `--help`로 확인한다. [공식 문서](https://docs.github.com/en/github-cli/github-cli/attaching-files-with-github-cli)

## 게시

- 사용자가 제공하거나 게시 대상으로 지정한 파일만 포함한다. 파일을 열어 내용과 민감정보를 확인하고, 공개하면 안 되는 내용이 있으면 첨부하지 않고 알린다.
- 버전 확인·조회·게시에는 같은 gh 실행기를 사용하고, 게시 명령에 대상 저장소를 `-R OWNER/REPO`로 명시한다.
- 본문은 `--body-file`로 전달하고 파일마다 `--attach`를 추가한다. 별도 업로드 단계는 없다. 첨부 없는 게시에는 이 절차를 적용하지 않는다.
- 원하는 위치에 `![설명](./evidence.png)`처럼 로컬 파일을 참조한다. 본문 참조와 `--attach`는 실행 디렉터리 기준 같은 파일을 가리켜야 한다. 참조가 없으면 본문 끝에 추가된다.
- 기존 본문을 편집할 때는 먼저 현재 내용을 읽고 기존 첨부 URL을 보존한다.

```sh
gh pr comment 123 -R OWNER/REPO \
  --body-file body.md --attach ./evidence.png
```

형식·크기·개수·인증·저장소 권한 검사는 CLI에 맡긴다. 일반 파일, 독립 asset URL 업로드, 리뷰·Discussion 첨부에는 별도 확장이나 우회 경로를 만들지 않고 미지원 범위를 알린다.

## 실패와 재시도

종료 코드가 0이 아니어도 일부 첨부와 본문은 이미 게시됐을 수 있다. 반환된 URL과 원격 본문을 먼저 조회한다. 게시가 확인되면 기존 URL을 재사용하고 누락된 첨부만 처리한다. 생성 명령 전체를 그대로 재실행하지 않는다.

게시되지 않았음이 확인되면 실패한 첨부와 로컬 참조를 제외한 본문으로 원래 게시 요청을 계속할 수 있다. 게시 여부가 불명확하거나 업로드 후 게시 실패로 asset URL을 확보하지 못했다면 자동 재시도를 멈추고 확인된 상태를 알린다.

결과는 게시 URL과 첨부 성공·실패 내용을 짧게 설명한다. 별도 상태 코드 체계를 만들지 않는다.
