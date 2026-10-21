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

function RangeEnds($startIdx, [string]$blockName) {
  # returns line index where named block definition ends (ENDBLK)
  $depth=0; $found=$null
  $i=$startIdx
  while ($i -lt $script:blkE-2) {
    $c=$script:L[$i].Trim(); $v=$script:L[$i+1].Trim()
    if ($c -eq '0' -and $v -eq 'BLOCK') {
      # find name
      $j=$i+2; $bn=''
      while ($j -lt $script:blkE-2) {
        $cc=$script:L[$j].Trim(); $vv=$script:L[$j+1].Trim()
        if ($cc -eq '0') { break }
        if ($cc -eq '2' -and -not $bn) { $bn=$vv }
        $j+=2
      }
      if ($bn -eq $blockName) { return $j }
      $i=$j
    } else { $i+=2 }
  }
  return $null
}

# list all named block defs with counts
$sw.WriteLine("=== NAMED BLOCKS in $Dxf ===")
$i=$blkS; $names=@()
while ($i -lt $blkE-2) {
  $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
  if ($c -eq '0' -and $v -eq 'BLOCK') {
    $j=$i+2; $bn=''; $bx=0
    while ($j -lt $blkE-2) {
      $cc=$L[$j].Trim(); $vv=$L[$j+1].Trim()
      if ($cc -eq '0') { break }
      if ($cc -eq '2' -and -not $bn) { $bn=$vv }
      $j+=2
    }
    if (-not $bn.StartsWith('*')) { $names += $bn }
    $i=$j
  } else { $i+=2 }
}
$names | ForEach-Object { $sw.WriteLine("  $_") }

# dump nested INSERTs inside a block definition (or in ENTITIES when blockName=='*ENTITIES*')
function DumpBlockInserts([string]$blockName, $from, $to) {
  $inv=[System.Globalization.CultureInfo]::InvariantCulture
  $sw.WriteLine("=== INSERTs inside '$blockName' [$from..$to] ===")
  $i=$from
  while ($i -lt $to-2) {
    $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
    if ($c -eq '0' -and $v -eq 'INSERT') {
      $name=''; $px=$null; $py=$null; $pz=$null; $rot=0.0
      $j=$i+2
      while ($j -lt $to-2) {
        $cc=$L[$j].Trim(); $vv=$L[$j+1].Trim()
        if ($cc -eq '0') { break }
        switch ($cc) {
          '2'  { if(-not $name){$name=$vv} }
          '10' { if($null -eq $px){$px=[double]::Parse($vv,$inv)} }
          '20' { if($null -eq $py){$py=[double]::Parse($vv,$inv)} }
          '30' { if($null -eq $pz){$pz=[double]::Parse($vv,$inv)} }
          '50' { $rot=[double]::Parse($vv,$inv) }
        }
        $j+=2
      }
      if ($px -ne $null) {
        $sw.WriteLine(("  '{0}' at ({1:N3} ; {2:N3} ; {3:N3}) rot={4}" -f $name, $px, $py, $pz, $rot))
      }
      $i=$j
    } else { $i+=2 }
  }
}

# find the 4 anonymous blocks in BLOCKS section and dump their nested structure
$found=@()
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
    $found += ,@($bn, $i, $j)
    $i=$j
  } else { $i+=2 }
}
foreach ($target in @('*U694','*U695','*U105','*U226')) {
  foreach ($f in $found) {
    if ($f[0] -eq $target) {
      $end=$blkE
      # find next block start after f[1]
      $sw.WriteLine("### ANON BLOCK $($f[0]) def at line $($f[1])")
      $k=$f[2]
      while ($k -lt $blkE-2) {
        $kc=$L[$k].Trim()
        if ($kc -eq '0') { $kv=$L[$k+1].Trim(); if ($kv -eq 'BLOCK' -or $kv -eq 'ENDBLK') { break } }
        $k+=2
      }
      DumpBlockInserts "$($f[0]) (def)" $f[2] $k
    }
  }
}
DumpBlockInserts '*ENTITIES*' $entS $entE
$sw.Close()
"WROTE $OutFile"