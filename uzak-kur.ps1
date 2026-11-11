# vSRM uzak baslaticisi. Icerik tasimaz; surum listesini ve secilen parcalari indirir, baslat.ps1'e devreder.
# Kaynak: 'github' (varsayilan: ozel depodaki kurulum-* surumu, danisman GitHub girisiyle), 'sharepoint' (Entra uygulama kimligi varsa Graph, yoksa esitlenen OneDrive klasoru).
# -TabanUrl verilirse dosyalar dogrudan o adresten alinir (testler).
param(
    [ValidateSet('github', 'sharepoint')][string]$Tur = 'github',
    [string]$GitHubDepo = 'trexpy/vsrm-assistant-v3',
    [string]$Etiket = '',
    [string]$TabanUrl = 'https://raw.githubusercontent.com/trexpy/vsrm-skills-test/main/dagitim',
    [string]$KiraciId = '5ec21d40-ac3d-4a65-bca6-fb88928bd93a',
    [string]$UygulamaId = '',
    [string]$SurucuId = '',
    [string]$Klasor = 'vsrm-assistant-v3',
    [string]$KaynakKlasor = '',
    [string[]]$Bilesen = @(),
    [string[]]$Komut = @(),
    [string]$HomeDir = $env:USERPROFILE,
    [string]$YerelKok = (Join-Path $env:USERPROFILE '.vsrm-assistant'),
    [switch]$Liste
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$utf8 = New-Object System.Text.UTF8Encoding($false)
$depo = Join-Path $YerelKok 'indirme'
$script:Token = ''
$script:Yayin = ($Tur -eq 'github' -and -not $PSBoundParameters.ContainsKey('TabanUrl'))
$script:Varliklar = @{}

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
function GitHub-Token {
    if ($env:VSRM_GITHUB_TOKEN) { return $env:VSRM_GITHUB_TOKEN }
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $t = & gh auth token 2>$null
        if ($LASTEXITCODE -eq 0 -and $t) { return "$t".Trim() }
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        # Git Credential Manager gerekirse tarayicida GitHub girisini acar; terminalden sifre sorulmaz.
        $env:GIT_TERMINAL_PROMPT = '0'
        $cikti = "protocol=https`nhost=github.com`n`n" | & git credential fill 2>$null
        $satir = @($cikti) | Where-Object { $_ -like 'password=*' } | Select-Object -First 1
        if ($satir) { return $satir.Substring(9) }
    }
    throw 'GitHub girisi bulunamadi. Bilgisayarda Git for Windows kurulu olmali; ilk kurulumda tarayicida GitHub girisi acilir.'
}
function Yayin-Bul {
    $h = @{ Authorization = "Bearer $script:Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'vsrm-kurulum' }
    $yol = if ($Etiket) { "https://api.github.com/repos/$GitHubDepo/releases/tags/$Etiket" } else { "https://api.github.com/repos/$GitHubDepo/releases?per_page=30" }
    try { $r = Invoke-RestMethod -Uri $yol -Headers $h -UseBasicParsing }
    catch {
        $kod = 0; try { $kod = [int]$_.Exception.Response.StatusCode } catch {}
        if ($kod -eq 401) { throw 'GitHub girisi gecersiz. Tarayicida GitHub hesabina yeniden giris yap.' }
        if ($kod -eq 404) { throw "Kurulum deposuna erisim yok ($GitHubDepo). Paket sahibinden GitHub daveti iste." }
        throw "GitHub'a ulasilamadi: $($_.Exception.Message)"
    }
    if (-not $Etiket) { $r = @($r) | Where-Object { $_.tag_name -like 'kurulum-*' -and -not $_.draft } | Select-Object -First 1 }
    if (-not $r) { throw 'Depoda kurulum surumu yok. Paket sahibine haber ver.' }
    foreach ($a in @($r.assets)) { $script:Varliklar[$a.name] = $a.url }
}
function Adres([string]$Dosya) {
    if ($Tur -eq 'sharepoint') { return "https://graph.microsoft.com/v1.0/drives/$SurucuId/root:/$Klasor/$([uri]::EscapeDataString($Dosya)):/content" }
    if ($script:Yayin) {
        $u = $script:Varliklar[$Dosya]
        if (-not $u) { throw "Kurulum surumunde dosya yok: $Dosya" }
        return $u
    }
    return "$TabanUrl/$Dosya"
}
function Istek([string]$Dosya, [long]$Baslangic) {
    $adres = Adres $Dosya
    for ($i = 0; $i -lt 4; $i++) {
        $r = [Net.HttpWebRequest]::Create($adres)
        $r.UserAgent = 'vsrm-kurulum'; $r.ReadWriteTimeout = 60000; $r.Timeout = 60000
        $kimlikli = $script:Token -and ($adres -like 'https://graph.microsoft.com/*' -or $adres -like 'https://api.github.com/*')
        if ($kimlikli) { $r.Headers['Authorization'] = "Bearer $script:Token" }
        if ($script:Yayin) {
            # GitHub dosyayi gecici bir indirme adresine yonlendirir; o adrese kimlik bilgisi gonderilmez.
            $r.Accept = 'application/octet-stream'; $r.AllowAutoRedirect = $false
        }
        if ($Baslangic -gt 0) { $r.AddRange($Baslangic) }
        $y = $r.GetResponse()
        $kod = [int]$y.StatusCode
        if ($kod -ge 300 -and $kod -lt 400 -and $y.Headers['Location']) { $adres = $y.Headers['Location']; $y.Close(); continue }
        return $y
    }
    throw "Indirme adresi cok fazla yonlendirildi: $Dosya"
}
function Indir-Metin([string]$Dosya) {
    $y = Istek $Dosya 0
    try { (New-Object IO.StreamReader($y.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() } finally { $y.Close() }
}
function Ozet([string]$Yol) { (Get-FileHash -LiteralPath $Yol -Algorithm SHA256).Hash.ToLower() }
function Dilimler($Parca) { if ($Parca.dilimler) { @($Parca.dilimler) } }
function Guvenli-Dosya([string]$Ad) { if ($Ad -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Gecersiz dosya adi: $Ad" } }
function Indir-Dosya([string]$Ad, [string]$Sha, [long]$Bayt) {
    Guvenli-Dosya $Ad
    $hedef = Join-Path $depo $Ad
    $yarim = "$hedef.partial"
    if ((Test-Path -LiteralPath $hedef) -and (Ozet $hedef) -eq $Sha) { return }
    for ($deneme = 1; $deneme -le 5; $deneme++) {
        try {
            $mevcut = if (Test-Path -LiteralPath $yarim) { (Get-Item -LiteralPath $yarim).Length } else { 0 }
            if ($mevcut -lt $Bayt) {
                $y = Istek $Ad $mevcut
                try {
                    # Sunucu Range desteklemezse 200 doner; o zaman dosya bastan yazilir.
                    $kip = if ([int]$y.StatusCode -eq 206) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
                    $cikis = New-Object IO.FileStream($yarim, $kip, [IO.FileAccess]::Write)
                    try { $y.GetResponseStream().CopyTo($cikis, 1MB) } finally { $cikis.Close() }
                } finally { $y.Close() }
            }
            if ((Ozet $yarim) -eq $Sha) {
                if (Test-Path -LiteralPath $hedef) { Remove-Item -LiteralPath $hedef -Force }
                Move-Item -LiteralPath $yarim -Destination $hedef
                return
            }
            Remove-Item -LiteralPath $yarim -Force
        } catch {
            if ($deneme -eq 5) { throw "Indirilemedi: $Ad. $($_.Exception.Message)" }
            Start-Sleep -Seconds ([math]::Min(30, 2 * $deneme))
        }
    }
    throw "Parca bozuk indi: $Ad"
}
function Indir-Parca($Parca) {
    $dilimler = @(Dilimler $Parca)
    if (-not $dilimler.Count) { Indir-Dosya $Parca.dosya $Parca.sha256 ([long]$Parca.bayt); return }
    Guvenli-Dosya $Parca.dosya
    $hedef = Join-Path $depo $Parca.dosya
    if ((Test-Path -LiteralPath $hedef) -and (Ozet $hedef) -eq $Parca.sha256) { return }
    # Tamamlanan dilimler diskte kalir, yeniden indirilmez. Dilimler ancak tum ozet tutunca silinir.
    foreach ($d in $dilimler) { Indir-Dosya $d.dosya $d.sha256 ([long]$d.bayt) }
    $birlesik = "$hedef.birlesik"
    $cikis = New-Object IO.FileStream($birlesik, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try {
        foreach ($d in $dilimler) {
            $giris = [IO.File]::OpenRead((Join-Path $depo $d.dosya))
            try { $giris.CopyTo($cikis, 1MB) } finally { $giris.Close() }
        }
    } finally { $cikis.Close() }
    if ((Ozet $birlesik) -ne $Parca.sha256) {
        Remove-Item -LiteralPath $birlesik -Force
        throw "Birlesik parca bozuk: $($Parca.dosya)"
    }
    if (Test-Path -LiteralPath $hedef) { Remove-Item -LiteralPath $hedef -Force }
    Move-Item -LiteralPath $birlesik -Destination $hedef
    foreach ($d in $dilimler) { Remove-Item -LiteralPath (Join-Path $depo $d.dosya) -Force }
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
    if ($script:Yayin) { $script:Token = GitHub-Token; Yayin-Bul }
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
