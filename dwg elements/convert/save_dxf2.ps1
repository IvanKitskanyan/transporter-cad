$ErrorActionPreference = 'Continue'
$DWG = 'C:\RobBox\ai\project\konveyer.dwg'
$DXF = 'C:\RobBox\ai\project\konveyer.dxf'
function Retry([scriptblock]$sb, [int]$tries = 600) {
  for ($t=0; $t -lt $tries; $t++) {
    try { $r = & $sb; return $r } catch {
      if ($_.Exception.HResult -eq -2147418111 -or $_.Exception.Message -match 'RPC_E_CALL_REJECTED|0x80010001') { Start-Sleep -Milliseconds 500 } else { throw }
    }
  }
  throw "RETRIES-EXHAUSTED"
}
$acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application")
$doc = Retry { $acad.Documents.Open($DWG, $true) }
Start-Sleep -Seconds 2
$ok = $false
try { $res = Retry { $doc.SaveAs($DXF) }; Write-Host ("SAVED-PLAIN res=" + $res); $ok = $true } catch { Write-Host ("ERR-PLAIN: " + $_.Exception.Message) }
if (-not $ok) {
  try { Retry { $doc.SetVariable('FILEDIA', 0) } | Out-Null; Start-Sleep -Milliseconds 500
        Retry { $doc.SendCommand("_FILEDIA`n0`n_SAVEAS`nDXF`n2018`n$DXF`n") }
        Start-Sleep -Seconds 25
        Retry { $doc.SetVariable('FILEDIA', 1) } | Out-Null
        Write-Host "SAVED-CMD" } catch { Write-Host ("ERR-CMD: " + $_.Exception.Message) }
}
Retry { $doc.Close($false) }
Write-Host "SAVE-DXF2-DONE"
