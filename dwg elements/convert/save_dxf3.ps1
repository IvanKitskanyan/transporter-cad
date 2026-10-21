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
Retry { $doc.SetVariable('FILEDIA', 0) } | Out-Null
Start-Sleep -Milliseconds 500
try { Retry { $doc.SendCommand("_FILEDIA`n0`n_SAVEAS`nDXF`n2018`n$DXF`n") } } catch { Write-Host ("ERR-CMD: " + $_.Exception.Message) }
Start-Sleep -Seconds 30
Retry { $doc.SetVariable('FILEDIA', 1) } | Out-Null
Retry { $doc.Close($false) }
Write-Host "SAVE-DXF3-DONE"
