# =====================================================================
#  Spotify 桌面歌词  v1.0
#  Windows PowerShell 5.1 + WPF，无需安装任何第三方组件
#  歌词来源：网易云音乐(含人工翻译) -> LRCLIB -> AI 翻译(可选)
# =====================================================================
param(
    [switch]$DebugMode,
    [string]$DebugTrack = '',
    [string]$Snapshot = '',
    [double]$SnapshotAt = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 } catch {}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Runtime.WindowsRuntime, System.Xaml

# 声明为 DPI 感知，保证坐标 = 物理像素，避免高分屏发虚/错位
try {
    if (-not ('LyricsDpi' -as [type])) {
        Add-Type -Namespace LyricsDpi -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    }
    [void][LyricsDpi.Native]::SetProcessDPIAware()
} catch {}

# 窗口样式 / 按键状态（锁定穿透 + 全局热键用）
try {
    if (-not ('LyricsWin32' -as [type])) {
        Add-Type -Namespace LyricsWin32 -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@
    }
} catch {}

# ---------------------------- 路径 / 日志 ----------------------------
$script:SrcRoot   = $PSScriptRoot
$script:AppRoot   = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = Join-Path $script:AppRoot 'config.json'
$script:CacheDir  = Join-Path $script:AppRoot 'cache'
$script:LogFile   = Join-Path $script:AppRoot 'logs\app.log'

foreach ($d in @($script:CacheDir, (Split-Path -Parent $script:LogFile))) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
}

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 300KB)) {
            Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $script:LogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch {}
}

# ---------------------------- 只允许一个实例 ----------------------------
$script:SingleMutex = $null
try {
    $script:SingleMutex = New-Object System.Threading.Mutex -ArgumentList $false, 'Local\SpotifyDesktopLyrics_v1'
    if (-not $script:SingleMutex.WaitOne(0)) {
        Write-Log 'already running, exit this instance'
        exit
    }
} catch {}

# ---------------------------- 配置 ----------------------------
$script:DefaultConfig = [ordered]@{
    mode               = 'both'      # original | translation | both
    fontSize           = 34
    translationFontSize = 20
    nextLineFontSize   = 21
    windowWidth        = 1120
    windowHeight       = 200
    panelOpacity       = 0.52        # 歌词底板透明度 0~1
    windowOpacity      = 1.0
    x                  = -1
    y                  = -1
    showNextLine       = $true
    alwaysOnTop        = $true
    netease            = $true
    lrclib             = $true
    syncOffset         = 0.0
    ballSize           = 58          # 悬浮球直径
    collapsed          = $false      # 启动时是否收起成球
    ai                 = [ordered]@{
        enabled = $true
        apiKey  = ''
        baseUrl = 'https://api.deepseek.com'
        model   = 'deepseek-chat'
    }
}

function Load-Config {
    $cfg = $null
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
            if ($raw.Trim()) { $cfg = $raw | ConvertFrom-Json }
        } catch { Write-Log "config parse failed: $($_.Exception.Message)" }
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    foreach ($k in $script:DefaultConfig.Keys) {
        if ($null -eq $cfg.PSObject.Properties[$k]) {
            $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $script:DefaultConfig[$k] -Force
        }
    }
    if ($null -eq $cfg.ai) { $cfg | Add-Member -NotePropertyName ai -NotePropertyValue ([pscustomobject]$script:DefaultConfig.ai) -Force }
    foreach ($k in $script:DefaultConfig.ai.Keys) {
        if ($null -eq $cfg.ai.PSObject.Properties[$k]) {
            $cfg.ai | Add-Member -NotePropertyName $k -NotePropertyValue $script:DefaultConfig.ai[$k] -Force
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.ai.apiKey) -and $env:DEEPSEEK_API_KEY) {
        $cfg.ai.apiKey = [string]$env:DEEPSEEK_API_KEY
    }
    return $cfg
}

function Save-Config {
    try {
        $script:Cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    } catch { Write-Log "config save failed: $($_.Exception.Message)" }
}

$script:Cfg = Load-Config
$script:DebugTrack = $DebugTrack
if (-not (Test-Path -LiteralPath $script:ConfigPath)) { Save-Config }   # 首次运行生成可编辑的配置文件

# ---------------------------- WinRT / SMTC ----------------------------
$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await-WinRT {
    param($Operation, [Type]$ResultType)
    $m    = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task = $m.Invoke($null, @($Operation))
    if (-not $task.Wait(15000)) { throw 'WinRT 调用超时' }
    return $task.Result
}

$script:SmtcMgr = $null
try {
    $mgrType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
    $script:SmtcMgr = Await-WinRT ($mgrType::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    Write-Log 'SMTC manager ready'
} catch {
    Write-Log "SMTC init failed: $($_.Exception.Message)"
}

$script:MediaPropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]

function Get-PlaySession {
    if (-not $script:SmtcMgr) { return $null }
    try {
        $sessions = $script:SmtcMgr.GetSessions()
        if (-not $sessions -or $sessions.Count -eq 0) { return $null }
        # 1) 优先 Spotify 桌面客户端
        foreach ($s in $sessions) {
            if ($s.SourceAppUserModelId -match '(?i)spotify') { return $s }
        }
        # 2) 其次浏览器里的 Spotify 网页版（要求有歌手名，避免被普通视频顶掉）
        foreach ($s in $sessions) {
            if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') { continue }
            if ($s.SourceAppUserModelId -notmatch '(?i)msedge|chrome|firefox|brave|opera|vivaldi') { continue }
            $p = Get-PlayProps -Session $s
            if ($p -and $p.Title -and $p.Artist) { return $s }
        }
        return $null
    } catch { return $null }
}

function Get-PlayProps {
    param($Session)
    try {
        $p = Await-WinRT ($Session.TryGetMediaPropertiesAsync()) $script:MediaPropsType
        return [pscustomobject]@{
            Title  = [string]$p.Title
            Artist = [string]$p.Artist
            Album  = [string]$p.AlbumTitle
        }
    } catch { return $null }
}

# ---------------------------- 文本工具 ----------------------------
function Get-NormText {
    param([string]$Text)
    if (-not $Text) { return '' }
    $s = $Text.ToLowerInvariant()
    $s = [regex]::Replace($s, '[\(\[（【].*?[\)\]）】]', '')
    $s = [regex]::Replace($s, '[^\p{L}\p{N}]', '')
    return $s
}

function Test-HasCjk {
    param([string]$Text)
    if (-not $Text) { return $false }
    $cjk = ([regex]::Matches($Text, '[\u4e00-\u9fff]')).Count
    $all = ($Text -replace '\s', '').Length
    if ($all -eq 0) { return $false }
    return (($cjk / [double]$all) -gt 0.25)
}

function Get-TrackKey {
    param([string]$Title, [string]$Artist)
    $md5   = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((("$Title|$Artist").ToLowerInvariant()))
    $hash  = $md5.ComputeHash($bytes)
    $md5.Dispose()
    return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16).ToLowerInvariant()
}

# ---------------------------- HTTP ----------------------------
$script:NetEaseHeaders = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    'Referer'    = 'http://music.163.com/'
    'Cookie'     = 'appver=2.0.2; os=pc'
    'Accept'     = '*/*'
}

