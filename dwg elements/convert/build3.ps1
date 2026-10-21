$ErrorActionPreference = 'Continue'

$SEC_DWG = 'C:\RobBox\ai\project\dwg elements\convert\section.dwg'
$GOR_DWG = 'C:\RobBox\ai\project\dwg elements\convert\gorka.dwg'
$TRF_DWG = 'C:\RobBox\ai\project\dwg elements\convert\transfer.dwg'
$OUT_DWG = 'C:\RobBox\ai\project\konveyer.dwg'
$RPT     = 'C:\RobBox\ai\project\dwg elements\convert\build3_report.txt'

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

# ---- measured constants ----
$SEC_STRIP_MINX = 126736.509
$SEC_STRIP_MAXX = 138436.500
$SEC_STRIP_LEN  = 11699.991
$SEC_YC         = 80542.275
$SEC_SENS_Z     = 8652.129
$GOR_ENTRY_XMAX = 204259.154          # entry (high) face
$GOR_EXIT_X     = 193569.558          # exit cube left face
$GOR_UP_Z       = 2700.492            # entry walk plane (U646 bottom)
$GOR_LO_Z       = -385.328            # exit walk plane (U647 bottom)
$TRF_ADPT1_YB   = 80542.275            # transfer section-side adapter band Y-center (staging)
$TRF_ADPT_TOPZ  = 8760.272             # transfer adapter top Z (staging)

$FLOOR_GAP = 3000.0
$fz = $FLOOR_GAP / ($GOR_UP_Z - $GOR_LO_Z)     # 0.972188915750108

$P2 = 12500.0; $N2 = 4
$P1 = 10000.0; $N1 = 3
$s2 = $P2 / $SEC_STRIP_LEN
$s1 = $P1 / $SEC_STRIP_LEN

# junction anchoring
$XG = $N2 * $P2                                   # gorka entry face at world X=50000
$DY_J = -$SEC_YC                                  # Y: scene section band -> world Y=0
$DZ_TRF = ($FLOOR_GAP - $SEC_SENS_Z + 296.0) - $TRF_ADPT_TOPZ   # adapters' top == world belt top (3104.5)
$GOR_X_INSR = $XG - $GOR_ENTRY_XMAX
$GOR_Y_INSR = $DY_J                               # gorka strip band -> world Y center=-1083.76
$GOR_Z_INSR = $fz * (-$GOR_LO_Z)
$GOR_EXIT_W = $GOR_X_INSR + $GOR_EXIT_X
# transfer is rigid: world = staging + offset
$TRF_X_INSR = $XG - $GOR_ENTRY_XMAX + 121236.438   # adapters start 53.23mm before gorka entry face
#   (adapter min X staging 121236.438; scene adapter min 204205.92 = Xg-53.23 -> keep same relation to Xg)
$TRF_Y_INSR = $DY_J
$TRF_Z_INSR = $DZ_TRF

$CONV_Y_INSR = -$SEC_YC
$CONV2_Z_INSR = $FLOOR_GAP - $SEC_SENS_Z
$CONV1_Z_INSR = -$SEC_SENS_Z
$CONV1_Y_INSR = -81626.036                        # floor1 line on gorka centerline (-1083.76)
$CONV2_X0 = -$s2 * $SEC_STRIP_MINX
$CONV1_XB = $GOR_EXIT_W - $s1 * $SEC_STRIP_MAXX

RW ("PLAN: floor2 N2=$N2 pitch=$P2 s=($s2,1,1) X=0..50000 | transfer rigid ins=($TRF_X_INSR,$TRF_Y_INSR,$TRF_Z_INSR) | gorka rot=0 s=(1,1,$fz) ins=($GOR_X_INSR,$GOR_Y_INSR,$GOR_Z_INSR) | floor1 N1=$N1 pitch=$P1 s=($s1,1,1) X=9310.4..$GOR_EXIT_W at Y-center=-1083.76")
RW ("adapters' top target = world belt top = " + ($CONV2_Z_INSR + 8652.129 - 8460.629 + 296.0) )

$acad = $null
try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") } catch {
  $acad = Retry { New-Object -ComObject AutoCAD.Application }
}
try { $acad.Visible = $false } catch {}
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

try { $null = Retry { $ms.InsertBlock((Pt $TRF_X_INSR $TRF_Y_INSR $TRF_Z_INSR), $TRF_DWG, [double]1, [double]1, [double]1, [double]0) } }
catch { $iFails++; RW ("FAIL transfer : " + $_.Exception.Message) }
RW ("INSERT transfer at ($TRF_X_INSR , $TRF_Y_INSR , $TRF_Z_INSR) s=(1,1,1) rot=0")

try { $null = Retry { $ms.InsertBlock((Pt $GOR_X_INSR $GOR_Y_INSR $GOR_Z_INSR), $GOR_DWG, [double]1, [double]1, [double]$fz, [double]0) } }
catch { $iFails++; RW ("FAIL gorka : " + $_.Exception.Message) }
RW ("INSERT gorka at ($GOR_X_INSR , $GOR_Y_INSR , $GOR_Z_INSR) s=(1,1,$fz) rot=0")

for ($k=0; $k -lt $N1; $k++) {
  $x = $CONV1_XB - (2-$k)*$P1
  try { $null = Retry { $ms.InsertBlock((Pt $x $CONV1_Y_INSR $CONV1_Z_INSR), $SEC_DWG, [double]$s1, [double]1, [double]1, [double]0) } }
  catch { $iFails++; RW ("FAIL floor1 unit $k : " + $_.Exception.Message); continue }
  RW ("INSERT floor1 unit $k at ($x , $CONV1_Y_INSR , $CONV1_Z_INSR) s=($s1,1,1) rot=0")
}

$cnt = Retry { $ms.Count }
RW ("MODELSPACE COUNT: $cnt  INSERT-FAILS: $iFails")

$gmin = @(1e30,1e30,1e30); $gmax = @(-1e30,-1e30,-1e30)
foreach ($e in $ms) {
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  $nm = Retry { $e.Name }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  RW ("CHECK '" + $nm + "'  bbox (" + [math]::Round($bb[0],2) + "," + [math]::Round($bb[1],2) + "," + [math]::Round($bb[2],2) + ") .. (" + [math]::Round($bb[3],2) + "," + [math]::Round($bb[4],2) + "," + [math]::Round($bb[5],2) + ")")
  for ($i=0; $i -lt 3; $i++) { if ($bb[$i] -lt $gmin[$i]) { $gmin[$i]=$bb[$i] }; if ($bb[3+$i] -gt $gmax[$i]) { $gmax[$i]=$bb[3+$i] } }
}
RW ("UNION: (" + [math]::Round($gmin[0],1) + "," + [math]::Round($gmin[1],1) + "," + [math]::Round($gmin[2],1) + ") .. (" + [math]::Round($gmax[0],1) + "," + [math]::Round($gmax[1],1) + "," + [math]::Round($gmax[2],1) + ")")

try { Retry { $doc.SaveAs($OUT_DWG) }; RW ("SAVED-DWG " + $OUT_DWG) } catch { RW ("SAVEAS-DWG-ERR: " + $_.Exception.Message) }
try { $doc.Close($false) } catch {}
$sw.Close()
Write-Host "BUILD3-DONE"