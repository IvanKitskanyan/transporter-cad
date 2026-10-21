param(
  [string]$Dxf,
  [string]$Out,
  [int]$MaxDepth = 8
)
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$L = [System.IO.File]::ReadAllLines($Dxf, [System.Text.Encoding]::GetEncoding(1251))
$n = $L.Length
$sw = New-Object System.IO.StreamWriter($Out, $false, (New-Object System.Text.UTF8Encoding($false)))
function RW($s) { $sw.WriteLine([string]$s); $sw.Flush() }
function P2V($s) { $d=0.0; if([double]::TryParse($s,[System.Globalization.NumberStyles]::Float,$inv,[ref]$d)){$d}else{0.0} }

# ---- locate sections ----
$secS=@{}; $secE=@{}; $cur=$null
for ($i=0; $i -lt $n-1; $i+=2) {
  $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
  if ($c -eq '0' -and $v -eq 'SECTION') { $secS[$L[$i+3].Trim()]=$i; $cur=$L[$i+3].Trim() }
  if ($c -eq '0' -and $v -eq 'ENDSEC') { if($cur){$secE[$cur]=$i; $cur=$null} }
}

# ---- header info ----
RW ("FILE: " + $Dxf)
$i0 = $secS['HEADER']; $i1 = $secE['HEADER']
$hdr = @{}
$i = $i0
while ($i -lt $i1-1) {
  if ($L[$i].Trim() -eq '9') {
    $key = $L[$i+1].Trim()
    # gather up to 3 following value lines (10,20,30 etc.)
    $vals=@(); $j=$i+2
    while ($j -lt $i1-1 -and $vals.Count -lt 3 -and $L[$j].Trim() -ne '9' -and $L[$j].Trim() -ne '0') { $vals += $L[$j+1].Trim(); $j+=2 }
    if ($key -match 'INSBASE|EXTMIN|EXTMAX') { $hdr[$key] = ($vals -join ' | ') }
    $i = $j
  } else { $i+=2 }
}
foreach ($k in @('$ACADVER','$INSBASE','$EXTMIN','$EXTMAX')) {
  if ($hdr.ContainsKey($k)) { RW ("HDR " + $k + " = " + $hdr[$k]) }
}

# ---- entity parser: extracts type, verts (x,y,z rows), and key params ----
function ParseEntities($from, $to) {
  $list = New-Object System.Collections.Generic.List[object]
  $i = $from
  $rec = $null
  while ($i -lt $to) {
    $c = $L[$i].Trim(); $v = $L[$i+1].Trim()
    if ($c -eq '0') {
      if ($v -eq 'ENDBLK' -or $v -eq 'SEQEND') { $rec=$null; $i+=2; continue }
      if ($v -eq 'VERTEX') { if ($rec -ne $null -and $rec.type -eq 'POLYLINE') { $i += 2; continue } } # vertex handled inline below
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
        } elseif ($rec.type -eq 'POLYLINE' -and $c -notin @('10')) {
          # skip
        } else {
          while ($rec.verts.Count -le $idx) {
            $row = @([double]::NaN, [double]::NaN, [double]::NaN)
            $rec.verts += ,$row
          }
          $rec.verts[$idx][$axis] = $d
        }
      } elseif ($c -eq '10' -and $rec.type -eq 'POLYLINE') {
        # polyline header point
        $rec.pts['ph'] = (P2V $L[$i+1])
      } elseif ($c -match '^2[0-3]$') {
        $d = (P2V $v)
        $idx = [int]$c.Substring(1)
        if ($rec.type -eq 'POLYLINE') {
          $rec.pts['ph'+$idx] = $d
        }
      } else {
        switch ($c) {
          '50' { $rec.pts['rot'] = (P2V $v) }
          '41' { $rec.pts['s1'] = (P2V $v) }
          '42' { $rec.pts['s2'] = (P2V $v) }
          '43' { $rec.pts['s3'] = (P2V $v) }
          '38' { $rec.pts['elev'] = (P2V $v) }
          '210' { $rec.pts['nx'] = (P2V $v) }
          '220' { $rec.pts['ny'] = (P2V $v) }
          '230' { $rec.pts['nz'] = (P2V $v) }
          '2'  { if ($rec.type -eq 'INSERT' -and -not $rec.pts.ContainsKey('blk')) { $rec.pts['blk']=$v } }
        }
      }
    }
    $i += 2
  }
  return ,$list
}

