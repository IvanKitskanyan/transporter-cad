$ErrorActionPreference = 'Continue'
$DWG = 'C:\RobBox\ai\project\konveyer.dwg'
$RPT = 'C:\RobBox\ai\project\dwg elements\convert\fix_transfer.txt'
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
$acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application")
$doc = Retry { $acad.Documents.Open($DWG, $true) }
Start-Sleep -Seconds 2
try { $ib = $doc.GetVariable('INSBASE'); RW ("INSBASE dwg konveyer: " + $ib[0] + "," + $ib[1] + "," + $ib[2]) } catch { RW ("no INSBASE: " + $_.Exception.Message) }
$ms = $doc.ModelSpace
$cnt = Retry { $ms.Count }
RW ("MS COUNT: " + $cnt)
for ($i=0; $i -lt $cnt; $i++) {
  $e = Retry { $ms.Item($i) }
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  $nm = Retry { $e.Name }
  if ($nm -ne 'transfer') { continue }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  RW ("BEFORE: bbox (" + [math]::Round($bb[0],3) + "," + [math]::Round($bb[1],3) + "," + [math]::Round($bb[2],3) + ") .. (" + [math]::Round($bb[3],3) + "," + [math]::Round($bb[4],3) + "," + [math]::Round($bb[5],3) + ")")
  # observed placement came out shifted; required world: adapters top=3104.5, min-x=49946.767, min-y=-352.5
  $dx = 49946.767 - $bb[0]
  $dy = 0.0
  $dz = 2827.332 - $bb[2]
  Retry { $e.Move((Pt 0 0 0), (Pt $dx $dy $dz)) } | Out-Null
  $bb2 = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  RW ("AFTER:  bbox (" + [math]::Round($bb2[0],3) + "," + [math]::Round($bb2[1],3) + "," + [math]::Round($bb2[2],3) + ") .. (" + [math]::Round($bb2[3],3) + "," + [math]::Round($bb2[4],3) + "," + [math]::Round($bb2[5],3) + ")  dxdz=($dx,$dz)")
}
Retry { $doc.SaveAs($DWG) }
RW ("SAVED-DWG " + $DWG)
Retry { $doc.Close($false) }
$sw.Close()
Write-Host "FIX-DONE"
