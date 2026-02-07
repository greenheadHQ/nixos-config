# QR 코드 방식 (deprecated)

> 이전에 QR 코드를 사용한 텍스트 공유를 시도했으나, Pushover의 클립보드 복사 기능이
> 더 편리하여 deprecated 되었습니다. 기록 목적으로 남겨둡니다.

## QR 코드 방식의 문제점

1. **스캔 필요**: iPhone 카메라로 QR 코드를 스캔해야 함 (2-3탭)
2. **크기 제한**: 600 bytes 초과 시 iPhone Termius 화면에 다 안 들어감
3. **폰트 의존성**: Termius에서 JetBrains Mono 폰트 필요 (Fira Code는 블록 문자 깨짐)
4. **한글 문제**: UTF-8에서 한글은 3바이트라 실제 200자 정도만 가능

## QR 코드 생성 방법 (참고용)

```bash
# qrencode 패키지 필요
echo "텍스트" | qrencode -t UTF8

# PNG 파일로 저장
echo "텍스트" | qrencode -o output.png
```

## Pushover vs QR 코드 비교

| 항목 | Pushover | QR 코드 |
|------|----------|---------|
| 복사 방법 | 알림에서 1탭 | 카메라 스캔 후 2-3탭 |
| 길이 제한 | 1,024자 | ~600 bytes (한글 ~200자) |
| 네트워크 | 필요 | 불필요 |
| 편의성 | ⭐⭐⭐ | ⭐ |
