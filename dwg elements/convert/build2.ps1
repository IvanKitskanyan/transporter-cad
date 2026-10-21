$ErrorActionPreference = 'Continue'

$SEC_DWG = 'C:\RobBox\ai\project\dwg elements\convert\section.dwg'   # = dwg elements\секция горизонтальная.dwg
$GOR_DWG = 'C:\RobBox\ai\project\dwg elements\convert\gorka.dwg'     # = dwg elements\горка.dwg
$OUT_DWG = 'C:\RobBox\ai\project\konveyer.dwg'
$OUT_DXF = 'C:\RobBox\ai\project\konveyer.dxf'
$RPT     = 'C:\RobBox\ai\project\dwg elements\convert\build2_report.txt'

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
function Pt([double]$x, [double]$y, [double]$z) {
  $p = New-Object 'double[]' 3
  $p[0]=$x; $p[1]=$y; $p[2]=$z
  return ,$p
}

# ---- measured constants (from dwg elements models, COM probes) ----
$SEC_STRIP_MINX = 126736.509
$SEC_STRIP_MAXX = 138436.500
$SEC_STRIP_LEN  = $SEC_STRIP_MAXX - $SEC_STRIP_MINX   # 11699.991
$SEC_YC         = 80542.275
$SEC_SENS_Z     = 8652.129            # datum: sensor-block bottoms -> floor plane
$GOR_ENTRY_XMAX = 204259.154          # strip high end (entry)
$GOR_EXIT_X     = 193569.558          # U647 left face (exit)
$GOR_STRIP_YC   = 79458.514
$GOR_UP_Z       = 2700.492            # U646 bottom (entry walk plane)
$GOR_LO_Z       = -385.328            # U647 bottom (exit walk plane)

$FLOOR_GAP = 3000.0
$DROP = $GOR_UP_Z - $GOR_LO_Z
$fz = $FLOOR_GAP / $DROP

$P2 = 12500.0; $N2 = 4      # floor2 pitch, count -> 50000
$P1 = 10000.0; $N1 = 3      # floor1 pitch, count -> 30000
$s2 = $P2 / $SEC_STRIP_LEN
$s1 = $P1 / $SEC_STRIP_LEN

$GOR_X_INSR = $N2 * $P2 - $GOR_ENTRY_XMAX
$GOR_EXIT_W = $GOR_X_INSR + $GOR_EXIT_X
$GOR_Y_INSR = -$GOR_STRIP_YC
$GOR_Z_INSR = $fz * (-$GOR_LO_Z)

$CONV_Y_INSR = -$SEC_YC
$CONV2_Z_INSR = $FLOOR_GAP - $SEC_SENS_Z
$CONV1_Z_INSR = -$SEC_SENS_Z
$CONV2_X0 = -$s2 * $SEC_STRIP_MINX
$CONV1_XB = $GOR_EXIT_W - $s1 * $SEC_STRIP_MAXX

RW ("PLAN: floor2 N2=$N2 pitch=$P2 scaleX=$s2 | gorka rot=0 ins=($GOR_X_INSR,$GOR_Y_INSR,$GOR_Z_INSR) fz=$fz | floor1 N1=$N1 pitch=$P1 scaleX=$s1")
RW ("expected: floor2 plane Z=3000, strips X=0..50000 ; gorka X=$GOR_EXIT_W..50000 drop 3000->0 ; floor1 plane Z=0, strips X=9310.4..$GOR_EXIT_W (under floor2)")

$acad = $null
try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") } catch {
  $acad = Retry { New-Object -ComObject AutoCAD.Application }
}
$acad.Visible = $false
$doc = Retry { $acad.Documents.Add() }
Start-Sleep -Seconds 3
Retry { $doc.SetVariable('INSUNITS', 4) } | Out-Null
$ms = $doc.ModelSpace

$iFails = 0
for ($j=0; $j -lt $N2; $j++) {
  $x = $CONV2_X0 + $j*$P2
  try { $null = Retry { $ms.InsertBlock((Pt $x $CONV_Y_INSR $CONV2_Z_INSR), $SEC_DWG, [double]$s2, [double]1, [double]1, [double]0) } }
  catch { $iFails++; RW ("FAIL floor2 unit $j : " + $_.Exception.Message); continue }
  RW ("INSERT floor2 unit $j at ($x , $CONV_Y_INSR , $CONV2_Z_INSR) s=($s2,1,1) rot=0")
}

