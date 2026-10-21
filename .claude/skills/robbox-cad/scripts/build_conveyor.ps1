param(
  [Parameter(Mandatory=$true)][string]$Config
)
$ErrorActionPreference = 'Continue'

$lib = $null
$cfg = $null
$libPath = ''
if (Test-Path $Config) {
  $cs = [System.IO.File]::ReadAllText($Config, [System.Text.UTF8Encoding]::new($false))
  for ($i=0; $i -lt 5; $i++) {
    try { $o = ConvertFrom-Json -InputObject $cs; if ($o -isnot [string]) { $cfg = $o; break } } catch {}
    Start-Sleep -Milliseconds 200
  }
} else { Write-Host "CONFIG NOT FOUND: $Config"; exit 1 }

$libPath = $cfg.elements_lib
if (-not $libPath) {
  $libPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\elements.json'
}
$lib = $null
$s = [System.IO.File]::ReadAllText($libPath, [System.Text.UTF8Encoding]::new($false))
for ($i=0; $i -lt 5 -and $lib -eq $null; $i++) {
  try { $o = ConvertFrom-Json -InputObject $s; if ($o -isnot [string]) { $lib = $o } } catch {}
  if ($lib -eq $null) { Start-Sleep -Milliseconds 200 }
}
if ($lib -eq $null) { Write-Host "JSON PARSE FAILED: $libPath"; exit 1 }
if ($cfg -eq $null) { Write-Host "CONFIG PARSE FAILED: $Config"; exit 1 }

$outDwg = $cfg.output.dwg
$outDxf = if ($cfg.output.PSObject.Properties['dxf'] -and $cfg.output.dxf) { [System.IO.Path]::ChangeExtension($outDwg, '.dxf') } else { $null }
$rptDir = 'C:\RobBox\ai\project\dwg elements\convert'
$RPT = Join-Path $rptDir (([System.IO.Path]::GetFileNameWithoutExtension($outDwg)) + '_report.txt')

$sw = New-Object System.IO.StreamWriter($RPT, $false, (New-Object System.Text.UTF8Encoding($false)))
function RW($s) { $sw.WriteLine([string]$s); $sw.Flush() }
function Retry([scriptblock]$sb, [int]$tries = 600) {
  for ($t=0; $t -lt $tries; $t++) {
    try { $r = & $sb; return $r } catch {
      if ($_.Exception.HResult -eq -2147418111 -or $_.Exception.Message -match 'RPC_E_CALL_REJECTED|0x80010001') { Start-Sleep -Milliseconds 500 } else { throw }
    }
  }
  throw "RETRIES-EXHAUSTED"
}
function Pt([double]$x, [double]$y, [double]$z) { $p = New-Object 'double[]' 3; $p[0]=$x; $p[1]=$y; $p[2]=$z; return ,$p }
function BBoxOf($e) {
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  return ,$bb
}
function FmtBb($bb) { return ("(" + ([math]::Round($bb[0],2)) + "," + ([math]::Round($bb[1],2)) + "," + ([math]::Round($bb[2],2)) + ")..(" + ([math]::Round($bb[3],2)) + "," + ([math]::Round($bb[4],2)) + "," + ([math]::Round($bb[5],2)) + ")") }

# ---------- element helpers ----------
function ElemProp($name, $prop) {
  $e = $lib.$name
  if ($e -eq $null) { throw "ELEMENT '$name' NOT IN LIBRARY ($libPath)" }
  return $e.$prop
}
# raw union bbox -> array
function ElemRaw($name) {
  $r = ElemProp $name 'raw'
  return ,(@([double]$r.x0, [double]$r.y0, [double]$r.z0, [double]$r.x1, [double]$r.y1, [double]$r.z1))
}

