# Smoke-check the built installer's wizard without clicking through it by hand.
#
# It launches the setup with /DIR pointed at a scratch folder that does not exist (so
# the destination page has no "folder already exists" prompt), accepts the license and
# walks to the "additional tasks" page, dumping every page's UI Automation elements to a
# UTF-8 text file. Then it kills the wizard -- it NEVER presses the install button, so
# nothing gets installed.
#
# ASCII only: Windows PowerShell 5.1 reads .ps1 as ANSI, so Chinese literals in here would
# end up as garbage. The Chinese text it captures comes from the wizard itself (read
# through UI Automation) and is written out as UTF-8.
#
#   usage: powershell -NoProfile -ExecutionPolicy Bypass -File tool\installer\verify_wizard.ps1 dist\Gracelink-Setup-1.0.0.exe
#          (add -Lang english to force the wizard's language with Inno's /LANG=, e.g. to
#           check the English license from a Chinese machine)
#
# Two things learned the hard way (2026-10-10):
#
#   * The wizard's controls are custom-drawn: UI Automation sees the "accept" radio, the
#     buttons and even the page heading as plain Panes with NO patterns, so nothing can be
#     invoked through UIA. Only key messages or a mouse can drive it.
#   * SendKeys/WScript.Shell types through the system input queue, which goes to whatever
#     window happens to be in the foreground -- on a machine where a chat client keeps
#     popping up, every Alt+A ended up in the wrong app and the wizard never moved. So the
#     key messages are POSTED straight to the wizard window instead (WM_SYSKEYDOWN carries
#     the Alt context in lParam bit 29); that works without owning the foreground.
#     The page heading is the only readable state, and it is never compared against a
#     literal in this file -- the dump records it for a human to read.
#
# What it can and cannot check: page headings, labels, buttons and the page text are
# exposed by UI Automation; the checkbox items on the tasks page are NOT (Inno draws them
# with a custom control), so for those read the dump's page text plus [Tasks] in
# gracelink.iss.
#
# The license page shows one of TWO files depending on the wizard's language ([Languages]
# LicenseFile in gracelink.iss): license.txt in Chinese, license-en.txt otherwise. Check
# both -- the default run on a Chinese machine picks Chinese, /LANG=english picks the other.
param(
    [Parameter(Mandatory = $true)][string] $Setup,
    # The install target is always wiped first: an existing folder makes Inno pop its
    # "the folder already exists, install anyway?" dialog on the destination page, which
    # then swallows the next Alt+N and this script dumps the dialog instead of page 3.
    # The dump itself is written to the scratch ROOT, never into the target.
    [string] $ScratchRoot = "$env:TEMP\gracelink-wizard-check",
    [string] $ScratchDir = "",
    [string] $OutFile = "",
    # Internal [Languages] name (e.g. "english") to force the wizard's language with
    # Inno's own /LANG= parameter, so a non-Chinese license can be checked from a
    # Chinese machine. Empty = let Inno pick from the system language.
    [string] $Lang = ""
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
}
'@

$setup = (Resolve-Path -LiteralPath $Setup).Path
if ([string]::IsNullOrWhiteSpace($ScratchDir)) { $ScratchDir = Join-Path $ScratchRoot 'dest' }
if ([string]::IsNullOrWhiteSpace($OutFile)) { $OutFile = Join-Path $ScratchRoot 'wizard-check.txt' }
$lines = New-Object System.Collections.Generic.List[string]

New-Item -ItemType Directory -Force -Path $ScratchRoot | Out-Null
if (Test-Path -LiteralPath $ScratchDir) {
    Remove-Item -LiteralPath $ScratchDir -Recurse -Force
}

function Find-Wizard {
    return Get-Process |
        Where-Object { $_.ProcessName -like 'Gracelink-Setup*' -and $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
}

# Only so the window is visible on screen while this runs (the dump works either way).
function Focus-Wizard {
    $p = Find-Wizard
    if (-not $p) { return $false }
    $h = $p.MainWindowHandle
    for ($i = 0; $i -lt 20; $i++) {
        [W32]::ShowWindow($h, 5) | Out-Null
        [W32]::BringWindowToTop($h) | Out-Null
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 200
        if ([W32]::GetForegroundWindow() -eq $h) { return $true }
    }
    return $false
}

# Which page are we on? The page heading is the TOPMOST named Pane (the page body text
# is a Document, not a Pane). Position, not text: an earlier version picked the first
# Pane whose name was shorter than 12 characters, which worked in Chinese ("许可协议")
# but on the English pages returned "Next".
function Get-PageTitle {
    $p = Find-Wizard
    if (-not $p) { return '' }
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
    $panes = $el.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Pane))
    $best = ''
    $bestTop = [double]::MaxValue
    foreach ($e in $panes) {
        $name = $e.Current.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $top = $e.Current.BoundingRectangle.Top
        if ($top -lt $bestTop) { $bestTop = $top; $best = $name }
    }
    return $best
}

