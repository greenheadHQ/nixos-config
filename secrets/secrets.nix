# agenix CLI가 사용하는 파일
# 새 secret 추가: nix run github:ryantm/agenix -- -e new-secret.age
# 재암호화: nix run github:ryantm/agenix -- -r
#
# 참고: agenix는 SSH 공개키 형식으로 암호화하면 SSH 비밀키로 복호화 가능
# age 공개키(age1...) 형식은 age 비밀키(AGE-SECRET-KEY-...)가 필요
let
  # SSH 공개키 (cat ~/.ssh/id_ed25519.pub)
  greenhead-MacBookPro = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDN048Qg9ABnM26jU0X0w2mG9pqcrwuVrcihvDbkRVX8";
  greenhead-minipc = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN64oEThAvKkI806sMRcIXOJxiaT2A8BbqcO4DfWlirO";

  # TODO: 호스트 추가 시
  # 1. 해당 머신에서 cat ~/.ssh/id_ed25519.pub 실행
  # 2. 아래에 공개키 추가
  # 3. nix run github:ryantm/agenix -- -r 로 재암호화
  # work-MacBookPro = "ssh-ed25519 AAAA...";

  allHosts = [
    greenhead-MacBookPro
    greenhead-minipc
  ];
in
{
  # 서비스별 Pushover credentials (독립적 토큰 revocation + API rate limit 분리)
  "pushover-claude-stop.age".publicKeys = allHosts;
  "pushover-claude-ask.age".publicKeys = allHosts;
  "pushover-atuin.age".publicKeys = allHosts;
  "pushover-fail2ban.age".publicKeys = allHosts;

  "pane-note-links.age".publicKeys = allHosts;
}
