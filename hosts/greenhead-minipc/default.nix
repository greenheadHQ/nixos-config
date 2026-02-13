# greenhead-minipc 호스트 설정
{
  config,
  lib,
  pkgs,
  inputs,
  username,
  constants,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix # placeholder → 설치 후 실제 내용으로 교체
    ./disko.nix
  ];

  # SSH 공개키 (Mac에서 접속용)
  users.users.${username}.openssh.authorizedKeys.keys = [
    constants.sshKeys.macbook
  ];

  # Wake-on-LAN (원격 전원 인가)
  # NIC: Intel igc (enp2s0), magic packet으로 부팅
  networking.interfaces.enp2s0.wakeOnLan.enable = true;

  # HDD 마운트 (기존 데이터 유지)
  # 중요: 이 HDD는 NixOS 설치 시 포맷하지 않음!
  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-uuid/3f1111d9-1641-4d5e-9e40-af54f4ce7870";
    fsType = "ext4";
    options = [
      "defaults"
      "nofail"
    ];
  };
}