function Invoke-JsonRequest {
    param([string]$Url, [hashtable]$Headers, [int]$TimeoutSec = 12)
    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        Write-Log "HTTP fail [$Url]: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------- LRC 解析 ----------------------------
$script:CreditPattern = '^(作词|作曲|编曲|制作人|出品人?|监制|混音|母带|录音|和声|吉他|贝斯|鼓|键盘|弦乐|统筹|企划|发行|词|曲|Lyrics?|Composer|Arranger|Producer|Mixed|Mastered|Written\s*by)\s*[:：]'

function ConvertFrom-Lrc {
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return , $out }
    $offsetMs = 0
    $clean    = $Text -replace "`r", ''
    foreach ($raw in ($clean -split "`n")) {
        if ($raw -match '^\s*\[offset:\s*([+-]?\d+)\s*\]') { $offsetMs = [int]$Matches[1]; continue }
        $stamps = [regex]::Matches($raw, '\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]')
        if ($stamps.Count -eq 0) { continue }
        $content = [regex]::Replace($raw, '\[[^\]]*\]', '').Trim()
        foreach ($m in $stamps) {
            $min  = [int]$m.Groups[1].Value
            $sec  = [int]$m.Groups[2].Value
            $frac = 0.0
            if ($m.Groups[3].Success) {
                $digits = $m.Groups[3].Value
                $frac   = [double]$digits / [Math]::Pow(10, $digits.Length)
            }
            $t = $min * 60 + $sec + $frac + ($offsetMs / 1000.0)
            if ($content -match $script:CreditPattern -and $t -lt 25) { continue }
            if ($content -match '纯音乐|沒有填词|没有填词|此歌曲为没有') { continue }
            [void]$out.Add([pscustomobject]@{ t = [double]$t; text = $content; tr = '' })
        }
    }
    $sorted = @($out | Sort-Object t)
    return , $sorted
}

function Merge-Translation {
    param($Lines, [string]$TranslationLrc)
    if (-not $TranslationLrc) { return $Lines }
    $trs = ConvertFrom-Lrc -Text $TranslationLrc
    if (-not $trs -or $trs.Count -eq 0) { return $Lines }
    foreach ($line in $Lines) {
        $best = $null; $bestDelta = 999
        foreach ($tr in $trs) {
            $d = [Math]::Abs($tr.t - $line.t)
            if ($d -lt $bestDelta) { $bestDelta = $d; $best = $tr }
        }
        if ($best -and $bestDelta -le 0.9 -and $best.text) { $line.tr = $best.text }
    }
    # 时间轴对不上时按顺序对齐
    if ((@($Lines | Where-Object { $_.tr }).Count) -eq 0 -and $trs.Count -eq $Lines.Count) {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($trs[$i].text) { $Lines[$i].tr = $trs[$i].text }
        }
    }
    return $Lines
}

# ---------------------------- 歌词源 ----------------------------
function Find-NetEaseSong {
    param([string]$Title, [string]$Artist, [double]$DurationSec)
    $q = [Uri]::EscapeDataString("$Title $Artist")
    $r = Invoke-JsonRequest -Url "http://music.163.com/api/search/get?s=$q&type=1&limit=10" -Headers $script:NetEaseHeaders
    if (-not $r -or -not $r.result -or -not $r.result.songs) { return $null }

    $nt = Get-NormText $Title
    $na = Get-NormText $Artist
    $best = $null; $bestScore = -999

    foreach ($song in $r.result.songs) {
        $st   = Get-NormText $song.name
        $sa   = Get-NormText ((@($song.artists) | ForEach-Object { $_.name }) -join ' ')
        $dur  = [double]$song.duration / 1000.0
        $score = 0
        if ($nt -and $st) {
            if ($st -eq $nt) { $score += 60 }
            elseif ($st.Contains($nt) -or $nt.Contains($st)) { $score += 34 }
            else { $score -= 20 }
        }
        if ($na -and $sa) {
            if ($sa.Contains($na) -or $na.Contains($sa)) { $score += 30 } else { $score -= 12 }
        }
        if ($DurationSec -gt 0 -and $dur -gt 0) {
            $d = [Math]::Abs($dur - $DurationSec)
            if ($d -lt 3) { $score += 20 } elseif ($d -lt 8) { $score += 10 } elseif ($d -gt 30) { $score -= 18 }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $song }
    }
    if ($bestScore -lt 24) {
        Write-Log "netease match rejected score=$bestScore for [$Title / $Artist]"
        return $null
    }
    Write-Log "netease match score=$bestScore -> $($best.name) / $(($best.artists | ForEach-Object { $_.name }) -join ',')"
    return $best
}

function Get-NetEaseLyric {
    param([long]$SongId)
    $r = Invoke-JsonRequest -Url "http://music.163.com/api/song/lyric?id=$SongId&lv=-1&kv=-1&tv=-1" -Headers $script:NetEaseHeaders
    if (-not $r) { return $null }
    $lrc = $null; $tlrc = $null
    if ($r.lrc -and $r.lrc.lyric) { $lrc = [string]$r.lrc.lyric }
    if ($r.tlyric -and $r.tlyric.lyric) { $tlrc = [string]$r.tlyric.lyric }
    return [pscustomobject]@{ Lrc = $lrc; Translation = $tlrc }
}

function Find-LrclibLyric {
    param([string]$Title, [string]$Artist, [double]$DurationSec)
    $url = 'https://lrclib.net/api/search?track_name={0}&artist_name={1}' -f ([Uri]::EscapeDataString($Title)), ([Uri]::EscapeDataString($Artist))
    $r = Invoke-JsonRequest -Url $url -Headers @{ 'User-Agent' = 'SpotifyDesktopLyrics/1.0 (Windows)' }
    if (-not $r) { return $null }
    $best = $null; $bestDelta = 999
    foreach ($item in $r) {
        if (-not $item.syncedLyrics) { continue }
        $d = 99
        if ($DurationSec -gt 0 -and $item.duration) { $d = [Math]::Abs([double]$item.duration - $DurationSec) }
        if ($d -lt $bestDelta) { $bestDelta = $d; $best = $item }
    }
    if ($best) { Write-Log "lrclib hit: $($best.trackName) delta=$bestDelta"; return [string]$best.syncedLyrics }
    return $null
}