function Post-AltKey([IntPtr] $h, [int] $vk) {
    # WM_SYSKEYDOWN(0x0104) / WM_SYSKEYUP(0x0105), Alt context = lParam bit 29
    [W32]::PostMessage($h, 0x0104, [IntPtr]$vk, [IntPtr](1 -bor 0x20000000)) | Out-Null
    Start-Sleep -Milliseconds 150
    [W32]::PostMessage($h, 0x0105, [IntPtr]$vk, [IntPtr](0xC0000001 -bor 0x20000000)) | Out-Null
}

# Post the given Alt+<key> sequence and wait for the heading to change. On the license page
# that means BOTH keystrokes went through (Alt+A selects "I accept", Alt+N turns the page --
# Alt+A on its own does not change anything), on the other pages Alt+N alone. Retries a few
# times and complains if the page never turns.
function Step-Keys([int[]] $vks, [string] $label, [string] $stayOn) {
    for ($i = 1; $i -le 5; $i++) {
        $p = Find-Wizard
        if (-not $p) {
            $lines.Add("WIZARD-GONE while sending $label")
            return $false
        }
        foreach ($vk in $vks) {
            Post-AltKey $p.MainWindowHandle $vk
            Start-Sleep -Milliseconds 350
        }
        Start-Sleep -Milliseconds 1400
        $title = Get-PageTitle
        if ($title -ne $stayOn -and -not [string]::IsNullOrWhiteSpace($title)) { return $true }
    }
    $lines.Add("STUCK ON '$stayOn': $label (try $i) did not turn the page")
    return $false
}

function Dump-Page([string] $label) {
    $p = Find-Wizard
    if (-not $p) { $lines.Add("=== ${label}: NO-WINDOW"); return }
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
    $lines.Add("=== $label | pid " + $p.Id + " | title: " + $el.Current.Name + " | heading: " + (Get-PageTitle))
    $elements = $el.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $seen = @{}
    foreach ($e in $elements) {
        $type = $e.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
        $name = $e.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $line = $type + ' | ' + $name
            if (-not $seen.ContainsKey($line)) { $seen[$line] = $true; $lines.Add($line) }
        }
        # The license page's text lives in a rich edit: grab it through TextPattern
        if ($type -ne 'Document' -and $type -ne 'Edit') { continue }
        $pattern = $null
        $text = ''
        if ($e.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
            # 协议页那份文本不短（英文那份五千多字符），多抓一点（600 只够看个开头）
            $text = $pattern.DocumentRange.GetText(20000)
        } elseif ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $text = $pattern.Current.Value
        }
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $flat = ($text -replace "`r?`n", ' / ').Trim()
            $line = 'TEXT(' + $type + ') | ' + $flat
            if (-not $seen.ContainsKey($line)) { $seen[$line] = $true; $lines.Add($line) }
        }
    }
}

Write-Host "setup: $setup"
Write-Host "scratch dir (never installed into): $ScratchDir"
$arguments = @('/DIR="' + $ScratchDir + '"')
if (-not [string]::IsNullOrWhiteSpace($Lang)) {
    Write-Host "language: $Lang (forced with /LANG=)"
    $arguments += "/LANG=$Lang"
}
Start-Process -FilePath $setup -ArgumentList $arguments | Out-Null

$wizard = $null
for ($i = 0; $i -lt 180; $i++) {
    $wizard = Find-Wizard
    if ($wizard) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $wizard) {
    Write-Host 'FAILED: the wizard never opened a window' -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 2
Focus-Wizard | Out-Null

Dump-Page 'page-1-license'
$page1 = Get-PageTitle

# Alt+A (accept) then Alt+N (next) on every try: the license page exposes no "is the radio
# selected" state, so the only proof the accept worked is the next page showing up. If the
# Alt+N lands while the page is still un-accepted it just does nothing, and the retry sends
# both keys again (Alt+A on an already-accepted page is harmless).
$advanced = Step-Keys @(0x41, 0x4E) 'Alt+A + Alt+N' $page1

if ($advanced) {
    Dump-Page 'page-2-destination'
    $page2 = Get-PageTitle
    if (Step-Keys @(0x4E) 'Alt+N' $page2) {
        Dump-Page 'page-3-tasks'
    } else {
        Write-Host 'FAILED: the destination page never moved on' -ForegroundColor Red
        Dump-Page 'page-3-MISSING'
    }
} else {
    Write-Host 'FAILED: the license page never accepted Alt+A + Alt+N' -ForegroundColor Red
    Dump-Page 'page-2-MISSING'
}

Get-Process | Where-Object { $_.ProcessName -like 'Gracelink-Setup*' } | Stop-Process -Force
$lines.Add('WIZARD-CLOSED-WITHOUT-INSTALLING')

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
$lines | Out-File -FilePath $OutFile -Encoding utf8
Write-Host ("wrote " + $lines.Count + " lines to " + $OutFile)
Write-Host 'check the three "heading:" lines, the license text, and the task list in that file'
