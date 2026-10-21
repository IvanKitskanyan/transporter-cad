param(
  [string]$Dxf,
  [string]$OutPng,
  [string]$Def = '',
  [double]$Vx = -1,
  [double]$Vy = -1,
  [double]$Vw = -1,
  [double]$Vh = -1,
  [int]$Px = 1600
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$L = [System.IO.File]::ReadAllLines($Dxf, [System.Text.Encoding]::GetEncoding(1251))
$n = $L.Length

function P2V($s) { $d=0.0; if([double]::TryParse($s,[System.Globalization.NumberStyles]::Float,$inv,[ref]$d)){$d}else{0.0} }

$secS=@{}; $secE=@{}; $cur=$null
for ($i=0; $i -lt $n-1; $i+=2) {
  $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
  if ($c -eq '0' -and $v -eq 'SECTION') { $secS[$L[$i+3].Trim()]=$i; $cur=$L[$i+3].Trim() }
  if ($c -eq '0' -and $v -eq 'ENDSEC') { if($cur){$secE[$cur]=$i; $cur=$null} }
}
$blkS=$secS['BLOCKS']; $blkE=$secE['BLOCKS']
$entS=$secS['ENTITIES']; $entE=if($secE.ContainsKey('ENTITIES')){$secE['ENTITIES']}else{$n}

function ParseEntities($from, $to) {
  $list = New-Object System.Collections.Generic.List[object]
  $i = $from
  $rec = $null
  while ($i -lt $to) {
    $c = $L[$i].Trim(); $v = $L[$i+1].Trim()
    if ($c -eq '0') {
      if ($v -eq 'ENDBLK') { $rec=$null; $i+=2; continue }
      $rec = @{ type=$v; verts=@(); pts=@{} }
      $list.Add($rec)
      $i += 2; continue
    }
    if ($rec -ne $null) {
      if ($c -match '^[123][0-3]$') {
        $d = (P2V $v)
        $axis = [int]$c.Substring(0,1) - 1
        $idx = [int]$c.Substring(1)
        if (($rec.type -eq 'LWPOLYLINE' -or $rec.type -eq 'MESH') -and $axis -eq 0) {
          $row = @($d, [double]::NaN, [double]::NaN)
          $rec.verts += ,$row
        } elseif (($rec.type -eq 'LWPOLYLINE' -or $rec.type -eq 'MESH') -and $axis -eq 1) {
          if ($rec.verts.Count -gt 0) { $last = $rec.verts[$rec.verts.Count-1]; $last[1] = $d }
        } else {
          while ($rec.verts.Count -le $idx) {
            $row = @([double]::NaN, [double]::NaN, [double]::NaN)
            $rec.verts += ,$row
          }
          $rec.verts[$idx][$axis] = $d
        }
      } else {
        switch ($c) {
          '50' { $rec.pts['rot'] = (P2V $v) }
          '41' { $rec.pts['s1'] = (P2V $v) }
          '42' { $rec.pts['s2'] = (P2V $v) }
          '43' { $rec.pts['s3'] = (P2V $v) }
          '38' { $rec.pts['elev'] = (P2V $v) }
          '2'  { if ($rec.type -eq 'INSERT' -and -not $rec.pts.ContainsKey('blk')) { $rec.pts['blk']=$v } }
        }
      }
    }
    $i += 2
  }
  return ,$list
}

$defs = @{}
$i = $blkS
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
    $k=$j; $end=$blkE
    while ($k -lt $blkE-2) {
      $kc=$L[$k].Trim()
      if ($kc -eq '0') { $kv=$L[$k+1].Trim(); if ($kv -eq 'ENDBLK' -or $kv -eq 'BLOCK') { $end=$k; break } }
      $k+=2
    }
    if ($bn) { $defs[$bn] = ParseEntities $j $end }
    $i=$end
  } else { $i+=2 }
}
Write-Host ("parsed " + $defs.Count + " block defs")

$seg = New-Object System.Collections.Generic.List[object]
function Rot([double]$x, [double]$y, [double]$a, [ref]$ox, [ref]$oy) {
  if ($a -eq 0) { $ox.Value=$x; $oy.Value=$y; return }
  $r = $a*3.14159265358979/180.0
  $ox.Value = $x*[math]::Cos($r) - $y*[math]::Sin($r)
  $oy.Value = $x*[math]::Sin($r) + $y*[math]::Cos($r)
}
function AddEntity($e, [double]$tx, [double]$ty, [double]$ang, [double]$gsx, [double]$gsy) {
  $t = $e.type
  $pts = New-Object System.Collections.Generic.List[object]
  $m = $e.verts.Count; if ($t -eq 'LINE') { $m = [math]::Min(2, $m) } elseif ($t -eq '3DFACE' -or $t -eq 'SOLID' -or $t -eq 'TRACE') { $m = [math]::Min(4, $m) }
  if ($t -ne 'LINE' -and $t -ne '3DFACE' -and $t -ne 'SOLID' -and $t -ne 'TRACE' -and $t -ne 'LWPOLYLINE' -and $t -ne 'MESH' -and $t -ne 'VERTEX') { return }
  for ($k=0; $k -lt $m; $k++) {
    if ($k -lt $e.verts.Count) {
      $vx = $e.verts[$k][0]
      if (-not [double]::IsNaN($vx)) {
        $vy = $e.verts[$k][1]
        $ox=[double]0; $oy=[double]0
        $rrx=[ref]$ox; $rry=[ref]$oy
        Rot $vx $vy $ang $rrx $rry
        $wx = $tx + $ox*$gsx
        $wy = $ty + $oy*$gsy
        $pts.Add((@($wx, $wy)))
      }
    }
  }
  if ($pts.Count -ge 2) {
    for ($k=1; $k -lt $pts.Count; $k++) { $seg.Add((@($pts[$k-1], $pts[$k]))) }
    if ($t -ne 'LINE' -and $t -ne 'LWPOLYLINE' -and $pts.Count -ge 3) { $seg.Add((@($pts[$pts.Count-1], $pts[0]))) }
  }
}