# ---------------------------- 歌词加载 ----------------------------
function Get-LyricsBundle {
    param([string]$Title, [string]$Artist, [double]$DurationSec)

    $key  = Get-TrackKey -Title $Title -Artist $Artist
    $file = Join-Path $script:CacheDir "$key.json"

    if (Test-Path -LiteralPath $file) {
        try {
            $cached = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cached -and $cached.lines) {
                Write-Log "cache hit $key"
                return [pscustomobject]@{
                    Lines  = @($cached.lines | ForEach-Object { [pscustomobject]@{ t = [double]$_.t; text = [string]$_.text; tr = [string]$_.tr } })
                    Source = [string]$cached.source
                }
            }
        } catch { Write-Log "cache read fail: $($_.Exception.Message)" }
    }

    $lines  = @()
    $source = ''

    if ($script:Cfg.netease) {
        $song = Find-NetEaseSong -Title $Title -Artist $Artist -DurationSec $DurationSec
        if ($song) {
            $lyric = Get-NetEaseLyric -SongId $song.id
            if ($lyric -and $lyric.Lrc) {
                $parsed = ConvertFrom-Lrc -Text $lyric.Lrc
                if (@($parsed).Count -gt 0) {
                    $lines  = @(Merge-Translation -Lines $parsed -TranslationLrc $lyric.Translation)
                    $source = if ($lyric.Translation) { '网易云(含翻译)' } else { '网易云' }
                }
            }
        }
    }

    if (@($lines).Count -eq 0 -and $script:Cfg.lrclib) {
        $text = Find-LrclibLyric -Title $Title -Artist $Artist -DurationSec $DurationSec
        if ($text) {
            $parsed = ConvertFrom-Lrc -Text $text
            if (@($parsed).Count -gt 0) { $lines = @($parsed); $source = 'LRCLIB' }
        }
    }

    $bundle = [pscustomobject]@{ Lines = @($lines); Source = $source }
    if (@($lines).Count -gt 0) {
        try {
            [pscustomobject]@{
                title  = $Title
                artist = $Artist
                source = $source
                saved  = (Get-Date).ToString('s')
                lines  = @($lines)
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
        } catch { Write-Log "cache write fail: $($_.Exception.Message)" }
    }
    return $bundle
}

# ---------------------------- AI 翻译 ----------------------------
function Start-AiTranslation {
    param($Lines)
    $cfg = $script:Cfg.ai
    if (-not $cfg.enabled) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.apiKey)) { return $false }
    if ($script:TrJob) { return $true }

    $texts = @($Lines | Where-Object { $_.text } | ForEach-Object { $_.text })
    if ($texts.Count -eq 0) { return $false }

    $payload = @{
        model       = [string]$cfg.model
        temperature = 0.3
        messages    = @(
            @{ role = 'system'; content = '你是专业的歌词翻译。把用户提供的每一行歌词翻译成简体中文，保留语气与诗意，人名品牌保留原文。只输出一个 JSON 数组，数组元素个数必须与输入行数完全一致，每个元素是该行的中文翻译，不要输出任何解释、不要使用代码块。' },
            @{ role = 'user'; content = ($texts | ConvertTo-Json -Depth 3 -Compress) }
        )
    } | ConvertTo-Json -Depth 6 -Compress

    $base   = ([string]$cfg.baseUrl).TrimEnd('/')
    $apiKey = [string]$cfg.apiKey

    Write-Log "AI translate start, lines=$($texts.Count)"
    $script:TrJob = Start-Job -ScriptBlock {
        param($Base, $Key, $Body)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $resp  = Invoke-RestMethod -Uri ($Base + '/chat/completions') -Method Post -TimeoutSec 120 `
                -Headers @{ Authorization = "Bearer $Key" } -ContentType 'application/json; charset=utf-8' -Body $bytes
            return $resp.choices[0].message.content
        } catch {
            return '__ERROR__ ' + $_.Exception.Message
        }
    } -ArgumentList $base, $apiKey, $payload

    $script:TrState = 'pending'
    return $true
}

function Complete-AiTranslation {
    $job = $script:TrJob
    if (-not $job) { return }
    if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') { return }

    $script:TrJob = $null
    $raw = ''
    try { $raw = (Receive-Job -Job $job -ErrorAction SilentlyContinue) -join "`n" } catch {}
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.StartsWith('__ERROR__')) {
        Write-Log "AI translate failed: $raw"
        $script:TrState = 'failed'
        Show-Status 'AI 翻译失败，请检查 config.json 里的密钥/网络'
        return
    }

    $json = $raw.Trim()
    $json = [regex]::Replace($json, '^```(json)?', '').Trim()
    $json = [regex]::Replace($json, '```$', '').Trim()
    $arr = $null
    try { $arr = $json | ConvertFrom-Json } catch {}

    if (-not $arr -or @($arr).Count -eq 0) {
        Write-Log 'AI translate parse failed'
        $script:TrState = 'failed'
        Show-Status 'AI 翻译结果解析失败'
        return
    }

    $i = 0
    foreach ($line in $script:Lines) {
        if (-not $line.text) { continue }
        if ($i -lt @($arr).Count) {
            $v = [string]$arr[$i]
            if ($v -and $v.Trim()) { $line.tr = $v.Trim() }
        }
        $i++
    }
    $script:TrState = 'ready'
    Write-Log 'AI translate done'

    # 回写缓存
    try {
        $key  = $script:Track.Key
        $file = Join-Path $script:CacheDir "$key.json"
        if (Test-Path -LiteralPath $file) {
            $c = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $c.lines = @($script:Lines)
            $c.source = [string]$c.source + '+AI翻译'
            $c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
        }
    } catch {}

    Render-CurrentLine
    Refresh-ModeButtons
}

# ---------------------------- UI ----------------------------
function Get-Brush {
    param([string]$Hex)
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]$c))
}

$script:FontName   = 'Microsoft YaHei UI'
$script:BrushDim   = Get-Brush '#80FFFFFF'
$script:BrushBase  = Get-Brush '#66FFFFFF'
$script:BrushHi    = Get-Brush '#FFFFFFFF'
$script:BrushTr    = Get-Brush '#D9A9D8FF'
$script:BrushNext  = Get-Brush '#38FFFFFF'
$script:BrushIdle  = Get-Brush '#66FFFFFF'
$script:BrushAccent = Get-Brush '#FF6FC9FF'

function New-LyricText {
    param([string]$Text, [double]$Size, $Brush, [string]$Weight = 'Normal')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text           = $Text
    $tb.FontFamily     = New-Object System.Windows.Media.FontFamily($script:FontName)
    $tb.FontSize       = $Size
    $tb.FontWeight     = if ($Weight -eq 'Bold') { [System.Windows.FontWeights]::Bold } else { [System.Windows.FontWeights]::Normal }
    $tb.Foreground     = $Brush
    $tb.TextWrapping   = 'NoWrap'
    $tb.TextAlignment  = 'Center'
    $tb.HorizontalAlignment = 'Center'
    $tb.VerticalAlignment   = 'Center'
    [System.Windows.Media.TextOptions]::SetTextRenderingMode($tb, [System.Windows.Media.TextRenderingMode]::Grayscale)
    $sh = New-Object System.Windows.Media.Effects.DropShadowEffect
    $sh.Color        = [System.Windows.Media.Colors]::Black
    $sh.BlurRadius   = 7
    $sh.ShadowDepth  = 0
    $sh.Opacity      = 0.9
    $tb.Effect = $sh
    return $tb
}

