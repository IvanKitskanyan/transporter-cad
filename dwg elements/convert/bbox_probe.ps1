param([string]$Dwg, [string]$OutFile, [string]$Tag = "x")
$ErrorActionPreference = 'Continue'
$sw = New-Object System.IO.StreamWriter($OutFile, $false, (New-Object System.Text.UTF8Encoding($false)))

function Retry([scriptblock]$sb, [int]$tries = 240) {
  for ($t=0; $t -lt $tries; $t++) {
    try { $r = & $sb; return $r } catch {
      if ($_.Exception.HResult -eq -2147418111 -or $_.Exception.Message -match 'RPC_E_CALL_REJECTED|0x80010001') { Start-Sleep -Milliseconds 500 } else { throw }
    }
  }
  throw "RETRIES-EXHAUSTED"
}

$acad = $null
try {
  $acad = Retry { New-Object -ComObject AutoCAD.Application }
} catch {
  $sw.WriteLine("COM-FAIL: " + $_.Exception.Message); $sw.Close(); exit 1
}
$sw.WriteLine("COM-OK")
$acad.Visible = $true
try { $doc = Retry { $acad.Documents.Open($Dwg, $true) } } catch {
  $sw.WriteLine("OPEN-FAIL: " + $_.Exception.Message); $sw.Close(); exit 1
}
$sw.WriteLine("OPENED " + $Dwg)
Start-Sleep -Seconds 5
$ms = Retry { $doc.ModelSpace }
$cnt = Retry { $ms.Count }
$sw.WriteLine("MODELSPACE COUNT: $cnt")
foreach ($e in $ms) {
  $on = Retry { $e.ObjectName }
  if ($on -ne 'AcDbBlockReference') { $sw.WriteLine("OBJ $on " + (Retry { $e.Handle })); continue }
  $name = Retry { $e.Name }
  $rot = Retry { $e.Rotation }
  $ix = Retry { $e.InsertionPoint.X } ; $iy = Retry { $e.InsertionPoint.Y }; $iz = Retry { $e.InsertionPoint.Z }
  $sw.WriteLine(("INSERT '{0}' rot={1:N3} ins=({2:N3} , {3:N3} , {4:N3})" -f $name, $rot, $ix, $iy, $iz))
  $mnv = Retry { $null = $null; $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn, [ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  $sw.WriteLine(("   BBOX: ({0:N3} , {1:N3} , {2:N3}) .. ({3:N3} , {4:N3} , {5:N3})" -f $mnv[0], $mnv[1], $mnv[2], $mnv[3], $mnv[4], $mnv[5]))
  $sw.WriteLine(("   SIZE: dX={0:N3} dY={1:N3} dZ={2:N3}" -f ($mnv[3]-$mnv[0]), ($mnv[4]-$mnv[1]), ($mnv[5]-$mnv[2])))
}
$doc.Close($false)
$sw.WriteLine("DONE")
$sw.Close()