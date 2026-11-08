# 노트북 VPN 분석 작업 이관서 (Claude Code용)

이 문서는 클라우드 세션에서 진행하던 "자체 VPN 구축 검토" 작업을 사용자 노트북(HEEWEON)의 Claude Code로 넘기기 위한 문서입니다.
노트북에서 Claude Code를 열고 아래처럼 지시하면 됩니다.

```
docs/vpn-analysis-handoff.md 읽고 그대로 진행해줘
```

---

## 1. 사용자 정보와 응대 규칙

- 호칭: 반드시 **「앙겔님」**으로 부릅니다. 다른 호칭은 쓰지 않습니다.
- 앙겔님은 조선기자재 업체에서 생산관리를 10년 했고, PM, ERP TFT, ISO 담당을 거쳤습니다. 지금은 공작기계 서브파트 제조사에서 구매/자재와 AI 담당을 맡고 있습니다.
- 네트워크 전문가는 아니므로, 기술 용어는 쉽게 풀어서 설명합니다.
- 답변은 한국어로 합니다.

## 2. 지금까지의 배경

- **목표**: 외부에서 회사 ERP와 NAS에 접속해야 하는 일부 직원에게 VPN을 제공하는 것. 비용은 무료가 목표입니다.
- **현재 방식**: 원격데스크톱으로 회사 PC에 접속해서 쓰고 있습니다. 느리고 파일 이동이 불편해서 직원들이 불만을 호소합니다.
- **제약**: 회사 방화벽은 **외부 업체가 관리**합니다. 예전에 업체에 부탁해서 VPN을 만든 적이 있고, 이번에는 앙겔님이 직접 해보고 싶어 합니다.
- **검토한 방안** (추천 순서)
  - A. 기존 방화벽의 SSL VPN 기능을 활용하고, 업체에서 사용자 추가·삭제 권한만 받는다 (가장 추천)
  - B. 사내 미니PC에 WireGuard(wg-easy)를 설치하고, 업체에는 UDP 51820 포트포워딩 1건만 요청한다
  - C. Tailscale·Headscale. 포트를 열 필요는 없지만 관리 중인 방화벽을 우회하는 구조라서 업체 승인이 필수다
- **지금 할 일**: 노트북에 설치되어 있고 활성화된 VPN이 어떻게 구성되어 있는지 분석합니다. 이 VPN은 예전에 업체가 만들어 준 것일 가능성이 높습니다. 결과를 보고 A안이 가능한지 판단합니다.

## 3. 작업 지시

### 반드시 지킬 것

- **읽기 전용으로만 작업합니다.** VPN 연결, 어댑터, 라우팅, 서비스, 방화벽, 레지스트리 설정을 바꾸거나, VPN을 끊거나 다시 연결하지 않습니다.
- 비밀번호, 인증서 개인키, 사전공유키(PSK), 토큰은 읽지도 출력하지도 않습니다. 설정 파일에 이런 값이 있으면 `***`로 가리고 "있음"이라고만 적습니다.
- 회사 공인 IP는 보고서에 마지막 자리를 `x`로 가려서 적습니다 (예: `211.45.12.x`).
- 관리자 권한이 필요한 명령은 실행하기 전에 앙겔님에게 먼저 묻습니다.

### 1단계: 정보 수집 (PowerShell)

