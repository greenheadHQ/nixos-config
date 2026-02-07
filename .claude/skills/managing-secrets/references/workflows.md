# Secret 워크플로 상세

## .age 파일 생성/암호화

**Interactive (터미널)** -- `agenix -e` 사용:

```bash
nix run github:ryantm/agenix -- -e secrets/<name>.age
# 에디터에서 내용 입력 후 저장 → 자동 암호화
```

추가와 수정 모두 동일한 명령으로 처리.

**Non-interactive (Claude Code)** -- `age` CLI pipe 사용:

```bash
# 1. secrets/secrets.nix에서 공개키 확인
# 2. 모든 recipient에 대해 -r 플래그 지정
nix shell nixpkgs#age -c sh -c 'printf "KEY=value\n" | age \
  -r "ssh-ed25519 <key1>" \
  -r "ssh-ed25519 <key2>" \
  -o secrets/<name>.age'
```

`secrets/secrets.nix`의 `allHosts` 목록에 있는 모든 공개키를 `-r` 플래그로 지정해야 양쪽 호스트에서 복호화 가능.

## 기존 secret 내용 확인 (복호화)

```bash
nix shell nixpkgs#age -c age -d -i ~/.ssh/id_ed25519 secrets/<name>.age
```

## 호스트 추가

새 호스트의 secret 접근이 필요한 경우:

1. 해당 머신에서 `cat ~/.ssh/id_ed25519.pub`으로 공개키 확인
2. `secrets/secrets.nix`에 공개키 등록 및 `allHosts`에 추가
3. 재암호화: `nix run github:ryantm/agenix -- -r`