try { $null = Retry { $ms.InsertBlock((Pt $GOR_X_INSR $GOR_Y_INSR $GOR_Z_INSR), $GOR_DWG, [double]1, [double]1, [double]$fz, [double]0) } }
catch { $iFails++; RW ("FAIL gorka : " + $_.Exception.Message) }
RW ("INSERT gorka at ($GOR_X_INSR , $GOR_Y_INSR , $GOR_Z_INSR) s=(1,1,$fz) rot=0")

for ($k=0; $k -lt $N1; $k++) {
  $x = $CONV1_XB - (2-$k)*$P1
  try { $null = Retry { $ms.InsertBlock((Pt $x $CONV_Y_INSR $CONV1_Z_INSR), $SEC_DWG, [double]$s1, [double]1, [double]1, [double]0) } }
  catch { $iFails++; RW ("FAIL floor1 unit $k : " + $_.Exception.Message); continue }
  RW ("INSERT floor1 unit $k at ($x , $CONV_Y_INSR , $CONV1_Z_INSR) s=($s1,1,1) rot=0")
}

$cnt = Retry { $ms.Count }
RW ("MODELSPACE COUNT: $cnt  INSERT-FAILS: $iFails")

# ---- verification: measure every block reference ----
$gmin = @(1e30,1e30,1e30); $gmax = @(-1e30,-1e30,-1e30)
foreach ($e in $ms) {
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  $nm = Retry { $e.Name }
  $ip = Retry { $e.InsertionPoint }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  RW ("CHECK '" + $nm + "' ins=(" + [math]::Round($ip[0],1) + "," + [math]::Round($ip[1],1) + "," + [math]::Round($ip[2],1) + ")  bbox (" + [math]::Round($bb[0],2) + "," + [math]::Round($bb[1],2) + "," + [math]::Round($bb[2],2) + ") .. (" + [math]::Round($bb[3],2) + "," + [math]::Round($bb[4],2) + "," + [math]::Round($bb[5],2) + ")")
  for ($i=0; $i -lt 3; $i++) { if ($bb[$i] -lt $gmin[$i]) { $gmin[$i]=$bb[$i] }; if ($bb[3+$i] -gt $gmax[$i]) { $gmax[$i]=$bb[3+$i] } }
}
RW ("UNION: (" + [math]::Round($gmin[0],1) + "," + [math]::Round($gmin[1],1) + "," + [math]::Round($gmin[2],1) + ") .. (" + [math]::Round($gmax[0],1) + "," + [math]::Round($gmax[1],1) + "," + [math]::Round($gmax[2],1) + ")")

# ---- save ----
$saveErr = ''
try { Retry { $doc.SaveAs($OUT_DWG) } ; RW ("SAVED-DWG " + $OUT_DWG) } catch { $saveErr = $_.Exception.Message; RW ("SAVEAS-DWG-ERR: " + $saveErr) }
if ($saveErr -eq '') {
  try { Retry { $doc.SaveAs($OUT_DXF, 60) } ; RW ("SAVED-DXF " + $OUT_DXF + " (enum 60)") }
  catch {
    try { Retry { $doc.SaveAs($OUT_DXF) } ; RW ("SAVED-DXF " + $OUT_DXF + " (auto)") }
    catch { RW ("SAVEAS-DXF-ERR: " + $_.Exception.Message)
      try { Retry { $doc.SetVariable('FILEDIA', 0) } | Out-Null; Start-Sleep -Milliseconds 500
            Retry { $doc.SendCommand("_SAVEAS`n2018`n$OUT_DXF`n") }
            Start-Sleep -Seconds 20
            Retry { $doc.SetVariable('FILEDIA', 1) } | Out-Null
            RW ("SAVED-DXF via command " + $OUT_DXF) }
      catch { RW ("SAVEAS-DXF-CMD-ERR: " + $_.Exception.Message) } }
  }
}
try { $doc.Close($false) } catch {}
$sw.Close()
Write-Host "BUILD2-DONE"