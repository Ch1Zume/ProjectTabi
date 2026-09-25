$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'assets/projecttabi_icon.png'
$generated = Join-Path $root '.local-tools/generated-icons'
$tauriCli = Join-Path $root 'node_modules/.bin/tauri.cmd'

if (-not (Test-Path -LiteralPath $source)) {
    throw "Source app icon not found: $source"
}
if (-not (Test-Path -LiteralPath $tauriCli)) {
    throw 'Install the Node dependencies with npm ci before generating app icons.'
}

& $tauriCli icon $source --output $generated
if ($LASTEXITCODE -ne 0) {
    throw 'Tauri icon generation failed.'
}

$tauriIcons = Join-Path $root 'src-tauri/icons'
foreach ($name in @('32x32.png', '64x64.png', '128x128.png', '128x128@2x.png', 'icon.png', 'icon.ico', 'icon.icns')) {
    Copy-Item -LiteralPath (Join-Path $generated $name) -Destination (Join-Path $tauriIcons $name) -Force
}

$androidResources = Join-Path $root 'android/app/src/main/res'
$generatedAndroid = Join-Path $generated 'android'
foreach ($directory in Get-ChildItem -LiteralPath $generatedAndroid -Directory) {
    $target = Join-Path $androidResources $directory.Name
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Get-ChildItem -LiteralPath $directory.FullName -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name) -Force
    }
}

$iosIcons = Join-Path $root 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
$generatedIos = Join-Path $generated 'ios'
$iosContents = Get-Content -LiteralPath (Join-Path $iosIcons 'Contents.json') -Raw | ConvertFrom-Json
foreach ($entry in $iosContents.images) {
    $sourceName = if ($entry.filename -eq 'Icon-App-1024x1024@1x.png') {
        'AppIcon-512@2x.png'
    } else {
        $entry.filename.Replace('Icon-App-', 'AppIcon-')
    }
    Copy-Item -LiteralPath (Join-Path $generatedIos $sourceName) -Destination (Join-Path $iosIcons $entry.filename) -Force
}

Add-Type -AssemblyName System.Drawing
$sourceImage = [System.Drawing.Bitmap]::FromFile($source)
try {
    function Write-IconPng([string] $destination, [int] $size) {
        $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.DrawImage($sourceImage, 0, 0, $size, $size)
            } finally {
                $graphics.Dispose()
            }
            $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $bitmap.Dispose()
        }
    }

    Write-IconPng (Join-Path $root 'web/favicon.png') 32
    Write-IconPng (Join-Path $root 'web/icons/Icon-192.png') 192
    Write-IconPng (Join-Path $root 'web/icons/Icon-512.png') 512
    Write-IconPng (Join-Path $root 'web/icons/Icon-maskable-192.png') 192
    Write-IconPng (Join-Path $root 'web/icons/Icon-maskable-512.png') 512
} finally {
    $sourceImage.Dispose()
}

Write-Output 'Generated Tauri, Android, iOS and web icons from assets/projecttabi_icon.png.'
