param(
  [Parameter(Mandatory=$true)][string]$Dwg,
  [string]$Lib = 'C:\RobBox\ai\project\.claude\skills\robbox-cad\lib\elements.json',
  [string]$Out = ''
)
$ErrorActionPreference = 'Continue'
$Dwg = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Dwg))
if (-not (Test-Path -LiteralPath $Dwg)) { Write-Host "DWG NOT FOUND: $Dwg"; exit 1 }
if ($Out) { $Out = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Out)) }
if (-not $Out) { $Out = [System.IO.Path]::ChangeExtension($Dwg, '') }  # base path

# build lib name map in an isolated scope
function Get-LibTypes([string]$libPath) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $libPath)) { return $map }
  $s = [System.IO.File]::ReadAllText($libPath, [System.Text.UTF8Encoding]::new($false))
  $libObj = $null
  for ($i=0; $i -lt 5 -and $libObj -eq $null; $i++) {
    try {
      $o = ConvertFrom-Json -InputObject $s
      if ($o -isnot [string]) { $libObj = $o }
    } catch {}
  }
  if ($libObj -eq $null) { throw ("JSON PARSE FAILED: " + $libPath) }
  foreach ($pr in $libObj.PSObject.Properties) {
    $v = $pr.Value
    if ($v -is [PSCustomObject] -and $v.PSObject.Properties['dwg']) {
      $b = [System.IO.Path]::GetFileNameWithoutExtension([string]$v.dwg)
      if (-not $map.ContainsKey($b)) { $map[$b] = $pr.Name }
      if (-not $map.ContainsKey($pr.Name)) { $map[$pr.Name] = $pr.Name }
    }
  }
  return $map
}
$libNames = Get-LibTypes $Lib

$RPT = $Out + '_spec_report.txt'
$CSV = $Out + '_spec.csv'
$MD  = $Out + '_spec.md'
$sw  = New-Object System.IO.StreamWriter($RPT, $false, (New-Object System.Text.UTF8Encoding($false)))
function RW($s) { $sw.WriteLine([string]$s); $sw.Flush() }
function Retry([scriptblock]$sb, [int]$tries = 600) {
  for ($t=0; $t -lt $tries; $t++) {
    try { $r = & $sb; return $r } catch {
      if ($_.Exception.HResult -eq -2147418111 -or $_.Exception.Message -match 'RPC_E_CALL_REJECTED|0x80010001') { Start-Sleep -Milliseconds 500 } else { throw }
    }
  }
  throw "RETRIES-EXHAUSTED"
}

# COM: open and collect inserts
$acad = $null
try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application") } catch {
  for ($w=0; $w -lt 60; $w++) {
    try { $acad = [System.Runtime.InteropServices.Marshal]::GetActiveObject("AutoCAD.Application"); break } catch {}
    if ($w -eq 0) { try { Start-Process 'acad.exe' -WindowStyle Hidden } catch {} }
    Start-Sleep -Seconds 5
  }
}
if ($acad -eq $null) { Write-Host "NO-COM"; exit 1 }
$doc = Retry { $acad.Documents.Open($Dwg, $true) }
Start-Sleep -Seconds 2
$ms = $doc.ModelSpace
$cnt = Retry { $ms.Count }
RW ("SPEC OF: " + $Dwg + "  modelspace entities: " + $cnt)

