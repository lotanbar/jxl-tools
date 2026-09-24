#Requires -Version 7.0
<#
.SYNOPSIS
    Recursively converts a folder of images to JPEG XL, picking lossy or lossless
    per file by measuring both. Results go to an 'output' folder next to the
    source folder, mirroring the structure below it. Keeps filenames and file
    timestamps. Never produces a file bigger than its input.

.EXAMPLE
    .\Convert-ToJxl.ps1 .\Photos

.NOTES
    Per file:
      1. encode lossless            -> L
      2. encode lossy (-d 1.0)      -> Y
      3. Y < Threshold * L          -> keep lossy
      4. else L < original          -> keep lossless
      5. else                       -> copy the original to output unchanged

    Originals are never touched. Re-running skips what is already in output.
    Anything that needs attention (failures, originals kept, non-image files
    not copied) is listed under 'Issues' at the end.
#>

param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Folder
)

# ============================== tunables ====================================
$Distance  = 1.0   # lossy target. 0 = lossless, 1.0 = visually lossless, 2.0 = smaller
$Effort    = 8     # 1-10. 8 is the sweet spot.
$Threshold = 0.7   # keep lossy only if it is <70% the size of the lossless version
# ============================================================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-Size { param([double]$b)
    $u = 'B','KB','MB','GB','TB'; $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }
    '{0:N1} {1}' -f $b, $u[$i]
}
function Get-Tool { param([string]$n)
    (Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)?.Source
}

$cjxl   = Get-Tool 'cjxl'
$magick = Get-Tool 'magick'
if (-not $cjxl) { throw "cjxl not found. Install with:  scoop install libjxl" }

$root = (Resolve-Path -LiteralPath $Folder).ProviderPath.TrimEnd('')
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Not a folder: $root" }
$parent = Split-Path -Path $root -Parent
if (-not $parent) { throw "Can't put 'output' next to a drive root: $root" }
$outRoot = Join-Path $parent 'output'

# cjxl reads these directly.
$native = @('.jpg','.jpeg','.jpe','.jfif','.png','.apng','.gif','.ppm','.pgm','.pnm','.pam','.pfm','.exr')
# These need ImageMagick to reach a format cjxl can read.
$bridge = @('.tif','.tiff','.bmp','.webp','.heic','.heif','.avif')
$jpeg   = @('.jpg','.jpeg','.jpe','.jfif')

Write-Host "Scanning $root ..." -ForegroundColor Cyan
$all    = @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)
$files  = @($all | Where-Object { ($native + $bridge) -contains $_.Extension.ToLowerInvariant() })
$others = @($all | Where-Object { ($native + $bridge) -notcontains $_.Extension.ToLowerInvariant() })

$issues = [Collections.Generic.List[string]]::new()
foreach ($o in $others) {
    $issues.Add("not an image, not copied :: $([IO.Path]::GetRelativePath($root, $o.FullName))")
}

$total = $files.Count
if ($total -eq 0) { Write-Host 'No images found.' -ForegroundColor Yellow; return }

$needBridge = @($files | Where-Object { $bridge -contains $_.Extension.ToLowerInvariant() }).Count
if ($needBridge -and -not $magick) {
    throw "$needBridge file(s) need ImageMagick, which isn't installed. Install with:  scoop install imagemagick"
}
Write-Host "Found $total image(s). Encoding each twice to compare." -ForegroundColor Cyan
Write-Host "Output: $outRoot`n" -ForegroundColor Cyan

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("jxl_" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmp)

$nLossy = 0; $nLossless = 0; $nKept = 0; $nSkip = 0; $nFail = 0
$bIn = [long]0; $bOut = [long]0
$t0 = Get-Date; $i = 0