function New-FlatButton {
    param([string]$Text, [scriptblock]$OnClick, [string]$Tip = '')
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.FontFamily = New-Object System.Windows.Media.FontFamily($script:FontName)
    $b.FontSize = 13
    $b.Foreground = $script:BrushDim
    $b.Background = [System.Windows.Media.Brushes]::Transparent
    $b.BorderThickness = New-Object System.Windows.Thickness(0)
    $b.Padding = New-Object System.Windows.Thickness(9, 4, 9, 4)
    $b.Margin  = New-Object System.Windows.Thickness(3, 0, 0, 0)
    $b.Cursor  = [System.Windows.Input.Cursors]::Hand
    $b.Focusable = $false
    if ($Tip) { $b.ToolTip = $Tip }
    $b.Template = [System.Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate TargetType="Button" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Border Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
</ControlTemplate>
'@)
    $b.Add_Click($OnClick)
    return $b
}

$script:Win = New-Object System.Windows.Window
$script:Win.WindowStyle        = 'None'
$script:Win.AllowsTransparency = $true
$script:Win.Background         = [System.Windows.Media.Brushes]::Transparent
$script:Win.Topmost            = [bool]$script:Cfg.alwaysOnTop
$script:Win.ShowInTaskbar      = $false
$script:Win.ShowActivated      = $false
$script:Win.ResizeMode         = 'CanResize'
$script:Win.Width              = [double]$script:Cfg.windowWidth
$script:Win.SizeToContent      = 'Height'
$script:Win.WindowStartupLocation = 'Manual'
$script:Win.Opacity            = [double]$script:Cfg.windowOpacity

$root = New-Object System.Windows.Controls.Grid
$root.Background = [System.Windows.Media.Brushes]::Transparent
$script:Win.Content = $root

$panel = New-Object System.Windows.Controls.Border
$panel.CornerRadius = New-Object System.Windows.CornerRadius(18)
$alpha = [int]([Math]::Max(0.0, [Math]::Min(1.0, [double]$script:Cfg.panelOpacity)) * 255)
$panel.Background = Get-Brush ('#{0:X2}0B1020' -f $alpha)
$panel.Padding    = New-Object System.Windows.Thickness(26, 12, 26, 10)
$panel.MinHeight  = 0
$root.Children.Add($panel) | Out-Null

# --- 悬浮球（收起状态） ---
$ball = New-Object System.Windows.Controls.Border
$ball.Width  = 58.0
$ball.Height = 58.0
$ball.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 29.0
$ball.Background = Get-Brush '#E00B1020'
$ball.BorderBrush = Get-Brush '#40FFFFFF'
$ball.BorderThickness = New-Object System.Windows.Thickness(1)
$ball.HorizontalAlignment = 'Center'
$ball.VerticalAlignment = 'Center'
$ball.Cursor = [System.Windows.Input.Cursors]::Hand
$ball.Visibility = 'Collapsed'
$ball.ToolTip = '点一下展开歌词，右键更多'
$ballText = New-Object System.Windows.Controls.TextBlock
$ballText.Text = '♪'
$ballText.FontFamily = New-Object System.Windows.Media.FontFamily($script:FontName)
$ballText.FontSize = 24.0
$ballText.Foreground = $script:BrushHi
$ballText.HorizontalAlignment = 'Center'
$ballText.VerticalAlignment = 'Center'
$ball.Child = $ballText
$root.Children.Add($ball) | Out-Null

$stack = New-Object System.Windows.Controls.StackPanel
$panel.Child = $stack

# --- 顶部：曲目信息 + 按钮 ---
$header = New-Object System.Windows.Controls.Grid
$colL = New-Object System.Windows.Controls.ColumnDefinition; $colL.Width = New-Object System.Windows.GridLength(1, 'Star')
$colR = New-Object System.Windows.Controls.ColumnDefinition; $colR.Width = [System.Windows.GridLength]::Auto
$header.ColumnDefinitions.Add($colL); $header.ColumnDefinitions.Add($colR)

$trackTb = New-LyricText -Text '等待 Spotify…' -Size 12 -Brush $script:BrushDim
$trackTb.HorizontalAlignment = 'Left'
$trackTb.TextAlignment = 'Left'
$trackTb.Effect = $null
$trackTb.TextTrimming = 'CharacterEllipsis'
$trackTb.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
[System.Windows.Controls.Grid]::SetColumn($trackTb, 0)
$header.Children.Add($trackTb) | Out-Null

$btnBar = New-Object System.Windows.Controls.StackPanel
$btnBar.Orientation = 'Horizontal'
$btnBar.HorizontalAlignment = 'Right'
$btnBar.Opacity = 0.42
[System.Windows.Controls.Grid]::SetColumn($btnBar, 1)
$header.Children.Add($btnBar) | Out-Null

$stack.Children.Add($header) | Out-Null

# --- 歌词区 ---
$mainGrid = New-Object System.Windows.Controls.Grid
$mainGrid.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
$mainGrid.Height = 56

$mainBase = New-LyricText -Text '♪' -Size ([double]$script:Cfg.fontSize) -Brush $script:BrushBase -Weight 'Bold'
$mainHi   = New-LyricText -Text '♪' -Size ([double]$script:Cfg.fontSize) -Brush $script:BrushHi   -Weight 'Bold'
$mainGrid.Children.Add($mainBase) | Out-Null
$mainGrid.Children.Add($mainHi) | Out-Null

$clipGeo = New-Object System.Windows.Media.RectangleGeometry
$clipGeo.Rect = New-Object System.Windows.Rect(0, -8, 0.5, 400)
$mainHi.Clip = $clipGeo

$stack.Children.Add($mainGrid) | Out-Null

$trTb = New-LyricText -Text '' -Size ([double]$script:Cfg.translationFontSize) -Brush $script:BrushTr
$trTb.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
$trTb.Visibility = 'Collapsed'
$stack.Children.Add($trTb) | Out-Null

$nextTb = New-LyricText -Text '' -Size ([double]$script:Cfg.nextLineFontSize) -Brush $script:BrushNext
$nextTb.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
$nextTb.Visibility = 'Collapsed'
$stack.Children.Add($nextTb) | Out-Null

$statusTb = New-LyricText -Text '' -Size 11 -Brush $script:BrushDim
$statusTb.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
$statusTb.Opacity = 0.8
$statusTb.Visibility = 'Collapsed'
$stack.Children.Add($statusTb) | Out-Null

$script:Ui = @{
    Track  = $trackTb
    MainBase = $mainBase
    MainHi   = $mainHi
    Tr       = $trTb
    Next     = $nextTb
    Status   = $statusTb
    Clip     = $clipGeo
    Buttons  = @{}
    BtnBar   = $btnBar
    Panel    = $panel
    MainGrid = $mainGrid
    Ball     = $ball
    BallText = $ballText
}

# --- 按钮逻辑 ---
function Refresh-ModeButtons {
    $mode = $script:Cfg.mode
    foreach ($k in @('original', 'translation', 'both')) {
        $b = $script:Ui.Buttons[$k]
        if (-not $b) { continue }
        if ($k -eq $mode) {
            $b.Foreground = $script:BrushAccent
            $b.Background = Get-Brush '#33FFFFFF'
        } else {
            $b.Foreground = $script:BrushDim
            $b.Background = [System.Windows.Media.Brushes]::Transparent
        }
    }
}

function Set-Mode {
    param([string]$Mode)
    $script:Cfg.mode = $Mode
    Save-Config
    Refresh-ModeButtons
    Render-CurrentLine
    if ($Mode -ne 'original' -and (Test-NeedsAiTranslation)) { Request-Translation }
}

function Cycle-Mode {
    $order = @('original', 'translation', 'both')
    $i = [array]::IndexOf($order, [string]$script:Cfg.mode)
    Set-Mode $order[($i + 1) % 3]
}

function Change-FontSize {
    param([int]$Delta)
    $s = [double]$script:Cfg.fontSize + $Delta
    if ($s -lt 18) { $s = 18 }
    if ($s -gt 64) { $s = 64 }
    $script:Cfg.fontSize = $s
    $script:Cfg.translationFontSize = [Math]::Max(12.0, $s * 0.58)
    $script:Cfg.nextLineFontSize = [Math]::Max(12.0, $s * 0.62)
    Save-Config
    Render-CurrentLine
}

$script:Ui.Buttons['original']    = New-FlatButton -Text '原'   -Tip '只看原歌词'      -OnClick { Set-Mode 'original' }
$script:Ui.Buttons['translation'] = New-FlatButton -Text '译'   -Tip '只看中文翻译'    -OnClick { Set-Mode 'translation' }
$script:Ui.Buttons['both']        = New-FlatButton -Text '对照' -Tip '原文 + 译文对照'  -OnClick { Set-Mode 'both' }
$btnSmaller = New-FlatButton -Text 'A−' -Tip '缩小字号'       -OnClick { Change-FontSize -3 }
$btnBigger  = New-FlatButton -Text 'A+' -Tip '放大字号'       -OnClick { Change-FontSize 3 }
$btnReload  = New-FlatButton -Text '↻'  -Tip '重新获取歌词'   -OnClick { Force-Reload }
$btnLock    = New-FlatButton -Text '锁'  -Tip '锁定：鼠标穿透，按 Ctrl+Alt+L 解锁' -OnClick { Set-Locked (-not $script:Locked) }
$btnOpacity = New-FlatButton -Text '透'  -Tip '底板透明度：无 / 淡 / 中 / 深' -OnClick { Cycle-PanelOpacity }
$btnClose   = New-FlatButton -Text '✕'  -Tip '退出'            -OnClick { $script:Win.Close() }

foreach ($b in @($script:Ui.Buttons['original'], $script:Ui.Buttons['translation'], $script:Ui.Buttons['both'],
        $btnSmaller, $btnBigger, $btnReload, $btnOpacity, $btnLock, $btnClose)) {
    [void]$btnBar.Children.Add($b)
}
Refresh-ModeButtons

# 悬停时按钮变清晰
$panel.Add_MouseEnter({ $script:Ui.BtnBar.Opacity = 1.0 })
$panel.Add_MouseLeave({ $script:Ui.BtnBar.Opacity = 0.42 })

# 拖动：整条都能拖，拖到屏幕边缘自动收成小球
$dragHandler = {
    param($s, $e)
    try {
        $script:Win.DragMove()
        $script:Cfg.x = [Math]::Round($script:Win.Left)
        $script:Cfg.y = [Math]::Round($script:Win.Top)
        Save-Config
    } catch { return }
    if (-not $script:Collapsed -and (Test-NearEdge)) { Set-Collapsed $true }
}
foreach ($el in @($panel, $mainGrid, $trackTb)) { $el.Add_MouseLeftButtonDown($dragHandler) }

# 双击切换模式 / 滚轮调字号
$script:Win.Add_MouseDoubleClick({ Cycle-Mode })
$panel.Add_MouseWheel({
        param($s, $e)
        if ($e.Delta -gt 0) { Change-FontSize 3 } else { Change-FontSize -3 }
    })

# 右键菜单
$menu = New-Object System.Windows.Controls.ContextMenu
foreach ($m in @(@('原歌词', 'original'), @('翻译', 'translation'), @('中外对照', 'both'))) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $m[0]
    $mode = $m[1]
    $mi.Add_Click([scriptblock]::Create("Set-Mode '$mode'"))
    [void]$menu.Items.Add($mi)
}
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
$miFontUp = New-Object System.Windows.Controls.MenuItem; $miFontUp.Header = '放大字号'
$miFontUp.Add_Click({ Change-FontSize 3 }); [void]$menu.Items.Add($miFontUp)
$miFontDown = New-Object System.Windows.Controls.MenuItem; $miFontDown.Header = '缩小字号'
$miFontDown.Add_Click({ Change-FontSize -3 }); [void]$menu.Items.Add($miFontDown)
$miReload = New-Object System.Windows.Controls.MenuItem; $miReload.Header = '重新获取歌词'
$miReload.Add_Click({ Force-Reload }); [void]$menu.Items.Add($miReload)
$miLock = New-Object System.Windows.Controls.MenuItem; $miLock.Header = '锁定（鼠标穿透，Ctrl+Alt+L 解锁）'
$miLock.Add_Click({ Set-Locked (-not $script:Locked) }); [void]$menu.Items.Add($miLock)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
$miQuit = New-Object System.Windows.Controls.MenuItem; $miQuit.Header = '退出'
$miQuit.Add_Click({ $script:Win.Close() }); [void]$menu.Items.Add($miQuit)
$panel.ContextMenu = $menu

