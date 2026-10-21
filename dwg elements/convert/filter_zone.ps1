$lines = Get-Content 'C:\RobBox\ai\project\dwg elements\convert\bbox_general_cur.txt'
$out = New-Object System.Collections.Generic.List[string]
foreach ($L in $lines) {
  if ($L -notmatch 'BBOX') { continue }
  # parse bbox min x, min z, max z
  $m = [regex]::Match($L, 'BBOX \(([\-\d.,]+),([\-\d.,]+),([\-\d.,]+)\) \.\. \(([\-\d.,]+)')
  if (-not $m.Success) { continue }
  $x0 = [double]($m.Groups[1].Value -replace ',','.')
  if ($x0 -ge 198600 -and $x0 -le 205600) { $out.Add($L) }
}
$out | ForEach-Object { Write-Output $_ }