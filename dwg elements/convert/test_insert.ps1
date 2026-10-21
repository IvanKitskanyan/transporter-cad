$ErrorActionPreference = 'Continue'
$acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application")
$doc = $acad.Documents.Add()
Start-Sleep -Seconds 3
$ms = $doc.ModelSpace
function Pt([double]$x, [double]$y, [double]$z) { return ,([double[]]@($x,$y,$z)) }
# A: forward slashes (как в elements.json)
try { $r = $ms.InsertBlock((Pt 0 0 0), 'C:/RobBox/ai/project/dwg elements/секция горизонтальная.dwg', 1.0,1.0,1.0, 0.0); Write-Host ("A-FWD-OK " + $r.Name) } catch { Write-Host ("A-FWD-FAIL: " + $_.Exception.Message) }
# B: backslashes
try { $r = $ms.InsertBlock((Pt 20000 0 0), 'C:\RobBox\ai\project\dwg elements\секция горизонтальная.dwg', 1.0,1.0,1.0, 0.0); Write-Host ("B-BACK-OK " + $r.Name) } catch { Write-Host ("B-BACK-FAIL: " + $_.Exception.Message) }
$doc.Close($false)
