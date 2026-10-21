param(
  [string]$Dxf,
  [string]$Out
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
if ($secS.ContainsKey('HEADER')) {
  $i0 = $secS['HEADER']; $i1 = $secE['HEADER']
  $i = $i0
  while ($i -lt $i1-1) {
    if ($L[$i].Trim() -eq '9') {
      $key = $L[$i+1].Trim()
      if ($key -match '^\$(ACADVER|INSBASE|EXTMIN|EXTMAX)$') {
        $vals=@(); $j=$i+2
        while ($j -lt $i1-1 -and $vals.Count -lt 3 -and $L[$j].Trim() -ne '9' -and $L[$j].Trim() -ne '0') { $vals += $L[$j+1].Trim(); $j+=2 }
        RW ("HDR " + $key + " = " + ($vals -join ' | '))
        $i = $j; continue
      }
    }
    $i+=2
  }
}

# ---- entity parser ----
function ParseEntities($from, $to) {
  $list = New-Object System.Collections.Generic.List[object]
  $i = $from
  $rec = $null
  while ($i -lt $to) {
    $c = $L[$i].Trim(); $v = $L[$i+1].Trim()
    if ($c -eq '0') {
      if ($v -eq 'ENDBLK' -or $v -eq 'SEQEND') { $rec = $null; $i+=2; continue }
      if ($v -eq 'VERTEX' -and $rec -ne $null -and $rec.type -eq 'POLYLINE') {
        # add vertex point to the polyline record
        $x=[double]::NaN; $y=[double]::NaN; $z=[double]::NaN
        $j=$i+2
        while ($j -lt $to) {
          $cc=$L[$j].Trim(); $vv=$L[$j+1].Trim()
          if ($cc -eq '0') { break }
          if ($cc -eq '10') { $x=P2V $vv } elseif ($cc -eq '20') { $y=P2V $vv } elseif ($cc -eq '30') { $z=P2V $vv }
          $j+=2
        }
        if (-not [double]::IsNaN($x)) { $rec.verts += ,@($x,$y,$z) }
        $i = $j; continue
      }
      if ($v -eq 'VERTEX') { $i+=2; continue }
      $rec = @{ type=$v; verts=@(); pts=@{}; ptidx=-1 }
      $list.Add($rec)
      $i += 2; continue
    }
    if ($rec -ne $null) {
      if ($c -match '^[123][0-3]$') {
        $d = (P2V $v)
        $axis = [int]$c.Substring(0,1) - 1
        $idx = [int]$c.Substring(1)
        if (($rec.type -eq 'LWPOLYLINE') -and $axis -eq 0) {
          $row = @($d, [double]::NaN, 0.0)
          $rec.verts += ,$row
        } elseif (($rec.type -eq 'LWPOLYLINE') -and $axis -eq 1) {
          if ($rec.verts.Count -gt 0) { $last = $rec.verts[$rec.verts.Count-1]; $last[1] = $d }
        } else {
          while ($rec.verts.Count -le $idx) {
            $row = @([double]::NaN, [double]::NaN, [double]::NaN)
            $rec.verts += ,$row
          }
          $rec.verts[$idx][$axis] = $d
        }
      } elseif ($c -eq '10') {
        $rec.pts['x0'] = (P2V $v)
      } elseif ($c -eq '20') {
        $rec.pts['y0'] = (P2V $v)
      } elseif ($c -eq '30') {
        $rec.pts['z0'] = (P2V $v)
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

# ---- block defs: name -> @{ base; ents } ----
$defs = @{}
$i = $secS['BLOCKS']; $blkE = $secE['BLOCKS']
while ($i -lt $blkE-2) {
  $c=$L[$i].Trim(); $v=$L[$i+1].Trim()
  if ($c -eq '0' -and $v -eq 'BLOCK') {
    $j=$i+2; $bn=''; $bx=0.0; $by=0.0; $bz=0.0
    while ($j -lt $blkE-2) {
      $cc=$L[$j].Trim(); $vv=$L[$j+1].Trim()
      if ($cc -eq '0') { break }
      if ($cc -eq '2' -and $bn -eq '') { $bn=$vv }
      if ($cc -eq '10' -and $bn -ne '' -and $bx -eq 0.0) { $bx = P2V $vv }
      if ($cc -eq '20' -and $bn -ne '' -and $by -eq 0.0) { $by = P2V $vv }
      if ($cc -eq '30' -and $bn -ne '' -and $bz -eq 0.0) { $bz = P2V $vv }
      $j+=2
    }
    if ($bn -eq $null -or $bn -eq '') { $i=$j; continue }
    $k=$j; $end=$blkE
    while ($k -lt $blkE-2) {
      $kc=$L[$k].Trim()
      if ($kc -eq '0') { $kv=$L[$k+1].Trim(); if ($kv -eq 'ENDBLK' -or $kv -eq 'BLOCK') { $end=$k; break } }
      $k+=2
    }
    $defs[$bn] = @{ base=@($bx,$by,$bz); ents=(ParseEntities $j $end) }
    $i=$end
  } else { $i+=2 }
}
RW ("blockdefs: " + $defs.Count)

# ---- geometry primitives -> segment list in block-local space ----
function AddLocal($de, $list) {
  $t = $de.type
  if ($t -eq 'INSERT' -or $t -eq 'VERTEX') { return }
  $m = $de.verts.Count
  if ($t -eq 'LINE') { $m = [math]::Min(2,$m) } elseif ($t -eq '3DFACE' -or $t -eq 'SOLID' -or $t -eq 'TRACE') { $m = [math]::Min(4,$m) }
  if ($t -ne 'LINE' -and $t -ne '3DFACE' -and $t -ne 'SOLID' -and $t -ne 'TRACE' -and $t -ne 'LWPOLYLINE' -and $t -ne 'MESH' -and $t -ne 'POLYLINE' -and $t -ne 'POINT') { return }
  $pts = New-Object System.Collections.Generic.List[object]
  $elev = 0.0; if ($de.pts.ContainsKey('elev')) { $elev = [double]$de.pts['elev'] }
  for ($k=0; $k -lt $m; $k++) {
    if ($k -lt $de.verts.Count) {
      $vx = $de.verts[$k][0]
      if ([double]::IsNaN($vx)) {
        if ($t -eq 'POINT' -and $de.pts.ContainsKey('x0')) { $vx = [double]$de.pts['x0'] } else { continue }
      }
      $vy = $de.verts[$k][1]; if ([double]::IsNaN($vy)) { $vy = 0.0 }
      $vz = $de.verts[$k][2]; if ([double]::IsNaN($vz)) { $vz = $elev }
      $pts.Add(@($vx,$vy,$vz))
    }
  }
  if ($pts.Count -ge 2) {
    for ($k=1; $k -lt $pts.Count; $k++) { $list.Add(@($pts[$k-1], $pts[$k])) }
    if ($t -eq '3DFACE' -or $t -eq 'SOLID' -or $t -eq 'TRACE') { $list.Add(@($pts[$pts.Count-1], $pts[0])) }
  } elseif ($pts.Count -eq 1 -and $t -eq 'POINT') {
    $list.Add(@($pts[0], $pts[0]))
  }
}

# transform: p (local of child) -> parent space:
#   v = (p - base_child); v = v*S; v = R(rot)*v; v = v + ins
# rotation angle in radians
function XformPt($p, $tr) {
  $x = ([double]$p[0] - [double]$tr.base[0]) * [double]$tr.sx
  $y = ([double]$p[1] - [double]$tr.base[1]) * [double]$tr.sy
  $z = ([double]$p[2] - [double]$tr.base[2]) * [double]$tr.sz
  $a = [double]$tr.rot
  $ox = $x*$tr.ca - $y*$tr.sa
  $oy = $x*$tr.sa + $y*$tr.ca
  return @(([double]$tr.tx + $ox), ([double]$tr.ty + $oy), ([double]$tr.tz + $z))
}

# get local bbox of block (memoized): returns @(@minx,miny,minz, maxx,maxy,maxz) plus slope info null
$lb = @{}
function GetLocalBox($bn, [int]$depth) {
  if ($lb.ContainsKey($bn)) { return $lb[$bn] }
  if ($depth -gt 10) { return $null }
  if (-not $defs.ContainsKey($bn)) { return $null }
  $mnx=1e30; $mny=1e30; $mnz=1e30; $mxx=-1e30; $mxy=-1e30; $mxz=-1e30
  $found = $false
  foreach ($de in $defs[$bn].ents) {
    if ($de.type -eq 'INSERT') {
      $cn = $de.pts['blk']
      $cb = GetLocalBox $cn ($depth+1)
      if ($cb -ne $null) {
        $ix=0.0; $iy=0.0; $iz=0.0
        if ($de.verts.Count -gt 0 -and -not [double]::IsNaN($de.verts[0][0])) { $ix=$de.verts[0][0]; $iy=$de.verts[0][1]; $iz=$de.verts[0][2] }
        elseif ($de.pts.ContainsKey('x0')) { $ix=[double]$de.pts['x0']; $iy=[double]$de.pts['y0']; $iz=[double]$de.pts['z0'] }
        $s1=1.0; if ($de.pts.ContainsKey('s1')) { $s1=[double]$de.pts['s1'] }
        $s2=1.0; if ($de.pts.ContainsKey('s2')) { $s2=[double]$de.pts['s2'] }
        $s3=1.0; if ($de.pts.ContainsKey('s3')) { $s3=[double]$de.pts['s3'] }
        $r=0.0; if ($de.pts.ContainsKey('rot')) { $r=[double]$de.pts['rot'] }
        $a = $r*3.14159265358979/180.0
        $tr = @{ base=(,@(0.0,0.0,0.0)); tx=$ix; ty=$iy; tz=$iz; sx=$s1; sy=$s2; sz=$s3; rot=$a; ca=[math]::Cos($a); sa=[math]::Sin($a) }
        # transform 8 corners
        foreach ($cx in @($cb[0],$cb[3])) { foreach ($cy in @($cb[1],$cb[4])) { foreach ($cz in @($cb[2],$cb[5])) {
          $w = XformPt @([double]$cx,[double]$cy,[double]$cz) $tr
          if ([double]$w[0] -lt $mnx) {$mnx=[double]$w[0]}; if ([double]$w[0] -gt $mxx) {$mxx=[double]$w[0]}
          if ([double]$w[1] -lt $mny) {$mny=[double]$w[1]}; if ([double]$w[1] -gt $mxy) {$mxy=[double]$w[1]}
          if ([double]$w[2] -lt $mnz) {$mnz=[double]$w[2]}; if ([double]$w[2] -gt $mxz) {$mxz=[double]$w[2]}
        } } }
        $found = $true
      }
    } else {
      $segs = New-Object System.Collections.Generic.List[object]
      AddLocal $de $segs
      foreach ($s in $segs) { foreach ($p in $s) {
        if ([double]$p[0] -lt $mnx) {$mnx=[double]$p[0]}; if ([double]$p[0] -gt $mxx) {$mxx=[double]$p[0]}
        if ([double]$p[1] -lt $mny) {$mny=[double]$p[1]}; if ([double]$p[1] -gt $mxy) {$mxy=[double]$p[1]}
        if ([double]$p[2] -lt $mnz) {$mnz=[double]$p[2]}; if ([double]$p[2] -gt $mxz) {$mxz=[double]$p[2]}
      } }
      if ($segs.Count -gt 0) { $found = $true }
    }
  }
  if (-not $found) { return $null }
  $box = @($mnx,$mny,$mnz,$mxx,$mxy,$mxz)
  $lb[$bn] = $box
  return ,$box
}

# ---- top-level modelspace ----
$entS = $secS['ENTITIES']; $entE = if($secE.ContainsKey('ENTITIES')){$secE['ENTITIES']}else{$n}
$ents = ParseEntities $entS $entE
RW ("modelspace top-level entities: " + $ents.Count)

function XformBox($box, $tr) {
  $mn=@(1e30,1e30,1e30); $mx=@(-1e30,-1e30,-1e30)
  foreach ($cx in @($box[0],$box[3])) { foreach ($cy in @($box[1],$box[4])) { foreach ($cz in @($box[2],$box[5])) {
    $w = XformPt @([double]$cx,[double]$cy,[double]$cz) $tr
    for ($a=0;$a -lt 3;$a++) { if ([double]$w[$a] -lt [double]$mn[$a]) { $mn[$a]=[double]$w[$a] }; if ([double]$w[$a] -gt [double]$mx[$a]) { $mx[$a]=[double]$w[$a] } }
  } } }
  return ,(@($mn[0],$mn[1],$mn[2],$mx[0],$mx[1],$mx[2]))
}

$idx=-1
foreach ($e in $ents) {
  $idx++
  if ($e.type -eq 'INSERT') {
    $cn = $e.pts['blk']
    $s1=1.0; if ($e.pts.ContainsKey('s1')) { $s1=[double]$e.pts['s1'] }
    $s2=1.0; if ($e.pts.ContainsKey('s2')) { $s2=[double]$e.pts['s2'] }
    $s3=1.0; if ($e.pts.ContainsKey('s3')) { $s3=[double]$e.pts['s3'] }
    $r=0.0; if ($e.pts.ContainsKey('rot')) { $r=[double]$e.pts['rot'] }
    $a = $r*3.14159265358979/180.0
    if (-not $defs.ContainsKey($cn)) { RW ("[" + $idx + "] INSERT '" + $cn + "' - block def NOT FOUND (external)"); continue }
    $ix0=0.0; $iy0=0.0; $iz0=0.0
    if ($e.pts.ContainsKey('x0')) { $ix0=[double]$e.pts['x0']; $iy0=[double]$e.pts['y0']; $iz0=[double]$e.pts['z0'] }
    $base = $defs[$cn].base
    $tr = @{ base=$base; tx=$ix0; ty=$iy0; tz=$iz0; sx=$s1; sy=$s2; sz=$s3; rot=$a; ca=[math]::Cos($a); sa=[math]::Sin($a) }
    # world point of block-local origin (p=0)
    $w0 = XformPt @(0.0,0.0,0.0) $tr
    $cbox = GetLocalBox $cn 0
    if ($cbox -eq $null) { RW ("[" + $idx + "] INSERT '" + $cn + "' - no geometry"); continue }
    $cb = $defs[$cn].base
    $tr2 = @{ base=$cb; tx=$w0[0]; ty=$w0[1]; tz=$w0[2]; sx=$s1; sy=$s2; sz=$s3; rot=$a; ca=[math]::Cos($a); sa=[math]::Sin($a) }
    $wb = XformBox $cbox $tr2
    $insStr = " ins=(" + [math]::Round($ix0,3) + "," + [math]::Round($iy0,3) + "," + [math]::Round($iz0,3) + ")"
    RW ("[" + $idx + "] INSERT '" + $cn + "' rot=" + [math]::Round($r,2) + " s=(" + [math]::Round($s1,4) + "," + [math]::Round($s2,4) + "," + [math]::Round($s3,4) + ") origin=(" + [math]::Round($w0[0],2) + "," + [math]::Round($w0[1],2) + "," + [math]::Round($w0[2],2) + ")")
    RW ("       BBOX (" + [math]::Round($wb[0],2) + "," + [math]::Round($wb[1],2) + "," + [math]::Round($wb[2],2) + ") .. (" + [math]::Round($wb[3],2) + "," + [math]::Round($wb[4],2) + "," + [math]::Round($wb[5],2) + ")  SIZE (" + [math]::Round($wb[3]-$wb[0],2) + "," + [math]::Round($wb[4]-$wb[1],2) + "," + [math]::Round($wb[5]-$wb[2],2) + ")")
    # end-Z info: sample block-local corners along its longest axis
    $dx=[double]$cbox[3]-$cbox[0]; $dy=[double]$cbox[4]-$cbox[1]; $dz=[double]$cbox[5]-$cbox[2]
    if ($dx -ge $dy -and $dx -ge $dz) { $u0=$cbox[0]; $u1=$cbox[3]; $mv=($cbox[1]+$cbox[4])/2.0; $mz=($cbox[2]+$cbox[5])/2.0; $p0=@($u0,$mv,$mz); $p1=@($u1,$mv,$mz); $axis='X' }
    elseif ($dy -ge $dz) { $u0=$cbox[1]; $u1=$cbox[4]; $mv=($cbox[0]+$cbox[3])/2.0; $mz=($cbox[2]+$cbox[5])/2.0; $p0=@($mv,$u0,$mz); $p1=@($mv,$u1,$mz); $axis='Y' }
    else { $u0=$cbox[2]; $u1=$cbox[5]; $mv=($cbox[0]+$cbox[3])/2.0; $mv2=($cbox[1]+$cbox[4])/2.0; $p0=@($mv,$mv2,$u0); $p1=@($mv,$mv2,$u1); $axis='Z' }
    $wA = XformPt $p0 $tr2; $wB = XformPt $p1 $tr2
    RW ("       along " + $axis + ": end1 (" + [math]::Round($wA[0],1) + "," + [math]::Round($wA[1],1) + "," + [math]::Round($wA[2],1) + ")  end2 (" + [math]::Round($wB[0],1) + "," + [math]::Round($wB[1],1) + "," + [math]::Round($wB[2],1) + ")")
  } else {
    $segs = New-Object System.Collections.Generic.List[object]
    AddLocal $e $segs
    if ($segs.Count -gt 0) {
      $mn=@(1e30,1e30,1e30); $mx=@(-1e30,-1e30,-1e30)
      foreach ($s in $segs) { foreach ($p in $s) { for ($a=0;$a -lt 3;$a++) { if ([double]$p[$a] -lt [double]$mn[$a]) { $mn[$a]=[double]$p[$a] }; if ([double]$p[$a] -gt [double]$mx[$a]) { $mx[$a]=[double]$p[$a] } } } }
      RW ("[" + $idx + "] " + $e.type + "  segs=" + $segs.Count + "  BBOX (" + [math]::Round($mn[0],2) + "," + [math]::Round($mn[1],2) + "," + [math]::Round($mn[2],2) + ") .. (" + [math]::Round($mx[0],2) + "," + [math]::Round($mx[1],2) + "," + [math]::Round($mx[2],2) + ") SIZE (" + [math]::Round($mx[0]-$mn[0],2) + "," + [math]::Round($mx[1]-$mn[1],2) + "," + [math]::Round($mx[2]-$mn[2],2) + ")")
    } else {
      RW ("[" + $idx + "] " + $e.type)
    }
  }
}
$sw.Close()
Write-Host "ANALYZE-DONE"