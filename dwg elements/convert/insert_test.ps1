$ErrorActionPreference = 'Continue'
$SEC_DWG = 'C:\RobBox\ai\project\dwg elements\convert\section.dwg'
$acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application")
$doc = $acad.Documents.Item($acad.Documents.Count - 1)   # last (new) document
$ms = $doc.ModelSpace
Write-Host ("DOC: " + $doc.Name + " MS-count: " + $ms.Count)

# variant 1: double[]
$pt = New-Object 'double[]' 3; $pt[0]=0; $pt[1]=0; $pt[2]=0
try { $b = $ms.InsertBlock($pt, $SEC_DWG, 1.0, 1.0, 1.0, 0.0); Write-Host ("V1-OK " + $b.Name) } catch { Write-Host ("V1-FAIL: " + $_.Exception.GetType().FullName + " :: " + $_.Exception.Message) }

# variant 2: object[] of doubles
$pt2 = @([double]100, [double]0, [double]0)
try { $b = $ms.InsertBlock($pt2, $SEC_DWG, 1.0, 1.0, 1.0, 0.0); Write-Host ("V2-OK " + $b.Name) } catch { Write-Host ("V2-FAIL: " + $_.Exception.GetType().FullName + " :: " + $_.Exception.Message) }

# variant 3: scale 1 as int? rot as int?
try { $pt3 = [double[]]@(200,0,0); $b = $ms.InsertBlock($pt3, $SEC_DWG, $true, $true, $true, 0); Write-Host ("V3-OK") } catch { Write-Host ("V3-FAIL: " + $_.Exception.Message) }