# ---- block defs: name -> base point + entity list ----
$defs = @{}
$bases = @{}
$i = $secS['BLOCKS']
$blkE = $secE['BLOCKS']
while ($i -lt $blkE-2) {
  $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
  if ($c -eq '0' -and $v -eq 'BLOCK') {
    $j=$i+2; $bn=''; $bx=0.0; $by=0.0; $bz=0.0
    $gotBase=$false
    while ($j -lt $blkE-2) {
      $cc=$L[$j].Trim(); $vv=$L[$j+1].Trim()
      if ($cc -eq '0') { break }
      if ($cc -eq '2' -and $bn -eq '') { $bn=$vv }
      if ($cc -eq '10' -and -not $gotBase) { $bx = P2V $vv; $gotBase=$true }
      if ($cc -eq '20' -and $gotBase -and $by -eq 0.0) { $by = P2V $vv }
      if ($cc -eq '30' -and $gotBase -and $bz -eq 0.0) { $bz = P2V $vv }
      $j+=2
    }
    $k=$j; $end=$blkE
    while ($k -lt $blkE-2) {
      $kc=$L[$k].Trim()
      if ($kc -eq '0') { $kv=$L[$k+1].Trim(); if ($kv -eq 'ENDBLK' -or $kv -eq 'BLOCK') { $end=$k; break } }
      $k+=2
    }
    if ($bn) { $defs[$bn] = ParseEntities $j $end; $bases[$bn] = @($bx,$by,$bz) }
    $i=$end
  } else { $i+=2 }
}
RW ("blockdefs: " + $defs.Count)

# ---- resolve world segments (3D) recursively ----
$seg = New-Object System.Collections.Generic.List[object]
$segEnt = @{}
function Rot([double]$x, [double]$y, [double]$a, [ref]$ox, [ref]$oy) {
  if ($a -eq 0) { $ox.Value=$x; $oy.Value=$y; return }
  $r = $a*3.14159265358979/180.0
  $ox.Value = $x*[math]::Cos($r) - $y*[math]::Sin($r)
  $oy.Value = $x*[math]::Sin($r) + $y*[math]::Cos($r)
}
# transform chain: each frame has tx,ty,tz, ang (rad), sx,sy,sz
function ApplyPt($pt, $fr) {
  $x = [double]$pt[0]*[double]$fr.sx; $y=[double]$pt[1]*[double]$fr.sy; $z=[double]$pt[2]*[double]$fr.sz
  $ox=[double]0; $oy=[double]0
  Rot $x $y ([double]$fr.ang) ([ref]$ox) ([ref]$oy)
  return @(([double]$fr.tx+$ox), ([double]$fr.ty+$oy), ([double]$fr.tz+$z))
}
function AddEntity3D($e, $fr) {
  $t = $e.type
  $m = $e.verts.Count
  if ($t -eq 'LINE') { $m = [math]::Min(2, $m) } elseif ($t -eq '3DFACE' -or $t -eq 'SOLID' -or $t -eq 'TRACE') { $m = [math]::Min(4, $m) }
  if ($t -ne 'LINE' -and $t -ne '3DFACE' -and $t -ne 'SOLID' -and $t -ne 'TRACE' -and $t -ne 'LWPOLYLINE' -and $t -ne 'MESH' -and $t -ne 'POLYLINE' -and $t -ne 'POINT' -and $t -ne 'VERTEX') { return }
  $pts = New-Object System.Collections.Generic.List[object]
  for ($k=0; $k -lt $m; $k++) {
    if ($k -lt $e.verts.Count) {
      $vx = $e.verts[$k][0]
      if (-not [double]::IsNaN($vx)) {
        $vy = $e.verts[$k][1]; if ([double]::IsNaN($vy)) { $vy=0.0 }
        $vz = $e.verts[$k][2]; if ([double]::IsNaN($vz)) { $vz=0.0 }
        if ($e.pts.ContainsKey('elev') -and $t -ne 'LWPOLYLINE') { $vz = [double]$e.pts['elev'] }
        $pts.Add((ApplyPt @($vx,$vy,$vz) $fr))
      }
    }
  }
  if ($pts.Count -ge 2) {
    for ($k=1; $k -lt $pts.Count; $k++) { $script:seg.Add((@($pts[$k-1], $pts[$k]))) }
    if ($t -ne 'LINE' -and $t -ne 'LWPOLYLINE' -and $t -ne 'POLYLINE' -and $pts.Count -ge 3) { $script:seg.Add((@($pts[$pts.Count-1], $pts[0]))) }
  }
}
function WalkBlock($bn, $fr, [int]$depth, $outList) {
  if (-not $defs.ContainsKey($bn)) { return }
  $base = $bases[$bn]
  foreach ($de in $defs[$bn]) {
    if ($de.type -eq 'INSERT') {
      $cn = $de.pts['blk']
      $ix=0.0; $iy=0.0; $iz=0.0
      if ($de.verts.Count -gt 0) {
        if ($de.verts[0][0] -ne $null -and -not [double]::IsNaN($de.verts[0][0])) { $ix=$de.verts[0][0] }
        if ($de.verts[0][1] -ne $null -and -not [double]::IsNaN($de.verts[0][1])) { $iy=$de.verts[0][1] }
        if ($de.verts[0][2] -ne $null -and -not [double]::IsNaN($de.verts[0][2])) { $iz=$de.verts[0][2] }
      }
      $s1=1.0; if ($de.pts.ContainsKey('s1')) { $s1=[double]$de.pts['s1'] }
      $s2=1.0; if ($de.pts.ContainsKey('s2')) { $s2=[double]$de.pts['s2'] }
      $s3=1.0; if ($de.pts.ContainsKey('s3')) { $s3=[double]$de.pts['s3'] }
      $rotd = 0.0; if ($de.pts.ContainsKey('rot')) { $rotd=[double]$de.pts['rot'] }
      $lp = ApplyPt @($ix,$iy,$iz) $fr   # insert point in frame space
      # minus base: world_child = fr( (ins + R(rot)*S*(pt-base)) )  => we create child frame:
      $ox=[double]0; $oy=[double]0
      Rot ($ix*[double]$fr.sx) ($iy*[double]$fr.sy) ([double]$fr.ang) ([ref]$ox) ([ref]$oy)
      $cang = [double]$fr.ang + $rotd*3.14159265358979/180.0
      $cf = @{ tx = [double]$fr.tx + $ox; ty = [double]$fr.ty + $oy; tz = [double]$fr.tz + $iz*[double]$fr.sz;
               ang = $cang; sx = [double]$fr.sx*$s1; sy = [double]$fr.sy*$s2; sz = [double]$fr.sz*$s3 }
      # block base offset: child frame coordinates measured from base
      $bo = ApplyPt @(-$base[0],-$base[1],-$base[2]) $cf
      $cf2 = @{ tx = $bo[0]; ty = $bo[1]; tz = $bo[2]; ang = 0.0; sx=$cf.sx; sy=$cf.sy; sz=$cf.sz }
      if ($depth -ge $MaxDepth) { return }
      WalkBlock $cn $cf2 ($depth+1) $outList
    } else {
      AddEntity3D $de $fr
    }
  }
}

