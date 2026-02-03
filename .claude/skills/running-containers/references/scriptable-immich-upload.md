# Scriptable + Immich 이미지 업로드

모바일 SSH 환경에서 Claude Code에 이미지를 전달하기 위한 Scriptable 스크립트 설정 가이드입니다.

## 배경

- 아이폰 Termius로 MiniPC SSH 접속 시 클립보드 이미지 붙여넣기 불가
- Claude Code의 WebFetch는 Anthropic 서버에서 실행되어 Tailscale IP 접근 불가
- Claude Code의 Read는 로컬에서 실행되어 **파일 경로로 이미지 접근 가능**

## 사전 요구사항

1. iPhone에 **Scriptable** 앱 설치 (무료)
2. Immich API 키 생성 (Immich 웹 UI → Account Settings → API Keys)
3. "Claude Code Temp" 앨범 생성

## Scriptable 스크립트

### 스크립트 이름

`Upload to Claude Code`

### 코드

```javascript
// Upload to Claude Code.js
const CONFIG = {
  immichUrl: "http://100.79.80.95:2283",
  apiKey: "YOUR_API_KEY",  // Immich API 키 입력
  albumName: "Claude Code Temp",
  containerPrefix: "/usr/src/app/upload/upload/",
  hostPrefix: "/var/lib/docker-data/immich/upload-cache/"
}

async function main() {
  if (!args.images || args.images.length === 0) {
    let alert = new Alert()
    alert.message = "이미지가 전달되지 않았습니다"
    await alert.present()
    return
  }
  let image = args.images[0]

  try {
    let req = new Request(CONFIG.immichUrl + "/api/assets")
    req.method = "POST"
    req.headers = { "x-api-key": CONFIG.apiKey }
    req.addImageToMultipart(image, "assetData", "image.jpg")
    req.addParameterToMultipart("deviceAssetId", "ios-" + Date.now())
    req.addParameterToMultipart("deviceId", "iPhone-Scriptable")
    req.addParameterToMultipart("fileCreatedAt", new Date().toISOString())
    req.addParameterToMultipart("fileModifiedAt", new Date().toISOString())
    let result = await req.loadJSON()
    let assetId = result.id

    let albumsReq = new Request(CONFIG.immichUrl + "/api/albums")
    albumsReq.headers = { "x-api-key": CONFIG.apiKey }
    let albums = await albumsReq.loadJSON()
    let album = albums.find(a => a.albumName === CONFIG.albumName)
    if (album) {
      let addReq = new Request(CONFIG.immichUrl + "/api/albums/" + album.id + "/assets")
      addReq.method = "PUT"
      addReq.headers = { "x-api-key": CONFIG.apiKey, "Content-Type": "application/json" }
      addReq.body = JSON.stringify({ ids: [assetId] })
      await addReq.loadJSON()
    }

    await new Promise(r => Timer.schedule(2, false, r))
    let assetReq = new Request(CONFIG.immichUrl + "/api/assets/" + assetId)
    assetReq.headers = { "x-api-key": CONFIG.apiKey }
    let asset = await assetReq.loadJSON()
    let path = asset.originalPath
    if (path.startsWith(CONFIG.containerPrefix)) {
      path = CONFIG.hostPrefix + path.substring(CONFIG.containerPrefix.length)
    }

    Pasteboard.copy(path)
    let n = new Notification()
    n.title = "업로드 완료"
    n.body = path
    n.schedule()
  } catch (e) {
    let alert = new Alert()
    alert.title = "업로드 실패"
    alert.message = e.message
    await alert.present()
  }
}

await main()
Script.complete()
```

## 설정 방법

### 1. Scriptable 앱에서 스크립트 생성

1. Scriptable 앱 실행
2. 우측 상단 `+` 버튼으로 새 스크립트 생성
3. 위 코드 붙여넣기
4. `CONFIG.apiKey`에 Immich API 키 입력
5. 저장

### 2. Share Sheet 활성화

1. 스크립트 편집 화면에서 설정 아이콘 (⚙️) 탭
2. **Share Sheet Inputs** → **모든 항목 체크** (Text, Images, URLs, File URLs)
3. 저장

> **참고**: Images만 체크했을 때 공유 시트에서 실행 시 아무 반응이 없다면, 다른 항목들(Text, URLs, File URLs)도 체크하면 문제가 해결될 수 있습니다.

### 3. Immich 앨범 생성

