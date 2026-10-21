$ErrorActionPreference = 'Continue'
$RPT = 'C:\RobBox\ai\project\dwg elements\convert\bbox_transfer.txt'
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
$doc = Retry { $acad.Documents.Open('C:\RobBox\ai\project\dwg elements\convert\transfer.dwg', $true) }
Start-Sleep -Seconds 2
$ms = $doc.ModelSpace
$cnt = Retry { $ms.Count }
RW ("COM-OK")
RW ("MODELSPACE COUNT: " + $cnt)
for ($i=0; $i -lt $cnt; $i++) {
  $e = Retry { $ms.Item($i) }
  $on = Retry { $e.ObjectName }
  $nm = ''
  $ip0 = ''
  if ($on -eq 'AcDbBlockReference') {
    $nm = Retry { $e.Name }
    try { $ip = Retry { $e.InsertionPoint }; $ip0 = (" ins=(" + [math]::Round($ip[0],2) + "," + [math]::Round($ip[1],2) + "," + [math]::Round($ip[2],2) + ")") } catch {}
  }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  $sz = ("  SIZE: dX=" + [math]::Round($bb[3]-$bb[0],3) + " dY=" + [math]::Round($bb[4]-$bb[1],3) + " dZ=" + [math]::Round($bb[5]-$bb[2],3))
  RW ("INSERT '" + $nm + "'" + $ip0 + "  BBOX: (" + [math]::Round($bb[0],3) + "," + [math]::Round($bb[1],3) + "," + [math]::Round($bb[2],3) + ") .. (" + [math]::Round($bb[3],3) + "," + [math]::Round($bb[4],3) + "," + [math]::Round($bb[5],3) +")" + $sz)
}
Retry { $doc.Close($false) }
$sw.Close()
Write-Host "PROBE-T-DONE"