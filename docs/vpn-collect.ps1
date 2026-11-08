# VPN 구성 정보 수집 스크립트 (읽기 전용)
# - 설정을 바꾸거나 VPN을 끊지 않습니다. 조회(Get-*) 명령만 사용합니다.
# - 비밀번호, 키, 토큰은 읽지 않습니다.
# - 공인 IP는 마지막 자리를 x로 가립니다.
# - 관리자 권한 없이 일반 PowerShell에서 실행하세요.
#
# 실행 방법:
#   powershell -ExecutionPolicy Bypass -File .\vpn-collect.ps1
# 결과: 바탕화면에 vpn-collect-result.txt 생성

$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'vpn-collect-result.txt'
$pattern = 'VPN|Forti|SECUI|AXGATE|WireGuard|OpenVPN|Cisco|Pulse|Ivanti|Tailscale|Sophos|WatchGuard|SSL|Secure|Monitorapp|Genian'
$procPattern = 'vpn|forti|secui|axgate|wireguard|openvpn|tailscale|ssl'

function Mask-IP([string]$ip) {
  if ([string]::IsNullOrWhiteSpace($ip)) { return $ip }
  if ($ip -match '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0|255\.)') { return $ip }
  if ($ip -match '^(\d+\.\d+\.\d+)\.\d+(.*)$') { return "$($Matches[1]).x$($Matches[2])" }
  return $ip
}
function Mask-Text([string]$s) {
  if ($null -eq $s) { return $s }
  $s = [regex]::Replace($s, '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b', { param($m) Mask-IP $m.Value })
  return $s
}
function Section($title, [scriptblock]$body) {
  "`n===== $title =====" | Out-File $out -Append -Encoding utf8
  try { (& $body | Format-Table -AutoSize -Wrap | Out-String -Width 300) | ForEach-Object { Mask-Text $_ } | Out-File $out -Append -Encoding utf8 }
  catch { "오류: $($_.Exception.Message)" | Out-File $out -Append -Encoding utf8 }
}

"VPN 수집 결과 - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-File $out -Encoding utf8
"OS: $((Get-CimInstance Win32_OperatingSystem).Caption)" | Out-File $out -Append -Encoding utf8

Section '1. 설치된 VPN 프로그램' {
  Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*, HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $pattern } |
    Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation
}
Section '2-1. VPN 관련 서비스' {
  Get-Service | Where-Object { $_.DisplayName -match $pattern -or $_.Name -match $pattern } | Select-Object Status, Name, DisplayName
}
Section '2-2. VPN 관련 프로세스' {
  Get-Process | Where-Object { $_.ProcessName -match $procPattern } | Select-Object ProcessName, Id, Path
}
Section '3. Windows 기본 VPN 연결' {
  Get-VpnConnection -ErrorAction SilentlyContinue |
    Select-Object Name, ServerAddress, TunnelType, AuthenticationMethod, EncryptionLevel, ConnectionStatus, SplitTunneling
}
Section '4-1. 네트워크 어댑터' {
  Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed
}
Section '4-2. IP 설정' {
  Get-NetIPConfiguration | Select-Object InterfaceAlias,
    @{n='IPv4';e={$_.IPv4Address.IPAddress -join ','}},
    @{n='Prefix';e={$_.IPv4Address.PrefixLength -join ','}},
    @{n='Gateway';e={$_.IPv4DefaultGateway.NextHop -join ','}},
    @{n='DNS';e={$_.DNSServer.ServerAddresses -join ','}}
}
Section '5. 라우팅 테이블' {
  Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -notmatch '^(224|255)' } |
    Sort-Object InterfaceAlias | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric
}
$vpnPids = @((Get-Process | Where-Object { $_.ProcessName -match $procPattern }).Id)
Section '6-1. VPN 프로세스의 TCP 연결 (게이트웨이 주소/포트)' {
  Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $vpnPids -contains $_.OwningProcess } |
    Select-Object LocalAddress, RemoteAddress, RemotePort, OwningProcess
}
Section '6-2. VPN 프로세스의 UDP 포트' {
  Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $vpnPids -contains $_.OwningProcess } |
    Select-Object LocalAddress, LocalPort, OwningProcess
}
Section '7. VPN 설정 파일 목록 (내용은 읽지 않음)' {
  $dirs = @($env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, ${env:ProgramFiles}, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
  foreach ($d in $dirs) {
    Get-ChildItem $d -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | ForEach-Object {
      Get-ChildItem $_.FullName -Recurse -Include *.conf,*.xml,*.ovpn,*.ini,*.cfg -ErrorAction SilentlyContinue |
        Select-Object FullName, Length, LastWriteTime
    }
  }
}

"`n수집 완료. 이 파일 내용을 Claude에게 붙여넣어 주세요." | Out-File $out -Append -Encoding utf8
Write-Host "완료: $out"