"Claude Code Temp" 앨범이 없으면 생성:

```bash
API_KEY="your-api-key"
curl -X POST "http://100.79.80.95:2283/api/albums" \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"albumName": "Claude Code Temp"}'
```

## 사용 방법

### iPhone에서

1. 스크린샷 촬영 또는 사진 선택
2. **공유** 버튼 탭
3. **Scriptable** 선택
4. **Upload to Claude Code** 스크립트 선택
5. 완료 알림과 함께 경로가 클립보드에 복사됨

### MiniPC SSH에서

1. Termius에서 MiniPC 접속
2. Claude Code 실행
3. 클립보드 경로 붙여넣기:
   ```
   /var/lib/docker-data/immich/upload-cache/UUID/xx/xx/file.jpg
   ```
4. Claude Code가 Read 도구로 이미지 확인

## 경로 변환 규칙

| Immich API 반환 경로 | 호스트 접근 경로 |
|---------------------|-----------------|
| `/usr/src/app/upload/upload/...` | `/var/lib/docker-data/immich/upload-cache/...` |

이 변환은 Immich의 볼륨 매핑에 기반합니다:
```nix
volumes = [
  "${dockerData}/immich/upload-cache:/usr/src/app/upload/upload"
];
```

## 자동 삭제 설정

NixOS에서 "Claude Code Temp" 앨범의 모든 이미지를 매일 삭제합니다.

### 활성화

```nix
# modules/nixos/configuration.nix
homeserver.immichCleanup.enable = true;
homeserver.immichCleanup.albumName = "Claude Code Temp";  # 기본값
```

### 관련 파일

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | mkOption 정의 |
| `modules/nixos/programs/immich-cleanup/default.nix` | systemd service + timer |
| `modules/nixos/programs/immich-cleanup/files/cleanup-script.sh` | 삭제 스크립트 |
| `secrets/immich-api-key.age` | Immich API 키 (agenix) |
| `secrets/pushover-immich.age` | Pushover 알림 (agenix) |

### 동작 방식

- **스케줄**: 매일 07:00 KST (systemd timer)
- **대상**: `albumName` 앨범의 **모든 이미지**
- **삭제 방식**: Immich API `force=true` (휴지통 우회)
- **알림**: Pushover로 삭제 결과 전송

### 알림 케이스

| 상황 | 메시지 | 우선순위 |
|------|--------|----------|
| 앨범 없음 | "'앨범명' 앨범이 없습니다. 설정 확인 필요" | 높음 |
| API 연결 실패 | "Immich API 연결 실패" | 높음 |
| 삭제할 이미지 없음 | "삭제할 이미지가 없습니다" | 낮음 |
| 삭제 완료 | "N개 이미지 삭제됨" | 낮음 |
| 부분 실패 | "N개 삭제, M개 실패" | 높음 |

### 수동 실행

```bash
# 서비스 수동 실행
sudo systemctl start immich-cleanup.service

# 로그 확인
journalctl -u immich-cleanup.service -f

# 타이머 상태 확인
systemctl status immich-cleanup.timer
```

### 적용 방법

```bash
# MiniPC에서 nrs 실행
nrs
```

## 보안 고려사항

1. **API 키 저장**: 스크립트에 직접 입력하면 편리하지만 덜 안전함
   - 대안: 매번 입력하도록 수정, 또는 1Password Shortcuts 통합
2. **전용 API 키 권장**: 최소 권한 (asset.upload, asset.read, album.read, album.write)
3. **Tailscale 내부만 접근**: API 키 노출 위험 최소화

## 제한사항

- Scriptable 스크립트는 Nix로 선언적 관리 불가 (Apple 생태계)
- 이 문서로 백업 및 복구 가이드 제공
- 1x1 픽셀 등 너무 작은 이미지는 Claude API에서 처리 불가

## 문제 해결

### "이미지가 전달되지 않았습니다"

- Share Sheet에서 직접 실행하지 않고 앱에서 실행한 경우
- 해결: 사진 앱에서 공유 → Scriptable 선택

### "앨범을 찾을 수 없음"

- "Claude Code Temp" 앨범이 생성되지 않음
- 해결: Immich 웹 UI 또는 API로 앨범 생성

### Claude Code에서 "Could not process image"

- 이미지가 너무 작음 (1x1 픽셀 등)
- 해결: 의미 있는 크기의 실제 이미지 사용
