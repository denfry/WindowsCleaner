<#
.SYNOPSIS
    Windows Senior - desktop (WPF) application for the cleanup, optimization and
    troubleshooting engines.

.DESCRIPTION
    A native Windows window built on WPF (ships with every Windows 10/11, nothing to
    install). It drives the three engines exactly like the console menu does - by
    launching them with parameters - so every action keeps the engines' real -WhatIf,
    the safety guard, restore points and per-tweak undo. Engine output streams into
    the log panel; JSON reports feed the per-task size and health columns.

    Normally started through WinSenior.cmd (double-click) or WinSenior.ps1 -Gui;
    both elevate first. Run directly with -NoElevate to skip the UAC prompt.

.NOTES
    Author : denfry  (https://github.com/denfry/WindowsCleaner)
    Requires: PowerShell 5.1+ (Windows), .NET Framework 4.x (built in).
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
# LOCATE ENGINES + ELEVATE
# =====================================================================
$script:Root           = $PSScriptRoot
$script:CommonScript   = Join-Path $script:Root 'WinSenior.Common.ps1'
$script:CleanupScript  = Join-Path $script:Root 'Cleanup-Windows-Senior.ps1'
$script:OptimizeScript = Join-Path $script:Root 'Optimize-Windows-Senior.ps1'
$script:RepairScript   = Join-Path $script:Root 'Repair-Windows-Senior.ps1'
$script:MenuScript     = Join-Path $script:Root 'WinSenior.ps1'
$script:ScheduleScript = Join-Path $script:Root 'WinSenior.Schedule.ps1'

foreach ($s in @($script:CommonScript, $script:CleanupScript, $script:OptimizeScript, $script:RepairScript, $script:ScheduleScript)) {
    if (-not (Test-Path $s)) {
        [System.Windows.MessageBox]::Show("Engine not found:`n$s`n`nKeep WinSenior.Gui.ps1 next to the engine scripts.", 'Windows Senior', 'OK', 'Error') | Out-Null
        exit 1
    }
}

. $script:CommonScript

# Which host are we? Children run on the same one so behaviour matches.
$script:HostExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
if (-not (Test-Path $script:HostExe)) { $script:HostExe = 'powershell.exe' }

if (-not (Test-AdminPrivileges) -and -not $NoElevate) {
    try {
        Start-Process -FilePath $script:HostExe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
        exit 0
    }
    catch {
        exit 1
    }
}

# Hide the console window that hosts us (when launched from a console).
try {
    Add-Type -Namespace WinSenior -Name ConsoleWin -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
    $h = [WinSenior.ConsoleWin]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [void][WinSenior.ConsoleWin]::ShowWindow($h, 0) }
} catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# Load the engines as libraries: registries, applied-state checks, selection defaults.
. $script:CleanupScript
. $script:OptimizeScript
. $script:RepairScript
. $script:ScheduleScript