# self-correcting placement: insert, measure, move to expected-min, re-measure
function Place($ms, $tag, $elemName, $insX, $insY, $insZ, $sx, $sy, $sz, $rotDeg, $expMinX, $expMinY, $expMinZ) {
  $path = (([string](ElemProp $elemName 'dwg')) -replace '/', '\')
  if (-not (Test-Path -LiteralPath $path)) { $path = [System.IO.Path]::GetFullPath($path) }
  $rotRad = [double]($rotDeg * [math]::PI / 180.0)
  $ref = $null
  try {
    $ref = Retry { $ms.InsertBlock((Pt $insX $insY $insZ), $path, [double]$sx, [double]$sy, [double]$sz, [double]$rotRad) }
  } catch {
    RW ("FAIL " + $tag + " insert: " + $_.Exception.Message)
    return $null
  }
  $bb = BBoxOf $ref
  $dx = [double]$expMinX - $bb[0]; $dy = [double]$expMinY - $bb[1]; $dz = [double]$expMinZ - $bb[2]
  if ([math]::Abs($dx) -gt 0.001 -or [math]::Abs($dy) -gt 0.001 -or [math]::Abs($dz) -gt 0.001) {
    Retry { $ref.Move((Pt 0 0 0), (Pt $dx $dy $dz)) } | Out-Null
    $bb = BBoxOf $ref
    RW ("MOVE " + $tag + " by (" + [math]::Round($dx,3) + "," + [math]::Round($dy,3) + "," + [math]::Round($dz,3) + ")")
  }
  RW ("PLACE " + $tag + "  " + (FmtBb $bb))
  $script:placedBB[[string]$tag] = $bb
  return $ref
}

# ---------- COM ----------
$acad = $null
try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") } catch {
  for ($w=0; $w -lt 60; $w++) {
    try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application"); break } catch {}
    if ($w -eq 0) { try { Start-Process 'acad.exe' -WindowStyle Hidden } catch {} }
    Start-Sleep -Seconds 5
  }
}
if ($acad -eq $null) { RW "NO-COM"; $sw.Close(); Write-Host "NO-COM"; exit 1 }
$doc = Retry { $acad.Documents.Add() }
Start-Sleep -Seconds 3
Retry { $doc.SetVariable('INSUNITS', 4) } | Out-Null
$ms = $doc.ModelSpace
RW ("PLAN file: " + $Config)
$plan = @()
$placedBB = @{}

# world length of a line from config (same rules as lines block)
function LineLen($ln) {
  if ($ln.PSObject.Properties['pitch'] -and $ln.pitch) {
    $count = if ($ln.PSObject.Properties['count'] -and $ln.count) { [int]$ln.count } else { [int]([math]::Floor(([double]$ln.length) / [double]$ln.pitch + 0.5)) }
    return [double]$ln.pitch * $count
  }
  return [double]$ln.length
}

# ---------- auto-anchor receiving lines to their drops ----------
# receiving line end MUST meet the gorka exit face; receiving axis MUST sit on
# the descent axis (upper.y + gorka_line_dy). Config x_start/y for a line that
# is a drop target are corrected here (with a warning), so the joined geometry
# does not depend on hand-placed values in the config.
foreach ($d in $cfg.drops) {
  $upLn = $null; $loLn = $null
  foreach ($ln2 in $cfg.lines) {
    if ([string]$ln2.id -eq [string]$d.upper) { $upLn = $ln2 }
    if ([string]$ln2.id -eq [string]$d.lower) { $loLn = $ln2 }
  }
  if ($upLn -eq $null -or $loLn -eq $null) { RW ("ANCHOR-SKIP " + $d.upper + "->" + $d.lower + " (line id not found)"); continue }
  $run = [double](ElemProp ([string]$d.gorka) 'raw_run')
  $dyD = 0.0
  if ($d.PSObject.Properties['transfer'] -and $d.transfer) { $dyD = [double](ElemProp ([string]$d.transfer) 'gorka_line_dy') }
  $upXs = [double]$upLn.x_start
  $upYv = [double]$upLn.y
  $upLen = LineLen $upLn
  $loLen = LineLen $loLn
  if ([string]$d.side -eq 'east') {
    # east drop (rot=0): gorka exit face at upper.xe - run, mirrored dy
    $newY = $upYv + $dyD
    $recvX = $upXs + $upLen - $run
    $newXs = $recvX - $loLen   # receiving EAST end = gorka exit face
  } else {
    $newY = $upYv - $dyD
    $recvX = $upXs + $run
    $newXs = $recvX            # receiving WEST end = gorka exit face
  }
  $dxs = $newXs - [double]$loLn.x_start
  $dyv = $newY - [double]$loLn.y
  if ([math]::Abs($dxs) -gt 0.0005 -or [math]::Abs($dyv) -gt 0.0005) {
    RW ("ANCHOR " + $loLn.id + ": x_start " + [double]$loLn.x_start + " -> " + [math]::Round($newXs,3) + " (d=" + [math]::Round($dxs,3) + "), y " + [double]$loLn.y + " -> " + [math]::Round($newY,3) + " (d=" + [math]::Round($dyv,3) + ")")
    $loLn.x_start = $newXs
    $loLn.y = $newY
  } else {
    RW ("ANCHOR-OK " + $loLn.id)
  }
}

