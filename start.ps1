# ============================================================
#  거북목 측정 부스 - 실행 스크립트
#  로컬 HTTP 서버를 띄우고 브라우저로 앱을 엽니다.
#  (브라우저는 file:// 페이지에 카메라를 허용하지 않으므로 필요)
#
#  사용법: start.bat 을 더블클릭하세요.
# ============================================================

param(
    [int]$Port = 0,          # 0 = 8000 부터 빈 포트 자동 선택
    [switch]$NoBrowser       # 브라우저를 열지 않음 (집계 전용 PC / 테스트용)
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

# ---------- 비어 있는 포트 찾기 ----------
function Test-PortFree([int]$p) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

$candidates = if ($Port -gt 0) { @($Port) } else { 8000..8020 }
$port = 0
foreach ($p in $candidates) { if (Test-PortFree $p) { $port = $p; break } }
if ($port -eq 0) {
    Write-Host "[오류] 쓸 수 있는 포트를 찾지 못했습니다 ($($candidates -join ', '))." -ForegroundColor Red
    Read-Host "엔터를 누르면 닫힘"; exit 1
}

$url = "http://localhost:$port/game/"

Write-Host ""
Write-Host "  분리수거 게임 부스" -ForegroundColor Cyan
Write-Host "  ------------------------------------------------"
Write-Host "  게임 화면 : $url"
Write-Host "  집계 화면 : http://localhost:$port/game/#dashboard"
Write-Host "  시작 페이지: http://localhost:$port/"
Write-Host ""
Write-Host "  O 키 = 운영자 패널   D 키 = 집계   Esc = 처음으로"
Write-Host "  이 창을 닫거나 Ctrl+C 를 누르면 종료됩니다."
Write-Host "  ------------------------------------------------"
Write-Host ""

# ---------- 브라우저 열기 (크롬 우선, 키오스크 모드) ----------
function Open-Browser($target) {
    if ($NoBrowser) { Write-Host "  (-NoBrowser) 브라우저는 열지 않습니다" -ForegroundColor DarkGray; return }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $chrome = @(
        (Join-Path $env:ProgramFiles   'Google\Chrome\Application\chrome.exe'),
        (Join-Path $pf86               'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA   'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if ($chrome) {
        Write-Host "  Chrome 으로 엽니다 (F11 = 전체화면)" -ForegroundColor DarkGray
        Start-Process $chrome -ArgumentList "--new-window", "--autoplay-policy=no-user-gesture-required", $target
    } else {
        Write-Host "  기본 브라우저로 엽니다" -ForegroundColor DarkGray
        Start-Process $target
    }
}

# ---------- 1순위: 쓸 수 있는 파이썬이 있으면 사용 ----------
# Windows 10/11 에는 "python.exe" 가 Microsoft Store 설치 유도용 더미로 깔려 있어
# Get-Command 로는 찾아지지만 실제로는 실행되지 않습니다. 반드시 실행해서 확인합니다.
#
# 경로로 걸러내면 안 됩니다. WindowsApps 폴더에는 더미와 진짜가 섞여 있습니다 —
# python.exe 는 더미(실행하면 exit 9009, 출력 없음)지만, py.exe 는 정상 동작하는
# 파이썬 런처입니다(exit 0). 폴더 이름만 보고 거르면 멀쩡한 py 까지 버려져
# 느린 PowerShell 내장 서버로 떨어지고, 그 서버는 디렉터리 → index.html 을
# 처리하지 못해 /scoliosis/ 같은 주소가 404 가 됩니다.
# 아래 실행 검사(exit code + 출력)만으로 둘은 확실히 구분됩니다.
#
# py 를 먼저 보는 이유: 윈도우 공식 런처라 설치 위치와 무관하게 가장 잘 잡힙니다.
function Resolve-Python {
    foreach ($cand in @('py', 'python', 'python3')) {
        $cmd = Get-Command $cand -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try {
            $out = & $cmd.Source -c "import sys;print(sys.version_info[0])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $out -match '^3') { return $cmd.Source }
        } catch { }
    }
    return $null
}
$py = Resolve-Python

if ($py) {
    Write-Host "  서버: Python ($py)" -ForegroundColor DarkGray
    # 경로에 한글/공백이 있어도 안전하도록 작업 디렉터리로 지정하고 os.chdir 은 쓰지 않는다
    $script = "import http.server,mimetypes; " +
              "mimetypes.add_type('application/wasm','.wasm'); " +
              "mimetypes.add_type('text/javascript','.mjs'); " +
              "http.server.test(HandlerClass=http.server.SimpleHTTPRequestHandler, port=$port, bind='127.0.0.1')"
    # 인자를 따옴표로 감싸야 합니다. Start-Process 의 -ArgumentList 는 배열을 공백으로
    # 이어 붙이기만 하고 따옴표를 덧붙여 주지 않아서, 그냥 넘기면 파이썬이 -c 뒤의
    # "import" 한 단어만 코드로 받고 나머지는 sys.argv 로 흘려보냅니다.
    # 그러면 SyntaxError 로 즉시 죽어 서버가 뜨지 않습니다(이 분기는 그동안 파이썬이
    # 안 잡혀 한 번도 실행되지 않아 드러나지 않았습니다).
    # $script 안의 문자열은 모두 홑따옴표라 겹따옴표로 감싸도 충돌하지 않습니다.
    $proc = Start-Process -FilePath $py -ArgumentList @('-c', ('"' + $script + '"')) `
                          -WorkingDirectory $root -NoNewWindow -PassThru
    Start-Sleep -Milliseconds 1200
    Open-Browser $url
    try { Wait-Process -Id $proc.Id } finally {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Write-Host "`n  서버를 종료했습니다." -ForegroundColor DarkGray
    }
    exit 0
}

# ---------- 2순위: 순수 PowerShell 정적 서버 ----------
Write-Host "  서버: PowerShell 내장" -ForegroundColor DarkGray

$mime = @{
    '.html'  = 'text/html; charset=utf-8'
    '.htm'   = 'text/html; charset=utf-8'
    '.js'    = 'text/javascript; charset=utf-8'
    '.mjs'   = 'text/javascript; charset=utf-8'
    '.css'   = 'text/css; charset=utf-8'
    '.json'  = 'application/json; charset=utf-8'
    '.wasm'  = 'application/wasm'
    '.task'  = 'application/octet-stream'
    '.data'  = 'application/octet-stream'
    '.bin'   = 'application/octet-stream'
    '.png'   = 'image/png'
    '.jpg'   = 'image/jpeg'
    '.jpeg'  = 'image/jpeg'
    '.gif'   = 'image/gif'
    '.svg'   = 'image/svg+xml'
    '.ico'   = 'image/x-icon'
    '.webp'  = 'image/webp'
    '.woff'  = 'font/woff'
    '.woff2' = 'font/woff2'
    '.mp4'   = 'video/mp4'
    '.txt'   = 'text/plain; charset=utf-8'
    '.md'    = 'text/plain; charset=utf-8'
}

function Send-Http($stream, [string]$status, [string]$ctype, [byte[]]$body, [bool]$headOnly) {
    if ($null -eq $body) { $body = [byte[]]@() }
    $header = "HTTP/1.1 $status`r`n" +
              "Content-Type: $ctype`r`n" +
              "Content-Length: $($body.Length)`r`n" +
              "Cache-Control: no-store`r`n" +
              "Connection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($hb, 0, $hb.Length)
    if ((-not $headOnly) -and $body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
$listener.Start()
Start-Sleep -Milliseconds 200
Open-Browser $url

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            # 브라우저가 미리 열어두고 요청을 보내지 않는 소켓이 있으므로 타임아웃을 둔다
            $client.ReceiveTimeout = 2500
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }
            do { $h = $reader.ReadLine() } while (-not [string]::IsNullOrEmpty($h))

            $parts  = $requestLine -split '\s+'
            $method = $parts[0]
            $rawPath = if ($parts.Count -gt 1) { $parts[1] } else { '/' }

            if ($method -notin @('GET', 'HEAD')) {
                Send-Http $stream '405 Method Not Allowed' 'text/plain' ([byte[]]@()) $false
                continue
            }

            $rel = ($rawPath -split '[?#]')[0]
            $rel = [System.Uri]::UnescapeDataString($rel).TrimStart('/')
            if ([string]::IsNullOrEmpty($rel)) { $rel = 'index.html' }
            $rel = $rel -replace '/', '\'

            $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
            $headOnly = ($method -eq 'HEAD')

            # 디렉터리 탈출 차단
            if (-not $full.StartsWith([System.IO.Path]::GetFullPath($root), 'OrdinalIgnoreCase')) {
                Send-Http $stream '403 Forbidden' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('403')) $headOnly
                continue
            }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                Send-Http $stream '404 Not Found' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes("404 $rel")) $headOnly
                continue
            }

            $ext   = [System.IO.Path]::GetExtension($full).ToLower()
            $ctype = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
            $bytes = [System.IO.File]::ReadAllBytes($full)
            Send-Http $stream '200 OK' $ctype $bytes $headOnly
        } catch {
            # 끊긴 연결 / 타임아웃은 무시하고 다음 요청으로
        } finally {
            if ($client) { $client.Close() }
        }
    }
} finally {
    $listener.Stop()
    Write-Host "`n  서버를 종료했습니다." -ForegroundColor DarkGray
}