# =====================================================================
# ROW MODEL (INotifyPropertyChanged so the grids update live)
# =====================================================================
if (-not ('WinSenior.Row' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace WinSenior {
    public class Row : INotifyPropertyChanged {
        string _id="", _name="", _group="", _risk="", _size="", _state="", _detail="", _explain="";
        bool _selected, _enabled = true; long _bytes;
        public event PropertyChangedEventHandler PropertyChanged;
        void On(string n){ var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
        public string Id      { get { return _id; }      set { _id = value; On("Id"); } }
        public string Name    { get { return _name; }    set { _name = value; On("Name"); } }
        public string Group   { get { return _group; }   set { _group = value; On("Group"); } }
        public string Risk    { get { return _risk; }    set { _risk = value; On("Risk"); } }
        public string Size    { get { return _size; }    set { _size = value; On("Size"); } }
        public string State   { get { return _state; }   set { _state = value; On("State"); } }
        public string Detail  { get { return _detail; }  set { _detail = value; On("Detail"); } }
        public string Explain { get { return _explain; } set { _explain = value; On("Explain"); } }
        public bool   Selected{ get { return _selected; }set { _selected = value; On("Selected"); } }
        public bool   Enabled { get { return _enabled; } set { _enabled = value; On("Enabled"); } }
        public long   Bytes   { get { return _bytes; }   set { _bytes = value; On("Bytes"); } }
    }
}
'@
}

# =====================================================================
# SETTINGS (persisted selections & options)
# =====================================================================
$script:SettingsDir = Join-Path $env:ProgramData 'WinSenior'
try {
    if (-not (Test-Path $script:SettingsDir)) { New-Item -ItemType Directory -Path $script:SettingsDir -Force -ErrorAction Stop | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $script:SettingsDir '.write-test'), 'ok'); Remove-Item (Join-Path $script:SettingsDir '.write-test') -Force
} catch {
    # Not writable (running without admin via -NoElevate): keep settings per user instead.
    $script:SettingsDir = Join-Path $env:LOCALAPPDATA 'WinSenior'
}
$script:SettingsFile = Join-Path $script:SettingsDir 'gui-settings.json'
$script:LogDir       = Join-Path $script:SettingsDir 'logs'
foreach ($d in $script:SettingsDir, $script:LogDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

function Get-GuiSettings {
    $def = [ordered]@{
        CleanOn = $null; OptOn = $null
        CurrentUserOnly = $false; RestorePoint = $true; DeferLocked = $true
        SkipOptimization = $false; MaxAgeDays = 0
    }
    if (Test-Path $script:SettingsFile) {
        try {
            $j = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $def[$p.Name] = $p.Value }
        } catch { }
    }
    $def
}

function Save-GuiSettings {
    try {
        $o = [ordered]@{
            CleanOn          = @($script:CleanRows | Where-Object Selected | ForEach-Object Id)
            OptOn            = @($script:OptRows   | Where-Object Selected | ForEach-Object Id)
            CurrentUserOnly  = [bool]$W.ChkCurrentUser.IsChecked
            RestorePoint     = [bool]$W.ChkRestore.IsChecked
            DeferLocked      = [bool]$W.ChkDefer.IsChecked
            SkipOptimization = [bool]$W.ChkSkipOpt.IsChecked
            MaxAgeDays       = [int]$W.TxtMaxAge.Text
        }
        ($o | ConvertTo-Json -Depth 4) | Set-Content -Path $script:SettingsFile -Encoding UTF8
    } catch { }
}

# =====================================================================
# XAML
# =====================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Senior" Width="1180" Height="760" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#1B1C20" FontFamily="Segoe UI" FontSize="13"
        Foreground="#E8E8EA" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Panel"  Color="#24252B"/>
    <SolidColorBrush x:Key="Panel2" Color="#2C2D34"/>
    <SolidColorBrush x:Key="Line"   Color="#3A3B44"/>
    <SolidColorBrush x:Key="Accent" Color="#5B8DEF"/>
    <SolidColorBrush x:Key="Muted"  Color="#9DA2AC"/>
    <SolidColorBrush x:Key="Text"   Color="#E8E8EA"/>

    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#383943"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#7A2E2E"/>
      <Setter Property="BorderBrush" Value="#A33"/>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Padding="16,11" Margin="8,2" CornerRadius="6" Background="Transparent">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="#2E3E63"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#2C2D34"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="CaretBrush" Value="White"/>
    </Style>
    <Style TargetType="ListView">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#2E3E63"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#2C2D34"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Padding" Value="10"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Margin" Value="0,0,0,12"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <DataTemplate x:Key="RiskCell">
      <Border CornerRadius="4" Padding="6,1" HorizontalAlignment="Left">
        <Border.Style>
          <Style TargetType="Border">
            <Setter Property="Background" Value="#3A3B44"/>
            <Style.Triggers>
              <DataTrigger Binding="{Binding Risk}" Value="Safe"><Setter Property="Background" Value="#1F5A3A"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Moderate"><Setter Property="Background" Value="#6A5314"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Aggressive"><Setter Property="Background" Value="#7A3E12"/></DataTrigger>
              <DataTrigger Binding="{Binding Risk}" Value="Dangerous"><Setter Property="Background" Value="#7A2323"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </Border.Style>
        <TextBlock Text="{Binding Risk}" FontSize="11" Foreground="White"/>
      </Border>
    </DataTemplate>
    <DataTemplate x:Key="StateCell">
      <TextBlock Text="{Binding State}" FontWeight="SemiBold">
        <TextBlock.Style>
          <Style TargetType="TextBlock">
            <Style.Triggers>
              <DataTrigger Binding="{Binding State}" Value="OK"><Setter Property="Foreground" Value="#3DDC84"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="Warn"><Setter Property="Foreground" Value="#F5B942"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="Fail"><Setter Property="Foreground" Value="#FF5C5C"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="applied"><Setter Property="Foreground" Value="#3DDC84"/></DataTrigger>
              <DataTrigger Binding="{Binding State}" Value="not applied"><Setter Property="Foreground" Value="#9DA2AC"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </TextBlock.Style>
      </TextBlock>
    </DataTemplate>
    <DataTemplate x:Key="CheckCell">
      <CheckBox IsChecked="{Binding Selected, Mode=TwoWay}" IsEnabled="{Binding Enabled}" Margin="0"/>
    </DataTemplate>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="210"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- SIDEBAR -->
    <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="20,22,20,18">
          <TextBlock Text="Windows Senior" FontSize="18" FontWeight="Bold"/>
          <TextBlock x:Name="LblVersion" Text="v" Foreground="{StaticResource Muted}" FontSize="11"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="20,0,20,18">
          <TextBlock x:Name="LblAdmin" Text="" FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
          <TextBlock x:Name="LblHost" Text="" FontSize="11" Foreground="{StaticResource Muted}"/>
        </StackPanel>
        <StackPanel>
          <RadioButton x:Name="NavClean"    Style="{StaticResource Nav}" Content="Disk cleanup" IsChecked="True"/>
          <RadioButton x:Name="NavOpt"      Style="{StaticResource Nav}" Content="Optimize"/>
          <RadioButton x:Name="NavRepair"   Style="{StaticResource Nav}" Content="Troubleshoot"/>
          <RadioButton x:Name="NavUndo"     Style="{StaticResource Nav}" Content="Undo &amp; restore"/>
          <RadioButton x:Name="NavSchedule" Style="{StaticResource Nav}" Content="Schedule"/>
          <RadioButton x:Name="NavAbout"    Style="{StaticResource Nav}" Content="About"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- MAIN -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="6"/>
        <RowDefinition x:Name="LogRow" Height="220"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="22,18,22,8">
        <!-- CLEANUP -->
        <DockPanel x:Name="PageClean">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Disk cleanup"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Scan measures what each task would free (nothing is deleted). Clean removes the checked tasks. Dangerous tasks are irreversible and must be checked by hand."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <Button x:Name="BtnScan"  Content="Scan (dry run)"/>
            <Button x:Name="BtnClean" Content="Clean now" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnCleanAll"  Content="Select all" Padding="10,7"/>
            <Button x:Name="BtnCleanSafe" Content="Safe only" Padding="10,7"/>
            <Button x:Name="BtnCleanDef"  Content="Defaults" Padding="10,7"/>
            <Button x:Name="BtnCleanNone" Content="None" Padding="10,7"/>
          </WrapPanel>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <CheckBox x:Name="ChkCurrentUser" Content="Current user only"/>
            <CheckBox x:Name="ChkRestore" Content="Restore point first" IsChecked="True"/>
            <CheckBox x:Name="ChkDefer" Content="Delete locked files at reboot" IsChecked="True"/>
            <CheckBox x:Name="ChkSkipOpt" Content="Skip SFC / DISM (slow)"/>
            <TextBlock Text="Only files older than" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,6,0"/>
            <TextBox x:Name="TxtMaxAge" Width="40" Text="0"/>
            <TextBlock Text="days" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="6,0,0,0"/>
          </WrapPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblCleanStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}"/>
          <ListView x:Name="LvClean">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Task" Width="430" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Category" Width="100" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Risk" Width="96" CellTemplate="{StaticResource RiskCell}"/>
                <GridViewColumn Header="Would free" Width="110" DisplayMemberBinding="{Binding Size}"/>
                <GridViewColumn Header="Id" Width="140" DisplayMemberBinding="{Binding Id}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- OPTIMIZE -->
        <DockPanel x:Name="PageOpt" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Optimize Windows"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Performance, privacy, debloat and network tweaks. Every applied tweak is backed up first and can be reverted from Undo &amp; restore."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="BtnOptPreview" Content="Preview"/>
            <Button x:Name="BtnOptApply"   Content="Apply tweaks" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnOptRefresh" Content="Refresh state" Padding="10,7"/>
            <Button x:Name="BtnOptAll"  Content="Select all" Padding="10,7"/>
            <Button x:Name="BtnOptDef"  Content="Defaults" Padding="10,7"/>
            <Button x:Name="BtnOptNone" Content="None" Padding="10,7"/>
            <CheckBox x:Name="ChkOptRestore" Content="Restore point first" IsChecked="True" Margin="10,0,0,0"/>
          </WrapPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblOptStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}"/>
          <ListView x:Name="LvOpt">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Tweak" Width="400" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Area" Width="100" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Risk" Width="96" CellTemplate="{StaticResource RiskCell}"/>
                <GridViewColumn Header="State" Width="100" CellTemplate="{StaticResource StateCell}"/>
                <GridViewColumn Header="Id" Width="160" DisplayMemberBinding="{Binding Id}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- TROUBLESHOOT -->
        <DockPanel x:Name="PageRepair" Visibility="Collapsed">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Troubleshoot"/>
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Sub}"
                     Text="Scan is read-only. Afterwards tick the problems you want repaired and press Fix. Heavy repairs (SFC, DISM, Windows Update reset, network stack) may need a reboot."/>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="BtnRepScan" Content="Scan" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnRepFix"  Content="Fix selected" IsEnabled="False"/>
            <Button x:Name="BtnRepFixAll" Content="Auto-fix everything (incl. heavy)" IsEnabled="False"/>
          </WrapPanel>
          <TextBlock DockPanel.Dock="Bottom" x:Name="LblRepStatus" Margin="0,8,0,0" Foreground="{StaticResource Muted}"/>
          <ListView x:Name="LvRep">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34" CellTemplate="{StaticResource CheckCell}"/>
                <GridViewColumn Header="Check" Width="260" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Category" Width="90" DisplayMemberBinding="{Binding Group}"/>
                <GridViewColumn Header="Status" Width="70" CellTemplate="{StaticResource StateCell}"/>
                <GridViewColumn Header="Detail" Width="330" DisplayMemberBinding="{Binding Detail}"/>
                <GridViewColumn Header="Fix" Width="96" CellTemplate="{StaticResource RiskCell}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>

        <!-- UNDO / RESTORE -->
        <StackPanel x:Name="PageUndo" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="Undo &amp; restore"/>
          <TextBlock Style="{StaticResource Sub}" Text="Safety nets: revert an optimization run from its backup manifest, or create a System Restore point right now."/>
          <GroupBox Header="Optimization backups">
            <StackPanel>
              <ListView x:Name="LvBackups" Height="180">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Backup manifest" Width="380" DisplayMemberBinding="{Binding Name}"/>
                    <GridViewColumn Header="Created" Width="160" DisplayMemberBinding="{Binding Detail}"/>
                    <GridViewColumn Header="Tweaks" Width="80" DisplayMemberBinding="{Binding Size}"/>
                  </GridView>
                </ListView.View>
              </ListView>
              <WrapPanel Margin="0,10,0,0">
                <Button x:Name="BtnUndoLast" Content="Undo newest run" Style="{StaticResource Primary}"/>
                <Button x:Name="BtnUndoSel"  Content="Undo selected manifest"/>
                <Button x:Name="BtnBackupsRefresh" Content="Refresh" Padding="10,7"/>
                <Button x:Name="BtnOpenBackups" Content="Open folder" Padding="10,7"/>
              </WrapPanel>
            </StackPanel>
          </GroupBox>
          <GroupBox Header="System Restore">
            <WrapPanel>
              <Button x:Name="BtnRestorePoint" Content="Create restore point now"/>
              <Button x:Name="BtnOpenRstrui" Content="Open System Restore (rstrui)"/>
            </WrapPanel>
          </GroupBox>
          <GroupBox Header="Logs &amp; reports">
            <WrapPanel>
              <Button x:Name="BtnOpenLogs" Content="Open log folder"/>
              <Button x:Name="BtnOpenTemp" Content="Open engine logs (%TEMP%)"/>
            </WrapPanel>
          </GroupBox>
        </StackPanel>

        <!-- SCHEDULE -->
        <StackPanel x:Name="PageSchedule" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="Schedule"/>
          <TextBlock Style="{StaticResource Sub}" Text="Register recurring maintenance in Task Scheduler (weekly cleanup + monthly health check). Runs as SYSTEM, unattended, no restore point, no Dangerous tier."/>
          <TextBlock x:Name="LblSchedule" Margin="0,0,0,12" TextWrapping="Wrap"/>
          <WrapPanel>
            <Button x:Name="BtnSchedInstall" Content="Install scheduled tasks" Style="{StaticResource Primary}"/>
            <Button x:Name="BtnSchedRemove"  Content="Remove scheduled tasks"/>
            <Button x:Name="BtnSchedRefresh" Content="Refresh" Padding="10,7"/>
            <Button x:Name="BtnSchedOpen" Content="Open Task Scheduler" Padding="10,7"/>
          </WrapPanel>
        </StackPanel>

        <!-- ABOUT -->
        <StackPanel x:Name="PageAbout" Visibility="Collapsed">
          <TextBlock Style="{StaticResource H1}" Text="About"/>
          <TextBlock x:Name="LblAbout" TextWrapping="Wrap" Foreground="{StaticResource Muted}" LineHeight="20"/>
          <WrapPanel Margin="0,14,0,0">
            <Button x:Name="BtnOpenRepo" Content="GitHub repository"/>
            <Button x:Name="BtnOpenConsole" Content="Open console menu (WinSenior.ps1)"/>
          </WrapPanel>
        </StackPanel>
      </Grid>

      <GridSplitter Grid.Row="1" Height="6" HorizontalAlignment="Stretch" Background="{StaticResource Line}" ResizeBehavior="PreviousAndNext"/>

      <!-- LOG -->
      <DockPanel Grid.Row="2" Margin="22,6,22,14">
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Button x:Name="BtnCancel" Content="Cancel" Style="{StaticResource Danger}" IsEnabled="False" Padding="10,5"/>
            <Button x:Name="BtnLogSave"  Content="Save log" Padding="10,5"/>
            <Button x:Name="BtnLogClear" Content="Clear" Padding="10,5" Margin="0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Log" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <ProgressBar x:Name="Prog" Width="160" Height="8" Visibility="Hidden" IsIndeterminate="True" Foreground="{StaticResource Accent}" Background="{StaticResource Panel2}" BorderThickness="0"/>
            <TextBlock x:Name="LblStatus" Text="Ready." VerticalAlignment="Center" Margin="12,0,0,0" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </DockPanel>
        <TextBox x:Name="TxtLog" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="#131417" Foreground="#D6D6DA"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" AcceptsReturn="True"/>
      </DockPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$Win = [System.Windows.Markup.XamlReader]::Load($reader)

