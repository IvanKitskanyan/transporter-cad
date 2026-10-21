$ErrorActionPreference = 'Continue'
$DWG = 'C:\RobBox\ai\project\konveyer.dwg'
$RPT = 'C:\RobBox\ai\project\dwg elements\convert\adjust_gorka_report.txt'
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

# --- target geometry (upper plane 3000, lower 0) ---
$beltTop   = 3000 + 104.5          # 3104.5
$tableDrop = 8760.272 - 8751.629   # 8.643 (transfer platforms top -> table plane)
$targetTop = $beltTop - $tableDrop # gorka union top target
$entryRaw  = 2956.847              # gorka union top (raw)
$exitRaw   = -385.328              # U647 bottom (raw) -> lower floor 0
$z0raw     = -564.755              # gorka union min (raw)
$span      = $entryRaw - $exitRaw  # 3342.175
$fzNew     = ($targetTop - 0.0) / $span
$insZ      = 0.0 - $fzNew*$exitRaw
$tgtZ0     = $insZ + $fzNew*$z0raw
$tgtX0     = 39310.404             # union min x (entry face 50000 - run 10689.596)
$tgtY0     = -1536.761             # union min y (strip center -1083.761 - 453)
RW ("fz new=" + [math]::Round($fzNew,6) + " target top=" + [math]::Round($targetTop,3) + " tgt bbox min=(" + [math]::Round($tgtX0,3) + "," + [math]::Round($tgtY0,3) + "," + [math]::Round($tgtZ0,3) + ")")

$acad = Retry { [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") }
$doc = $null
$ndoc = Retry { $acad.Documents.Count }
for ($i=0; $i -lt $ndoc; $i++) {
  $dc = Retry { $acad.Documents.Item($i) }
  $fn = Retry { $dc.FullName }
  RW ("OPEN-DOC " + $fn + (Retry { if ($dc.ReadOnly) { " [READONLY]" } else { "" } }))
  if ($fn -ieq $DWG) { $doc = $dc }
}
if ($doc -eq $null) { $doc = Retry { $acad.Documents.Open($DWG, $false) }; Start-Sleep -Seconds 5 }
try { Retry { $doc.Activate() } } catch {}
$ms = Retry { $doc.ModelSpace }
$cnt = Retry { $ms.Count }

$gk = $null
for ($i=0; $i -lt $cnt; $i++) {
  $e = Retry { $ms.Item($i) }
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  if ((Retry { $e.Name }) -eq 'gorka') { $gk = $e; break }
}
if ($gk -eq $null) { RW "NO-GORKA"; $sw.Close(); Write-Host "NO-GORKA"; exit 1 }

$bb = Retry { $mn=$null; $mx=$null; $gk.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
RW ("BEFORE gorka (" + [math]::Round($bb[0],3) + "," + [math]::Round($bb[1],3) + "," + [math]::Round($bb[2],3) + ")..(" + [math]::Round($bb[3],3) + "," + [math]::Round($bb[4],3) + "," + [math]::Round($bb[5],3) + ") zscale=" + [math]::Round((Retry { $gk.ZScaleFactor }),4))

Retry { $gk.ZScaleFactor = [double]$fzNew } | Out-Null
$bb = Retry { $mn=$null; $mx=$null; $gk.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
$dx = $tgtX0 - $bb[0]; $dy = $tgtY0 - $bb[1]; $dz = $tgtZ0 - $bb[2]
RW ("MOVE gorka by (" + [math]::Round($dx,3) + "," + [math]::Round($dy,3) + "," + [math]::Round($dz,3) + ")")
if ([math]::Abs($dx) -gt 0.001 -or [math]::Abs($dy) -gt 0.001 -or [math]::Abs($dz) -gt 0.001) {
  Retry { $gk.Move((Pt 0 0 0), (Pt $dx $dy $dz)) } | Out-Null
}
$bb = Retry { $mn=$null; $mx=$null; $gk.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
RW ("AFTER  gorka (" + [math]::Round($bb[0],3) + "," + [math]::Round($bb[1],3) + "," + [math]::Round($bb[2],3) + ")..(" + [math]::Round($bb[3],3) + "," + [math]::Round($bb[4],3) + "," + [math]::Round($bb[5],3) + ")")

try { Retry { $doc.Save() }; RW "SAVED doc.Save()" } catch { RW ("SAVE-ERR: " + $_.Exception.Message) }
$sw.Close()
Write-Host "ADJUST-DONE -> $RPT"