# ---------------------------- 锁定 / 鼠标穿透 ----------------------------
$script:Locked = $false
$script:LockKeyWasDown = $false

function Update-Header {
    $base = [string]$script:HeaderBase
    if (-not $base) { $base = 'Spotify 未在播放' }
    if ($script:Locked) {
        $script:Ui.Track.Text = ("{0}    ·  🔒 已锁定，Ctrl+Alt+L 解锁" -f $base)
        $script:Ui.BtnBar.Opacity = 0
    } else {
        $script:Ui.Track.Text = $base
        $script:Ui.BtnBar.Opacity = 0.42
    }
}

function Set-Locked {
    param([bool]$On)
    if ($On -eq $script:Locked) { return }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:Win)
        $hwnd = $helper.Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            $ex = [LyricsWin32.Api]::GetWindowLong($hwnd, -20)
            if ($On) { $ex = $ex -bor 0x20 } else { $ex = $ex -band (-bnot 0x20) }
            [void][LyricsWin32.Api]::SetWindowLong($hwnd, -20, $ex)
            [void][LyricsWin32.Api]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x37)
        }
    } catch {
        Write-Log "lock fail: $($_.Exception.Message)"
        return
    }
    $script:Locked = $On
    Update-Header
    Write-Log ("locked=" + $On)
}

function Test-LockHotkey {
    try {
        $c = (([int][LyricsWin32.Api]::GetAsyncKeyState(0x11)) -band 0x8000) -ne 0
        $a = (([int][LyricsWin32.Api]::GetAsyncKeyState(0x12)) -band 0x8000) -ne 0
        $k = (([int][LyricsWin32.Api]::GetAsyncKeyState(0x4C)) -band 0x8000) -ne 0
        return ($c -and $a -and $k)
    } catch { return $false }
}

# ---------------------------- 底板透明度 / 收起成球 ----------------------------
$script:Collapsed = $false

function Set-PanelOpacity {
    param([double]$Value)
    $v = [Math]::Max(0.0, [Math]::Min(1.0, $Value))
    $script:Cfg.panelOpacity = $v
    $a = [int][Math]::Round($v * 255)
    $script:Ui.Panel.Background = Get-Brush ('#{0:X2}0B1020' -f $a)
    Save-Config
}