# ---------- lines (sections) ----------
$lineMap = @{}
foreach ($ln in $cfg.lines) {
  $lineMap[$ln.id] = $ln
  $elem = [string]$ln.element
  $raw = ElemRaw $elem
  $rawLen = [double]$raw[3] - [double]$raw[0]
  $halfBand = ($raw[4] - $raw[1]) / 2.0
  $datumZ = [double](ElemProp $elem 'datum_z')
  $z0w = [double]$ln.z + (($raw[2]) - $datumZ)      # strip bottom world
  $xs = [double]$ln.x_start
  $yc = [double]$ln.y
  if ($ln.PSObject.Properties['pitch'] -and $ln.pitch) {
    $pitch = [double]$ln.pitch
    $count = if ($ln.PSObject.Properties['count'] -and $ln.count) { [int]$ln.count } else { [int]([math]::Floor(([double]$ln.length) / $pitch + 0.5)) }
  } else {
    # by length: choose count = round(length/rawLen), pitch = length/count
    $count = [int]([math]::Round(([double]$ln.length) / $rawLen))
    if ($count -lt 1) { $count = 1 }
    $pitch = ([double]$ln.length) / $count
  }
  $sx = $pitch / $rawLen
  RW ("LINE " + $ln.id + " z=" + $ln.z + " y=" + $yc + " x=" + $xs + ".." + ($xs + $pitch*$count) + "  elem=" + $elem + " n=" + $count + " pitch=" + $pitch + " scaleX=" + $sx)
  for ($j=0; $j -lt $count; $j++) {
    $x0t = $xs + $j*$pitch
    $insX = $x0t - $sx*[double]$raw[0]
    $insY = $yc - [double]$raw[1] - $halfBand
    $insZ = [double]$ln.z - $datumZ
    $null = Place $ms ("line:" + $ln.id + ":" + $j) $elem $insX $insY $insZ $sx 1.0 1.0 0.0 $x0t ($yc - $halfBand) $z0w
  }
  $lineMap[$ln.id] = @{ z = [double]$ln.z; y = $yc; xs = $xs; xe = ($xs + $pitch*$count); elem = $elem }
}

# ---------- drops (gorka + transfer, rigid pair) ----------
# fz is computed PER DROP (below): gorka union top -> transfer table plane
# (belt top - table offset), exit leg U647 bottom -> lower floor plane.
$gap = 3000.0
if ($cfg.PSObject.Properties['floor_gap'] -and $cfg.floor_gap) { $gap = [double]$cfg.floor_gap }

