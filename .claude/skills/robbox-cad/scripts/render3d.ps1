param(
  [string]$Dxf,
  [string]$OutPng,
  [string]$Proj = 'XY',   # XY=top, XZ=side(front), YZ=side(end)
  [int]$Px = 2200
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

# segments hold 3D points: (x,y,z)
$seg = New-Object System.Collections.Generic.List[object]
function Rot([double]$x, [double]$y, [double]$a, [ref]$ox, [ref]$oy) {
  if ($a -eq 0) { $ox.Value=$x; $oy.Value=$y; return }
  $r = $a*3.14159265358979/180.0
  $ox.Value = $x*[math]::Cos($r) - $y*[math]::Sin($r)
  $oy.Value = $x*[math]::Sin($r) + $y*[math]::Cos($r)
}
function AddEntity($e, [double]$tx, [double]$ty, [double]$tz, [double]$ang, [double]$gsx, [double]$gsy, [double]$gsz) {
  $t = $e.type
  $m = $e.verts.Count
  if ($t -eq 'LINE') { $m = [math]::Min(2, $m) } elseif ($t -eq '3DFACE' -or $t -eq 'SOLID' -or $t -eq 'TRACE') { $m = [math]::Min(4, $m) }
  if ($t -ne 'LINE' -and $t -ne '3DFACE' -and $t -ne 'SOLID' -and $t -ne 'TRACE' -and $t -ne 'LWPOLYLINE' -and $t -ne 'MESH' -and $t -ne 'VERTEX') { return }
  $pts = New-Object System.Collections.Generic.List[object]
  for ($k=0; $k -lt $m; $k++) {
    if ($k -lt $e.verts.Count) {
      $vx = $e.verts[$k][0]
      if (-not [double]::IsNaN($vx)) {
        $vy = $e.verts[$k][1]; if ([double]::IsNaN($vy)) { $vy = 0.0 }
        $vz = $e.verts[$k][2]; if ([double]::IsNaN($vz)) { $vz = 0.0 }
        $ox=[double]0; $oy=[double]0
        Rot $vx $vy $ang ([ref]$ox) ([ref]$oy)
        $wx = $tx + $ox*$gsx
        $wy = $ty + $oy*$gsy
        $wz = $tz + $vz*$gsz
        $pts.Add((@($wx, $wy, $wz)))
      }
    }
  }
  if ($pts.Count -ge 2) {
    for ($k=1; $k -lt $pts.Count; $k++) { $seg.Add((@($pts[$k-1], $pts[$k]))) }
    if ($t -ne 'LINE' -and $t -ne 'LWPOLYLINE' -and $pts.Count -ge 3) { $seg.Add((@($pts[$pts.Count-1], $pts[0]))) }
  }
}

$ents = ParseEntities $entS $entE

$stack = New-Object System.Collections.Generic.List[object]
foreach ($e in $ents) { if ($e.type -eq 'INSERT') { $it = @{ e=$e; depth=0; ox=[double]0.0; oy=[double]0.0; oz=[double]0.0; ang=[double]0.0; sx=1.0; sy=1.0; sz=1.0 }; $stack.Add($it) } }
foreach ($e in $ents) {
  if ($e.type -ne 'INSERT') { AddEntity $e 0.0 0.0 0.0 0.0 1.0 1.0 1.0 }
}

$vis = 0
while ($stack.Count -gt 0) {
  $it = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
  $e = $it.e; $d = $it.depth
  if ($d -gt 6) { continue }
  $bn = $e.pts['blk']
  if (-not $defs.ContainsKey($bn)) { continue }
  $ix = 0.0; $iy = 0.0; $iz = 0.0
  if ($e.verts.Count -gt 0) {
    if ($e.verts[0][0] -ne $null -and -not [double]::IsNaN($e.verts[0][0])) { $ix = [double]$e.verts[0][0] }
    if ($e.verts[0][1] -ne $null -and -not [double]::IsNaN($e.verts[0][1])) { $iy = [double]$e.verts[0][1] }
    if ($e.verts[0][2] -ne $null -and -not [double]::IsNaN($e.verts[0][2])) { $iz = [double]$e.verts[0][2] }
  }
  $rot = [double]0; if ($e.pts.ContainsKey('rot')) { $rot = [double]$e.pts['rot'] }
  $sx = 1.0; if ($e.pts.ContainsKey('s1')) { $sx = [double]$e.pts['s1'] }
  $sy = 1.0; if ($e.pts.ContainsKey('s2')) { $sy = [double]$e.pts['s2'] }
  $sz = 1.0; if ($e.pts.ContainsKey('s3')) { $sz = [double]$e.pts['s3'] }
  $ox=[double]0; $oy=[double]0
  Rot $ix $iy $it.ang ([ref]$ox) ([ref]$oy)
  $gx = $it.ox + $ox
  $gy = $it.oy + $oy
  $gz = $it.oz + $iz*$it.sz
  $gang = $it.ang + $rot
  $gwx = $it.sx * $sx
  $gwy = $it.sy * $sy
  $gwz = $it.sz * $sz
  foreach ($de in $defs[$bn]) {
    AddEntity $de $gx $gy $gz $gang $gwx $gwy $gwz
    if ($de.type -eq 'INSERT' -and $d -lt 6) {
      $nit = @{ e=$de; depth=($d+1); ox=$gx; oy=$gy; oz=$gz; ang=$gang; sx=$gwx; sy=$gwy; sz=$gwz }
      $stack.Add($nit)
      $vis++
    }
  }
}
Write-Host ("segments: " + $seg.Count)
if ($seg.Count -eq 0) { Write-Host 'NO SEGMENTS'; exit 1 }

$mnx=1e30; $mny=1e30; $mnz=1e30; $mxx=-1e30; $mxy=-1e30; $mxz=-1e30
foreach ($s in $seg) {
  foreach ($p in @($s[0], $s[1])) {
    if ([double]$p[0] -lt $mnx) { $mnx=[double]$p[0] }
    if ([double]$p[0] -gt $mxx) { $mxx=[double]$p[0] }
    if ([double]$p[1] -lt $mny) { $mny=[double]$p[1] }
    if ([double]$p[1] -gt $mxy) { $mxy=[double]$p[1] }
    if ([double]$p[2] -lt $mnz) { $mnz=[double]$p[2] }
    if ([double]$p[2] -gt $mxz) { $mxz=[double]$p[2] }
  }
}
Write-Host ("bounds X: {0:N1}..{1:N1}  Y: {2:N1}..{3:N1}  Z: {4:N1}..{5:N1}" -f $mnx,$mxx,$mny,$mxy,$mnz,$mxz)

if ($Proj -eq 'XZ') { $u0=$mnx; $u1=$mxx; $v0=$mnz; $v1=$mxz; $getu={ param($p) [double]$p[0] }; $getv={ param($p) [double]$p[2] } }
elseif ($Proj -eq 'YZ') { $u0=$mny; $u1=$mxy; $v0=$mnz; $v1=$mxz; $getu={ param($p) [double]$p[1] }; $getv={ param($p) [double]$p[2] } }
else { $u0=$mnx; $u1=$mxx; $v0=$mny; $v1=$mxy; $getu={ param($p) [double]$p[0] }; $getv={ param($p) [double]$p[1] } }

$Vw = $u1-$u0; $Vh = $v1-$v0
if ($Vw -le 0 -or $Vh -le 0) { Write-Host 'BAD VIEW'; exit 1 }

$px = $Px
$py = [int][math]::Max(1,[double]$Px*$Vh/$Vw)
$bmp = New-Object System.Drawing.Bitmap($px, $py)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,20,60,180))
$cnt=0
foreach ($s in $seg) {
  $a = $s[0]; $b = $s[1]
  $au = & $getu $a; $bv = & $getv $a
  $bu = & $getu $b; $bv2 = & $getv $b
  $sx1 = [int]((($au-$u0)/$Vw)*$px)
  $sy1 = $py - [int]((($bv-$v0)/$Vh)*$py)
  $sx2 = [int]((($bu-$u0)/$Vw)*$px)
  $sy2 = $py - [int]((($bv2-$v0)/$Vh)*$py)
  $g.DrawLine($pen, $sx1, $sy1, $sx2, $sy2)
  $cnt++
}
Write-Host ("drawn segs: " + $cnt)
$g.Dispose()
$bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host ("WROTE " + $OutPng + " [" + $px + "x" + $py + "]")