{
  pkgs,
  mountPoint,
  requiresMountsFor,
}:
pkgs.testers.runNixOSTest {
  name = "copyparty-mount";
  # CI의 KVM 접근 권한을 확대하지 않고 소프트웨어 에뮬레이션도 허용한다.
  requiredFeatures.kvm = false;

  nodes.machine = {
    # 실제 디스크 대신 VM 내부의 합성 bind mount를 사용한다. 부팅 때는 마운트하지 않는다.
    virtualisation.fileSystems.${mountPoint} = {
      device = "/srv/copyparty-mount-source";
      fsType = "none";
      options = [
        "bind"
        "noauto"
        "nofail"
      ];
    };
    systemd.tmpfiles.rules = [ "d ${mountPoint} 0755 root root -" ];
    systemd.services.copyparty-fixture = {
      unitConfig.RequiresMountsFor = requiresMountsFor;
      # 자체 마운트 guard를 두지 않는다. 생산 RequiresMountsFor가 빠지면 실패 검사가 깨져야 한다.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "copyparty-start-fixture" ''
          ${pkgs.coreutils}/bin/touch /run/copyparty-started
        '';
      };
    };
  };

  testScript = ''
    import shlex

    start_all()
    machine.wait_for_unit("multi-user.target")
    mount_point = ${builtins.toJSON mountPoint}
    quoted_mount = shlex.quote(mount_point)
    mount_unit = machine.succeed("systemd-escape --path --suffix=mount " + quoted_mount).strip()

    with subtest("마운트점 디렉터리만 있으면 서비스가 시작하지 않는다"):
        machine.succeed("test -d " + quoted_mount)
        machine.fail("mountpoint -q " + quoted_mount)
        machine.succeed("test ! -e /srv/copyparty-mount-source")
        machine.fail("systemctl start copyparty-fixture.service")
        machine.succeed("systemctl is-failed " + mount_unit)
        machine.succeed("test ! -e /run/copyparty-started")

    with subtest("마운트가 성공하면 같은 서비스가 시작한다"):
        machine.succeed("mkdir -p /srv/copyparty-mount-source")
        machine.succeed("touch /srv/copyparty-mount-source/fixture-data")
        machine.succeed("systemctl reset-failed " + mount_unit + " copyparty-fixture.service")
        machine.succeed("systemctl start copyparty-fixture.service")
        machine.wait_for_unit("copyparty-fixture.service")
        machine.succeed("mountpoint -q " + quoted_mount)
        machine.succeed("test -f " + shlex.quote(mount_point + "/fixture-data"))
        machine.succeed("test -f /run/copyparty-started")
  '';
}
