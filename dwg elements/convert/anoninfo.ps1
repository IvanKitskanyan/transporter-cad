param([string]$Dxf, [string]$OutFile)
$L = [System.IO.File]::ReadAllLines($Dxf, [System.Text.Encoding]::GetEncoding(1251))
$n = $L.Length
$sw = New-Object System.IO.StreamWriter($OutFile, $false, (New-Object System.Text.UTF8Encoding($false)))
$secStart=@{}; $secEnd=@{}; $cur=$null
for ($i=0; $i -lt $n-1; $i+=2) {
  $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
  if ($c -eq '0' -and $v -eq 'SECTION') { $nm=$L[$i+3].Trim(); $secStart[$nm]=$i; $cur=$nm }
  if ($c -eq '0' -and $v -eq 'ENDSEC') { if($cur){$secEnd[$cur]=$i; $cur=$null} }
}
$blkS=$secStart['BLOCKS']; $blkE=$secEnd['BLOCKS']
$entS=$secStart['ENTITIES']; $entE=if($secEnd.ContainsKey('ENTITIES')){$secEnd['ENTITIES']}else{$n}
$inv=[System.Globalization.CultureInfo]::InvariantCulture

function BlockBounds($from, $to) {
  $mn=@(1e30,1e30,1e30); $mx=@(-1e30,-1e30,-1e30); $types=@{}
  $i=$from
  while ($i -lt $to-2) {
    $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
    if ($c -eq '0') { if ($types.ContainsKey($v)) { $types[$v]++ } else { $types[$v]=1 } }
    elseif ($c -match '^(1[0-3]|2[0-3]|3[0-3]|40|41|42|43|50)$') {
      $d=0.0
      if([double]::TryParse($v,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$d) -and [math]::Abs($d) -lt 1e12) {
        $idx = if ($c -match '^1') { 0 } elseif ($c -match '^2') { 1 } elseif ($c -match '^3') { 2 } else { -1 }
        if ($idx -ge 0) {
          if ($d -lt $mn[$idx]) {$mn[$idx]=$d}
          if ($d -gt $mx[$idx]) {$mx[$idx]=$d}
        }
      }
    }
    $i+=2
  }
  return @{ types=$types; mn=$mn; mx=$mx }
}

$i=$blkS
while ($i -lt $blkE-2) {
  $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
  if ($c -eq '0' -and $v -eq 'BLOCK') {
    $j=$i+2; $bn=''
    while ($j -lt $blkE-2) {
      $cc=$L[$j].Trim(); $vv=$L[$j+1].Trim()
      if ($cc -eq '0') { break }
      if ($cc -eq '2' -and -not $bn) { $bn=$vv }
      $j+=2
    }
    # find def end
    $k=$j
    $end=$blkE
    while ($k -lt $blkE-2) {
      $kc=$L[$k].Trim()
      if ($kc -eq '0') { $kv=$L[$k+1].Trim(); if ($kv -eq 'BLOCK' -or $kv -eq 'ENDBLK') { $end=$k; break } }
      $k+=2
    }
    $len = $end - $i
    if (($bn -match '^\*U(105|226|694|695)$') -or ($len -gt 3000)) {
      if ($bn -match '^\*U') {
        $r = BlockBounds $j $end
        $sw.WriteLine("### BLOCK $bn  lines=$($end-$i)")
        $sw.WriteLine(("    X: {0:N1}..{1:N1} (len {2:N1})" -f $r.mn[0], $r.mx[0], ($r.mx[0]-$r.mn[0])))
        $sw.WriteLine(("    Y: {0:N1}..{1:N1} (len {2:N1})" -f $r.mn[1], $r.mx[1], ($r.mx[1]-$r.mn[1])))
        $sw.WriteLine(("    Z: {0:N1}..{1:N1} (len {2:N1})" -f $r.mn[2], $r.mx[2], ($r.mx[2]-$r.mn[2])))
        $tstr = ($r.types.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "
        $sw.WriteLine("    types: $tstr")
      }
    }
    $i=$end
  } else { $i+=2 }
}
$sw.Close()
"WROTE $OutFile"