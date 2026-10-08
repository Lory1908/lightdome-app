param(
    [switch]$SkipAndroid
)

$ErrorActionPreference = 'Stop'
$flutter = 'C:\Users\loryc\.vscode\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) {
    throw "Flutter non trovato in $flutter"
}

Write-Host '[1/4] Aggiorno le dipendenze Flutter...'
& $flutter pub get

Write-Host '[2/4] Controllo il codice...'
& $flutter analyze

Write-Host '[3/4] Creo la versione Web con il font icone completo...'
& $flutter build web --release --no-tree-shake-icons

if ($SkipAndroid) {
    Write-Host '[4/4] APK saltato. Build Web pronta in build\web.'
} else {
    Write-Host '[4/4] Creo l''APK Android di test...'
    & $flutter build apk --debug
}

Write-Host 'Build LightDome completata.'