$ents = ParseEntities $entS $entE
if ($Def) {
  if (-not $defs.ContainsKey($Def)) { Write-Host "NO DEF $Def"; exit 1 }
  Write-Host ("using def " + $Def + " (entities " + $defs[$Def].Count + ")")
  # wrap def entities as a pseudo top-level list where nested INSERTs resolve
  $ents = $defs[$Def]
}

$stack = New-Object System.Collections.Generic.List[object]
foreach ($e in $ents) { if ($e.type -eq 'INSERT') { $it = @{ e=$e; depth=0; ox=[double]0.0; oy=[double]0.0; ang=[double]0.0; sx=[double]1.0; sy=[double]1.0 }; $stack.Add($it) } }
foreach ($e in $ents) {
  if ($e.type -ne 'INSERT') { AddEntity $e ([double]0.0) ([double]0.0) ([double]0.0) ([double]1.0) ([double]1.0) }
}

$vis = 0
while ($stack.Count -gt 0) {
  $it = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
  $e = $it.e; $d = $it.depth
  if ($d -gt 4) { continue }
  $bn = $e.pts['blk']
  if (-not $defs.ContainsKey($bn)) { continue }
  $ix = [double]0; $iy = [double]0
  if ($e.verts.Count -gt 0) { $ix = [double]$e.verts[0][0]; $iy = [double]$e.verts[0][1] }
  $rot = [double]0; if ($e.pts.ContainsKey('rot')) { $rot = [double]$e.pts['rot'] }
  $sx = [double]1; if ($e.pts.ContainsKey('s1')) { $sx = [double]$e.pts['s1'] }
  $sy = [double]1; if ($e.pts.ContainsKey('s2')) { $sy = [double]$e.pts['s2'] }
  $ox=[double]0; $oy=[double]0
  $rrx=[ref]$ox; $rry=[ref]$oy
  Rot $ix $iy $it.ang $rrx $rry
  $gx = $it.ox + $ox
  $gy = $it.oy + $oy
  $gang = $it.ang + $rot
  $gwx = $it.sx * $sx
  $gwy = $it.sy * $sy
  foreach ($de in $defs[$bn]) {
    AddEntity $de $gx $gy $gang $gwx $gwy
    if ($de.type -eq 'INSERT' -and $d -lt 4) {
      $nit = @{ e=$de; depth=($d+1); ox=$gx; oy=$gy; ang=$gang; sx=$gwx; sy=$gwy }
      $stack.Add($nit)
      $vis++
    }
  }
}
Write-Host ("segments: " + $seg.Count)
if ($seg.Count -eq 0) { Write-Host 'NO SEGMENTS'; exit 1 }

$mnx=1e30; $mny=1e30; $mxx=-1e30; $mxy=-1e30
foreach ($s in $seg) {
  $p0 = $s[0]; $p1 = $s[1]
  if ([double]$p0[0] -lt $mnx) { $mnx=[double]$p0[0] }
  if ([double]$p0[0] -gt $mxx) { $mxx=[double]$p0[0] }
  if ([double]$p1[0] -lt $mnx) { $mnx=[double]$p1[0] }
  if ([double]$p1[0] -gt $mxx) { $mxx=[double]$p1[0] }
  if ([double]$p0[1] -lt $mny) { $mny=[double]$p0[1] }
  if ([double]$p0[1] -gt $mxy) { $mxy=[double]$p0[1] }
  if ([double]$p1[1] -lt $mny) { $mny=[double]$p1[1] }
  if ([double]$p1[1] -gt $mxy) { $mxy=[double]$p1[1] }
}
Write-Host ("bounds X: {0:N1}..{1:N1}  Y: {2:N1}..{3:N1}" -f $mnx,$mxx,$mny,$mxy)
if ($Vx -lt 0) { $Vx=$mnx; $Vy=$mny; $Vw=$mxx-$mnx; $Vh=$mxy-$mny }
if ($Vw -le 0 -or $Vh -le 0) { Write-Host 'BAD VIEW'; exit 1 }

$px = $Px
$py = [int]([double]$Px*$Vh/$Vw)
$bmp = New-Object System.Drawing.Bitmap($px, $py)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160,20,60,180))
$cnt=0
foreach ($s in $seg) {
  $a = $s[0]; $b = $s[1]
  $ax=[double]$a[0]; $ay=[double]$a[1]; $bx=[double]$b[0]; $by=[double]$b[1]
  if (($ax -lt $Vx-1 -and $bx -lt $Vx-1) -or ($ax -gt $Vx+$Vw+1 -and $bx -gt $Vx+$Vw+1)) { continue }
  if (($ay -lt $Vy-1 -and $by -lt $Vy-1) -or ($ay -gt $Vy+$Vh+1 -and $by -gt $Vy+$Vh+1)) { continue }
  $sx1 = [int]((($ax-$Vx)/$Vw)*$px)
  $sy1 = $py - [int]((($ay-$Vy)/$Vh)*$py)
  $sx2 = [int]((($bx-$Vx)/$Vw)*$px)
  $sy2 = $py - [int]((($by-$Vy)/$Vh)*$py)
  $g.DrawLine($pen, $sx1, $sy1, $sx2, $sy2)
  $cnt++
}
Write-Host ("drawn segs: " + $cnt)
$g.Dispose()
$bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host ("WROTE " + $OutPng + " [" + $px + "x" + $py + "]")