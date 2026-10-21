$ErrorActionPreference = 'Continue'
$DWG = 'C:\RobBox\ai\project\konveyer.dwg'
$RPT = 'C:\RobBox\ai\project\dwg elements\convert\attach_transfer_report.txt'
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

$acad = Retry { [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") }
$doc = $null
$ndoc = Retry { $acad.Documents.Count }
for ($i=0; $i -lt $ndoc; $i++) {
  $dc = Retry { $acad.Documents.Item($i) }
  $fn = Retry { $dc.FullName }
  RW ("OPEN-DOC " + $fn + (Retry { if ($dc.ReadOnly) { " [READONLY]" } else { "" } }))
  if ($fn -ieq $DWG) { $doc = $dc }
}
if ($doc -eq $null) {
  RW ("doc not open in session, opening: " + $DWG)
  $doc = Retry { $acad.Documents.Open($DWG, $false) }
  Start-Sleep -Seconds 5
}
try { Retry { $doc.Activate() } } catch {}
$ms = Retry { $doc.ModelSpace }
$cnt = Retry { $ms.Count }
RW ("MS COUNT: " + $cnt)

$trRef = $null
for ($i=0; $i -lt $cnt; $i++) {
  $e = Retry { $ms.Item($i) }
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  $nm = Retry { $e.Name }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  RW ("STATE '" + $nm + "' (" + [math]::Round($bb[0],2) + "," + [math]::Round($bb[1],2) + "," + [math]::Round($bb[2],2) + ")..(" + [math]::Round($bb[3],2) + "," + [math]::Round($bb[4],2) + "," + [math]::Round($bb[5],2) + ")")
  if ($nm -eq 'transfer') { $trRef = $e }
}
if ($trRef -eq $null) { RW "NO-TRANSFER-FOUND"; $sw.Close(); Write-Host "NO-TRANSFER"; exit 1 }

$bb = Retry { $mn=$null; $mx=$null; $trRef.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
# required world position (reference scene): adapter min-x tucked 53.232 under line end (50000),
# section band min-y = -352.5 (upper line axis y=0), adapter top at belt top 3104.5 -> union min-z 2827.332
$tgtX = 49946.768; $tgtY = -1443.5; $tgtZ = 2827.332
$dx = $tgtX - $bb[0]; $dy = $tgtY - $bb[1]; $dz = $tgtZ - $bb[2]
RW ("MOVE transfer by (" + [math]::Round($dx,3) + "," + [math]::Round($dy,3) + "," + [math]::Round($dz,3) + ")")
if ([math]::Abs($dx) -gt 0.001 -or [math]::Abs($dy) -gt 0.001 -or [math]::Abs($dz) -gt 0.001) {
  Retry { $trRef.Move((Pt 0 0 0), (Pt $dx $dy $dz)) } | Out-Null
}
$bb2 = Retry { $mn=$null; $mx=$null; $trRef.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
RW ("AFTER transfer (" + [math]::Round($bb2[0],3) + "," + [math]::Round($bb2[1],3) + "," + [math]::Round($bb2[2],3) + ")..(" + [math]::Round($bb2[3],3) + "," + [math]::Round($bb2[4],3) + "," + [math]::Round($bb2[5],3) + ")")

try {
  Retry { $doc.Save() }
  RW "SAVED doc.Save()"
} catch {
  RW ("SAVE-ERR doc.Save(): " + $_.Exception.Message + " -- trying SaveAs new name")
  try { Retry { $doc.SaveAs('C:\RobBox\ai\project\konveyer_fixed.dwg') }; RW "SAVED konveyer_fixed.dwg" } catch { RW ("SAVEAS-ERR: " + $_.Exception.Message) }
}
$sw.Close()
Write-Host "ATTACH-DONE -> $RPT"
