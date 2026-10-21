param([string]$Dxf, [switch]$DumpInserts)
$L = [System.IO.File]::ReadAllLines($Dxf, [System.Text.Encoding]::GetEncoding(1251))
$n = $L.Length
$secStart = @{}; $secEnd = @{}; $cur = $null
for ($i=0; $i -lt $n-1; $i+=2) {
  $code = $L[$i].Trim(); $val = $L[$i+1].Trim()
  if ($code -eq '0' -and $val -eq 'SECTION') { $name = $L[$i+3].Trim(); $secStart[$name]=$i; $cur=$name }
  if ($code -eq '0' -and $val -eq 'ENDSEC') { if($cur){$secEnd[$cur]=$i; $cur=$null} }
}
$names = $secStart.Keys -join ", "
"Sections: $names"
$entS = $secStart['ENTITIES']; $entE = if($secEnd.ContainsKey('ENTITIES')){$secEnd['ENTITIES']}else{$n}
$blkS = $secStart['BLOCKS'];   $blkE = $secEnd['BLOCKS']

$namedBlocks = @()
$inBlockHeader = $false
for ($i=$blkS; $i -le $blkE-2; $i+=2) {
  $code = $L[$i].Trim(); $val = $L[$i+1].Trim()
  if ($code -eq '0') { $inBlockHeader = ($val -eq 'BLOCK'); continue }
  if ($inBlockHeader -and $code -eq '2') { if (-not $val.StartsWith('*')) { $namedBlocks += $val }; $inBlockHeader=$false }
}
"Named block defs:"
$namedBlocks | ForEach-Object { "  $_" }

$counts = @{}
$blockRef = @{}
$last0 = ''
for ($i=$entS; $i -le $entE-2; $i+=2) {
  $code = $L[$i].Trim(); $val = $L[$i+1].Trim()
  if ($code -eq '0') {
    if ($counts.ContainsKey($val)) { $counts[$val]++ } else { $counts[$val]=1 }
    $last0 = $val
  } elseif ($code -eq '2' -and $last0 -eq 'INSERT') {
    if ($blockRef.ContainsKey($val)) { $blockRef[$val]++ } else { $blockRef[$val]=1 }
  }
}
"Entity counts:"
$counts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "  $($_.Key) : $($_.Value)" }
"INSERT refs by block:"
$blockRef.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "  $($_.Key) : $($_.Value)" }

if ($DumpInserts) {
  "--- INSERT details ---"
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  $i = $entS
  while ($i -lt $entE - 2) {
    if ($L[$i].Trim() -eq '0' -and $L[$i+1].Trim() -eq 'INSERT') {
      $name=''; $px=''; $py=''; $pz=''; $rot='0'; $sx='1'; $sy='1'; $sz='1'
      $j = $i + 2
      while ($j -lt $entE - 2) {
        $c = $L[$j].Trim(); $v = $L[$j+1].Trim()
        if ($c -eq '0') { break }
        switch ($c) {
          '2'  { if(-not $name){$name=$v} }
          '10' { if($px -eq ''){$px=$v} }
          '20' { if($py -eq ''){$py=$v} }
          '30' { if($pz -eq ''){$pz=$v} }
          '50' { if($rot -eq '0'){$rot=$v} }
          '41' { if($sx -eq '1'){$sx=$v} }
          '42' { if($sy -eq '1'){$sy=$v} }
          '43' { if($sz -eq '1'){$sz=$v} }
          '67' { }
        }
        $j += 2
      }
      "INSERT '$name' at ($px ; $py ; $pz) rot=$rot scale=($sx,$sy,$sz)"
      $i = $j
    } else { $i += 2 }
  }
}
# extents over coordinate codes
$mn=@(1e30,1e30,1e30); $mx=@(-1e30,-1e30,-1e30)
for ($i=$entS; $i -le $entE-2; $i+=2) {
  $code = $L[$i].Trim(); $val = $L[$i+1].Trim()
  if ($code -match '^(1[0-3]|2[0-3]|3[0-3])$') {
    $d=0.0
    if([double]::TryParse($val,[ref]$d) -and [math]::Abs($d) -lt 1e9) {
      if($code -match '^1[0-3]$'){ if($d -lt $mn[0]){$mn[0]=$d}; if($d -gt $mx[0]){$mx[0]=$d} }
      elseif($code -match '^2[0-3]$'){ if($d -lt $mn[1]){$mn[1]=$d}; if($d -gt $mx[1]){$mx[1]=$d} }
      else { if($d -lt $mn[2]){$mn[2]=$d}; if($d -gt $mx[2]){$mx[2]=$d} }
    }
  }
}
"Extents (approximation, X=10..13 Y=20..23 Z=30..33):"
"  X: $([math]::Round($mn[0],2)) .. $([math]::Round($mx[0],2))  (len $([math]::Round($mx[0]-$mn[0],2)))"
"  Y: $([math]::Round($mn[1],2)) .. $([math]::Round($mx[1],2))  (len $([math]::Round($mx[1]-$mn[1],2)))"
"  Z: $([math]::Round($mn[2],2)) .. $([math]::Round($mx[2],2))  (len $([math]::Round($mx[2]-$mn[2],2)))"