# Every x:Name'd element becomes $W.<Name>
$W = @{}
([xml]$xaml).SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($n) { $W[$n] = $Win.FindName($n) }
}

# =====================================================================
# LOG + STATUS
# =====================================================================
function Add-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $W.TxtLog.AppendText($Text)
    if (-not $Text.EndsWith("`n")) { $W.TxtLog.AppendText("`r`n") }
    $W.TxtLog.ScrollToEnd()
}
function Set-Status { param([string]$Text) $W.LblStatus.Text = $Text }

function Set-Busy {
    param([bool]$On, [string]$Text = '')
    $script:Busy = $On
    $W.Prog.Visibility = if ($On) { 'Visible' } else { 'Hidden' }
    $W.BtnCancel.IsEnabled = $On
    foreach ($b in 'BtnScan','BtnClean','BtnOptPreview','BtnOptApply','BtnRepScan','BtnUndoLast','BtnUndoSel',
                   'BtnRestorePoint','BtnSchedInstall','BtnSchedRemove','BtnRepFixAll','BtnRepFix') {
        $W[$b].IsEnabled = -not $On
    }
    if ($On) { $W.BtnRepFix.IsEnabled = $false; $W.BtnRepFixAll.IsEnabled = $false }
    else { $W.BtnRepFix.IsEnabled = [bool]$script:RepScanned; $W.BtnRepFixAll.IsEnabled = [bool]$script:RepScanned }
    if ($Text) { Set-Status $Text }
}

