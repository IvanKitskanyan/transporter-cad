param(
  [Parameter(Mandatory=$true)][string]$Dwg,
  [Parameter(Mandatory=$true)][string]$Name,
  [string]$Lib = 'C:\RobBox\ai\project\.claude\skills\robbox-cad\lib\elements.json'
)
$ErrorActionPreference = 'Continue'
$RPT = 'C:\RobBox\ai\project\dwg elements\convert\probe_' + $Name + '.txt'
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

$acad = $null
try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") } catch {
  for ($w=0; $w -lt 60; $w++) {
    try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application"); break } catch {}
    if ($w -eq 0) { try { Start-Process 'acad.exe' -WindowStyle Hidden } catch {} }
    Start-Sleep -Seconds 5
  }
}
if ($acad -eq $null) { RW "NO-COM"; $sw.Close(); Write-Host "NO-COM"; exit 1 }
$doc = Retry { $acad.Documents.Open($Dwg, $true) }
Start-Sleep -Seconds 2

$ib = 0,0,0
try { $v = $doc.GetVariable('INSBASE'); $ib = @([double]$v[0],[double]$v[1],[double]$v[2]) } catch {}
RW ("INSBASE: " + ($ib -join ','))
$ms = $doc.ModelSpace
$cnt = Retry { $ms.Count }
RW ("MODELSPACE COUNT: " + $cnt)
$gmin = @(1e30,1e30,1e30); $gmax = @(-1e30,-1e30,-1e30)
for ($i=0; $i -lt $cnt; $i++) {
  $e = Retry { $ms.Item($i) }
  $on = Retry { $e.ObjectName }
  $nm = ''
  if ($on -eq 'AcDbBlockReference') { $nm = Retry { $e.Name } }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  RW ("[" + $i + "] " + $on + " '" + $nm + "'  BBOX (" + [math]::Round($bb[0],3) + "," + [math]::Round($bb[1],3) + "," + [math]::Round($bb[2],3) + ") .. (" + [math]::Round($bb[3],3) + "," + [math]::Round($bb[4],3) + "," + [math]::Round($bb[5],3) + ")  d=(" + [math]::Round($bb[3]-$bb[0],3) + "," + [math]::Round($bb[4]-$bb[1],3) + "," + [math]::Round($bb[5]-$bb[2],3) + ")")
  for ($a=0; $a -lt 3; $a++) { if ($bb[$a] -lt $gmin[$a]) { $gmin[$a]=$bb[$a] }; if ($bb[3+$a] -gt $gmax[$a]) { $gmax[$a]=$bb[3+$a] } }
}
RW ("UNION: (" + [math]::Round($gmin[0],3) + "," + [math]::Round($gmin[1],3) + "," + [math]::Round($gmin[2],3) + ") .. (" + [math]::Round($gmax[0],3) + "," + [math]::Round($gmax[1],3) + "," + [math]::Round($gmax[2],3) + ")")
Retry { $doc.Close($false) }

# merge into library json
$entry = @{
  label = [System.IO.Path]::GetFileNameWithoutExtension($Dwg)
  dwg = ($Dwg -replace '\\','/')
  raw = @{ x0 = [math]::Round($gmin[0],3); x1 = [math]::Round($gmax[0],3); y0 = [math]::Round($gmin[1],3); y1 = [math]::Round($gmax[1],3); z0 = [math]::Round($gmin[2],3); z1 = [math]::Round($gmax[2],3) }
}
$json = $null
$js = [System.IO.File]::ReadAllText($Lib, [System.Text.UTF8Encoding]::new($false))
for ($i=0; $i -lt 5 -and $json -eq $null; $i++) {
  try { $o = ConvertFrom-Json -InputObject $js; if ($o -isnot [string]) { $json = $o } } catch {}
  if ($json -eq $null) { Start-Sleep -Milliseconds 200 }
}
if ($json -eq $null) { Write-Host "JSON PARSE FAILED: $Lib"; exit 1 }
# rebuild object preserving _schema
$newProps = [ordered]@{}
if ($json.PSObject.Properties['_schema']) { $newProps['_schema'] = $json._schema }
foreach ($p in $json.PSObject.Properties) {
  if ($p.Name -eq '_schema') { continue }
  if ($p.Name -eq $Name) { continue }   # replace existing
  $newProps[$p.Name] = $p.Value
}
if ($lib.PSObject.Properties[$Name]) {
  $old = $lib.$Name
  foreach ($prop in $old.PSObject.Properties) {
    switch -Regex ($prop.Name) {
      '^(label|dwg|raw)$' { }   # overwritten
      default { $entry[$prop.Name] = $old.($prop.Name) }   # keep datums from previous entry
    }
  }
}
$newProps[$Name] = [PSCustomObject]$entry
$outJson = [ordered]@{}
foreach ($p in $newProps.GetEnumerator()) { $outJson[$p.Key] = $p.Value }
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Lib, ($outJson | ConvertTo-Json -Depth 10), $enc)
RW "LIBRARY UPDATED"
$sw.Close()
Write-Host "PROBE-ELEM-DONE"
Get-Content $RPT | Select-Object -Last 2