# vSRM uzak baslaticisi. Icerik tasimaz; surum listesini ve secilen parcalari indirir, baslat.ps1'e devreder.
# Kaynak: 'github' (test), 'sharepoint' (Entra uygulama kimligi varsa Graph, yoksa esitlenen OneDrive klasoru).
param(
    [ValidateSet('github', 'sharepoint')][string]$Tur = 'sharepoint',
    [string]$TabanUrl = 'https://raw.githubusercontent.com/trexpy/vsrm-skills-test/main/dagitim',
    [string]$KiraciId = '5ec21d40-ac3d-4a65-bca6-fb88928bd93a',
    [string]$UygulamaId = '',
    [string]$SurucuId = '',
    [string]$Klasor = 'vsrm-assistant-v3',
    [string]$KaynakKlasor = '',
    [string[]]$Bilesen = @(),
    [string[]]$Komut = @(),
    [string]$HomeDir = $env:USERPROFILE,
    [string]$YerelKok = (Join-Path $env:LOCALAPPDATA 'vSRM-Assistant'),
    [switch]$Liste
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$utf8 = New-Object System.Text.UTF8Encoding($false)
$depo = Join-Path $YerelKok 'indirme'
$script:Token = ''

function Base64Url([byte[]]$B) { [Convert]::ToBase64String($B).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function Giris {
    # Sistem tarayicisi ve PKCE. Parola bu betige gelmez.
    $dogrulayici = Base64Url ([Guid]::NewGuid().ToByteArray() + [Guid]::NewGuid().ToByteArray())
    $meydan = Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($dogrulayici)))
    $durum = [Guid]::NewGuid().ToString('N')
    $dinleyici = New-Object Net.HttpListener
    $port = Get-Random -Minimum 49200 -Maximum 49900
    $donus = "http://localhost:$port/"
    $dinleyici.Prefixes.Add($donus); $dinleyici.Start()
    $kapsam = [uri]::EscapeDataString('offline_access Files.Read.All')
    $adres = "https://login.microsoftonline.com/$KiraciId/oauth2/v2.0/authorize?client_id=$UygulamaId&response_type=code&redirect_uri=$([uri]::EscapeDataString($donus))&scope=$kapsam&code_challenge=$meydan&code_challenge_method=S256&state=$durum"
    Start-Process $adres
    'Tarayicida Microsoft girisini tamamla.'
    $bekle = $dinleyici.GetContextAsync()
    if (-not $bekle.Wait([TimeSpan]::FromMinutes(5))) { $dinleyici.Stop(); throw 'Giris zaman asimina ugradi.' }
    $baglam = $bekle.Result
    $kod = $baglam.Request.QueryString['code']; $gelen = $baglam.Request.QueryString['state']
    $yanit = [Text.Encoding]::UTF8.GetBytes('Giris tamam. Bu sekmeyi kapatabilirsin.')
    $baglam.Response.OutputStream.Write($yanit, 0, $yanit.Length); $baglam.Response.Close(); $dinleyici.Stop()
    if (-not $kod -or $gelen -ne $durum) { throw 'Microsoft girisi tamamlanamadi.' }
    $t = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$KiraciId/oauth2/v2.0/token" -Body @{
        client_id = $UygulamaId; grant_type = 'authorization_code'; code = $kod; redirect_uri = $donus; code_verifier = $dogrulayici
    }
    $script:Token = $t.access_token
}
function Adres([string]$Dosya) {
    if ($Tur -eq 'sharepoint') { return "https://graph.microsoft.com/v1.0/drives/$SurucuId/root:/$Klasor/$([uri]::EscapeDataString($Dosya)):/content" }
    return "$TabanUrl/$Dosya"
}
function Istek([string]$Dosya, [long]$Baslangic) {
    $r = [Net.HttpWebRequest]::Create((Adres $Dosya))
    $r.UserAgent = 'vsrm-kurulum'; $r.ReadWriteTimeout = 60000; $r.Timeout = 60000
    if ($script:Token) { $r.Headers['Authorization'] = "Bearer $script:Token" }
    if ($Baslangic -gt 0) { $r.AddRange($Baslangic) }
    return $r.GetResponse()
}
function Indir-Metin([string]$Dosya) {
    $y = Istek $Dosya 0
    try { (New-Object IO.StreamReader($y.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() } finally { $y.Close() }
}
function Indir-Parca($Parca) {
    $hedef = Join-Path $depo $Parca.dosya
    $yarim = "$hedef.partial"
    if ((Test-Path -LiteralPath $hedef) -and (Get-FileHash -LiteralPath $hedef -Algorithm SHA256).Hash.ToLower() -eq $Parca.sha256) { return }
    for ($deneme = 1; $deneme -le 5; $deneme++) {
        try {
            $mevcut = if (Test-Path -LiteralPath $yarim) { (Get-Item -LiteralPath $yarim).Length } else { 0 }
            if ($mevcut -lt [long]$Parca.bayt) {
                $y = Istek $Parca.dosya $mevcut
                try {
                    # Sunucu Range desteklemezse 200 doner; o zaman dosya bastan yazilir.
                    $kip = if ([int]$y.StatusCode -eq 206) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
                    $cikis = New-Object IO.FileStream($yarim, $kip, [IO.FileAccess]::Write)
                    try { $y.GetResponseStream().CopyTo($cikis, 1MB) } finally { $cikis.Close() }
                } finally { $y.Close() }
            }
            if ((Get-FileHash -LiteralPath $yarim -Algorithm SHA256).Hash.ToLower() -eq $Parca.sha256) {
                if (Test-Path -LiteralPath $hedef) { Remove-Item -LiteralPath $hedef -Force }
                Move-Item -LiteralPath $yarim -Destination $hedef
                return
            }
            Remove-Item -LiteralPath $yarim -Force
        } catch {
            if ($deneme -eq 5) { throw "Indirilemedi: $($Parca.dosya). $($_.Exception.Message)" }
            Start-Sleep -Seconds ([math]::Min(30, 2 * $deneme))
        }
    }
    throw "Parca bozuk indi: $($Parca.dosya)"
}
function Klasor-Bul {
    if ($KaynakKlasor) { return $KaynakKlasor }
    $adaylar = Get-ChildItem $HomeDir -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName $Klasor } |
        Where-Object { Test-Path (Join-Path $_ 'surum.json') }
    if (-not $adaylar) { throw 'Kurulum klasoru bulunamadi. Paylasilan vsrm-assistant-v3 klasorunu OneDrive''a ekle.' }
    @($adaylar)[0]
}

# Ara birakilan adimlarin tamami tek cagriyla tekrar edilebilir.
New-Item -ItemType Directory -Force $depo | Out-Null
$kaynak = $depo
if ($Tur -eq 'sharepoint' -and -not $UygulamaId) {
    $kaynak = Klasor-Bul
    $manifest = [IO.File]::ReadAllText((Join-Path $kaynak 'surum.json'), $utf8) | ConvertFrom-Json
} else {
    if ($Tur -eq 'sharepoint') { Giris }
    $metin = Indir-Metin 'surum.json'
    [IO.File]::WriteAllText((Join-Path $depo 'surum.json'), $metin, $utf8)
    $manifest = $metin | ConvertFrom-Json
    $secilen = @($Bilesen | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $durumYolu = Join-Path $YerelKok 'kurulu-surum.json'
    if (Test-Path $durumYolu) { $secilen += @(([IO.File]::ReadAllText($durumYolu, $utf8) | ConvertFrom-Json).bilesenler) }
    foreach ($p in $manifest.parcalar) {
        if ($p.ad -eq 'danisman-paketi' -or $secilen -contains $p.bilesen) { Indir-Parca $p }
    }
}
$paket = $manifest.parcalar | Where-Object { $_.ad -eq 'danisman-paketi' } | Select-Object -First 1
if (-not $paket) { throw 'Surum listesinde danisman paketi yok.' }

# Ilk calistirmada baslat.ps1 paketin icinden gelir.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$gecici = Join-Path $YerelKok "bootstrap-$PID"
try {
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $kaynak $paket.dosya), $gecici)
    $baslat = Join-Path $gecici 'vsrm-assistant\kurulum\baslat.ps1'
    $arg = @{ Kaynak = $kaynak; HomeDir = $HomeDir; PaketYeri = (Join-Path $YerelKok 'paket'); KurulumYeri = (Join-Path $YerelKok 'uygulama') }
    if ($Liste) { $arg.Liste = $true }
    if ($Bilesen.Count) { $arg.Bilesen = $Bilesen }
    if ($Komut.Count) { $arg.Komut = $Komut }
    & $baslat @arg
} finally { Remove-Item $gecici -Recurse -Force -ErrorAction SilentlyContinue }
