$ErrorActionPreference = 'Continue'
$RPT = 'C:\RobBox\ai\project\dwg elements\convert\probe_dxf_report.txt'
$sw = New-Object System.IO.StreamWriter($RPT, $false, (New-Object System.Text.UTF8Encoding($false)))
function RW($s) { $sw.WriteLine([string]$s); $sw.Flush() }

function Retry([scriptblock]$sb, [int]$tries = 300) {
  for ($t=0; $t -lt $tries; $t++) {
    try { $r = & $sb; return $r } catch {
      if ($_.Exception.HResult -eq -2147418111 -or $_.Exception.Message -match 'RPC_E_CALL_REJECTED|0x80010001') { Start-Sleep -Milliseconds 500 } else { throw }
    }
  }
  throw "RETRIES-EXHAUSTED"
}
function Fmt([double[]]$bb) {
  return ("(" + ([math]::Round($bb[0],2)) + " , " + ([math]::Round($bb[1],2)) + " , " + ([math]::Round($bb[2],2)) + ") .. (" + ([math]::Round($bb[3],2)) + " , " + ([math]::Round($bb[4],2)) + " , " + ([math]::Round($bb[5],2)) + ")")
}

try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") } catch {
  $acad = Retry { New-Object -ComObject AutoCAD.Application }
}
$acad.Visible = $false
RW ("CADEngine: " + $acad.Version)

foreach ($path in @('C:\RobBox\ai\project\dxf elements\section.dxf','C:\RobBox\ai\project\dxf elements\gorka.dxf')) {
  RW "===="
  RW ("OPEN: " + $path)
  try {
    $doc = Retry { $acad.Documents.Open($path, $true) }
    Start-Sleep -Seconds 2
    $ms = $doc.ModelSpace
    $cnt = Retry { $ms.Count }
    RW ("MODELSPACE COUNT: " + $cnt)
    for ($i=0; $i -lt $cnt; $i++) {
      $e = Retry { $ms.Item($i) }
      $on = Retry { $e.ObjectName }
      $nm = ''
      $ins = ''
      if ($on -eq 'AcDbBlockReference') {
        $nm = Retry { $e.Name }
        try { $ip = Retry { $e.InsertionPoint }; $ins = (" ins=[" + [math]::Round($ip[0],2) + "," + [math]::Round($ip[1],2) + "," + [math]::Round($ip[2],2) + "]") } catch {}
        $rot = ''
        try { $rot = (" rot=" + [math]::Round((Retry { $e.Rotation }),3)) } catch {}
        $sc = ''
        try { $sc = (" sc=[" + [math]::Round((Retry { $e.XScaleFactor }),3) + "," + [math]::Round((Retry { $e.YScaleFactor }),3) + "," + [math]::Round((Retry { $e.ZScaleFactor }),3) + "]") } catch {}
      }
      $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
      $sz = (" d=(" + [math]::Round(([double]$bb[3]-$bb[0]),2) + "," + [math]::Round(([double]$bb[4]-$bb[1]),2) + "," + [math]::Round(([double]$bb[5]-$bb[2]),2) + ")")
      RW ("[" + $i + "] " + $on + " '" + $nm + "'" + $ins + $rot + $sc + "  BBOX " + (Fmt $bb) + "  SIZE " + $sz)
    }
    # also overall extmin/extmax from header
    $doc.Close($false)
    RW ("CLOSED: " + $path)
  } catch {
    RW ("ERROR on " + $path + ": " + $_.Exception.Message)
    try { if ($doc) { $doc.Close($false) } } catch {}
  }
}
$sw.Close()
Write-Host "PROBE-DONE"