```powershell
# 1. 설치된 VPN 프로그램
Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match 'VPN|Forti|SECUI|AXGATE|WireGuard|OpenVPN|Cisco|Pulse|Ivanti|Tailscale|Sophos|WatchGuard|SSL|Secure|Monitorapp|Genian' } |
  Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation

# 2. VPN 관련 서비스와 프로세스
Get-Service | Where-Object { $_.DisplayName -match 'VPN|Forti|SECUI|AXGATE|WireGuard|OpenVPN|Tailscale|SSL|Secure' } |
  Select-Object Status, Name, DisplayName
Get-Process | Where-Object { $_.ProcessName -match 'vpn|forti|secui|axgate|wireguard|openvpn|tailscale|ssl' } |
  Select-Object ProcessName, Id, Path

# 3. Windows 기본 VPN 연결
Get-VpnConnection -ErrorAction SilentlyContinue |
  Select-Object Name, ServerAddress, TunnelType, AuthenticationMethod, EncryptionLevel, ConnectionStatus, SplitTunneling

# 4. 네트워크 어댑터와 IP 설정
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed
Get-NetIPConfiguration |
  Select-Object InterfaceAlias,
    @{n='IPv4';e={$_.IPv4Address.IPAddress}},
    @{n='Prefix';e={$_.IPv4Address.PrefixLength}},
    @{n='Gateway';e={$_.IPv4DefaultGateway.NextHop}},
    @{n='DNS';e={$_.DNSServer.ServerAddresses -join ','}}

# 5. 라우팅 테이블 (어떤 대역이 VPN 어댑터로 가는지)
Get-NetRoute -AddressFamily IPv4 |
  Where-Object { $_.DestinationPrefix -notmatch '^(224|255)' } |
  Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric |
  Sort-Object InterfaceAlias

# 6. VPN 프로세스가 연결 중인 원격 서버 (VPN 게이트웨이 주소와 포트)
$vpnPids = (Get-Process | Where-Object { $_.ProcessName -match 'vpn|forti|secui|axgate|wireguard|openvpn|tailscale|ssl' }).Id
Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $vpnPids -contains $_.OwningProcess } |
  Select-Object LocalAddress, RemoteAddress, RemotePort, OwningProcess
Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $vpnPids -contains $_.OwningProcess } |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

추가로 확인할 것:
- 설치 폴더(`InstallLocation`)나 `%ProgramData%`, `%AppData%` 아래에 있는 VPN 클라이언트 설정 파일(.conf, .xml, .ovpn, .ini)에서 **접속 서버 주소, 포트, 프로토콜, 인증 방식**만 확인합니다. 비밀값은 가립니다.
- ERP 서버와 NAS의 IP를 앙겔님에게 물어보고, `Test-NetConnection <IP> -Port <포트>`와 `Find-NetRoute -RemoteIPAddress <IP>`로 VPN을 거쳐 접근하는지 확인합니다.

### 2단계: 분석

아래 질문에 답합니다.

1. 어떤 VPN 제품인가 (제조사, 클라이언트 이름, 버전)
2. 접속 방식은 무엇인가 (SSL VPN, IPsec, L2TP, WireGuard 등)와 사용하는 포트
3. 회사 방화벽 장비 모델을 추정할 수 있는가 (예: FortiClient면 FortiGate, SECUI면 SECUI BLUEMAX)
4. VPN 접속 시 받는 사내 IP 대역과 DNS
5. 스플릿 터널인가 풀 터널인가 (회사 대역만 VPN으로 가는지, 인터넷 전체가 회사를 거치는지)
6. ERP와 NAS가 이 VPN으로 접근 가능한 대역에 있는가
7. 인증 방식 (아이디/비밀번호, OTP, 인증서 등)
8. 보안상 눈에 띄는 문제 (PPTP 같은 취약 프로토콜, 오래된 클라이언트 버전 등)

### 3단계: 결과물

`docs/vpn-analysis-report.md` 파일로 보고서를 작성합니다. 구성은 다음과 같습니다.

1. **한눈에 보는 결론** (3~5줄): 어떤 VPN이고 A안이 가능해 보이는지
2. **현재 VPN 구성**: 2단계 질문 1~8에 대한 답
3. **구성도**: 노트북, 인터넷, 회사 방화벽, ERP·NAS 사이의 연결 흐름 (mermaid 또는 텍스트 그림)
4. **A·B·C안 판단**: 분석 결과를 근거로 어느 방안이 맞는지 추천
5. **방화벽 업체에 보낼 질문과 요청 메일 초안**: 분석 결과를 반영해서 구체적으로 작성
   - 방화벽 모델과 SSL VPN 라이선스(동시접속 인원)
   - VPN 사용자 추가·삭제용 관리자 권한을 받을 수 있는지
   - 안 된다면 사내 서버로 UDP 51820 포트포워딩이 가능한지
   - VPN 사용자의 접근을 ERP와 NAS로만 제한하는 정책이 가능한지
6. **다음 단계**: 2~3명 시범 운영, 사용자 대장, 퇴사자 계정 삭제 절차, ISO 접근통제 문서화

보고서는 앙겔님이 대표나 업체에 그대로 보여줄 수 있는 수준으로, 전문용어는 괄호로 쉬운 설명을 붙여 작성합니다.

## 4. 이후 작업 (앙겔님이 요청하면 진행)

- B안 단계별 설치 가이드 (미니PC + Docker + wg-easy)
- 직원 배포용 VPN 접속 매뉴얼 (앱 설치부터 NAS 네트워크 드라이브 연결까지)
- VPN 사용자 관리대장 엑셀 양식