function Cycle-PanelOpacity {
    $steps = @(0.0, 0.2, 0.35, 0.52, 0.8)
    $cur = [double]$script:Cfg.panelOpacity
    $idx = 0
    for ($i = 0; $i -lt $steps.Count; $i++) { if ($cur -ge ($steps[$i] - 0.03)) { $idx = $i } }
    $next = $steps[($idx + 1) % $steps.Count]
    Set-PanelOpacity $next
    $pct = [int][Math]::Round($next * 100)
    Show-Status ("底板不透明度 " + $pct + "%")
}

function Set-Collapsed {
    param([bool]$On)
    if ($On -eq $script:Collapsed) { return }
    $screenW = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenH = [double][System.Windows.SystemParameters]::PrimaryScreenHeight
    if ($On) {
        $script:Cfg.x = [Math]::Round($script:Win.Left)
        $script:Cfg.y = [Math]::Round($script:Win.Top)
        $script:Ui.Panel.Visibility = 'Collapsed'
        $script:Ui.Ball.Visibility = 'Visible'
        $script:Win.Width = [double]$script:Cfg.ballSize
        $bs = [double]$script:Cfg.ballSize
        $side = if ($script:Win.Left -lt ($screenW / 2)) { 8.0 } else { $screenW - $bs - 8.0 }
        $top = [Math]::Max(8.0, [Math]::Min($screenH - $bs - 8.0, [double]$script:Win.Top))
        $script:Win.Left = $side
        $script:Win.Top = $top
    } else {
        $script:Ui.Ball.Visibility = 'Collapsed'
        $script:Ui.Panel.Visibility = 'Visible'
        $script:Win.Width = [double]$script:Cfg.windowWidth
        $l = [double]$script:Win.Left
        $t = [double]$script:Win.Top
        if ($l -lt 0) { $l = 0 }
        if ($l -gt ($screenW - [double]$script:Cfg.windowWidth)) { $l = $screenW - [double]$script:Cfg.windowWidth }
        if ($t -lt 0) { $t = 0 }
        if ($t -gt ($screenH - 140.0)) { $t = $screenH - 140.0 }
        $script:Win.Left = $l
        $script:Win.Top = $t
    }
    $script:Collapsed = $On
    $script:Cfg.collapsed = $On
    Save-Config
}

function Test-NearEdge {
    $screenW = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenH = [double][System.Windows.SystemParameters]::PrimaryScreenHeight
    $l = [double]$script:Win.Left
    $t = [double]$script:Win.Top
    $r = $l + [double]$script:Win.ActualWidth
    $b = $t + [double]$script:Win.ActualHeight
    return (($l -le 12.0) -or ($r -ge ($screenW - 12.0)) -or ($t -le 12.0) -or ($b -ge ($screenH - 12.0)))
}

$ballMenu = New-Object System.Windows.Controls.ContextMenu
$miExpand = New-Object System.Windows.Controls.MenuItem
$miExpand.Header = '展开歌词'
$miExpand.Add_Click({ Set-Collapsed $false })
[void]$ballMenu.Items.Add($miExpand)
[void]$ballMenu.Items.Add((New-Object System.Windows.Controls.Separator))
$miBallQuit = New-Object System.Windows.Controls.MenuItem
$miBallQuit.Header = '退出'
$miBallQuit.Add_Click({ $script:Win.Close() })
[void]$ballMenu.Items.Add($miBallQuit)
$script:Ui.Ball.ContextMenu = $ballMenu

$script:Ui.Ball.Add_MouseLeftButtonDown({
        $l0 = [double]$script:Win.Left
        $t0 = [double]$script:Win.Top
        try { $script:Win.DragMove() } catch { return }
        $moved = ([Math]::Abs([double]$script:Win.Left - $l0) -gt 3.0) -or ([Math]::Abs([double]$script:Win.Top - $t0) -gt 3.0)
        $screenW = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
        if ($script:Win.Left -lt 40.0) { $script:Win.Left = 8.0 }
        elseif (([double]$script:Win.Left + [double]$script:Win.ActualWidth) -gt ($screenW - 40.0)) { $script:Win.Left = $screenW - [double]$script:Win.ActualWidth - 8.0 }
        $script:Cfg.x = [Math]::Round($script:Win.Left)
        $script:Cfg.y = [Math]::Round($script:Win.Top)
        Save-Config
        if (-not $moved) { Set-Collapsed $false }
    })

# ---------------------------- 渲染 ----------------------------
$script:Lines      = @()
$script:Index      = -1
$script:LineWidth  = 300.0
$script:TrState    = 'none'
$script:TrJob      = $null
$script:StatusUntil = [DateTime]::MinValue
$script:Track      = [pscustomobject]@{ Title = ''; Artist = ''; Album = ''; Duration = 0; Key = '' }
$script:LastPropPoll = [DateTime]::MinValue
$script:DemoClock  = [System.Diagnostics.Stopwatch]::StartNew()
$script:HeaderBase = ''

function Show-Status {
    param([string]$Text, [int]$Seconds = 5)
    $script:Ui.Status.Text = $Text
    $script:Ui.Status.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
    $script:StatusUntil = (Get-Date).AddSeconds($Seconds)
}

function Fit-FontSize {
    param($Element, [string]$Text, [double]$Base, [double]$MaxWidth)
    $size = $Base
    while ($size -gt 13) {
        $Element.FontSize = $size
        $Element.Text = $Text
        $Element.Measure((New-Object System.Windows.Size(20000, 400)))
        if ($Element.DesiredSize.Width -le $MaxWidth) { return $size }
        $size -= 2
    }
    return $size
}

function Render-CurrentLine {
    $lines = $script:Lines
    if (-not $lines -or $lines.Count -eq 0) { return }

    $mode = [string]$script:Cfg.mode
    $idx  = $script:Index
    $maxW = [double]$script:Cfg.windowWidth - 80 - 20

    $cur = $null; $nxt = $null
    if ($idx -ge 0 -and $idx -lt $lines.Count) {
        $cur = $lines[$idx]
        $nxt = Get-NextLyricLine -From ($idx + 1)
    } else {
        $nxt = Get-NextLyricLine -From 0
    }

    $mainText = '♪'
    $trText   = ''
    $nextText = ''

    if ($cur) {
        $hasTr = ($cur.tr -and $cur.tr.Trim().Length -gt 0)
        switch ($mode) {
            'original'    { $mainText = if ($cur.text) { $cur.text } else { '♪' } }
            'translation' {
                if ($hasTr) { $mainText = $cur.tr }
                else {
                    $mainText = if ($cur.text) { $cur.text } else { '♪' }
                    $trText = '（暂无翻译）'
                }
            }
            default {
                $mainText = if ($cur.text) { $cur.text } else { '♪' }
                if ($hasTr) { $trText = $cur.tr }
                elseif ($script:TrState -eq 'pending') { $trText = 'AI 翻译中…' }
            }
        }
        if ($nxt) {
            if ($mode -eq 'translation' -and $nxt.tr) { $nextText = $nxt.tr } else { $nextText = $nxt.text }
        }
    } else {
        if ($nxt) { $nextText = $nxt.text }
    }

    # 主行
    $script:Ui.MainBase.Text = $mainText
    $script:Ui.MainHi.Text   = $mainText
    $baseSize = [Math]::Min([double]$script:Cfg.fontSize, 64.0)
    $size = Fit-FontSize -Element $script:Ui.MainBase -Text $mainText -Base $baseSize -MaxWidth $maxW
    $script:Ui.MainBase.FontSize = $size
    $script:Ui.MainHi.FontSize   = $size
    $script:Ui.MainGrid.Height   = [Math]::Max(42.0, [Math]::Round($size * 1.45))
    $script:Ui.MainHi.Measure((New-Object System.Windows.Size(20000, 400)))
    $script:LineWidth = [Math]::Max(1.0, $script:Ui.MainHi.DesiredSize.Width)

    # 翻译行
    if ($trText) {
        $script:Ui.Tr.Text = $trText
        $trSize = Fit-FontSize -Element $script:Ui.Tr -Text $trText -Base ([Math]::Max(12.0, $baseSize * 0.58)) -MaxWidth $maxW
        $script:Ui.Tr.FontSize = $trSize
        $script:Ui.Tr.Visibility = 'Visible'
    } else {
        $script:Ui.Tr.Text = ''
        $script:Ui.Tr.Visibility = 'Collapsed'
    }

    # 下一行
    if ($script:Cfg.showNextLine -and $nextText) {
        $script:Ui.Next.Text = $nextText
        $nxSize = Fit-FontSize -Element $script:Ui.Next -Text $nextText -Base ([Math]::Max(12.0, $baseSize * 0.62)) -MaxWidth $maxW
        $script:Ui.Next.FontSize = $nxSize
        $script:Ui.Next.Visibility = 'Visible'
    } else {
        $script:Ui.Next.Visibility = 'Collapsed'
    }

    Set-Wipe 0.0
}

