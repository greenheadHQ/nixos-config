# 관리 대상 노트 유형 원장

초기 대상은 **CS 재활 Basic** 한 가지다. 이 디렉터리는 검토할 수 있는
내용 원본이며, 실행 중인 Anki를 읽어 자동으로 갱신하지 않는다.
`KaTeX and Markdown Cloze`를 비롯한 다른 유형은 관리 대상이 아니다.

- `cs-rehab-basic/model.json`: 필드와 템플릿의 순서·설정, 카드 생성 조건,
  LaTeX 설정. HTML/CSS의 `{ "file": "…" }` 참조만 빌드 시 치환한다.
- `front.html`, `back.html`, `style.css`: 전체 앞면·뒷면·스타일의 정확한 UTF-8
  원문. 줄바꿈을 정규화하지 않는다.
- `manifest.json`: 관리할 JS의 실제 미디어 파일명과 기존 저장소 원본 경로.
  `code-highlighting/dist/`의 파일을 재사용하며 JS를 중복 저장하지 않는다.
- `version.json`: 위 내용과 등록 자산의 실제 바이트로 계산한 버전.
  Git SHA, 작성 시각, collection·note type·field·template ID는 포함하지 않는다.

필드 정의에는 표시 이름과 일반 편집 설정만 있다. 이 원장에는 개인 노트의
필드 값, 이미지, 음성, 학습 기록, 운영 ID가 없다. 기본 LaTeX 헤더와 일반 UI
코드를 포함한 전체 원문을 검토한 뒤 등록했다. 원본의 코드 주석에 있는
공개 이슈 링크는 운영 데이터가 아니다.

## 기존 기능 원본과의 관계

전체 템플릿은 카드 ID 복사·노트 링크·코드 강조 표시·본문 글자 크기의 기존
기능 파일과 동시에 검증한다. 카드 ID 버튼의 ANY 조건, 노트 링크 렌더러, 코드
강조 렌더러와 그 안에 직렬화한 CSS·자산명, 카드 ID 조각 바로 뒤에 같은 조건으로
놓인 본문 글자 크기 조작부가 정확하게 일치해야 한다. 어느 한쪽만
바꾸면 빌드와 테스트가 실패한다. 템플릿을 수정할 때 적용 중인 카드 생성
조건을 임의로 단순화하지 않는다.

변경을 검토한 뒤 내용 버전을 갱신하고, 검증된 오프라인 번들을 생성한다.
저장소 루트에서 실행한다.

```sh
python3 modules/nixos/programs/anki-host/managed-types/build.py \
  modules/nixos/programs/anki-host --refresh-version
python3 modules/nixos/programs/anki-host/managed-types/build.py \
  modules/nixos/programs/anki-host /tmp/anki-managed-reviewed-bundle
```

출력 디렉터리는 새 경로여야 한다. 출력은 `bundle.json`과 `assets/`이며,
재현 가능한 내용과 해시만 포함한다. 기존 배포 기준을 덮어쓰지 않는다.

원장이나 버전의 존재는 배포 완료·검증 완료·복원 승인이 아니다. 운영자 최초
등록 시 호스트가 실제 collection/model 바인딩과 적용 상태를 별도로 검증하고,
성공한 정의·자산을 로컬에 보존해야 한다. 최신 Git 내용과 마지막 적용 버전이
다른 것은 업데이트 대기이며, 그 자체로 실행 중인 유형의 변경은 아니다.
