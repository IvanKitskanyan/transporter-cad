$ErrorActionPreference = 'Continue'

$SEC_DWG = 'C:\RobBox\ai\project\dwg elements\convert\section.dwg'
$GOR_DWG = 'C:\RobBox\ai\project\dwg elements\convert\gorka.dwg'
$OUT_DWG = 'C:\RobBox\ai\project\dwg elements\convert\konveyer_dvig.dwg'
$OUT_DXF = 'C:\RobBox\ai\project\dwg elements\convert\konveyer_dvig.dxf'
$RPT     = 'C:\RobBox\ai\project\dwg elements\convert\build_report.txt'

$sw = New-Object System.IO.StreamWriter($RPT, $false, (New-Object System.Text.UTF8Encoding($false)))
function RW($s) { $sw.WriteLine($s); $sw.Flush() }

function Retry([scriptblock]$sb, [int]$tries = 300) {
  for ($t=0; $t -lt $tries; $t++) {
    try { $r = & $sb; return $r } catch {
      if ($_.Exception.HResult -eq -2147418111 -or $_.Exception.Message -match 'RPC_E_CALL_REJECTED|0x80010001') { Start-Sleep -Milliseconds 500 } else { throw }
    }
  }
  throw "RETRIES-EXHAUSTED"
}
function Pt([double]$x, [double]$y, [double]$z) {
  $p = New-Object 'double[]' 3
  $p[0]=$x; $p[1]=$y; $p[2]=$z
  return ,$p
}

# ---- measured constants (COM probes) ----
$SEC_STRIP_MINX = 126736.509
$SEC_STRIP_LEN  = 11700.000
$SEC_YC         = 80542.275
$SEC_SENS_Z     = 8652.129
$GOR_ENTRY_X_MAX = 204259.154
$GOR_EXIT_X_MIN  = 193569.558
$GOR_YC          = 79408.264
$GOR_PLANE_UP    = 2700.492
$GOR_PLANE_LO    = -385.328

$FLOOR_GAP = 3000.0
$DROP = $GOR_PLANE_UP - $GOR_PLANE_LO
$fz = $FLOOR_GAP / $DROP

$N2 = 4; $N1 = 3
$P2 = 50000.0 / $N2
$P1 = 30000.0 / $N1
$s2 = $P2 / $SEC_STRIP_LEN
$s1 = $P1 / $SEC_STRIP_LEN

$CONV_END2  = $N2 * $P2
$GOR_X_INSR = $CONV_END2 + $GOR_ENTRY_X_MAX
$GOR_EXIT   = $GOR_X_INSR - $GOR_EXIT_X_MIN
$GOR_Y_INSR = $GOR_YC
$GOR_Z_INSR = $fz * (-$GOR_PLANE_LO)

$CONV_Y_INSR = -$SEC_YC
$CONV_Z_INSR = $FLOOR_GAP - $SEC_SENS_Z
$CONV1_Z_INSR = -$SEC_SENS_Z
$CONV2_X0 = -$s2 * $SEC_STRIP_MINX
$CONV1_X0 = $GOR_EXIT - $s1 * $SEC_STRIP_MINX

RW ("PLAN: floor2 N2=$N2 pitch=$P2 scaleX=$s2 ; gorka ins=($GOR_X_INSR,$GOR_Y_INSR,$GOR_Z_INSR) fz=$fz rot=180 ; floor1 N1=$N1 pitch=$P1 scaleX=$s1 from X=$GOR_EXIT")
RW ("expected: floor2 plane Z=3000 X=0..50000 ; gorka X=$CONV_END2..$GOR_EXIT drop 3000->0 ; floor1 plane Z=0 X=$GOR_EXIT..$($GOR_EXIT+30000)")

# ---- COM ----
$acad=$null
try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") } catch {
  $acad = Retry { New-Object -ComObject AutoCAD.Application }
}
$acad.Visible = $true
$doc = $acad.Documents.Add()
Start-Sleep -Seconds 3
Retry { $doc.SetVariable('INSUNITS', 4) } | Out-Null
$ms = $doc.ModelSpace

for ($j=0; $j -lt $N2; $j++) {
  $x = $CONV2_X0 + $j*$P2
  $null = Retry { $ms.InsertBlock((Pt $x $CONV_Y_INSR $CONV_Z_INSR), $SEC_DWG, [double]$s2, [double]1, [double]1, [double]0) }
RW ("INSERT floor2 unit $j at ($x , $CONV_Y_INSR , $CONV_Z_INSR) scaleX=$s2")
}

$null = Retry { $ms.InsertBlock((Pt $GOR_X_INSR $GOR_Y_INSR $GOR_Z_INSR), $GOR_DWG, [double]1, [double]1, [double]$fz, [double]3.14159265358979) }
RW ("INSERT gorka at ($GOR_X_INSR , $GOR_Y_INSR , $GOR_Z_INSR) fz=$fz rot=pi")

for ($k=0; $k -lt $N1; $k++) {
  $x = $CONV1_X0 + $k*$P1
  $null = Retry { $ms.InsertBlock((Pt $x $CONV_Y_INSR $CONV1_Z_INSR), $SEC_DWG, [double]$s1, [double]1, [double]1, [double]0) }
RW ("INSERT floor1 unit $k at ($x , $CONV_Y_INSR , $CONV1_Z_INSR) scaleX=$s1")
}

$cnt = Retry { $ms.Count }
RW ("MODELSPACE COUNT: $cnt")
$gmin = @(1e30,1e30,1e30); $gmax = @(-1e30,-1e30,-1e30)
foreach ($e in $ms) {
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  $name = Retry { $e.Name }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  $line = "   " + $name + "  bbox: (" + [math]::Round($bb[0],1) + " , " + [math]::Round($bb[1],1) + " , " + [math]::Round($bb[2],1) + ") .. (" + [math]::Round($bb[3],1) + " , " + [math]::Round($bb[4],1) + " , " + [math]::Round($bb[5],1) + ")"
  RW $line
  for ($i=0; $i -lt 3; $i++) { if ($bb[$i] -lt $gmin[$i]) { $gmin[$i]=$bb[$i] }; if ($bb[3+$i] -gt $gmax[$i]) { $gmax[$i]=$bb[3+$i] } }
}
$u = "UNION: (" + [math]::Round($gmin[0],1) + " , " + [math]::Round($gmin[1],1) + " , " + [math]::Round($gmin[2],1) + ") .. (" + [math]::Round($gmax[0],1) + " , " + [math]::Round($gmax[1],1) + " , " + [math]::Round($gmax[2],1) + ")"
RW $u
$null = (try { Retry { $doc.ZoomExtents() } } catch { RW ("ZOOM-ERR: " + $_.Exception.Message) })

$null = (try { Retry { $doc.SaveAs($OUT_DWG) } } catch { RW ("SAVEAS-DWG-ERR: " + $_.Exception.Message) })
RW ("SAVED " + $OUT_DWG)
Retry { $doc.SetVariable('FILEDIA', 0) } | Out-Null
Start-Sleep -Milliseconds 800
$null = (try { Retry { $doc.SendCommand("_SAVEAS`n2018`n$OUT_DXF`n") } } catch { RW ("SAVEAS-DXF-ERR: " + $_.Exception.Message) })
Start-Sleep -Seconds 15
Retry { $doc.SetVariable('FILEDIA', 1) } | Out-Null
RW ("SAVED " + $OUT_DXF)
$sw.Close()
Write-Host "BUILD-DONE"