$rows = New-Object System.Collections.Generic.List[object]
$n = 0
foreach ($e in $ms) {
  if ((Retry { $e.ObjectName }) -ne 'AcDbBlockReference') { continue }
  $n++
  $nm = [string](Retry { $e.Name })
  $ip = Retry { $e.InsertionPoint }
  $bb = Retry { $mn=$null; $mx=$null; $e.GetBoundingBox([ref]$mn,[ref]$mx); ,(@([double]$mn[0],[double]$mn[1],[double]$mn[2],[double]$mx[0],[double]$mx[1],[double]$mx[2])) }
  $sx = 1.0; try { $sx = [double](Retry { $e.XScaleFactor }) } catch {}
  $rows.Add([PSCustomObject]@{
    num = $n; block = $nm;
    X = [math]::Round([double]$ip[0],1); Y = [math]::Round([double]$ip[1],1); Z = [math]::Round([double]$ip[2],1);
    Sx = [math]::Round($sx,4);
    dX = [math]::Round($bb[3]-$bb[0],1); dY = [math]::Round($bb[4]-$bb[1],1); dZ = [math]::Round($bb[5]-$bb[2],1);
    MinZ = [math]::Round($bb[2],1); MaxZ = [math]::Round($bb[5],1)
  })
}
# element type via known lib entries (block ref Name == element key usually)
foreach ($r in $rows) {
  $key = ''
  foreach ($p in $libNames.Keys) { if ([string]$r.block -eq $p) { $key = $p } }
  $tp = '?'
  if ($key) { $tp = $key }
  $len = [double]$r.dX
  if ($key -and $libNames[$key].PSObject.Properties['raw_len']) { $len = [math]::Round($libNames[$key].raw_len * [double]$r.Sx,1) }
  $r | Add-Member -Force -NotePropertyName tip -NotePropertyValue $tp
  $r | Add-Member -Force -NotePropertyName len_mm -NotePropertyValue $len
  if ($r.num -le 2) { [IO.File]::AppendAllText('C:/RobBox/ai/project/dbg_make_spec.txt', ("num=" + $r.num + " block=[" + $r.block + "] key=[" + $key + "] tip=[" + $tp + "] libCount=" + $libNames.Count + "`n"), [Text.UTF8Encoding]::new($true)) }
}
Retry { $doc.Close($false) }

# CSV
$csvW = New-Object System.IO.StreamWriter($CSV, $false, (New-Object System.Text.UTF8Encoding($true)))
$csvW.WriteLine("№;Блок;Тип;X;Y;Z;Масштаб_X;Длина_мм;dX;dY;dZ;Уровень_Z(низ);Уровень_Z(верх)")
foreach ($r in $rows) {
  $csvW.WriteLine(("{0};{1};{2};{3};{4};{5};{6};{7};{8};{9};{10};{11};{12}" -f $r.num,$r.block,$r.tip,$r.X,$r.Y,$r.Z,$r.Sx,$r.len_mm,$r.dX,$r.dY,$r.dZ,$r.MinZ,$r.MaxZ))
}
$csvW.Close()

# MD summary: totals by type and by Z-level
$mdW = New-Object System.IO.StreamWriter($MD, $false, (New-Object System.Text.UTF8Encoding($false)))
$mdW.WriteLine("# Спецификация: " + (Split-Path $Dwg -Leaf))
$mdW.WriteLine("")
$types = $rows | Group-Object -Property tip
$mdW.WriteLine("## По типам элементов")
$mdW.WriteLine("")
$mdW.WriteLine("| Элемент | Кол-во | Σ длина, мм | Σ длина, м |")
$mdW.WriteLine("|---|---|---|---|")
foreach ($t in $types) {
  $sum = ($t.Group | Measure-Object -Property len_mm -Sum).Sum
  $mdW.WriteLine("| " + $t.Name + " | " + $t.Count + " | " + [math]::Round($sum,1) + " | " + [math]::Round($sum/1000.0,2) + " |")
}
$mdW.WriteLine("")
$lvls = $rows | Group-Object -Property MinZ
$mdW.WriteLine("## По уровням этажей (Z нижней грани)")
$mdW.WriteLine("")
$mdW.WriteLine("| Z, мм | Элементов | Состав |")
$mdW.WriteLine("|---|---|---|")
foreach ($l in ($lvls | Sort-Object Name -Descending)) {
  $comp = (($l.Group | Group-Object tip | ForEach-Object { $_.Name + "x" + $_.Count }) -join ", ")
  $mdW.WriteLine("| " + $l.Name + " | " + $l.Count + " | " + $comp + " |")
}
$mdW.Close()
RW ("ROWS: " + $rows.Count)
$sw.Close()
Write-Host "SPEC-DONE: $CSV ; $MD"