foreach ($d in $cfg.drops) {
  $up = $lineMap[[string]$d.upper]
  $low = $lineMap[[string]$d.lower]
  $side = [string]$d.side
  $gorka = [string]$d.gorka
  $gorRaw = ElemRaw $gorka
  $entryFace = [double](ElemProp $gorka 'entry_face_x')
  $run = [double](ElemProp $gorka 'raw_run')
  $stripYc = [double](ElemProp $gorka 'strip_y_center')
  $exitPlane = [double](ElemProp $gorka 'exit_plane_z')
  $yHalfTop = [double](ElemProp ([string]$up.elem) 'band_half')
  $hasTransfer = $false
  $dyDev = 0.0
  if ($d.PSObject.Properties['transfer'] -and $d.transfer) {
    $hasTransfer = $true
    $dyDev = [double](ElemProp ([string]$d.transfer) 'gorka_line_dy')
  }

  # --- gorka Z datum (matches user's reference scene "Общий чертеж") ---
  # gorka union TOP (slide entry surface, raw entry_top_raw) sits flush with the
  # transfer TABLE plane = belt top - (adapter_topz_raw - table_plane_raw) [= -8.643];
  # exit leg U647 bottom (exit_plane_z) stands on the lower floor plane.
  $secRawG = ElemRaw ([string]$up.elem)
  $secDatumZG = [double](ElemProp ([string]$up.elem) 'datum_z')
  $beltTopG = [double]$up.z + ([double]$secRawG[5] - $secDatumZG)
  if ($hasTransfer) {
    $tableDrop = [double](ElemProp ([string]$d.transfer) 'adapter_topz_raw') - [double](ElemProp ([string]$d.transfer) 'table_plane_raw')
    $targetTop = $beltTopG - $tableDrop
    $span = [double](ElemProp $gorka 'raw_span_entry_top_exit')
    $fz = ($targetTop - [double]$low.z) / $span
  } else {
    # no transfer: legacy datum (entry leg on upper floor, exit leg on lower floor)
    $fz = ([double]$up.z - [double]$low.z) / ([double]$entryPlane - [double]$exitPlane)
  }
  $insGZ = [double]$low.z - $fz*$exitPlane
  $expMinZ = $insGZ + $fz*$gorRaw[2]

  if ($side -eq 'east') {
    $Xend = $up.xe
    $rotDeg = 0.0
    $lowerY = [double]$up.y + $dyDev           # rot=0: device keeps internal -dy
    $gYc = $lowerY                             # strip center = receiving line axis
    $insGX = $Xend - $entryFace
    $expMinX = $Xend - $run
    $expMinY = $gYc - ($stripYc - $gorRaw[1])   # union y0 below strip center
  } else {
    $Xend = $up.xs
    $rotDeg = 180.0
    $lowerY = [double]$up.y - $dyDev           # rot=180: mirrored device, dy flips
    $gYc = $lowerY                             # strip center = receiving line axis
    $insGX = $Xend + $entryFace
    $expMinX = $Xend
    $expMinY = $gYc - ([double]$gorRaw[4] - $stripYc)   # rot=180: y0 mirrored to the other side
  }
  $insGY = $gYc - $stripYc
  RW ("DROP " + $d.upper + "->" + $d.lower + " side=" + $side + " rot=" + $rotDeg + " fz=" + $fz + " lowerY=" + $lowerY)
  $null = Place $ms ("gorka:" + $d.upper + "->" + $d.lower) $gorka $insGX $insGY $insGZ 1.0 1.0 $fz $rotDeg $expMinX $expMinY $expMinZ

  if ($hasTransfer) {
    $trf = [string]$d.transfer
    $trfRaw = ElemRaw $trf
    $tuck = [double](ElemProp $trf 'tuck')
    $adpTopZ = [double](ElemProp $trf 'adapter_topz_raw')
    $secRaw = ElemRaw ([string]$up.elem)
    $secDatumZ = [double](ElemProp ([string]$up.elem) 'datum_z')
    $beltTop = [double]$up.z + ([double]$secRaw[5] - $secDatumZ)   # belt top = plane + 104.5
    $insTZ = $beltTop - $adpTopZ
    if ($side -eq 'east') {
      $adpMinX = [double](ElemProp $trf 'adapter_minx_raw')
      $insTX = $Xend - $tuck - $adpMinX
      $insTY = [double]$up.y - 80542.275
      $expTX = $Xend - $tuck
      $expTY = $insTY + $trfRaw[1]
    } else {
      $adpMaxX = [double](ElemProp $trf 'adapter_maxx_raw')
      $insTX = $Xend + $tuck + $adpMaxX
      $insTY = [double]$up.y + 80542.275
      $expTX = $insTX - $trfRaw[3]
      $expTY = $insTY - $trfRaw[4]
    }
    $expTZ = $insTZ + $trfRaw[2]
    $null = Place $ms ("transfer:" + $d.upper) $trf $insTX $insTY $insTZ 1.0 1.0 1.0 $rotDeg $expTX $expTY $expTZ
  }
}# ---------- extras ----------
if ($cfg.PSObject.Properties['extras'] -and $cfg.extras) {
  foreach ($x in $cfg.extras) {
    $path = [string](ElemProp ([string]$x.element) 'dwg')
    $rotRad = 0.0
    if ($x.PSObject.Properties['rot'] -and $x.rot -ne $null) { $rotRad = [double]$x.rot * [math]::PI / 180.0 }
    $ref = Retry { $ms.InsertBlock((Pt ([double]$x.ins[0]) ([double]$x.ins[1]) ([double]$x.ins[2])), $path, 1.0, 1.0, 1.0, [double]$rotRad) }
    if ($x.PSObject.Properties['expected_min'] -and $x.expected_min -ne $null) {
      $bb = BBoxOf $ref
      $dx = [double]$x.expected_min[0] - $bb[0]; $dy = [double]$x.expected_min[1] - $bb[1]; $dz = [double]$x.expected_min[2] - $bb[2]
      if ([math]::Abs($dx) -gt 0.001 -or [math]::Abs($dy) -gt 0.001 -or [math]::Abs($dz) -gt 0.001) {
        Retry { $ref.Move((Pt 0 0 0), (Pt $dx $dy $dz)) } | Out-Null
        RW ("MOVE extra:" + $x.element + " by (" + [math]::Round($dx,3) + "," + [math]::Round($dy,3) + "," + [math]::Round($dz,3) + ")")
      }
    }
    RW ("PLACE extra:" + $x.element + "  " + (FmtBb (BBoxOf $ref)))
  }
}

# ---------- verify ----------
$cnt = [int](Retry { [int]$ms.Count })
RW ("MODELSPACE COUNT: " + $cnt)