$entS = $secS['ENTITIES']; $entE = if($secE.ContainsKey('ENTITIES')){$secE['ENTITIES']}else{$n}
$ents = ParseEntities $entS $entE
RW ("modelspace top-level entities: " + $ents.Count)

# top-level listing + per-insert world bbox
# group segments by top-level index: process one at a time
for ($idx=0; $idx -lt $ents.Count; $idx++) {
  $e = $ents[$idx]
  if ($e.type -eq 'INSERT') {
    $cn = $e.pts['blk']
    $ix=0.0; $iy=0.0; $iz=0.0
    if ($e.verts.Count -gt 0 -and -not [double]::IsNaN($e.verts[0][0])) {
      $ix=$e.verts[0][0]; $iy=$e.verts[0][1]; if ([double]::IsNaN($e.verts[0][2])) { $vz=0.0 } else { $vz=$e.verts[0][2] }; $iz=$vz
    }
    $s1=1.0; if ($e.pts.ContainsKey('s1')) { $s1=[double]$e.pts['s1'] }
    $s2=1.0; if ($e.pts.ContainsKey('s2')) { $s2=[double]$e.pts['s2'] }
    $s3=1.0; if ($e.pts.ContainsKey('s3')) { $s3=[double]$e.pts['s3'] }
    $rotd=0.0; if ($e.pts.ContainsKey('rot')) { $rotd=[double]$e.pts['rot'] }
    $fr = @{ tx=$ix; ty=$iy; tz=$iz; ang=$rotd*3.14159265358979/180.0; sx=$s1; sy=$s2; sz=$s3 }
    $base = if ($bases.ContainsKey($cn)) { $bases[$cn] } else { @(0.0,0.0,0.0) }
    $fr = @{ tx=$ix; ty=$iy; tz=$iz; ang=$rotd*3.14159265358979/180.0; sx=$s1; sy=$s2; sz=$s3 }
    # world position of child origin (with base subtraction baked in via cf2 translation):
    $bfr = @{ tx = $fr.tx; ty = $fr.ty; tz = $fr.tz; ang = $fr.ang; sx = $fr.sx; sy = $fr.sy; sz = $fr.sz }
    $script:seg = New-Object System.Collections.Generic.List[object]
    $before=$script:seg.Count
    WalkBlock $cn @($false) 0 @() # placeholder to avoid stale call - real walk below
    # NOTE: real walk with base-offset frame:
    $script:seg = New-Object System.Collections.Generic.List[object]
    function Dummy {}
    # compute effective frame with base compensation:
    $ox=[double]0; $oy=[double]0
    Rot (-[double]$base[0]*$s1) (-[double]$base[1]*$s2) $fr.ang ([ref]$ox) ([ref]$oy)
    $frB = @{ tx = $fr.tx + $ox; ty = $fr.ty + $oy; tz = $fr.tz - $base[2]*$s3; ang = 0.0; sx=$s1; sy=$s2; sz=$s3 }
    $savedEnts = $ents
    WalkBlockDirect $cn $frB 0
    $script:ents = $savedEnts
    $mn=@(1e30,1e30,1e30); $mx=@(-1e30,-1e30,-1e30)
    foreach ($s in $script:seg) { foreach ($p in @($s[0],$s[1])) { for ($a=0;$a -lt 3;$a++) { if ([double]$p[$a] -lt [double]$mn[$a]) { $mn[$a]=[double]$p[$a] }; if ([double]$p[$a] -gt [double]$mx[$a]) { $mx[$a]=[double]$p[$a] } } } }
    $insStr = " ins=(" + [math]::Round($ix,2) + "," + [math]::Round($iy,2) + "," + [math]::Round($iz,2) + ") rot=" + [math]::Round($rotd,1) + " s=(" + [math]::Round($s1,3) + "," + [math]::Round($s2,3) + "," + [math]::Round($s3,3) + ")"
    if ($script:seg.Count -eq 0) {
      RW ("[" + $idx + "] INSERT '" + $cn + "'" + $insStr + "  BBOX: no drawn geometry resolved")
    } else {
      RW ("[" + $idx + "] INSERT '" + $cn + "'" + $insStr + "  segs=" + $script:seg.Count + " BBOX (" + [math]::Round($mn[0],2) + "," + [math]::Round($mn[1],2) + "," + [math]::Round($mn[2],2) + ") .. (" + [math]::Round($mx[0],2) + "," + [math]::Round($mx[1],2) + "," + [math]::Round($mx[2],2) + ") SIZE (" + [math]::Round($mx[0]-$mn[0],2) + "," + [math]::Round($mx[1]-$mn[1],2) + "," + [math]::Round($mx[2]-$mn[2],2) + ")")
    }
  } else {
    $script:seg = New-Object System.Collections.Generic.List[object]
    $fr0 = @{ tx=0.0; ty=0.0; tz=0.0; ang=0.0; sx=1.0; sy=1.0; sz=1.0 }
    AddEntity3D $e $fr0
    if ($script:seg.Count -gt 0) {
      $mn=@(1e30,1e30,1e30); $mx=@(-1e30,-1e30,-1e30)
      foreach ($s in $script:seg) { foreach ($p in @($s[0],$s[1])) { for ($a=0;$a -lt 3;$a++) { if ([double]$p[$a] -lt [double]$mn[$a]) { $mn[$a]=[double]$p[$a] }; if ([double]$p[$a] -gt [double]$mx[$a]) { $mx[$a]=[double]$p[$a] } } } }
      RW ("[" + $idx + "] " + $e.type + "  segs=" + $script:seg.Count + " BBOX (" + [math]::Round($mn[0],2) + "," + [math]::Round($mn[1],2) + "," + [math]::Round($mn[2],2) + ") .. (" + [math]::Round($mx[0],2) + "," + [math]::Round($mx[1],2) + "," + [math]::Round($mx[2],2) + ") SIZE (" + [math]::Round($mx[0]-$mn[0],2) + "," + [math]::Round($mx[1]-$mn[1],2) + "," + [math]::Round($mx[2]-$mn[2],2) + ")")
    } else {
      RW ("[" + $idx + "] " + $e.type + "  (no drawable geometry)")
    }
  }
}
$sw.Close()
Write-Host "ANALYZE-DONE"