try {
    foreach ($f in $files) {
        $i++
        $rel = [IO.Path]::GetRelativePath($root, $f.FullName)
        $ext = $f.Extension.ToLowerInvariant()
        $out  = Join-Path $outRoot ([IO.Path]::ChangeExtension($rel, '.jxl'))
        $copy = Join-Path $outRoot $rel
        [void][IO.Directory]::CreateDirectory((Split-Path -Path $out -Parent))

        Write-Progress -Id 1 -Activity 'Converting to JPEG XL' `
            -Status ("[{0}/{1}] {2}  |  saved {3}" -f $i, $total, $rel, (Format-Size ($bIn - $bOut))) `
            -PercentComplete (($i - 1) / $total * 100)

        if ((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath $copy)) {
            $nSkip++; Write-Host "  skip  $rel  (already in output)" -ForegroundColor DarkGray; continue
        }

        $stem  = Join-Path $tmp ([guid]::NewGuid().ToString('N'))
        $png   = "$stem.png"
        $tmpL  = "$stem.l.jxl"
        $tmpY  = "$stem.y.jxl"
        $isJpeg = $jpeg -contains $ext

        try {
            # -- get to something cjxl can read ------------------------------
            $src = $f.FullName
            if ($bridge -contains $ext) {
                $m = & $magick $f.FullName -auto-orient $png 2>&1
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $png)) { throw "ImageMagick: $m" }
                $src = $png
            }

            # -- encode 1: lossless ------------------------------------------
            # JPEG gets the reversible coefficient repack; everything else -d 0.
            $argsL = if ($isJpeg) { @('--lossless_jpeg=1','-e',$Effort) } else { @('-d',0,'-e',$Effort) }
            $r = & $cjxl @argsL $src $tmpL 2>&1
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpL)) { throw "cjxl lossless: $($r -join ' ')" }
            $L = (Get-Item -LiteralPath $tmpL).Length

            # -- encode 2: lossy ---------------------------------------------
            $argsY = @('-d',$Distance,'-e',$Effort) + $(if ($isJpeg) { @('--lossless_jpeg=0') } else { @() })
            $r = & $cjxl @argsY $src $tmpY 2>&1
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpY)) { throw "cjxl lossy: $($r -join ' ')" }
            $Y = (Get-Item -LiteralPath $tmpY).Length

            # -- decide -------------------------------------------------------
            $orig = $f.Length
            if ($Y -lt $Threshold * $L -and $Y -lt $orig) {
                Move-Item -LiteralPath $tmpY -Destination $out -Force
                $mode = 'lossy   '; $new = $Y; $nLossy++
            }
            elseif ($L -lt $orig) {
                Move-Item -LiteralPath $tmpL -Destination $out -Force
                $mode = 'lossless'; $new = $L; $nLossless++
            }
            else {
                Copy-Item -LiteralPath $f.FullName -Destination $copy
                (Get-Item -LiteralPath $copy).CreationTime = $f.CreationTime
                $nKept++
                $issues.Add(("kept original, JXL would be bigger (lossy {0}, lossless {1}) :: {2}" -f (Format-Size $Y), (Format-Size $L), $rel))
                Write-Host ("  keep  {0}  {1}  (JXL would be bigger, original copied)" -f $rel, (Format-Size $orig)) -ForegroundColor DarkYellow
                $bIn += $orig; $bOut += $orig
                continue
            }

            # -- carry timestamps across --------------------------------------
            $item = Get-Item -LiteralPath $out
            $item.CreationTime  = $f.CreationTime
            $item.LastWriteTime = $f.LastWriteTime

            $bIn += $orig; $bOut += $new
            $pct = (1 - $new / $orig) * 100
            Write-Host ("  {0}  {1}  {2} -> {3}  ({4:N1}%)" -f $mode, $rel,
                (Format-Size $orig), (Format-Size $new), $pct) -ForegroundColor Green
        }
        catch {
            $nFail++; $issues.Add("FAILED: $($_.Exception.Message) :: $rel")
            Write-Host ("  FAIL  {0}  {1}" -f $rel, $_.Exception.Message) -ForegroundColor Red
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
        }
        finally {
            foreach ($t in @($png, $tmpL, $tmpY)) {
                if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
finally {
    Write-Progress -Id 1 -Activity 'Converting to JPEG XL' -Completed
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$pctAll = if ($bIn) { (1 - $bOut / $bIn) * 100 } else { 0 }
Write-Host ''
Write-Host ('-' * 58) -ForegroundColor DarkGray
Write-Host "Lossy     : $nLossy"    -ForegroundColor Green
Write-Host "Lossless  : $nLossless" -ForegroundColor Green
Write-Host "Kept as-is: $nKept"     -ForegroundColor DarkYellow
Write-Host "Skipped   : $nSkip"     -ForegroundColor DarkGray
Write-Host "Failed    : $nFail"     -ForegroundColor $(if ($nFail) { 'Red' } else { 'DarkGray' })
Write-Host ("Size      : {0} -> {1}" -f (Format-Size $bIn), (Format-Size $bOut))
Write-Host ("Saved     : {0}  ({1:N1}%)" -f (Format-Size ($bIn - $bOut)), $pctAll) -ForegroundColor Cyan
Write-Host ("Elapsed   : {0:hh\:mm\:ss}" -f ((Get-Date) - $t0)) -ForegroundColor DarkGray
Write-Host ('-' * 58) -ForegroundColor DarkGray
Write-Host "Output    : $outRoot" -ForegroundColor DarkGray
if ($issues.Count) {
    Write-Host "`nIssues ($($issues.Count)):" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "  $_" -ForegroundColor $(if ($_ -like 'FAILED*') { 'Red' } else { 'Yellow' }) }
}