# JOIN checks: gorka exit face must coincide with the receiving line end,
# and the descent axis with the receiving line axis (delta should be ~0).
foreach ($d in $cfg.drops) {
  $gk = "gorka:" + $d.upper + "->" + $d.lower
  if (-not $placedBB.ContainsKey($gk)) { continue }
  $bb = $placedBB[$gk]
  $lo = $lineMap[[string]$d.lower]
  $gorRaw2 = ElemRaw ([string]$d.gorka)
  $stripYc2 = [double](ElemProp ([string]$d.gorka) 'strip_y_center')
  if ([string]$d.side -eq 'east') {
    $exitX = $bb[0]; $recvX = $lo.xe
    $stripC = $bb[1] + ($stripYc2 - $gorRaw2[1])
  } else {
    $exitX = $bb[3]; $recvX = $lo.xs
    $stripC = $bb[4] - ($gorRaw2[4] - $stripYc2)
  }
  RW ("JOIN " + $d.upper + "->" + $d.lower + ": exit_x=" + [math]::Round($exitX,2) + " recv_x=" + [math]::Round($recvX,2) + " dx=" + [math]::Round($exitX-$recvX,3) + " ; strip_y=" + [math]::Round($stripC,2) + " line_y=" + [math]::Round($lo.y,2) + " dy=" + [math]::Round($stripC-$lo.y,3))
  # gorka entry top must sit on the transfer table plane (belt top - tableDrop)
  $upL3 = $lineMap[[string]$d.upper]
  $secR3 = ElemRaw $upL3.elem
  $belt3 = [double]$upL3.z + ([double]$secR3[5] - [double](ElemProp $upL3.elem 'datum_z'))
  $tblDrop = 8.643
  if ($d.PSObject.Properties['transfer'] -and $d.transfer) {
    $tblDrop = [double](ElemProp ([string]$d.transfer) 'adapter_topz_raw') - [double](ElemProp ([string]$d.transfer) 'table_plane_raw')
  }
  $tblZ = $belt3 - $tblDrop
  RW ("JOIN " + $d.upper + " top: gorka_top_z=" + [math]::Round($bb[5],2) + " table_z=" + [math]::Round($tblZ,2) + " dz=" + [math]::Round($bb[5]-$tblZ,3))
  $tk = "transfer:" + $d.upper
  if ($placedBB.ContainsKey($tk)) {
    $tb = $placedBB[$tk]
    $upL = $lineMap[[string]$d.upper]
    $tuckV = [double](ElemProp ([string]$d.transfer) 'tuck')
    # adapter side must end at (line end -/+ tuck); far side overhang (~851.8) is normal
    if ([string]$d.side -eq 'east') {
      $joinD = $tb[0] - ($upL.xe - $tuckV); $farOv = $tb[3] - $upL.xe
    } else {
      $joinD = ($upL.xs + $tuckV) - $tb[3]; $farOv = $upL.xs - $tb[0]
    }
    RW ("JOIN transfer:" + $d.upper + " adapter_join_dx=" + [math]::Round($joinD,3) + " (must be ~0; tuck=" + $tuckV + ") far_overhang=" + [math]::Round($farOv,3) + " (norm ~851.8)")
  }
}
$gmin = @(1e30,1e30,1e30); $gmax = @(-1e30,-1e30,-1e30)
foreach ($e in $ms) {
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  $nm = Retry { $e.Name }
  $bb = BBoxOf $e
  RW ("CHECK '" + $nm + "'  " + (FmtBb $bb))
  for ($i=0; $i -lt 3; $i++) { if ($bb[$i] -lt $gmin[$i]) { $gmin[$i]=$bb[$i] }; if ($bb[3+$i] -gt $gmax[$i]) { $gmax[$i]=$bb[3+$i] } }
}
RW ("UNION: (" + [math]::Round($gmin[0],1) + "," + [math]::Round($gmin[1],1) + "," + [math]::Round($gmin[2],1) + ") .. (" + [math]::Round($gmax[0],1) + "," + [math]::Round($gmax[1],1) + "," + [math]::Round($gmax[2],1) + ")")

try { Retry { $doc.SaveAs($outDwg) }; RW ("SAVED-DWG " + $outDwg) } catch { RW ("SAVE-DWG-ERR: " + $_.Exception.Message) }
try { Retry { $doc.Close($false) } } catch {}
$sw.Close()

if ($outDxf) {
  Push-Location $rptDir
  & "$rptDir\dwg2dxf.exe" -v0 --as r2004 $outDwg 2>&1 | Out-Null
  Move-Item -Force (Join-Path $rptDir ([System.IO.Path]::GetFileName($outDxf))) $outDxf
  Pop-Location
  Write-Host ("DXF-OUT " + $outDxf)
}
Write-Host "BUILD-DONE -> $RPT"