# =====================================================================
# CHILD PROCESS RUNNER (engine output tails into the log)
# =====================================================================
$script:Busy      = $false
$script:Proc      = $null
$script:OutFile   = $null
$script:OutPos    = 0
$script:OnDone    = $null
$script:ReportTmp = $null

$script:ChildEnc = if ($PSVersionTable.PSEdition -eq 'Core') { [System.Text.Encoding]::UTF8 } else { [System.Text.Encoding]::Default }

function Read-ChildOutput {
    if (-not $script:OutFile -or -not (Test-Path $script:OutFile)) { return }
    try {
        $fs = [System.IO.File]::Open($script:OutFile, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $script:OutPos) { return }
            $fs.Position = $script:OutPos
            $buf = New-Object byte[] ($fs.Length - $script:OutPos)
            $n = $fs.Read($buf, 0, $buf.Length)
            $script:OutPos += $n
            $text = $script:ChildEnc.GetString($buf, 0, $n)
            # WhatIf lines from ShouldProcess are verbose; keep them but compact.
            $text = $text -replace 'What if: Performing the operation "Remove \((.*?)\)" on target "(.*?)"\.', '  [WhatIf] $2'
            Add-Log $text
        } finally { $fs.Dispose() }
    } catch { }
}

function Start-Engine {
    param(
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Arguments = @(),
        [string]$Status = 'Running...',
        [scriptblock]$OnDone,
        [switch]$WantReport
    )
    if ($script:Busy) { return }
    Save-GuiSettings
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:OutFile = Join-Path $script:LogDir "gui-$stamp.out.log"
    $script:OutPos  = 0
    $script:OnDone  = $OnDone
    $script:ReportTmp = $null
    if ($WantReport) {
        $script:ReportTmp = Join-Path $env:TEMP "winsenior-gui-$stamp.json"
        $Arguments += @('-ReportPath', "`"$script:ReportTmp`"")
    }
    $argLine = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"") + $Arguments
    Add-Log ("`r`n===== {0}  {1} {2}`r`n" -f (Get-Date -Format 'HH:mm:ss'), (Split-Path $Script -Leaf), ($Arguments -join ' '))
    Set-Busy $true $Status
    try {
        $script:Proc = Start-Process -FilePath $script:HostExe -ArgumentList $argLine -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $script:OutFile -RedirectStandardError "$script:OutFile.err"
    } catch {
        Add-Log "Failed to start: $($_.Exception.Message)"
        Set-Busy $false 'Failed.'
        return
    }
    $script:Timer.Start()
}

function Complete-Engine {
    $script:Timer.Stop()
    Read-ChildOutput
    $errFile = "$script:OutFile.err"
    if (Test-Path $errFile) {
        $e = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        if ($e -and $e.Trim()) { Add-Log ("[stderr] " + $e.Trim()) }
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    $code = if ($script:Proc) { $script:Proc.ExitCode } else { -1 }
    $report = $null
    if ($script:ReportTmp -and (Test-Path $script:ReportTmp)) {
        try { $report = Get-Content $script:ReportTmp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        Remove-Item $script:ReportTmp -Force -ErrorAction SilentlyContinue
    }
    Set-Busy $false ("Done (exit code {0})." -f $code)
    $script:Proc = $null
    if ($script:OnDone) { try { & $script:OnDone $report $code } catch { Add-Log "post-processing error: $($_.Exception.Message)" } }
    $script:OnDone = $null
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:Timer.Add_Tick({
    Read-ChildOutput
    if ($script:Proc -and $script:Proc.HasExited) { Complete-Engine }
})

$W.BtnCancel.Add_Click({
    if ($script:Proc -and -not $script:Proc.HasExited) {
        Add-Log '--- cancelled by user ---'
        & taskkill.exe /PID $script:Proc.Id /T /F *>$null
    }
})

# =====================================================================
# SELECTION HELPERS
# =====================================================================
function Get-IncludeExcludeArgs {
    param($Rows)
    $on  = @($Rows | Where-Object Selected | ForEach-Object Id)
    $off = @($Rows | Where-Object { -not $_.Selected } | ForEach-Object Id)
    $a = @()
    if ($on)  { $a += @('-Include', ($on -join ',')) }
    if ($off) { $a += @('-Exclude', ($off -join ',')) }
    $a
}
function Set-RowSelection {
    param($Rows, [scriptblock]$Predicate)
    foreach ($r in $Rows) { $r.Selected = [bool](& $Predicate $r) }
}
function Confirm-Dangerous {
    param($Rows, [string]$Verb)
    $d = @($Rows | Where-Object { $_.Selected -and $_.Risk -eq 'Dangerous' })
    if (-not $d) { return $true }
    $list = ($d | ForEach-Object { "  - $($_.Name)" }) -join "`n"
    $r = [System.Windows.MessageBox]::Show(
        "These are IRREVERSIBLE:`n`n$list`n`n$Verb them anyway?", 'Dangerous tier', 'YesNo', 'Warning')
    $r -eq 'Yes'
}

# =====================================================================
# CLEANUP PAGE
# =====================================================================
$settings = Get-GuiSettings
$script:CleanReg = Get-CleanupTaskRegistry
$defaultClean = @(Resolve-CleanupSelection -Registry $script:CleanReg | ForEach-Object Id)
$script:CleanRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
foreach ($t in $script:CleanReg) {
    $r = New-Object WinSenior.Row
    $r.Id = $t.Id; $r.Name = $t.Name; $r.Group = $t.Category; $r.Risk = $t.Risk
    $r.Selected = if ($settings.CleanOn) { $settings.CleanOn -contains $t.Id } else { $defaultClean -contains $t.Id }
    $script:CleanRows.Add($r)
}
$W.LvClean.ItemsSource = $script:CleanRows
$W.ChkCurrentUser.IsChecked = [bool]$settings.CurrentUserOnly
$W.ChkRestore.IsChecked     = [bool]$settings.RestorePoint
$W.ChkDefer.IsChecked       = [bool]$settings.DeferLocked
$W.ChkSkipOpt.IsChecked     = [bool]$settings.SkipOptimization
$W.TxtMaxAge.Text           = [string]([int]$settings.MaxAgeDays)

function Update-CleanStatus {
    $on = @($script:CleanRows | Where-Object Selected)
    $bytes = ($on | Measure-Object Bytes -Sum).Sum
    $txt = "Selected {0} of {1} tasks" -f $on.Count, $script:CleanRows.Count
    if ($bytes) { $txt += "   |   estimated: " + (Format-FileSize ([int64]$bytes)) }
    $danger = @($on | Where-Object Risk -eq 'Dangerous').Count
    if ($danger) { $txt += "   |   $danger DANGEROUS selected" }
    $W.LblCleanStatus.Text = $txt
}
$script:CleanRows | ForEach-Object { $_.Add_PropertyChanged({ Update-CleanStatus }) }
Update-CleanStatus

function Get-CleanupArgs {
    param([bool]$Preview)
    $a = Get-IncludeExcludeArgs $script:CleanRows
    $a += '-Unattended'
    if ($Preview) { $a += '-WhatIf' }
    if ($W.ChkCurrentUser.IsChecked) { $a += '-CurrentUserOnly' }
    if (-not $W.ChkRestore.IsChecked -or $Preview) { $a += '-NoRestorePoint' }
    if ($W.ChkDefer.IsChecked -and -not $Preview) { $a += '-DeferLocked' }
    if ($W.ChkSkipOpt.IsChecked) { $a += '-SkipOptimization' }
    $age = 0; [void][int]::TryParse($W.TxtMaxAge.Text, [ref]$age)
    if ($age -gt 0) { $a += @('-MaxAgeDays', $age) }
    if ($script:CleanRows | Where-Object { $_.Selected -and $_.Risk -eq 'Dangerous' }) { $a += '-IncludeDangerous' }
    $a
}

$applyReport = {
    param($report, $code)
    if (-not $report) { return }
    $map = @{}
    foreach ($i in @($report.Items)) { $map[$i.Task] = $i }
    foreach ($r in $script:CleanRows) {
        if ($map.ContainsKey($r.Id)) {
            $r.Bytes = [int64]$map[$r.Id].Bytes
            $r.Size  = if ($r.Bytes -gt 0) { Format-FileSize $r.Bytes } elseif ([int]$map[$r.Id].Files -gt 0) { "$($map[$r.Id].Files) items" } else { '-' }
        }
    }
    Update-CleanStatus
    $verb = if ($report.Mode -eq 'DryRun') { 'Would free' } else { 'Reclaimed' }
    Set-Status ("{0}: {1}   ({2} items, {3} errors)" -f $verb, $report.Summary.TotalFreed, $report.Summary.TotalFiles, $report.Summary.TotalErrors)
}

$W.BtnScan.Add_Click({
    if (-not ($script:CleanRows | Where-Object Selected)) { Set-Status 'Nothing selected.'; return }
    foreach ($r in $script:CleanRows) { $r.Size = ''; $r.Bytes = 0 }
    Start-Engine -Script $script:CleanupScript -Arguments (Get-CleanupArgs $true) -Status 'Scanning (dry run)...' -WantReport -OnDone $applyReport
})
$W.BtnClean.Add_Click({
    if (-not ($script:CleanRows | Where-Object Selected)) { Set-Status 'Nothing selected.'; return }
    if (-not (Confirm-Dangerous $script:CleanRows 'Run')) { return }
    Start-Engine -Script $script:CleanupScript -Arguments (Get-CleanupArgs $false) -Status 'Cleaning...' -WantReport -OnDone $applyReport
})
$W.BtnCleanAll.Add_Click({  Set-RowSelection $script:CleanRows { param($r) $r.Risk -ne 'Dangerous' } })
$W.BtnCleanSafe.Add_Click({ Set-RowSelection $script:CleanRows { param($r) $r.Risk -eq 'Safe' } })
$W.BtnCleanDef.Add_Click({  Set-RowSelection $script:CleanRows { param($r) $defaultClean -contains $r.Id } })
$W.BtnCleanNone.Add_Click({ Set-RowSelection $script:CleanRows { $false } })

# =====================================================================
# OPTIMIZE PAGE
# =====================================================================
$script:OptReg = Get-OptimizationTweakRegistry
$defaultOpt = @(Resolve-TweakSelection -Registry $script:OptReg | ForEach-Object Id)
$script:OptRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
foreach ($t in $script:OptReg) {
    $r = New-Object WinSenior.Row
    $r.Id = $t.Id; $r.Name = $t.Name; $r.Group = $t.Area; $r.Risk = $t.Risk; $r.Explain = [string]$t.Explain
    $r.Selected = if ($settings.OptOn) { $settings.OptOn -contains $t.Id } else { $defaultOpt -contains $t.Id }
    $script:OptRows.Add($r)
}
$W.LvOpt.ItemsSource = $script:OptRows

function Update-OptStatus {
    $on = @($script:OptRows | Where-Object Selected).Count
    $applied = @($script:OptRows | Where-Object State -eq 'applied').Count
    $W.LblOptStatus.Text = "Selected {0} of {1} tweaks   |   currently applied: {2}" -f $on, $script:OptRows.Count, $applied
}
function Update-OptState {
    Set-Status 'Reading current tweak state...'
    $Win.Dispatcher.Invoke([action]{}, 'Background')
    foreach ($t in $script:OptReg) {
        $row = $script:OptRows | Where-Object Id -eq $t.Id
        $st = $null
        try { $st = Test-TweakApplied -Tweak $t } catch { }
        $row.State = if ($st -eq $true) { 'applied' } elseif ($st -eq $false) { 'not applied' } else { '?' }
    }
    Update-OptStatus
    Set-Status 'Ready.'
}
$script:OptRows | ForEach-Object { $_.Add_PropertyChanged({ Update-OptStatus }) }
Update-OptStatus

function Get-OptArgs {
    param([bool]$Preview)
    $a = Get-IncludeExcludeArgs $script:OptRows
    $a += '-Unattended'
    if ($Preview) { $a += '-WhatIf' }
    if (-not $W.ChkOptRestore.IsChecked -or $Preview) { $a += '-NoRestorePoint' }
    if ($script:OptRows | Where-Object { $_.Selected -and $_.Risk -eq 'Dangerous' }) { $a += '-IncludeDangerous' }
    $a
}
$W.BtnOptPreview.Add_Click({
    if (-not ($script:OptRows | Where-Object Selected)) { Set-Status 'Nothing selected.'; return }
    Start-Engine -Script $script:OptimizeScript -Arguments (Get-OptArgs $true) -Status 'Previewing tweaks...'
})
$W.BtnOptApply.Add_Click({
    if (-not ($script:OptRows | Where-Object Selected)) { Set-Status 'Nothing selected.'; return }
    if (-not (Confirm-Dangerous $script:OptRows 'Apply')) { return }
    Start-Engine -Script $script:OptimizeScript -Arguments (Get-OptArgs $false) -Status 'Applying tweaks...' -OnDone { Update-OptState; Update-Backups }
})
$W.BtnOptRefresh.Add_Click({ Update-OptState })
$W.BtnOptAll.Add_Click({  Set-RowSelection $script:OptRows { param($r) $r.Risk -ne 'Dangerous' } })
$W.BtnOptDef.Add_Click({  Set-RowSelection $script:OptRows { param($r) $defaultOpt -contains $r.Id } })
$W.BtnOptNone.Add_Click({ Set-RowSelection $script:OptRows { $false } })

# =====================================================================
# TROUBLESHOOT PAGE
# =====================================================================
$script:RepReg = Get-DiagnosticCheckRegistry
$script:RepRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:RepScanned = $false
foreach ($c in $script:RepReg) {
    $r = New-Object WinSenior.Row
    $r.Id = $c.Id; $r.Name = $c.Name; $r.Group = $c.Category; $r.Risk = $(if ($c.Fix) { $c.FixRisk } else { '' })
    $r.State = ''; $r.Detail = 'not scanned'; $r.Enabled = $false
    $script:RepRows.Add($r)
}
$W.LvRep.ItemsSource = $script:RepRows

$applyScan = {
    param($report, $code)
    if (-not $report) { return }
    $fail = 0; $warn = 0
    foreach ($i in @($report.Items)) {
        $row = $script:RepRows | Where-Object Id -eq $i.Id
        if (-not $row) { continue }
        $row.State = [string]$i.Status; $row.Detail = [string]$i.Detail
        $fixable = [bool]$i.HasFix -and ($i.Status -in 'Warn','Fail')
        $row.Enabled = $fixable
        $row.Selected = $fixable -and ($i.FixRisk -in 'Safe','Moderate')
        if ($i.Status -eq 'Fail') { $fail++ } elseif ($i.Status -eq 'Warn') { $warn++ }
    }
    $script:RepScanned = $true
    $W.BtnRepFix.IsEnabled = $true; $W.BtnRepFixAll.IsEnabled = $true
    $W.LblRepStatus.Text = "Scan complete: {0} failing, {1} warnings. Fixable problems are pre-ticked (Safe + Moderate)." -f $fail, $warn
}
$W.BtnRepScan.Add_Click({
    Start-Engine -Script $script:RepairScript -Arguments @('-ScanOnly', '-Unattended') -Status 'Scanning for problems...' -WantReport -OnDone $applyScan
})
$W.BtnRepFix.Add_Click({
    $sel = @($script:RepRows | Where-Object { $_.Selected -and $_.Enabled })
    if (-not $sel) { Set-Status 'No fixes selected.'; return }
    $a = @('-FixAll', '-Unattended', '-Include', (($sel | ForEach-Object Id) -join ','),
           '-Exclude', ((@($script:RepRows | Where-Object { $_.Id -notin $sel.Id } | ForEach-Object Id)) -join ','))
    if ($sel | Where-Object Risk -eq 'Aggressive') { $a += '-IncludeHeavy' }
    Start-Engine -Script $script:RepairScript -Arguments $a -Status 'Repairing...' -WantReport -OnDone {
        param($report, $code)
        if ($report -and $report.Summary.Reboot) { [System.Windows.MessageBox]::Show('A reboot is required to finish the repair.', 'Windows Senior', 'OK', 'Information') | Out-Null }
        $W.BtnRepScan.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
    }
})
$W.BtnRepFixAll.Add_Click({
    $r = [System.Windows.MessageBox]::Show('Apply every available fix, including heavy ones (SFC, DISM, Windows Update reset, network stack)? A restore point is created first.', 'Auto-fix everything', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Start-Engine -Script $script:RepairScript -Arguments @('-FixAll', '-IncludeHeavy', '-Unattended') -Status 'Auto-fixing...' -WantReport -OnDone {
        param($report, $code)
        if ($report -and $report.Summary.Reboot) { [System.Windows.MessageBox]::Show('A reboot is required to finish the repair.', 'Windows Senior', 'OK', 'Information') | Out-Null }
    }
})

# =====================================================================
# UNDO / RESTORE PAGE
# =====================================================================
$script:BackupDirPath = Join-Path $env:ProgramData 'WinSenior\backups'
$script:BackupRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$W.LvBackups.ItemsSource = $script:BackupRows
function Update-Backups {
    $script:BackupRows.Clear()
    if (-not (Test-Path $script:BackupDirPath)) { return }
    Get-ChildItem $script:BackupDirPath -Filter 'optimize-backup-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            $r = New-Object WinSenior.Row
            $r.Id = $_.FullName; $r.Name = $_.Name; $r.Detail = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            try { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json; $r.Size = [string]@($j.Snapshots).Count } catch { $r.Size = '?' }
            $script:BackupRows.Add($r)
        }
}
Update-Backups
$W.BtnUndoLast.Add_Click({
    if (-not $script:BackupRows.Count) { Set-Status 'No backups found.'; return }
    Start-Engine -Script $script:OptimizeScript -Arguments @('-Undo', '-Unattended') -Status 'Reverting newest run...' -OnDone { Update-OptState; Update-Backups }
})
$W.BtnUndoSel.Add_Click({
    $sel = $W.LvBackups.SelectedItem
    if (-not $sel) { Set-Status 'Select a manifest first.'; return }
    Start-Engine -Script $script:OptimizeScript -Arguments @('-Undo', '-Unattended', '-BackupManifest', "`"$($sel.Id)`"") -Status 'Reverting selected manifest...' -OnDone { Update-OptState; Update-Backups }
})
$W.BtnBackupsRefresh.Add_Click({ Update-Backups })
$W.BtnOpenBackups.Add_Click({ if (-not (Test-Path $script:BackupDirPath)) { New-Item -ItemType Directory $script:BackupDirPath -Force | Out-Null }; Start-Process explorer.exe $script:BackupDirPath })
$W.BtnRestorePoint.Add_Click({
    $cmd = ". '$script:CommonScript'; New-WinSeniorRestorePoint -Description 'WinSenior manual $(Get-Date -Format ''yyyy-MM-dd HH:mm'')' -LogAction { param(`$m, `$l) Write-Host `$m }"
    $tmp = Join-Path $env:TEMP 'winsenior-gui-rp.ps1'
    Set-Content -Path $tmp -Value $cmd -Encoding UTF8
    Start-Engine -Script $tmp -Status 'Creating restore point...'
})
$W.BtnOpenRstrui.Add_Click({ Start-Process rstrui.exe })
$W.BtnOpenLogs.Add_Click({ Start-Process explorer.exe $script:LogDir })
$W.BtnOpenTemp.Add_Click({ Start-Process explorer.exe $env:TEMP })

# =====================================================================
# SCHEDULE PAGE
# =====================================================================
function Update-Schedule {
    $tasks = @(Get-ScheduledTask -TaskPath '\WinSenior\' -ErrorAction SilentlyContinue)
    if (-not $tasks) { $W.LblSchedule.Text = 'Not installed.'; return }
    $lines = foreach ($t in $tasks) {
        $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        "{0}  -  {1}   next: {2}   last: {3}" -f $t.TaskName, $t.State, $info.NextRunTime, $info.LastRunTime
    }
    $W.LblSchedule.Text = ($lines -join "`n")
}
Update-Schedule
$W.BtnSchedInstall.Add_Click({ Start-Engine -Script $script:MenuScript -Arguments @('-InstallSchedule', '-NoElevate') -Status 'Installing scheduled tasks...' -OnDone { Update-Schedule } })
$W.BtnSchedRemove.Add_Click({  Start-Engine -Script $script:MenuScript -Arguments @('-RemoveSchedule', '-NoElevate')  -Status 'Removing scheduled tasks...'   -OnDone { Update-Schedule } })
$W.BtnSchedRefresh.Add_Click({ Update-Schedule })
$W.BtnSchedOpen.Add_Click({ Start-Process taskschd.msc })

# =====================================================================
# ABOUT / NAV / LOG BUTTONS
# =====================================================================
$ver = Get-WinSeniorVersion
$W.LblVersion.Text = "v$ver"
$W.LblAdmin.Text = if (Test-AdminPrivileges) { 'Administrator: yes' } else { 'Administrator: NO - most actions will fail' }
$W.LblHost.Text  = "PowerShell $($PSVersionTable.PSVersion)"
$W.LblAbout.Text = @"
Windows Senior v$ver - registry-driven Windows cleaner, optimizer and troubleshooter.

Cleanup tasks: $($script:CleanReg.Count)    Optimization tweaks: $($script:OptReg.Count)    Diagnostic checks: $($script:RepReg.Count)

This window drives the same PowerShell engines as the console menu and the command line, so every action keeps
the engines' real -WhatIf dry run, the delete safety guard, System Restore points and per-tweak undo.

Settings: $script:SettingsFile
Engine logs: $env:TEMP\WindowsCleanup.log, WindowsOptimize.log, WindowsRepair.log
Backups: $script:BackupDirPath

MIT License - https://github.com/denfry/WindowsCleaner
"@
$W.BtnOpenRepo.Add_Click({ Start-Process 'https://github.com/denfry/WindowsCleaner' })
$W.BtnOpenConsole.Add_Click({ Start-Process -FilePath $script:HostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:MenuScript`"", '-NoElevate') })

$pages = @{ NavClean = 'PageClean'; NavOpt = 'PageOpt'; NavRepair = 'PageRepair'; NavUndo = 'PageUndo'; NavSchedule = 'PageSchedule'; NavAbout = 'PageAbout' }
foreach ($nav in $pages.Keys) {
    $W[$nav].Tag = $pages[$nav]
    $W[$nav].Add_Checked({
        param($sender, $e)
        foreach ($p in $pages.Values) { $W[$p].Visibility = 'Collapsed' }
        $W[$sender.Tag].Visibility = 'Visible'
        if ($sender.Tag -eq 'PageOpt' -and -not $script:OptStateLoaded) { $script:OptStateLoaded = $true; Update-OptState }
    })
}

$W.BtnLogClear.Add_Click({ $W.TxtLog.Clear() })
$W.BtnLogSave.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Log files (*.log)|*.log|All files|*.*'
    $dlg.FileName = "WinSenior-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
    if ($dlg.ShowDialog()) { Set-Content -Path $dlg.FileName -Value $W.TxtLog.Text -Encoding UTF8; Set-Status "Saved $($dlg.FileName)" }
})

$Win.Add_Closing({
    param($sender, $e)
    if ($script:Busy) {
        $r = [System.Windows.MessageBox]::Show('An operation is still running. Cancel it and quit?', 'Windows Senior', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        if ($script:Proc -and -not $script:Proc.HasExited) { & taskkill.exe /PID $script:Proc.Id /T /F *>$null }
    }
    Save-GuiSettings
})

Add-Log "Windows Senior v$ver ready. $($script:CleanReg.Count) cleanup tasks, $($script:OptReg.Count) tweaks, $($script:RepReg.Count) checks."
if (-not (Test-AdminPrivileges)) { Add-Log 'WARNING: not running as Administrator - most actions will fail.' }

# Automation hook (smoke tests): WINSENIOR_GUI_AUTOCLOSE=<seconds> closes the window by
# itself; WINSENIOR_GUI_SCREENSHOT=<file.png> captures it first.
if ($env:WINSENIOR_GUI_AUTOCLOSE) {
    $auto = New-Object System.Windows.Threading.DispatcherTimer
    $auto.Interval = [TimeSpan]::FromSeconds([double]$env:WINSENIOR_GUI_AUTOCLOSE)
    $auto.Add_Tick({
        $auto.Stop()
        if ($env:WINSENIOR_GUI_SCREENSHOT) {
            try {
                Add-Type -AssemblyName System.Drawing
                $bmp = New-Object System.Drawing.Bitmap ([int]$Win.ActualWidth), ([int]$Win.ActualHeight)
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen([int]$Win.Left, [int]$Win.Top, 0, 0, $bmp.Size)
                $bmp.Save($env:WINSENIOR_GUI_SCREENSHOT, [System.Drawing.Imaging.ImageFormat]::Png)
                $g.Dispose(); $bmp.Dispose()
            } catch { Add-Log "screenshot failed: $($_.Exception.Message)" }
        }
        if ($script:Proc -and -not $script:Proc.HasExited) { & taskkill.exe /PID $script:Proc.Id /T /F *>$null }
        $script:Busy = $false
        $Win.Close()
    })
    $auto.Start()
    # WINSENIOR_GUI_AUTORUN=<button name> presses that button once the window is up.
    if ($env:WINSENIOR_GUI_AUTORUN -and $W[$env:WINSENIOR_GUI_AUTORUN]) {
        $Win.Add_ContentRendered({
            $W[$env:WINSENIOR_GUI_AUTORUN].RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        })
    }
}

[void]$Win.ShowDialog()