function Fit-WindowHeight {
    # 窗口高度由 SizeToContent 自动撑开，这里只保证不超出屏幕底部
    try {
        $screenH = [System.Windows.SystemParameters]::PrimaryScreenHeight
        if (($script:Win.Top + $script:Win.ActualHeight) -gt ($screenH - 10)) {
            $script:Win.Top = [Math]::Max(0, $screenH - 10 - $script:Win.ActualHeight)
        }
    } catch {}
}

function Set-Wipe {
    param([double]$Progress)
    $p = [Math]::Max(0.0, [Math]::Min(1.0, $Progress))
    $w = $script:LineWidth * $p
    if ($w -lt 0.5) { $w = 0.5 } else { $w = $w + 2.0 }
    $script:Ui.Clip.Rect = New-Object System.Windows.Rect(0, -10, $w, 420)
}

function Get-NextLyricLine {
    param([int]$From)
    for ($i = [Math]::Max(0, $From); $i -lt $script:Lines.Count; $i++) {
        if ($script:Lines[$i].text) { return $script:Lines[$i] }
    }
    return $null
}

function Update-Position {
    param([double]$Pos)
    $lines = $script:Lines
    if (-not $lines -or $lines.Count -eq 0) { return }

    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].t -le $Pos) { $idx = $i } else { break }
    }
    if ($idx -ne $script:Index) {
        $script:Index = $idx
        Render-CurrentLine
        if ($script:Cfg.mode -ne 'original' -and (Test-NeedsAiTranslation)) { Request-Translation }
    }
    if ($idx -ge 0) {
        $start = [double]$lines[$idx].t
        $end   = if ($idx + 1 -lt $lines.Count) { [double]$lines[$idx + 1].t } else { [double]$script:Track.Duration }
        if ($end -le $start) { $end = $start + 4 }
        $span = [Math]::Max(0.4, $end - $start)
        Set-Wipe (($Pos - $start) / $span)
    }
}

function Test-NeedsAiTranslation {
    if ($script:TrState -eq 'ready' -or $script:TrState -eq 'pending' -or $script:TrState -eq 'failed') { return $false }
    if ([string]$script:Cfg.mode -eq 'original') { return $false }
    if (-not $script:Lines -or $script:Lines.Count -eq 0) { return $false }
    if (Test-HasCjk (($script:Lines | ForEach-Object { $_.text }) -join ' ')) { return $false }
    foreach ($l in $script:Lines) { if ($l.tr) { return $false } }
    return $true
}

function Request-Translation {
    if (-not (Test-NeedsAiTranslation)) { return }
    if (-not $script:Cfg.ai.enabled) {
        Show-Status '未找到翻译；可在 config.json 里填写 AI 密钥自动翻译'
        $script:TrState = 'failed'
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Cfg.ai.apiKey)) {
        Show-Status '这首歌没有现成翻译；填写 config.json 里的 ai.apiKey 可自动翻译'
        $script:TrState = 'failed'
        return
    }
    if (Start-AiTranslation -Lines $script:Lines) {
        $script:TrState = 'pending'
        Render-CurrentLine
    }
}

# ---------------------------- 曲目切换 ----------------------------
function Start-Track {
    param([string]$Title, [string]$Artist, [string]$Album, [double]$Duration)
    $key = Get-TrackKey -Title $Title -Artist $Artist
    if ($key -eq $script:Track.Key) { return }
    if ($script:TrJob) { Stop-Job -Job $script:TrJob -ErrorAction SilentlyContinue; Remove-Job -Job $script:TrJob -Force -ErrorAction SilentlyContinue; $script:TrJob = $null }

    $script:Track = [pscustomobject]@{ Title = $Title; Artist = $Artist; Album = $Album; Duration = $Duration; Key = $key }
    $script:Lines  = @()
    $script:Index  = -1
    $script:TrState = 'none'

    $label = if ($Artist) { "$Title — $Artist" } else { $Title }
    $script:HeaderBase = $label
    Update-Header
    $script:Win.ToolTip = $label

    $script:Ui.MainBase.Text = '正在获取歌词…'
    $script:Ui.MainHi.Text   = ''
    $script:Ui.Tr.Visibility = 'Collapsed'
    $script:Ui.Next.Visibility = 'Collapsed'

    $bundle = Get-LyricsBundle -Title $Title -Artist $Artist -DurationSec $Duration
    $script:Lines = @($bundle.Lines)
    $script:TrState = 'none'

    if ($script:Lines.Count -eq 0) {
        $script:Ui.MainBase.Text = '♪ 没有找到这首歌的歌词'
        $script:Ui.MainHi.Text = ''
        $script:Ui.Tr.Visibility = 'Collapsed'
        $script:Ui.Next.Visibility = 'Collapsed'
        Write-Log "no lyrics: $Title / $Artist"
        return
    }

    Write-Log "lyrics loaded: $($script:Lines.Count) lines from $($bundle.Source)"
    $script:HeaderBase = $label
    Update-Header
    $script:Index = -2
    Render-CurrentLine
}

function Force-Reload {
    $t = $script:Track
    if (-not $t.Key) { return }
    $file = Join-Path $script:CacheDir "$($t.Key).json"
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    $savedKey = $t.Key
    $script:Track.Key = ''
    Start-Track -Title $t.Title -Artist $t.Artist -Album $t.Album -Duration $t.Duration
    Show-Status '已重新获取歌词'
}

function Show-Idle {
    if ($script:Track.Key) {
        $script:Track = [pscustomobject]@{ Title = ''; Artist = ''; Album = ''; Duration = 0; Key = '' }
        $script:Lines = @()
        $script:Index = -1
    }
    $script:HeaderBase = 'Spotify 未在播放'
    Update-Header
    $script:Ui.MainBase.Text = '♪'
    $script:Ui.MainHi.Text   = ''
    $script:Ui.Tr.Visibility = 'Collapsed'
    $script:Ui.Next.Visibility = 'Collapsed'
    Set-Wipe 0
}

