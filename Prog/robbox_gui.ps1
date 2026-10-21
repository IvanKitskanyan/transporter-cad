<#
  RobBox CAD конструктор — GUI-обёртка скилла robbox-cad
  Запуск: robbox_gui.cmd (powershell -STA -File robbox_gui.ps1)
  Файл ОБЯЗАТЕЛЬНО в UTF-8 с BOM (кириллица в коде).
#>
param()

# --- STA для WPF ---
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  Start-Process powershell.exe ("-NoProfile -STA -ExecutionPolicy Bypass -File `"" + $PSCommandPath + "`"")
  exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$Project  = 'C:\RobBox\ai\project'
$SkillDir = Join-Path $Project '.claude\skills\robbox-cad'
$LibPath  = Join-Path $SkillDir 'lib\elements.json'
$ScrDir   = Join-Path $SkillDir 'scripts'
$ConvDir  = Join-Path $Project 'dwg elements\convert'
$Dwg2Dxf  = Join-Path $ConvDir 'dwg2dxf.exe'
$ScrBuild = Join-Path $ScrDir 'build_conveyor.ps1'
$ScrSpec  = Join-Path $ScrDir 'make_spec.ps1'
$ScrProbe = Join-Path $ScrDir 'probe_element.ps1'

# ================= JSON / библиотека =================
function Read-JsonFile([string]$p) {
  $s = [IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
  $o = $null
  for ($i = 0; $i -lt 5 -and $o -eq $null; $i++) {
    try { $t = ConvertFrom-Json -InputObject $s; if ($t -isnot [string]) { $o = $t } } catch {}
    if ($o -eq $null) { Start-Sleep -Milliseconds 150 }
  }
  if ($o -eq $null) { throw ("JSON PARSE FAILED: " + $p) }
  return $o
}
function Write-JsonFile([string]$p, $obj) {
  $s = ConvertTo-Json -InputObject $obj -Depth 8
  [IO.File]::WriteAllText($p, $s, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-ElemNames {
  if (-not (Test-Path $LibPath)) { return @() }
  $lib = Read-JsonFile $LibPath
  return @($lib.PSObject.Properties | Where-Object { $_.Name -ne '_schema' -and $_.Value.PSObject.Properties['dwg'] } | ForEach-Object { $_.Name })
}
function Get-ElemEntry([string]$name) {
  if (-not (Test-Path $LibPath)) { return $null }
  $lib = Read-JsonFile $LibPath
  $pr = $lib.PSObject.Properties[$name]
  if ($null -eq $pr) { return $null }
  return $pr.Value
}
function To-Num([string]$s, [double]$def) {
  $t = ('' + $s).Trim().Replace(',', '.')
  $v = 0.0
  if ([double]::TryParse($t, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
  return $def
}
function Test-FileLocked([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $false }
  try { $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false } catch { return $true }
}
function New-Row($pairs) {
  $o = New-Object PSCustomObject
  foreach ($k in $pairs.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $pairs[$k] }
  return $o
}

# ================= XAML =================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RobBox CAD конструктор" Width="1080" Height="800" WindowStartupLocation="CenterScreen" Name="wnd">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="150"/>
      <RowDefinition Height="26"/>
    </Grid.RowDefinitions>

    <TabControl Grid.Row="0" Name="tabMain">

      <!-- ============ СБОРКА ============ -->
      <TabItem Header="Сборка конвейера">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="2*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <GroupBox Grid.Row="0" Header="Выход">
            <Grid Margin="4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Выходной DWG:" VerticalAlignment="Center" Margin="0,0,6,0"/>
              <TextBox Grid.Column="1" Name="txtOutDwg" VerticalAlignment="Center" Text="C:\RobBox\ai\project\konveyer_gui.dwg"/>
              <Button  Grid.Column="2" Name="btnBrowseOut" Content="…" Width="30" Margin="6,3"/>
              <CheckBox Grid.Column="3" Name="chkDxf" Content="также DXF" VerticalAlignment="Center" IsChecked="True" Margin="8,0"/>
              <TextBlock Grid.Column="4" Text="Шаг этажей (floor_gap), мм:" VerticalAlignment="Center" Margin="8,0,6,0"/>
              <TextBox  Grid.Column="5" Name="txtGap" Width="70" Text="3000" VerticalAlignment="Center"/>
            </Grid>
          </GroupBox>

          <GroupBox Grid.Row="1" Header="Этажи (линии секций)">
            <Grid Margin="4">
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <DataGrid Grid.Row="0" Name="dgLines" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="id"      Binding="{Binding id}"      Width="80"/>
                  <DataGridTextColumn Header="z (плоскость), мм" Binding="{Binding z}" Width="110"/>
                  <DataGridTextColumn Header="y (ось), мм" Binding="{Binding y}" Width="100"/>
                  <DataGridTextColumn Header="x_start, мм" Binding="{Binding x_start}" Width="100"/>
                  <DataGridTextColumn Header="длина, мм" Binding="{Binding length}" Width="100"/>
                  <DataGridComboBoxColumn x:Name="colLineElem" Header="Элемент" SelectedItemBinding="{Binding element}" Width="110"/>
                  <DataGridTextColumn Header="примечание" Binding="{Binding note}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
              <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,4,0,0">
                <Button Name="btnAddLine" Content="+ этаж (выше)" Padding="10,3" Margin="0,0,6,0"/>
                <Button Name="btnDelLine" Content="− удалить строку" Padding="10,3"/>
              </StackPanel>
            </Grid>
          </GroupBox>

          <GroupBox Grid.Row="2" Header="Спуски (горка + трансфер)">
            <Grid Margin="4">
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <DataGrid Grid.Row="0" Name="dgDrops" AutoGenerateColumns="False" CanUserAddRows="False">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="верхний этаж (id)" Binding="{Binding upper}" Width="130"/>
                  <DataGridTextColumn Header="нижний этаж (id)"  Binding="{Binding lower}" Width="130"/>
                  <DataGridComboBoxColumn x:Name="colSide" Header="Сторона" SelectedItemBinding="{Binding side}" Width="80"/>
                  <DataGridComboBoxColumn x:Name="colGorka" Header="Горка" SelectedItemBinding="{Binding gorka}" Width="110"/>
                  <DataGridComboBoxColumn x:Name="colTrans" Header="Трансфер" SelectedItemBinding="{Binding transfer}" Width="110"/>
                </DataGrid.Columns>
              </DataGrid>
              <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,4,0,0">
                <Button Name="btnAutoDrops" Content="авто-цепочка (east/west…)" Padding="10,3" Margin="0,0,6,0"/>
                <Button Name="btnAddDrop"   Content="+ спуск" Padding="10,3" Margin="0,0,6,0"/>
                <Button Name="btnDelDrop"   Content="− удалить" Padding="10,3"/>
              </StackPanel>
            </Grid>
          </GroupBox>

          <GroupBox Grid.Row="3" Header="Прочие элементы (extras: зоны сортировки и т.п.)">
            <Grid Margin="4">
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <DataGrid Grid.Row="0" Name="dgExtras" AutoGenerateColumns="False" CanUserAddRows="False">
                <DataGrid.Columns>
                  <DataGridComboBoxColumn x:Name="colExtraElem" Header="Элемент" SelectedItemBinding="{Binding element}" Width="120"/>
                  <DataGridTextColumn Header="ins x, мм" Binding="{Binding ins_x}" Width="90"/>
                  <DataGridTextColumn Header="ins y, мм" Binding="{Binding ins_y}" Width="90"/>
                  <DataGridTextColumn Header="ins z, мм" Binding="{Binding ins_z}" Width="90"/>
                  <DataGridTextColumn Header="rot, град" Binding="{Binding rot}"   Width="80"/>
                </DataGrid.Columns>
              </DataGrid>
              <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,4,0,0">
                <Button Name="btnAddExtra" Content="+ элемент" Padding="10,3" Margin="0,0,6,0"/>
                <Button Name="btnDelExtra" Content="− удалить" Padding="10,3"/>
              </StackPanel>
            </Grid>
          </GroupBox>

          <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,8,0,0">
            <Button Name="btnLoadCfg"  Content="Загрузить конфиг…" Padding="12,5" Margin="0,0,8,0"/>
            <Button Name="btnSaveCfg"  Content="Сохранить конфиг…" Padding="12,5" Margin="0,0,8,0"/>
            <Button Name="btnExample"  Content="Заполнить пример (4 этажа)" Padding="12,5" Margin="0,0,8,0"/>
            <Button Name="btnBuild"    Content="СОБРАТЬ (DWG)" FontWeight="Bold" Padding="20,5"/>
          </StackPanel>
        </Grid>
      </TabItem>

      <!-- ============ СПЕЦИФИКАЦИЯ ============ -->
      <TabItem Header="Спецификация (BOM)">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Grid.Row="0" Margin="0,4">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="DWG сборки:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox  Grid.Column="1" Name="txtSpecDwg" VerticalAlignment="Center"/>
            <Button   Grid.Column="2" Name="btnBrowseSpecDwg" Content="…" Width="30" Margin="6,3"/>
          </Grid>
          <Grid Grid.Row="1" Margin="0,4">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Имя выхода (пусто = рядом с DWG):" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox  Grid.Column="1" Name="txtSpecOut" VerticalAlignment="Center"/>
          </Grid>
          <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,8">
            <Button Name="btnMakeSpec" Content="Сформировать спецификацию" FontWeight="Bold" Padding="16,5"/>
            <Button Name="btnOpenCsv"  Content="Открыть CSV" Padding="12,5" Margin="8,0,0,0"/>
          </StackPanel>
          <GroupBox Grid.Row="3" Header="Сводка (Markdown)">
            <TextBox Name="txtSpecResult" IsReadOnly="True" FontFamily="Consolas"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" AcceptsReturn="True"/>
          </GroupBox>
        </Grid>
      </TabItem>

      <!-- ============ БИБЛИОТЕКА ============ -->
      <TabItem Header="Библиотека элементов">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="150"/>
          </Grid.RowDefinitions>
          <GroupBox Grid.Row="0" Header="Элементы (lib/elements.json)">
            <Grid Margin="4">
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <DataGrid Grid.Row="0" Name="dgLib" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Имя"     Binding="{Binding name}"  Width="90"/>
                  <DataGridTextColumn Header="Описание" Binding="{Binding label}" Width="220"/>
                  <DataGridTextColumn Header="DWG"     Binding="{Binding dwg}"   Width="280"/>
                  <DataGridTextColumn Header="Габариты dx×dy×dz" Binding="{Binding size}" Width="130"/>
                  <DataGridTextColumn Header="datum_z" Binding="{Binding datum_z}" Width="80"/>
                  <DataGridTextColumn Header="Файл"    Binding="{Binding exists}" Width="60"/>
                </DataGrid.Columns>
              </DataGrid>
              <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,4,0,0">
                <Button Name="btnRefreshLib" Content="Обновить" Padding="10,3"/>
              </StackPanel>
            </Grid>
          </GroupBox>
          <GroupBox Grid.Row="1" Header="Добавить новый элемент (замер DWG → библиотека)">
            <Grid Margin="4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="140"/>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Имя (латиница):" VerticalAlignment="Center" Margin="0,0,6,0"/>
              <TextBox  Grid.Column="1" Name="txtNewElemName" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="2" Text="  DWG-файл:" VerticalAlignment="Center" Margin="6,0"/>
              <TextBox  Grid.Column="3" Name="txtNewElemDwg" VerticalAlignment="Center"/>
              <Button   Grid.Column="4" Name="btnBrowseNewDwg" Content="…" Width="30" Margin="6,3"/>
              <Button   Grid.Column="5" Name="btnProbe" Content="Замерить и добавить" FontWeight="Bold" Padding="12,4"/>
            </Grid>
          </GroupBox>
          <GroupBox Grid.Row="2" Header="Датумы выбранного элемента (JSON; править руками, потом «Сохранить»)">
            <Grid Margin="4">
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <TextBox Grid.Row="0" Name="txtEntryJson" FontFamily="Consolas" AcceptsReturn="True"
                       VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
              <Button Grid.Row="1" Name="btnSaveEntry" Content="Сохранить изменения элемента" Padding="12,3"
                      HorizontalAlignment="Left" Margin="0,4,0,0"/>
            </Grid>
          </GroupBox>
        </Grid>
      </TabItem>

      <!-- ============ СХЕМА ============ -->
      <TabItem Header="Схема серпантина">
        <Grid Margin="8">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal">
            <Button Name="btnRefreshPreview" Content="Обновить схему" Padding="12,4" Margin="0,0,8,0"/>
            <TextBlock VerticalAlignment="Center" Text="Проекция XZ: этажи друг над другом, стрелки — спуски (east на правом конце, west на левом)." Foreground="Gray"/>
          </StackPanel>
          <Border Grid.Row="1" BorderBrush="Gray" BorderThickness="1" Margin="0,6,0,0" Background="White">
            <Canvas Name="cvPreview"/>
          </Border>
        </Grid>
      </TabItem>

    </TabControl>

    <TextBox Grid.Row="1" Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="#FF1E1E1E" Foreground="#FFDDDDDD" AcceptsReturn="True"/>
    <StatusBar Grid.Row="2">
      <StatusBarItem><TextBlock Name="txtStatus" Text="Готов"/></StatusBarItem>
    </StatusBar>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# ================= коллекции / привязки =================
$script:Lines     = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Drops     = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Extras    = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:ElemNames = New-Object System.Collections.ObjectModel.ObservableCollection[string]
$script:ElemLib   = New-Object System.Collections.ObjectModel.ObservableCollection[object]

$F = { param($n) $window.FindName($n) }
$txtOutDwg = & $F 'txtOutDwg';  $chkDxf = & $F 'chkDxf';  $txtGap = & $F 'txtGap'
$dgLines = & $F 'dgLines';      $dgDrops = & $F 'dgDrops'; $dgExtras = & $F 'dgExtras'
$dgLib = & $F 'dgLib';          $txtLog = & $F 'txtLog';  $txtStatus = & $F 'txtStatus'
$txtSpecDwg = & $F 'txtSpecDwg'; $txtSpecOut = & $F 'txtSpecOut'; $txtSpecResult = & $F 'txtSpecResult'
$txtNewElemName = & $F 'txtNewElemName'; $txtNewElemDwg = & $F 'txtNewElemDwg'
$txtEntryJson = & $F 'txtEntryJson'; $cvPreview = & $F 'cvPreview'

$dgLines.ItemsSource  = $script:Lines
$dgDrops.ItemsSource  = $script:Drops
$dgExtras.ItemsSource = $script:Extras
$dgLib.ItemsSource    = $script:ElemLib

(& $F 'colLineElem').ItemsSource  = $script:ElemNames
(& $F 'colGorka').ItemsSource     = $script:ElemNames
(& $F 'colTrans').ItemsSource     = $script:ElemNames
(& $F 'colExtraElem').ItemsSource = $script:ElemNames
(& $F 'colSide').ItemsSource      = @('east', 'west')

function Log([string]$s) {
  $txtLog.AppendText($s + [Environment]::NewLine)
  $txtLog.ScrollToEnd()
}
function St([string]$s) { $txtStatus.Text = $s }

# ================= фоновый запуск скриптов =================
$script:busy     = $false
$script:tailFile = ''
$script:tailSeen = ''
$script:onDone   = $null

$tailTimer = New-Object System.Windows.Threading.DispatcherTimer
$tailTimer.Interval = [TimeSpan]::FromSeconds(3)
$tailTimer.Add_Tick({
  try {
    if ($script:tailFile -and (Test-Path -LiteralPath $script:tailFile)) {
      $all = [IO.File]::ReadAllText($script:tailFile, (New-Object System.Text.UTF8Encoding($false)))
      if ($all.Length -gt $script:tailSeen.Length) {
        Log ($all.Substring($script:tailSeen.Length).TrimEnd())
        $script:tailSeen = $all
      }
    }
  } catch {}
})

function Set-Busy([bool]$b) {
  $script:busy = $b
  foreach ($n in 'btnBuild','btnMakeSpec','btnProbe','btnSaveEntry') { (& $F $n).IsEnabled = -not $b }
  if ($b) { St 'Выполняется (AutoCAD COM стартует до ~1 мин)…' } else { St 'Готов' }
}

function Start-PsScript([string]$file, [string]$argStr, [string]$tailFile, [scriptblock]$onDone) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = 'powershell.exe'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $file + '" ' + $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true
  $enc = [System.Text.Encoding]::GetEncoding(866)
  $psi.StandardOutputEncoding = $enc
  $psi.StandardErrorEncoding  = $enc
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $p.EnableRaisingEvents = $true
  $p.add_OutputDataReceived({ if ($_.Data) { $d = $_.Data; $window.Dispatcher.BeginInvoke([action]{ Log ('   ' + $d) }) | Out-Null } })
  $p.add_ErrorDataReceived({  if ($_.Data) { $d = $_.Data; $window.Dispatcher.BeginInvoke([action]{ Log ('!! ' + $d) }) | Out-Null } })
  $script:onDone = $onDone
  $p.add_Exited({
    $window.Dispatcher.BeginInvoke([action]{
      $tailTimer.Stop()
      try {
        if ($script:tailFile -and (Test-Path -LiteralPath $script:tailFile)) {
          $all = [IO.File]::ReadAllText($script:tailFile, (New-Object System.Text.UTF8Encoding($false)))
          if ($all.Length -gt $script:tailSeen.Length) { Log ($all.Substring($script:tailSeen.Length).TrimEnd()) }
          $script:tailSeen = $all
        }
      } catch {}
      $cb = $script:onDone; $script:onDone = $null
      Set-Busy $false
      if ($cb) { & $cb }
    }) | Out-Null
  })
  $script:tailFile = $tailFile
  $script:tailSeen = ''
  $tailTimer.Start()
  $null = $p.Start()
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()
}

# ================= конфиг <-> UI =================
function Get-ConfigObject {
  $cfg = New-Object PSCustomObject
  $cfg | Add-Member -NotePropertyName output -NotePropertyValue ([ordered]@{
    dwg = $txtOutDwg.Text.Trim(); dxf = [bool]$chkDxf.IsChecked })
  $cfg | Add-Member -NotePropertyName elements_lib -NotePropertyValue ($LibPath -replace '\\', '/')
  $cfg | Add-Member -NotePropertyName floor_gap -NotePropertyValue (To-Num $txtGap.Text 3000)
  $lns = @()
  foreach ($r in $script:Lines) {
    $lns += [ordered]@{ id = $r.id; z = (To-Num $r.z 0); y = (To-Num $r.y 0)
      x_start = (To-Num $r.x_start 0); length = (To-Num $r.length 0); element = $r.element; note = $r.note }
  }
  $cfg | Add-Member -NotePropertyName lines -NotePropertyValue $lns
  $drs = @()
  foreach ($r in $script:Drops) {
    $drs += [ordered]@{ upper = $r.upper; lower = $r.lower; side = $r.side; gorka = $r.gorka; transfer = $r.transfer }
  }
  $cfg | Add-Member -NotePropertyName drops -NotePropertyValue $drs
  $exs = @()
  foreach ($r in $script:Extras) {
    $exs += [ordered]@{ element = $r.element
      ins = @((To-Num $r.ins_x 0), (To-Num $r.ins_y 0), (To-Num $r.ins_z 0)); rot = (To-Num $r.rot 0) }
  }
  $cfg | Add-Member -NotePropertyName extras -NotePropertyValue $exs
  return $cfg
}

function Set-UIFromConfig($cfg) {
  $txtOutDwg.Text = [string]$cfg.output.dwg
  $chkDxf.IsChecked = [bool]$cfg.output.dxf
  if ($cfg.PSObject.Properties['floor_gap']) { $txtGap.Text = [string]$cfg.floor_gap }
  $script:Lines.Clear()
  foreach ($ln in $cfg.lines) {
    $script:Lines.Add((New-Row ([ordered]@{ id = [string]$ln.id; z = [string]$ln.z; y = [string]$ln.y
      x_start = [string]$ln.x_start; length = [string]$ln.length; element = [string]$ln.element
      note = [string]$ln.note })))
  }
  $script:Drops.Clear()
  foreach ($d in $cfg.drops) {
    $script:Drops.Add((New-Row ([ordered]@{ upper = [string]$d.upper; lower = [string]$d.lower
      side = [string]$d.side; gorka = [string]$d.gorka; transfer = [string]$d.transfer })))
  }
  $script:Extras.Clear()
  foreach ($x in $cfg.extras) {
    $script:Extras.Add((New-Row ([ordered]@{ element = [string]$x.element
      ins_x = [string]$x.ins[0]; ins_y = [string]$x.ins[1]; ins_z = [string]$x.ins[2]; rot = [string]$x.rot })))
  }
}

# ================= вкладка «Сборка»: кнопки =================
(& $F 'btnBrowseOut').Add_Click({
  $dlg = New-Object Microsoft.Win32.SaveFileDialog
  $dlg.Filter = 'DWG (*.dwg)|*.dwg'; $dlg.FileName = $txtOutDwg.Text
  if ($dlg.ShowDialog()) { $txtOutDwg.Text = $dlg.FileName }
})

(& $F 'btnAddLine').Add_Click({
  $gap = To-Num $txtGap.Text 3000
  $z = 0.0
  foreach ($r in $script:Lines) { if ((To-Num $r.z 0) -gt $z) { $z = To-Num $r.z 0 } }
  if ($script:Lines.Count -gt 0) { $z += $gap }
  $names = @($script:ElemNames)
  $elem = if ($names -contains 'section') { 'section' } elseif ($names.Count -gt 0) { $names[0] } else { '' }
  $script:Lines.Add((New-Row ([ordered]@{ id = ('floor' + ($script:Lines.Count + 1)); z = [string]$z
    y = '0'; x_start = '0'; length = '50000'; element = $elem; note = '' })))
})
(& $F 'btnDelLine').Add_Click({
  if ($dgLines.SelectedItem) { $script:Lines.Remove($dgLines.SelectedItem) | Out-Null }
})

(& $F 'btnAutoDrops').Add_Click({
  if ($script:Lines.Count -lt 2) { Log 'Нужно минимум 2 этажа для авто-цепочки.'; return }
  $sorted = @($script:Lines | Sort-Object { To-Num $_.z 0 } -Descending)
  $script:Drops.Clear()
  $g = if ($script:ElemNames -contains 'gorka') { 'gorka' } else { '' }
  $t = if ($script:ElemNames -contains 'transfer') { 'transfer' } else { '' }
  for ($i = 0; $i -lt $sorted.Count - 1; $i++) {
    $side = if ($i % 2 -eq 0) { 'east' } else { 'west' }
    $script:Drops.Add((New-Row ([ordered]@{ upper = $sorted[$i].id; lower = $sorted[$i + 1].id
      side = $side; gorka = $g; transfer = $t })))
  }
  Log ('Авто-цепочка: ' + ($script:Drops.Count) + ' спуска(ов), east/west змейкой. Датумы горки самокорректирует build_conveyor (приёмник анкорится автоматически).')
})
(& $F 'btnAddDrop').Add_Click({
  $script:Drops.Add((New-Row ([ordered]@{ upper = ''; lower = ''; side = 'east'; gorka = 'gorka'; transfer = 'transfer' })))
})
(& $F 'btnDelDrop').Add_Click({
  if ($dgDrops.SelectedItem) { $script:Drops.Remove($dgDrops.SelectedItem) | Out-Null }
})

(& $F 'btnAddExtra').Add_Click({
  $script:Extras.Add((New-Row ([ordered]@{ element = ''; ins_x = '0'; ins_y = '0'; ins_z = '0'; rot = '0' })))
})
(& $F 'btnDelExtra').Add_Click({
  if ($dgExtras.SelectedItem) { $script:Extras.Remove($dgExtras.SelectedItem) | Out-Null }
})

(& $F 'btnLoadCfg').Add_Click({
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Filter = 'JSON (*.json)|*.json'
  $dlg.InitialDirectory = (Join-Path $SkillDir 'configs')
  if ($dlg.ShowDialog()) {
    try { Set-UIFromConfig (Read-JsonFile $dlg.FileName); Log ('Конфиг загружен: ' + $dlg.FileName); Draw-Preview }
    catch { Log ('ОШИБКА чтения конфига: ' + $_.Exception.Message) }
  }
})
(& $F 'btnSaveCfg').Add_Click({
  $dlg = New-Object Microsoft.Win32.SaveFileDialog
  $dlg.Filter = 'JSON (*.json)|*.json'
  $dlg.InitialDirectory = (Join-Path $SkillDir 'configs')
  if ($dlg.ShowDialog()) {
    try { Write-JsonFile $dlg.FileName (Get-ConfigObject); Log ('Конфиг сохранён: ' + $dlg.FileName) }
    catch { Log ('ОШИБКА записи конфига: ' + $_.Exception.Message) }
  }
})
(& $F 'btnExample').Add_Click({
  $p = Join-Path $SkillDir 'configs\serpentine4.json'
  if (Test-Path $p) { Set-UIFromConfig (Read-JsonFile $p); Log ('Загружен пример: ' + $p); Draw-Preview }
  else { Log 'Пример не найден.' }
})

(& $F 'btnBuild').Add_Click({
  if ($script:busy) { return }
  $dgLines.CommitEdit(); $dgDrops.CommitEdit(); $dgExtras.CommitEdit()
  $outDwg = $txtOutDwg.Text.Trim()
  if (-not $outDwg) { Log 'Укажите выходной DWG.'; return }
  if ($script:Lines.Count -eq 0) { Log 'Нет ни одной линии (этажа).'; return }

  # проверка локов (СКИЛЛ правило 4)
  $locked = @()
  if (Test-FileLocked $outDwg) { $locked += $outDwg }
  if (Test-Path $LibPath) {
    $lib = Read-JsonFile $LibPath
    foreach ($pr in $lib.PSObject.Properties) {
      $v = $pr.Value
      if ($v.PSObject.Properties['dwg'] -and (Test-FileLocked ([string]$v.dwg))) { $locked += [string]$v.dwg }
    }
  }
  if ($locked.Count -gt 0) {
    Log ('ОТКАЗ: файлы заняты (открыты в AutoCAD?). Закройте их или смените выходной путь:')
    foreach ($f in $locked) { Log ('  LOCKED: ' + $f) }
    return
  }

  $cfgPath = Join-Path $SkillDir 'configs\gui_last.json'
  $cfg = Get-ConfigObject
  $cfg.output.dwg = $outDwg
  try { Write-JsonFile $cfgPath $cfg } catch { Log ('ОШИБКА записи конфига: ' + $_.Exception.Message); return }
  Log '================ СБОРКА ================'
  Log ('Конфиг: ' + $cfgPath + '  ->  ' + $outDwg)
  foreach ($r in $script:Lines) { Log ('  этаж ' + $r.id + ': z=' + $r.z + ' y=' + $r.y + ' x=' + $r.x_start + ' L=' + $r.length) }
  foreach ($r in $script:Drops) { Log ('  спуск ' + $r.upper + '->' + $r.lower + ' (' + $r.side + ')') }

  $rpt = Join-Path $ConvDir (([IO.Path]::GetFileNameWithoutExtension($outDwg)) + '_report.txt')
  Set-Busy $true
  Start-PsScript $ScrBuild ('-Config "' + $cfgPath + '"') $rpt {
    Log '================ сборка завершена ================'
    if (Test-Path $outDwg) {
      $mb = ((Get-Item $outDwg).Length / 1MB).ToString('F2', [Globalization.CultureInfo]::InvariantCulture)
      Log ('OK: ' + $outDwg + '  (' + $mb + ' МБ)')
    } else { Log ('ВНИМАНИЕ: выходной DWG не появился: ' + $outDwg) }
    if ([bool]$chkDxf.IsChecked) {
      $wantDxf = [IO.Path]::ChangeExtension($outDwg, '.dxf')
      if (Test-Path $wantDxf) { Log ('OK DXF: ' + $wantDxf) } else { Log ('DXF не появился: ' + $wantDxf + ' — см. отчёт.') }
    }
    Log 'Совет: проверьте в отчёте строки JOIN (dx/dy ~0) и UNION-габарит.'
  }
})

# ================= вкладка «Спецификация» =================
(& $F 'btnBrowseSpecDwg').Add_Click({
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Filter = 'DWG (*.dwg)|*.dwg'; $dlg.InitialDirectory = $Project
  if ($dlg.ShowDialog()) { $txtSpecDwg.Text = $dlg.FileName }
})
(& $F 'btnMakeSpec').Add_Click({
  if ($script:busy) { return }
  $dwg = $txtSpecDwg.Text.Trim()
  if (-not (Test-Path -LiteralPath $dwg)) { Log 'Укажите существующий DWG.'; return }
  if (Test-FileLocked $dwg) { Log ('ОТКАЗ: DWG занят (открыт в AutoCAD): ' + $dwg); return }
  $outBase = $txtSpecOut.Text.Trim()
  if (-not $outBase) { $outBase = [IO.Path]::Combine([IO.Path]::GetDirectoryName($dwg), [IO.Path]::GetFileNameWithoutExtension($dwg)) }
  $rpt = $outBase + '_spec_report.txt'
  Log '================ СПЕЦИФИКАЦИЯ ================'
  Log ('DWG: ' + $dwg + '  -> ' + $outBase + '_spec.csv/.md')
  Set-Busy $true
  Start-PsScript $ScrSpec ('-Dwg "' + $dwg + '" -Lib "' + $LibPath + '" -Out "' + $outBase + '"') $rpt {
    $md = $outBase + '_spec.md'
    if (Test-Path $md) {
      $txtSpecResult.Text = [IO.File]::ReadAllText($md, (New-Object System.Text.UTF8Encoding($false)))
      Log ('OK: ' + $md)
    } else { Log ('MD не найден: ' + $md) }
    if (Test-Path ($outBase + '_spec.csv')) { Log ('OK: ' + $outBase + '_spec.csv') }
  }
})
(& $F 'btnOpenCsv').Add_Click({
  $dwg = $txtSpecDwg.Text.Trim()
  $outBase = $txtSpecOut.Text.Trim()
  if (-not $outBase) { $outBase = [IO.Path]::Combine([IO.Path]::GetDirectoryName($dwg), [IO.Path]::GetFileNameWithoutExtension($dwg)) }
  $csvp = $outBase + '_spec.csv'
  if (Test-Path $csvp) { Invoke-Item $csvp } else { Log ('CSV не найден: ' + $csvp) }
})

# ================= вкладка «Библиотека» =================
function Refresh-Lib {
  $script:ElemNames.Clear()
  $script:ElemLib.Clear()
  if (-not (Test-Path $LibPath)) { Log ('Библиотека не найдена: ' + $LibPath); return }
  $lib = Read-JsonFile $LibPath
  foreach ($pr in $lib.PSObject.Properties) {
    $v = $pr.Value
    if ($pr.Name -eq '_schema' -or -not ($v.PSObject.Properties['dwg'])) { continue }
    $script:ElemNames.Add($pr.Name)
    $dwg = [string]$v.dwg
    $size = ''
    if ($v.PSObject.Properties['raw']) {
      $r = $v.raw
      $dx = (To-Num ([string]$r.x1) 0) - (To-Num ([string]$r.x0) 0)
      $dy = (To-Num ([string]$r.y1) 0) - (To-Num ([string]$r.y0) 0)
      $dzv = (To-Num ([string]$r.z1) 0) - (To-Num ([string]$r.z0) 0)
      $inv = [Globalization.CultureInfo]::InvariantCulture
      $size = $dx.ToString('F1', $inv) + ' x ' + $dy.ToString('F1', $inv) + ' x ' + $dzv.ToString('F1', $inv)
    }
    $dz = if ($v.PSObject.Properties['datum_z']) { [string]$v.datum_z } else { '-' }
    $ex = if (Test-Path -LiteralPath $dwg) { 'ок' } else { 'НЕТ' }
    $script:ElemLib.Add((New-Row ([ordered]@{ name = $pr.Name; label = [string]$v.label
      dwg = $dwg; size = $size; datum_z = $dz; exists = $ex })))
  }
}
(& $F 'btnRefreshLib').Add_Click({ Refresh-Lib })

$dgLib.add_SelectionChanged({
  $row = $dgLib.SelectedItem
  if (-not $row) { return }
  $e = Get-ElemEntry ([string]$row.name)
  if ($e) { $txtEntryJson.Text = ConvertTo-Json -InputObject $e -Depth 8 }
})
(& $F 'btnSaveEntry').Add_Click({
  $row = $dgLib.SelectedItem
  if (-not $row) { Log 'Выберите элемент в таблице.'; return }
  try {
    $newEntry = ConvertFrom-Json -InputObject $txtEntryJson.Text
    $lib = Read-JsonFile $LibPath
    $bak = $LibPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $LibPath -Destination $bak
    if ($lib.PSObject.Properties[$row.name]) { $lib.PSObject.Properties.Remove($row.name) }
    $lib | Add-Member -NotePropertyName ([string]$row.name) -NotePropertyValue $newEntry
    Write-JsonFile $LibPath $lib
    Log ('Элемент "' + $row.name + '" сохранён (резервная копия: ' + $bak + ')')
    Refresh-Lib
  } catch { Log ('ОШИБКА: JSON невалиден — ' + $_.Exception.Message) }
})

(& $F 'btnBrowseNewDwg').Add_Click({
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Filter = 'DWG (*.dwg)|*.dwg'
  $dlg.InitialDirectory = (Join-Path $Project 'dwg elements')
  if ($dlg.ShowDialog()) { $txtNewElemDwg.Text = $dlg.FileName }
})
(& $F 'btnProbe').Add_Click({
  if ($script:busy) { return }
  $name = $txtNewElemName.Text.Trim()
  $dwg  = $txtNewElemDwg.Text.Trim()
  if ($name -notmatch '^[a-zA-Z0-9_]+$') { Log 'Имя элемента: только латиница/цифры/подчёркивание.'; return }
  if (-not (Test-Path -LiteralPath $dwg)) { Log 'Укажите существующий DWG-файл.'; return }
  if (Test-FileLocked $dwg) { Log ('ОТКАЗ: DWG занят (открыт в AutoCAD): ' + $dwg); return }
  $rpt = Join-Path $ConvDir ('probe_' + $name + '.txt')
  Log ('================ ЗАМЕР ЭЛЕМЕНТА "' + $name + '" ================')
  Set-Busy $true
  Start-PsScript $ScrProbe ('-Dwg "' + $dwg + '" -Name "' + $name + '" -Lib "' + $LibPath + '"') $rpt {
    Refresh-Lib
    Log ('Замер завершён. ВАЖНО: заполните датумы нового элемента (datum_z, точки стыковки) в редакторе ниже —')
    Log 'probe даёт только raw-габариты. Для неконвейерных элементов (датчики/рамы/зоны) датумы не нужны: размещайте через extras.'
  }
})

# ================= вкладка «Схема» =================
function Draw-Preview {
  if (-not $cvPreview -or -not $cvPreview.IsLoaded) { return }
  $cv = $cvPreview
  $cv.Children.Clear()
  if ($script:Lines.Count -eq 0) { return }
  $dgLines.CommitEdit(); $dgDrops.CommitEdit()

  $gapPlane = 800.0   # визуальное расстояние между этажами по вертикали (мм проектных)
  $run = 10690.0      # ход горки; точное значение из библиотеки, если есть
  $ge = Get-ElemEntry 'gorka'
  if ($ge -and $ge.PSObject.Properties['raw_run']) { $run = To-Num ([string]$ge.raw_run) 10690.0 }

  $minX = [double]::MaxValue; $maxX = [double]::MinValue; $maxZ = 0.0
  $L = @()
  foreach ($r in $script:Lines) {
    $z = To-Num $r.z 0; $xs = To-Num $r.x_start 0; $len = To-Num $r.length 0
    if ($xs -lt $minX) { $minX = $xs }
    if (($xs + $len) -gt $maxX) { $maxX = $xs + $len }
    if ($z -gt $maxZ) { $maxZ = $z }
    $L += @{ id = $r.id; z = $z; y = (To-Num $r.y 0); xs = $xs; xe = $xs + $len }
  }
  $minX -= $run * 0.6; $maxX += $run * 0.2
  $zSpan = $maxZ + 2 * $gapPlane

  $W = $cv.ActualWidth - 140; $H = $cv.ActualHeight - 80
  if ($W -lt 50 -or $H -lt 50) { return }
  $s = [math]::Min($W / ($maxX - $minX), $H / $zSpan)
  $ox = 70.0; $oy = 40.0
  $SX = { param($x) $ox + ($x - $minX) * $s }
  $SZ = { param($z) $oy + $H - ($z + $gapPlane) * $s }

  function AddTxt($x, $yy, $t, $color) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $t; $tb.FontSize = 10; $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ($color)
    [System.Windows.Controls.Canvas]::SetLeft($tb, $x); [System.Windows.Controls.Canvas]::SetTop($tb, $yy)
    $cvPreview.Children.Add($tb) | Out-Null
  }

  $zById = @{}
  foreach ($i in $L) {
    $yPix = & $SZ $i.z
    $x1 = & $SX $i.xs; $x2 = & $SX $i.xe
    $line = New-Object System.Windows.Shapes.Line
    $line.X1 = $x1; $line.Y1 = $yPix; $line.X2 = $x2; $line.Y2 = $yPix
    $line.Stroke = [System.Windows.Media.Brushes]::SteelBlue; $line.StrokeThickness = 5
    $cv.Children.Add($line) | Out-Null
    AddTxt ($x1 + 2) ($yPix - 15) ($i.id + ': z=' + [int]$i.z + '  L=' + [int]($i.xe - $i.xs) + '  y=' + [int]$i.y) ([System.Windows.Media.Colors]::DarkSlateBlue)
    $zById[$i.id] = $i
  }
  # спуски — стрелки
  foreach ($d in $script:Drops) {
    if (-not $zById.ContainsKey($d.upper) -or -not $zById.ContainsKey($d.lower)) { continue }
    $up = $zById[$d.upper]; $lo = $zById[$d.lower]
    if ($d.side -eq 'east') { $xa = & $SX $up.xe; $xb = & $SX ($up.xe - $run); $anchor = ($lo.xe) }
    else { $xa = & $SX $up.xs; $xb = & $SX ($up.xs + $run); $anchor = $lo.xs }
    $ya = & $SZ $up.z; $yb = & $SZ $lo.z
    $a = New-Object System.Windows.Shapes.Line
    $a.X1 = $xa; $a.Y1 = $ya; $a.X2 = $xb; $a.Y2 = $yb
    $a.Stroke = [System.Windows.Media.Brushes]::Crimson; $a.StrokeThickness = 2.5
    $a.StrokeEndLineCap = 'Triangle'
    $cv.Children.Add($a) | Out-Null
    AddTxt ((($xa + $xb) / 2) - 10) (($ya + $yb) / 2 - 14) $d.side ([System.Windows.Media.Colors]::Crimson)
  }
}

(& $F 'btnRefreshPreview').Add_Click({ Draw-Preview })
$window.Add_SizeChanged({ Draw-Preview })
$window.Add_Loaded({
  Refresh-Lib
  Draw-Preview
  Log ('Библиотека: ' + $LibPath)
  Log '1) задайте этажи и спуски  2) вкладка «Схема» — визуальная проверка  3) «СОБРАТЬ» — DWG (+DXF).'
})

$window.ShowDialog() | Out-Null
