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
try { Retry { $doc.SaveAs($DXF, 64) }; Write-Host "DXF-OK-64" }
catch {
  Write-Host ("ERR-64: " + $_.Exception.Message)
  try { Retry { $doc.SaveAs($DXF, 1) }; Write-Host "DXF-OK-R12" } catch { Write-Host ("ERR-R12: " + $_.Exception.Message) }
}
Retry { $doc.Close($false) }
Remove-Item 'C:\RobBox\ai\project\konveyer.dxf.dwg' -ErrorAction SilentlyContinue
Write-Host "SAVE-DXF-DONE"