# ---------------------------- 主循环 ----------------------------
$script:AppClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:DebugShotTaken = $false

function Save-DebugShot {
    if (-not $DebugMode) { return }
    if ($script:DebugShotTaken) { return }
    if ($script:AppClock.ElapsedMilliseconds -lt 3000) { return }
    $script:DebugShotTaken = $true
    try {
        $w = [int][Math]::Ceiling($script:Win.ActualWidth)
        $h = [int][Math]::Ceiling($script:Win.ActualHeight)
        if ($w -lt 10) { $w = 800 }
        if ($h -lt 10) { $h = 200 }
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($script:Win)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create((Join-Path $script:AppRoot 'live.png'))
        $enc.Save($fs)
        $fs.Close()
        Write-Log "debug shot saved ${w}x${h}"
        Write-Log ("state: main=[{0}] size={1} desired={2}x{3} tr={4} next=[{5}] winH={6} idx={7}" -f `
                $script:Ui.MainBase.Text, $script:Ui.MainBase.FontSize, $script:Ui.MainBase.DesiredSize.Width, $script:Ui.MainBase.DesiredSize.Height,
                $script:Ui.Tr.Visibility, $script:Ui.Next.Text, $script:Win.ActualHeight, $script:Index)
    } catch { Write-Log "debug shot fail: $($_.Exception.Message)" }
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)

$script:Timer.Add_Tick({
        try {
            if ($script:StatusUntil -ne [DateTime]::MinValue -and (Get-Date) -gt $script:StatusUntil) {
                Show-Status ''
                $script:StatusUntil = [DateTime]::MinValue
            }
            # 全局热键 Ctrl+Alt+L：锁定 / 解锁（轮询按键状态，无需抢焦点）
            $hot = Test-LockHotkey
            if ($hot -and -not $script:LockKeyWasDown) { Set-Locked (-not $script:Locked) }
            $script:LockKeyWasDown = $hot

            if ($script:TrJob) { Complete-AiTranslation }
            if ($script:Cfg.alwaysOnTop) { $script:Win.Topmost = $true }
            if (-not $script:LoggedGeometry) {
                $script:LoggedGeometry = $true
                Write-Log ("geometry L={0} T={1} W={2} H={3} topmost={4}" -f $script:Win.Left, $script:Win.Top, $script:Win.ActualWidth, $script:Win.ActualHeight, $script:Win.Topmost)
            }

            # 调试模式：用假曲目跑时间轴
            if ($script:DebugTrack) {
                if (-not $script:Track.Key) {
                    $parts = $script:DebugTrack -split '\|'
                    Start-Track -Title $parts[0].Trim() -Artist $(if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }) -Album '' -Duration 240
                }
                Update-Position ($script:DemoClock.Elapsed.TotalSeconds)
                Save-DebugShot
                return
            }

            $session = Get-PlaySession
            if (-not $session) { Show-Idle; return }

            $now = [DateTime]::UtcNow
            if (($now - $script:LastPropPoll).TotalMilliseconds -gt 800) {
                $script:LastPropPoll = $now
                $props = Get-PlayProps -Session $session
                if ($props -and $props.Title) {
                    $tl0 = $session.GetTimelineProperties()
                    $dur = ($tl0.EndTime - $tl0.StartTime).TotalSeconds
                    if ($dur -le 0) { $dur = 0 }
                    Start-Track -Title $props.Title -Artist $props.Artist -Album $props.Album -Duration $dur
                }
            }

            $tl = $session.GetTimelineProperties()
            $pb = $session.GetPlaybackInfo()
            $pos = $tl.Position.TotalSeconds
            if ($pb.PlaybackStatus.ToString() -eq 'Playing') {
                $delta = ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds
                if ($delta -gt 0 -and $delta -lt 8) { $pos += $delta }
            }
            $pos += [double]$script:Cfg.syncOffset
            Update-Position $pos
        } catch {
            Write-Log "tick error: $($_.Exception.Message)"
        }
    })

# ---------------------------- 启动 ----------------------------
$winW = [double]$script:Cfg.windowWidth
$winH = [double]$script:Cfg.windowHeight
$screenW = [System.Windows.SystemParameters]::PrimaryScreenWidth
$screenH = [System.Windows.SystemParameters]::PrimaryScreenHeight

if ([double]$script:Cfg.x -ge 0 -and [double]$script:Cfg.y -ge 0) {
    $script:Win.Left = [double]$script:Cfg.x
    $script:Win.Top  = [double]$script:Cfg.y
} else {
    $script:Win.Left = [Math]::Round(($screenW - $winW) / 2)
    $script:Win.Top  = [Math]::Round($screenH - $winH - 60)
}

if ([bool]$script:Cfg.collapsed) { Set-Collapsed $true }

$script:Win.Add_SizeChanged({ Fit-WindowHeight })

$script:Win.Add_Closed({
        try {
            if (-not $Snapshot) {
                if (-not $script:Collapsed) {
                    $script:Cfg.x = [Math]::Round($script:Win.Left)
                    $script:Cfg.y = [Math]::Round($script:Win.Top)
                }
                Save-Config
            }
            if ($script:TrJob) { Stop-Job -Job $script:TrJob -ErrorAction SilentlyContinue; Remove-Job -Job $script:TrJob -Force -ErrorAction SilentlyContinue }
        } catch {}
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    })

Write-Log "app start (debug=$DebugMode track=$DebugTrack snapshot=$Snapshot)"

if ($Snapshot) {
    # 截图模式：把窗口放到屏幕外，渲染当前行并存图，然后退出（用于开发自检）
    $script:Win.Left = -6000
    $script:Win.Top  = -6000
    $script:SnapPath = $Snapshot
    $snapTimer = New-Object System.Windows.Threading.DispatcherTimer
    $snapTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $snapTimer.Add_Tick({
            $snapTimer.Stop()
            try {
                if ($script:DebugTrack) {
                    $parts = $script:DebugTrack -split '\|'
                    $artist = ''
                    if ($parts.Count -gt 1) { $artist = $parts[1].Trim() }
                    Start-Track -Title $parts[0].Trim() -Artist $artist -Album '' -Duration 240
                }
                Update-Position ([double]$SnapshotAt)
                $script:Win.UpdateLayout()
                $w = [int][Math]::Ceiling($script:Win.ActualWidth)
                $h = [int][Math]::Ceiling($script:Win.ActualHeight)
                if ($w -lt 10) { $w = 800 }
                if ($h -lt 10) { $h = 200 }
                $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                $rtb.Render($script:Win)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $fs = [IO.File]::Create($script:SnapPath)
                $enc.Save($fs)
                $fs.Close()
                Write-Log "snapshot saved $($script:SnapPath) ${w}x${h}"
            } catch {
                Write-Log "snapshot fail: $($_.Exception.Message)"
            }
            $script:Win.Close()
        })
    $script:Win.Show()
    $snapTimer.Start()
} else {
    $script:Win.Show()
    $script:Timer.Start()
}
[System.Windows.Threading.Dispatcher]::Run()
Write-Log 'app exit'
