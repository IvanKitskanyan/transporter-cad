$ErrorActionPreference = 'Continue'
$RPT = 'C:\RobBox\ai\project\dwg elements\convert\bbox_general_cur.txt'
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
$acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application")
$doc = Retry { $acad.Documents.Open('C:\RobBox\ai\project\dwg elements\convert\general_cur.dwg', $true) }
Start-Sleep -Seconds 2
$ms = $doc.ModelSpace
$cnt = Retry { $ms.Count }
RW ("COM-OK  MODELSPACE COUNT: " + $cnt)
for ($i=0; $i -lt $cnt; $i++) {
  $e = Retry { $ms.Item($i) }
  $on = Retry { $e.ObjectName }
  $nm = ''
  $extra = ''
  if ($on -eq 'AcDbBlockReference') {
    $nm = Retry { $e.Name }
    try { $ip = Retry { $e.InsertionPoint }; $extra = " ins=(" + [math]::Round($ip[0],2) + "," + [math]::Round($ip[1],2) + "," + [math]::Round($ip[2],2) + ")" } catch {}
    try { $extra += " rot=" + [math]::Round((Retry { $e.Rotation }),2) + " s=(" + [math]::Round((Retry { $e.XScaleFactor }),3) + "," + [math]::Round((Retry { $e.YScaleFactor }),3) + "," + [math]::Round((Retry { $e.ZScaleFactor }),3) + ")" } catch {}
  }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  $sz = ("  d=(" + [math]::Round($bb[3]-$bb[0],2) + "," + [math]::Round($bb[4]-$bb[1],2) + "," + [math]::Round($bb[5]-$bb[2],2) + ")")
  RW ("[" + $i + "] " + $on + " '" + $nm + "'" + $extra + "  BBOX (" + [math]::Round($bb[0],2) + "," + [math]::Round($bb[1],2) + "," + [math]::Round($bb[2],2) + ") .. (" + [math]::Round($bb[3],2) + "," + [math]::Round($bb[4],2) + "," + [math]::Round($bb[5],2) + ")" + $sz)
}
Retry { $doc.Close($false) }
$sw.Close()
Write-Host "PROBE-G-DONE"
