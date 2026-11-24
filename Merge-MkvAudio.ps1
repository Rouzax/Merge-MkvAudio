#Requires -Version 7.0
<#
.SYNOPSIS
    Merges a second-language audio track (Dutch by default) from one MKV into another.

.DESCRIPTION
    Takes a primary MKV (usually the better quality English release) and a
    secondary MKV that has the extra language, and adds to the primary:

      - the best audio track in the language (most channels, then lossless,
        then bitrate). This is required; without it nothing happens.
      - the SRT subtitles in the language, only when the primary has no
        non-forced SRT in that language. Image subtitles (PGS, VobSub) and
        forced subtitles are never taken. When neither file has one embedded,
        a sidecar file such as "<movie>.nl.srt" next to the primary (or else
        next to the secondary) is merged in instead.
      - the chapters, only when the primary has none.

    Nothing else from the secondary is used: no video, attachments, tags or
    other tracks. The primary's tracks and flags are untouched, so its original
    audio stays the default. Added tracks are neither default nor forced.

    Before merging, the script checks that the audio lines up: it compares
    the loudness of both soundtracks at seven points across the film and
    reports whether they are in sync, offset by a fixed amount, drifting, or
    cut differently. A fixed offset is corrected automatically: the added
    tracks are shifted by the measured amount and the check is run again with
    the shift applied; the offset is used only if that re-check is in sync.
    When the offset changes once (one release has a few seconds of footage
    the other lacks, such as a localized title card), the cut is located to
    10 ms and can be repaired: the added audio is rebuilt across it with
    ffmpeg (missing footage is filled with the primary's own audio, extra
    footage is cut out), re-encoded, and checked again; the added subtitles
    are re-timed to match.
    It does not merge unless the audio is in sync (or you pass -Force).

    The merge is written to a temporary .partial file next to the primary and
    checked. Only then is the primary renamed to "<name>.mkv.bak", the merged
    file put in its place, and the .bak deleted (keep it with -KeepBackup).

    Run it without -Primary and -Secondary for interactive mode: it asks for
    the two files (paste a path, or drag the file into the window), asks
    before merging, and offers to do another pair afterwards.

.PARAMETER Primary
    The MKV to merge into. It is replaced by the merged file.

.PARAMETER Secondary
    The MKV to take the language's audio, subtitles and chapters from. It is not changed.

.PARAMETER Language
    The language to merge, as a code such as nl, de or fr. Default: nl (Dutch).

.PARAMETER AudioTrackId
    Use this audio track ID from the secondary instead of choosing one by language.

.PARAMETER SyncOffsetMs
    Delay in milliseconds applied to the added tracks (negative makes them
    earlier). Rarely needed: the sync check finds and applies a fixed offset
    itself. Use it with -SkipSyncCheck when you already know the value.

.PARAMETER SkipSyncCheck
    Do not run the sync check.

.PARAMETER Force
    Merge even when the sync check is not "in sync".

.PARAMETER KeepBackup
    Keep the original primary as "<name>.mkv.bak" instead of deleting it after a verified merge.

.PARAMETER RepairCut
    When the sync check finds one clean cut (one release has a few seconds of
    footage the other lacks), repair it without asking: the added audio is
    rebuilt across the cut and re-encoded, and the added subtitles re-timed.
    Interactive mode asks instead.

.PARAMETER MaxRepairGapS
    The longest gap a cut repair may fill or remove, in seconds. Default 30:
    a few seconds of original-language sound in a dub go unnoticed, minutes
    do not.

.PARAMETER OutputPath
    Write the merged file here instead of replacing the primary, which is then
    left untouched (useful when the primary is still seeding).

.EXAMPLE
    .\Merge-MkvAudio.ps1

    Interactive mode: asks for the two files, shows the plan and sync check, then asks before merging.

.EXAMPLE
    .\Merge-MkvAudio.ps1 -Primary 'D:\Movies\Film (2024)\Film (2024).mkv' -Secondary 'D:\Downloads\Film.2024.NL.mkv' -WhatIf

    Shows both files, the plan and the sync check without writing anything.

.EXAMPLE
    .\Merge-MkvAudio.ps1 -Primary .\Film.mkv -Secondary .\Film.NL.mkv -SyncOffsetMs -480 -SkipSyncCheck

    Merges with the Dutch tracks moved 480 ms earlier, without checking (you already know the offset).

.NOTES
    Requires MKVToolNix (mkvmerge) and ffmpeg on PATH.
    Author: Rouzax
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$Primary,
    [string]$Secondary,
    [string]$Language = 'nl',
    [int]$AudioTrackId = -1,
    [int]$SyncOffsetMs = 0,
    [switch]$SkipSyncCheck,
    [switch]$Force,
    [switch]$KeepBackup,
    [switch]$RepairCut,
    [ValidateRange(0, 600)][double]$MaxRepairGapS = 30,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\MkvAudioMerge.psm1') -Force

#region Output helpers

$c = $PSStyle.Foreground
$script:Dim = $PSStyle.Dim
$script:Bold = $PSStyle.Bold
$script:Reset = $PSStyle.Reset

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host "  $($script:Bold)$($c.BrightCyan)$Text$($script:Reset)"
    Write-Host "  $($script:Dim)$('─' * 72)$($script:Reset)"
}

function Write-Field([string]$Label, [string]$Value, [string]$Color = '') {
    Write-Host ('  {0}{1,-10}{2} {3}{4}{2}' -f $script:Dim, $Label, $script:Reset, $Color, $Value)
}

function Write-Mark([ValidateSet('ok', 'add', 'keep', 'skip', 'warn', 'fail', 'info')][string]$Kind, [string]$Text, [string]$Detail = '') {
    $mark, $color = switch ($Kind) {
        'ok' { '✓', $c.BrightGreen }
        'add' { '+', $c.BrightGreen }
        'keep' { '=', $c.BrightBlue }
        'skip' { '-', $c.BrightBlack }
        'warn' { '!', $c.BrightYellow }
        'fail' { '✗', $c.BrightRed }
        'info' { '·', $c.BrightBlack }
    }
    $line = "    $color$mark$($script:Reset) $Text"
    if ($Detail) { $line += "  $($script:Dim)$Detail$($script:Reset)" }
    Write-Host $line
}

function Write-FileSummary([string]$Label, [pscustomobject]$Info) {
    Write-Title $Label
    Write-Field 'File' $Info.Name $script:Bold
    Write-Field 'Folder' (Split-Path $Info.Path -Parent) $script:Dim
    $fps = $Info.Fps.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    $chap = ($Info.Chapters -gt 0) ? "$($Info.Chapters) chapters" : 'no chapters'
    Write-Field 'Length' ('{0}   {1} fps   {2}   {3}' -f (Format-Duration $Info.DurationS), $fps, (Format-Size $Info.Size), $chap)
    foreach ($type in 'video', 'audio', 'subtitles') {
        $label = @{ video = 'Video'; audio = 'Audio'; subtitles = 'Subtitles' }[$type]
        $tracks = @($Info.Tracks | Where-Object Type -eq $type)
        if ($tracks.Count -eq 0) { Write-Field $label 'none' $script:Dim; continue }
        $first = $true
        foreach ($t in $tracks) {
            Write-Field ($first ? $label : '') (Format-TrackLine $t)
            $first = $false
        }
    }
}

function Read-YesNo([string]$Question, [bool]$Default = $true) {
    $hint = $Default ? '[Y/n]' : '[y/N]'
    while ($true) {
        $answer = (Read-Host "  $Question $hint").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in 'y', 'yes', 'j', 'ja') { return $true }
        if ($answer -in 'n', 'no', 'nee') { return $false }
    }
}

function Test-FileUnlocked([string]$Path) {
    # Exclusive open fails while anything else (a media server scanning it, a
    # player) holds the file, which would also make the final rename fail.
    try {
        [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None).Dispose()
        return $true
    } catch [IO.IOException] {
        return $false
    }
}

function Wait-FileUnlocked([string]$Path, [int]$TimeoutS = 600) {
    if (Test-FileUnlocked $Path) { return $true }
    Write-Mark warn "$(Split-Path $Path -Leaf) is open in another program" 'a media server scanning it, or someone playing it; waiting'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutS) {
        Write-Progress -Activity 'Waiting for the file to be released' -Status ('{0} of {1}' -f (Format-Duration $timer.Elapsed.TotalSeconds), (Format-Duration $TimeoutS)) `
            -PercentComplete ($timer.Elapsed.TotalSeconds / $TimeoutS * 100)
        Start-Sleep -Seconds 5
        if (Test-FileUnlocked $Path) {
            Write-Progress -Activity 'Waiting for the file to be released' -Completed
            Write-Mark ok 'File released' ('after {0}' -f (Format-Duration $timer.Elapsed.TotalSeconds))
            return $true
        }
    }
    Write-Progress -Activity 'Waiting for the file to be released' -Completed
    return $false
}

function Read-MkvPath([string]$Prompt) {
    while ($true) {
        $raw = Read-Host "  $Prompt"
        $path = ConvertFrom-PastedPath $raw
        if (-not $path) { return $null }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Mark fail "File not found: $path"
            continue
        }
        if ([IO.Path]::GetExtension($path) -ne '.mkv') {
            Write-Mark fail 'That is not an .mkv file.'
            continue
        }
        return (Resolve-Path -LiteralPath $path).ProviderPath
    }
}

#endregion

function Invoke-SyncCheck {
    param($PrimaryInfo, [int]$PrimaryTrackId, $SecondaryInfo, [int]$SecondaryTrackId, [int]$OffsetMs, [string]$What, [double[]]$At)

    Write-Host "    $($script:Dim)comparing $What$($script:Reset)"
    $onPoint = {
        param($p, $i, $n)
        $offset = ('{0:+0;-0;0} ms' -f $p.OffsetMs)
        $score = [math]::Max(0.0, [math]::Min(1.0, [double]$p.Peak))
        $bars = [int][math]::Round($score * 10)
        $clear = $p.Peak -ge 0.45 -and ($p.Peak - $p.RunnerUp) -ge 0.1 -and -not $p.AtEdge
        $color = (-not $clear) ? $c.BrightBlack : ([math]::Abs($p.OffsetMs) -le 40 ? $c.BrightGreen : $c.BrightYellow)
        $note = $clear ? '' : '  unclear match'
        $match = 'match ' + $score.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
        Write-Host ('    {0}  {1}{2,9}{3}   {4}{5}{3}{6}{3}  {7}{8}{9}{3}' -f (Format-Duration $p.TimeS), $color, $offset, $script:Reset,
            $color, ('█' * $bars), ($script:Dim + ('░' * (10 - $bars))), $script:Dim, $match, $note)
        Write-Progress -Activity 'Sync check' -Status "point $i of $n" -PercentComplete ($i / $n * 100)
    }
    $measure = @{
        Primary = $PrimaryInfo; PrimaryTrackId = $PrimaryTrackId; Secondary = $SecondaryInfo
        SecondaryTrackId = $SecondaryTrackId; AppliedOffsetMs = $OffsetMs; OnPoint = $onPoint
    }
    if ($At) { $measure.At = $At }
    $points = @(Measure-AudioOffset @measure)
    Write-Progress -Activity 'Sync check' -Completed
    $verdict = Get-SyncVerdict -Point $points
    $verdict | Add-Member -NotePropertyName Points -NotePropertyValue $points
    return $verdict
}

function Invoke-CutRepair {
    <#
    Handles a single clean jump in the sync check: one release has a few
    seconds of footage the other lacks. Locates the cut, rebuilds the added
    audio across it (and re-times the added subtitles), and re-checks sync.
    On success the plan's secondary tracks are replaced by the rebuilt files
    (plan.External) and the new verdict is returned; otherwise $null.
    #>
    param($PrimaryInfo, $PrimaryAudio, $SecondaryInfo, $Plan, $Lang, $Step, [int]$AppliedOffsetMs, [bool]$Interactive, [bool]$Allow, [double]$MaxGapS)

    # Offsets as secondary time minus primary time, without the applied shift.
    $before = $Step.BeforeMs - $AppliedOffsetMs
    $after = $Step.AfterMs - $AppliedOffsetMs
    $inv = [Globalization.CultureInfo]::InvariantCulture
    Write-Host ''
    Write-Mark info ('The offset changes once, between {0} and {1}: one cut, not a different edit throughout' -f (Format-Duration $Step.LastBeforeS), (Format-Duration $Step.FirstAfterS))
    Write-Progress -Activity 'Locating the cut' -Status 'comparing the soundtracks moment by moment'
    $cut = Find-AudioCut -Primary $PrimaryInfo -PrimaryTrackId $PrimaryAudio.Id -Secondary $SecondaryInfo -SecondaryTrackId $Plan.Audio.Id `
        -BeforeMs $before -AfterMs $after -FromS $Step.LastBeforeS -ToS ($Step.FirstAfterS + 30)
    Write-Progress -Activity 'Locating the cut' -Completed

    $at = '{0}.{1:00}' -f (Format-Duration ([math]::Floor($cut.PrimaryCutS))), [int](($cut.PrimaryCutS % 1) * 100)
    $gap = $cut.GapS.ToString('0.00', $inv)
    $found = ($cut.Mode -eq 'Insert') ? "The $($Lang.Name) release is missing $gap s of footage at $at" : "The $($Lang.Name) release has $gap s of extra footage at $at"
    Write-Mark warn $found ('agreement {0} before the cut, {1} after' -f $cut.ConfidenceBefore.ToString('0.00', $inv), $cut.ConfidenceAfter.ToString('0.00', $inv))
    if ($cut.ConfidenceBefore -lt 0.5 -or $cut.ConfidenceAfter -lt 0.5) {
        Write-Mark fail 'The cut could not be located reliably, so it is not repaired.'
        return $null
    }
    # A few seconds of original-language sound in a dub go unnoticed; minutes do not.
    if ($cut.GapS -gt $MaxGapS) {
        Write-Mark fail ('The gap is longer than {0} s, so it is not repaired automatically.' -f $MaxGapS) 'raise -MaxRepairGapS to allow it'
        return $null
    }
    $how = ($cut.Mode -eq 'Insert') ? "fill the $gap s with the primary's $($PrimaryAudio.Language) audio" : "cut the extra $gap s out"
    Write-Mark info "Repair: rebuild the $($Lang.Name) audio across the cut ($how), re-encoded; re-time the $($Lang.Name) subtitles to match."
    if ($WhatIfPreference) {
        Write-Mark info 'What if: the repaired track is not built or re-checked.'
        return [pscustomobject]@{ Verdict = 'InSync'; Points = @() }
    }
    if ($Interactive) {
        if (-not (Read-YesNo 'Repair the cut?' $true)) { return $null }
    } elseif (-not $Allow) {
        Write-Mark info 'Pass -RepairCut to repair it.'
        return $null
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('Merge-MkvAudio-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $script:TempDirs.Add($tmp)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $audioPath = New-RepairedAudioTrack -Primary $PrimaryInfo -PrimaryTrackId $PrimaryAudio.Id -Secondary $SecondaryInfo `
        -SecondaryTrack $Plan.Audio -Cut $cut -OutputPath (Join-Path $tmp 'audio.mka')
    $rebuilt = Get-MkvInfo $audioPath
    Write-Mark ok "Rebuilt the $($Lang.Name) audio track" ('{0}, {1}, in {2}' -f (Format-TrackLine $rebuilt.Tracks[0] -NoFlags), (Format-Duration $rebuilt.DurationS), (Format-Duration $timer.Elapsed.TotalSeconds))

    # Re-check: the usual seven points plus four close around the cut.
    $syncMs = -$before
    $span = [math]::Min($PrimaryInfo.DurationS, $rebuilt.DurationS) - 30
    $primaryGap = ($cut.Mode -eq 'Insert') ? $cut.GapS : 0
    $near = @(($cut.PrimaryCutS - 75), ($cut.PrimaryCutS - 35), ($cut.PrimaryCutS + $primaryGap + 5), ($cut.PrimaryCutS + $primaryGap + 45)) |
        Where-Object { $_ -ge 0 -and $_ -le $span }
    $points = @(@(0.05, 0.2, 0.35, 0.5, 0.65, 0.8, 0.95) + @($near | ForEach-Object { $_ / $span }) | Sort-Object)
    Write-Host ''
    $recheck = Invoke-SyncCheck $PrimaryInfo $PrimaryAudio.Id $rebuilt 0 $syncMs "primary with the rebuilt $($Lang.Name) track" -At $points
    Write-SyncVerdict $recheck $syncMs
    if ($recheck.Verdict -ne 'InSync') {
        Write-Mark fail 'The rebuilt track is not in sync, so it is not used.'
        return $null
    }

    # Dense scan of the whole stretch that held the jump, every 20 s. A second
    # cut close to the first would look like one bigger jump at the seven
    # points; any part placed wrongly by the repair shows up here.
    $fromS = [math]::Max(0.0, $Step.LastBeforeS)
    $toS = [math]::Min($Step.FirstAfterS + 30, $span)
    $denseSpan = [math]::Min($PrimaryInfo.DurationS, $rebuilt.DurationS) - 15
    $times = for ($t = $fromS; $t -le $toS; $t += 20) { $t }
    Write-Host ''
    Write-Host ("    $($script:Dim)scanning {0} to {1} every 20 s ({2} points)$($script:Reset)" -f (Format-Duration $fromS), (Format-Duration $toS), @($times).Count)
    # $args: point, index, count (the point itself is not needed here).
    $onDense = { Write-Progress -Activity 'Scanning around the cut' -Status "point $($args[1]) of $($args[2])" -PercentComplete ($args[1] / $args[2] * 100) }
    $dense = @(Measure-AudioOffset -Primary $PrimaryInfo -PrimaryTrackId $PrimaryAudio.Id -Secondary $rebuilt -SecondaryTrackId 0 `
            -AppliedOffsetMs $syncMs -At @($times | ForEach-Object { $_ / $denseSpan }) -WindowS 15 -SearchS 10 -OnPoint $onDense)
    Write-Progress -Activity 'Scanning around the cut' -Completed
    $denseVerdict = Get-SyncVerdict -Point $dense
    $off = @($dense | Where-Object { $_.Peak -ge 0.45 -and ($_.Peak - $_.RunnerUp) -ge 0.1 -and -not $_.AtEdge -and [math]::Abs($_.OffsetMs) -gt 40 })
    if ($denseVerdict.Verdict -ne 'InSync') {
        foreach ($p in $off) { Write-Mark fail ('{0}  {1:+0;-0;0} ms' -f (Format-Duration $p.TimeS), $p.OffsetMs) 'out of sync here' }
        Write-Mark fail "The stretch around the cut is not in sync everywhere ($($denseVerdict.Verdict)): probably more than one cut. Not repaired."
        return $null
    }
    Write-Mark ok 'Stretch around the cut in sync' ("$($denseVerdict.Reliable) of $($denseVerdict.Total) points clear, largest deviation $($denseVerdict.DeviationMs) ms")

    $external = [Collections.Generic.List[pscustomobject]]::new()
    $external.Add([pscustomobject]@{
            Type = 'audio'; Path = $audioPath; LanguageIetf = $Lang.Ietf; Name = $Plan.Audio.Name
            Channels = $Plan.Audio.Channels; SyncMs = $syncMs
        })
    $n = 0
    foreach ($s in $Plan.Subtitles) {
        $n++
        $srt = New-RepairedSubtitle -Cut $cut -OutputPath (Join-Path $tmp "subtitle$n.srt") -MkvPath $SecondaryInfo.Path -TrackId $s.Id
        $external.Add([pscustomobject]@{ Type = 'subtitles'; Path = $srt; LanguageIetf = $Lang.Ietf; Name = $s.Name; Charset = 'UTF-8'; SyncMs = $syncMs })
    }
    $side = $Plan.SidecarSubtitle
    if ($side -and $side.Origin -eq 'Secondary') {
        $n++
        $srt = New-RepairedSubtitle -Cut $cut -OutputPath (Join-Path $tmp "subtitle$n.srt") -SrtPath $side.Path -Charset ($side.Charset ?? 'UTF-8')
        $external.Add([pscustomobject]@{ Type = 'subtitles'; Path = $srt; LanguageIetf = $Lang.Ietf; Name = ''; Charset = 'UTF-8'; SyncMs = $syncMs })
        $Plan.SidecarSubtitle = $null
    }
    if ($n -gt 0) { Write-Mark ok "Re-timed $n $($Lang.Name) subtitle track(s) across the cut" }
    if ($Plan.Chapters) {
        $Plan.Chapters = $false
        Write-Mark warn "The secondary's chapters are skipped: they follow the other cut."
    }
    $Plan.Audio = $null
    $Plan.Subtitles = @()
    $Plan | Add-Member -NotePropertyName External -NotePropertyValue $external -Force
    return $recheck
}

function Write-SyncVerdict($Verdict, [int]$OffsetMs) {
    $n = "$($Verdict.Reliable) of $($Verdict.Total) points"
    switch ($Verdict.Verdict) {
        'InSync' {
            $extra = ($Verdict.Outliers -gt 0) ? ", 1 stray point ignored" : ''
            Write-Mark ok "$($c.BrightGreen)In sync$($script:Reset)" "$n agree, largest deviation $($Verdict.DeviationMs) ms$extra"
        }
        'Offset' {
            $suggest = $OffsetMs - $Verdict.OffsetMs
            $dir = ($Verdict.OffsetMs -gt 0) ? 'late' : 'early'
            Write-Mark warn "$($c.BrightYellow)Fixed offset: the secondary audio is $([math]::Abs($Verdict.OffsetMs)) ms $dir$($script:Reset)" $n
            Write-Mark info "Offset that should line them up: $suggest ms"
        }
        'Drift' {
            Write-Mark fail "$($c.BrightRed)Drifting: the offset grows by about $([math]::Abs($Verdict.DriftMsPerHour)) ms per hour$($script:Reset)" $n
            Write-Mark info 'The two releases run at different speeds (for example 25 fps PAL against 23.976). That needs re-timing, which this script does not do.'
        }
        'Inconsistent' {
            Write-Mark fail "$($c.BrightRed)Inconsistent: the offset jumps between points$($script:Reset)" $n
            Write-Mark info 'The releases are probably different cuts, or one has scenes added or removed.'
        }
        'Inconclusive' {
            Write-Mark warn "$($c.BrightYellow)Inconclusive: only $n gave a clear match$($script:Reset)"
            Write-Mark info 'The soundtracks may be too different to compare. Check a few scenes by hand.'
        }
    }
}

function Invoke-Merge {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string]$PrimaryPath,
        [string]$SecondaryPath,
        [bool]$Interactive,
        [string]$LanguageCode,
        [int]$AudioTrackId,
        [int]$SyncOffsetMs,
        [bool]$SkipSyncCheck,
        [bool]$Force,
        [bool]$KeepBackup,
        [bool]$RepairCut,
        [double]$MaxRepairGapS,
        [string]$OutputPath
    )

    $lang = Get-LanguageCode $LanguageCode
    $prim = Get-MkvInfo $PrimaryPath
    $sec = Get-MkvInfo $SecondaryPath
    if ($prim.Path -eq $sec.Path) { Write-Mark fail 'Primary and secondary are the same file.'; return $false }

    Write-FileSummary 'Primary  (merge into)' $prim
    Write-FileSummary "Secondary  (take $($lang.Name) from)" $sec

    # Untagged tracks: ask rather than guess.
    $untaggedAs = @()
    $untagged = @(Get-UntaggedTrack -Primary $prim -Secondary $sec -Language $lang)
    if ($untagged.Count -gt 0 -and $AudioTrackId -lt 0) {
        Write-Title 'Untagged tracks'
        foreach ($u in $untagged) {
            $desc = "$($u.File) $(Format-TrackLine $u.Track)"
            if (-not $Interactive -and -not [Environment]::UserInteractive) { throw "Track has no language tag: $desc" }
            if (Read-YesNo "Is $desc $($lang.Name)?" $false) { $untaggedAs += "$($u.File):$($u.Track.Id)" }
        }
    }

    # Sidecar subtitles next to either file, used only when neither has one embedded.
    $sidecars = foreach ($info in @(@{ I = $prim; O = 'Primary' }, @{ I = $sec; O = 'Secondary' })) {
        $dir = Split-Path $info.I.Path -Parent
        # Select-Object, not ForEach-Object Name (which honours -WhatIf and prints a line per
        # file) or .Name (which yields one $null for a folder without .srt files).
        $names = @(Get-ChildItem -LiteralPath $dir -Filter '*.srt' -File | Select-Object -ExpandProperty Name)
        Find-SidecarSubtitle -FileName $names -Directory $dir -BaseName ([IO.Path]::GetFileNameWithoutExtension($info.I.Path)) -Language $lang -Origin $info.O
    }
    foreach ($s in $sidecars) { Write-Field 'Sidecar' "$($s.Name)  $($script:Dim)next to the $($s.Origin.ToLowerInvariant())$($script:Reset)" }

    $plan = New-MergePlan -Primary $prim -Secondary $sec -Language $lang -UntaggedAs $untaggedAs -AudioTrackId $AudioTrackId -Sidecar @($sidecars)
    if ($plan.SidecarSubtitle) {
        $plan.SidecarSubtitle.Charset = Get-TextCharset ([IO.File]::ReadAllBytes($plan.SidecarSubtitle.Path))
    }
    Write-Title 'Plan'
    if ($plan.Error) { Write-Mark fail $plan.Error; return $false }
    Write-Mark add "Audio      $(Format-TrackLine $plan.Audio -NoFlags)" $plan.Notes[0]
    foreach ($s in $plan.Subtitles) { Write-Mark add "Subtitles  $(Format-TrackLine $s -NoFlags)" "primary has no $($lang.Name) SRT" }
    if ($plan.SidecarSubtitle) {
        $side = $plan.SidecarSubtitle
        Write-Mark add "Subtitles  $($side.Name)  $($side.Charset)" "sidecar next to the $($side.Origin.ToLowerInvariant()); neither file has $($lang.Name) SRT embedded"
    }
    if ($plan.Chapters) { Write-Mark add "Chapters   $($sec.Chapters) from the secondary" 'primary has none' }
    foreach ($note in $plan.Notes | Select-Object -Skip 1) { Write-Mark keep $note }
    foreach ($s in $plan.Skipped) { Write-Mark skip "Skip       $(Format-TrackLine $s.Track)" $s.Reason }
    Write-Mark info 'Added tracks are not default and not forced; the primary audio stays the default.'
    if ($SyncOffsetMs -ne 0) { Write-Mark info "Added tracks are shifted by $SyncOffsetMs ms." }

    # Pre-checks
    Write-Title 'Pre-checks'
    $ok = $true
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($prim.Fps -gt 0 -and $sec.Fps -gt 0 -and [math]::Abs($prim.Fps - $sec.Fps) -gt 0.01) {
        Write-Mark fail ('Frame rates differ: {0} against {1} fps' -f $prim.Fps.ToString('0.000', $inv), $sec.Fps.ToString('0.000', $inv)) 'audio from a different speed will drift'
        $ok = $false
    } else {
        Write-Mark ok 'Frame rates match' "$($prim.Fps.ToString('0.000', $inv)) fps"
    }
    $diff = $sec.DurationS - $prim.DurationS
    if ([math]::Abs($diff) -le 2) {
        Write-Mark ok 'Lengths match' ('difference {0} s' -f [math]::Abs($diff).ToString('0.0', $inv))
    } else {
        Write-Mark warn ('Lengths differ by {0}' -f (Format-Duration ([math]::Abs($diff)))) 'a different cut, or extra logos or credits; the sync check will tell'
    }

    $syncOk = $true
    $offsetMs = $SyncOffsetMs
    if ($SkipSyncCheck) {
        Write-Mark warn 'Sync check skipped (-SkipSyncCheck)'
    } else {
        Write-Title 'Sync check'
        $primAudio = Select-SyncReferenceTrack $prim.Tracks
        if (-not $primAudio.Default) {
            Write-Mark info "Listening to primary #$($primAudio.Id) $($primAudio.Codec) for the checks" "same mix as the default track, much faster to decode than TrueHD"
        }
        $syncTrackId = $plan.Audio.Id
        $verdict = Invoke-SyncCheck $prim $primAudio.Id $sec $syncTrackId $offsetMs `
            "primary #$($primAudio.Id) $($primAudio.Language) with secondary #$($plan.Audio.Id) $($plan.Audio.Language)"

        # When the languages are too different to compare, check the secondary's
        # timeline through its own track in the primary's language instead.
        if ($verdict.Verdict -eq 'Inconclusive') {
            $same = $sec.Tracks | Where-Object { $_.Type -eq 'audio' -and $_.Id -ne $plan.Audio.Id -and $_.Language -eq $primAudio.Language } |
                Select-Object -First 1
            if ($same) {
                Write-Mark info "Retrying with the secondary's own $($same.Language) track, which shares the timeline of the $($lang.Name) track"
                $syncTrackId = $same.Id
                $verdict = Invoke-SyncCheck $prim $primAudio.Id $sec $syncTrackId $offsetMs "primary #$($primAudio.Id) with secondary #$($same.Id) $($same.Language)"
            }
        }
        Write-SyncVerdict $verdict $offsetMs

        # A fixed offset can be corrected: shift the added tracks by the measured
        # amount and check again with the shift applied before trusting it.
        if ($verdict.Verdict -eq 'Offset') {
            $inferred = $offsetMs - $verdict.OffsetMs
            $apply = $true
            if ($Interactive -and -not $WhatIfPreference) {
                $apply = Read-YesNo "Shift the $($lang.Name) tracks by $inferred ms and check again?" $true
            }
            if ($apply) {
                Write-Host ''
                $recheck = Invoke-SyncCheck $prim $primAudio.Id $sec $syncTrackId $inferred "again with the $($lang.Name) tracks shifted by $inferred ms"
                Write-SyncVerdict $recheck $inferred
                if ($recheck.Verdict -eq 'InSync') {
                    $offsetMs = $inferred
                    Write-Mark ok "Using an offset of $offsetMs ms" "same as -SyncOffsetMs $offsetMs"
                }
                $verdict = $recheck
            }
        }

        # One clean jump (a shot one release lacks) can be repaired.
        if ($verdict.Verdict -eq 'Inconsistent' -and $syncTrackId -eq $plan.Audio.Id) {
            $step = Get-SyncStep -Point $verdict.Points
            if ($step) {
                $repaired = Invoke-CutRepair -PrimaryInfo $prim -PrimaryAudio $primAudio -SecondaryInfo $sec -Plan $plan -Lang $lang `
                    -Step $step -AppliedOffsetMs $offsetMs -Interactive $Interactive -Allow $RepairCut -MaxGapS $MaxRepairGapS
                if ($repaired) { $verdict = $repaired }
            }
        }
        $syncOk = $verdict.Verdict -eq 'InSync'
    }

    if (-not ($ok -and $syncOk)) {
        if ($Force) {
            Write-Mark warn 'Continuing anyway (-Force)'
        } elseif ($Interactive -and -not $WhatIfPreference) {
            if (-not (Read-YesNo 'The checks did not pass. Merge anyway?' $false)) { return $false }
        } else {
            Write-Host ''
            Write-Mark fail 'Not merging. Fix the cause, or pass -Force to merge anyway.'
            return $false
        }
    }

    # Output paths and space. With -OutputPath the primary is left untouched.
    $replace = -not $OutputPath
    if ($replace) {
        $target = $prim.Path
        $partial = Join-Path (Split-Path $prim.Path -Parent) ([IO.Path]::GetFileNameWithoutExtension($prim.Path) + '.merging.mkv.partial')
        $backup = "$($prim.Path).bak"
        if (Test-Path -LiteralPath $backup) {
            Write-Mark fail "A backup already exists: $(Split-Path $backup -Leaf)" 'delete or move it first'
            return $false
        }
    } else {
        $target = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $partial = "$target.partial"
        if (Test-Path -LiteralPath $target) { Write-Mark fail "The output file already exists: $target"; return $false }
        if (-not (Test-Path -LiteralPath (Split-Path $target -Parent) -PathType Container)) { Write-Mark fail "The output folder does not exist: $(Split-Path $target -Parent)"; return $false }
    }
    $audioBps = $plan.Audio ? $plan.Audio.Bps : 640000
    $needed = $prim.Size + $audioBps / 8 * $prim.DurationS + 512MB
    $free = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($target))).AvailableFreeSpace
    if ($free -lt $needed) {
        Write-Mark fail "Not enough free space: $(Format-Size $needed) needed, $(Format-Size $free) free"
        return $false
    }

    if ($replace -and -not $WhatIfPreference -and -not (Wait-FileUnlocked $prim.Path)) {
        Write-Mark fail 'The primary is still in use after 10 minutes. Close whatever has it open and try again.'
        return $false
    }

    $mkvArgs = New-MkvMergeArgument -Primary $prim -Secondary $sec -Plan $plan -OutputPath $partial -SyncOffsetMs $offsetMs
    Write-Verbose ("mkvmerge " + (($mkvArgs | ForEach-Object { ($_ -match '\s') ? "`"$_`"" : $_ }) -join ' '))

    if ($Interactive -and -not $WhatIfPreference) {
        Write-Host ''
        if (-not (Read-YesNo "Merge now? About $(Format-Size $needed) is written next to the primary." $true)) { return $false }
    }
    $what = "Merge $($lang.Name) tracks from '$($sec.Name)'" +
        ((-not $replace) ? " into a new file (the primary is not changed)" : ($KeepBackup ? ' (original kept as .bak)' : ' (original deleted once verified)'))
    if (-not $PSCmdlet.ShouldProcess($target, $what)) {
        return $true
    }

    Write-Title 'Merging'
    $done = $false
    $warnings = [Collections.Generic.List[string]]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        & mkvmerge @mkvArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($line -match '^#GUI#progress (\d+)%') {
                Write-Progress -Activity 'Merging' -Status "$($Matches[1])%" -PercentComplete ([int]$Matches[1])
            } elseif ($line -match '^#GUI#(warning|error) (.*)$') {
                $warnings.Add("$($Matches[1]): $($Matches[2])")
            }
        }
        $exit = $LASTEXITCODE
        Write-Progress -Activity 'Merging' -Completed
        foreach ($w in $warnings) { Write-Mark warn $w }
        if ($exit -ge 2) { Write-Mark fail "mkvmerge failed (exit code $exit)"; return $false }
        Write-Mark ok ('mkvmerge finished in {0}' -f (Format-Duration $timer.Elapsed.TotalSeconds)) (($exit -eq 1) ? 'with warnings' : '')

        $out = Get-MkvInfo $partial
        $problems = Test-MergedOutput -Primary $prim -Plan $plan -Output $out
        if ($problems.Count -gt 0) {
            foreach ($p in $problems) { Write-Mark fail $p }
            Write-Mark fail 'The merged file did not pass verification; the primary is unchanged.'
            return $false
        }
        Write-Mark ok 'Merged file verified' "$($out.Tracks.Count) tracks, $(Format-Duration $out.DurationS), $($out.Chapters) chapters"

        if (-not $replace) {
            Rename-Item -LiteralPath $partial -NewName (Split-Path $target -Leaf)
            $done = $true
            Write-Title 'Done'
            Write-FileSummary 'Result' (Get-MkvInfo $target)
            Write-Host ''
            Write-Mark info 'The primary was not changed.'
            return $true
        }

        # Something may have opened the primary during the merge; wait rather than lose the merge.
        if (-not (Wait-FileUnlocked $prim.Path)) {
            $done = $true   # keep the verified merge
            Write-Mark fail 'The primary is still in use, so it was not replaced.'
            Write-Mark info "The verified merge is kept as $(Split-Path $partial -Leaf). Once the primary is free, delete it and rename the .partial to $($prim.Name)."
            return $false
        }
        Rename-Item -LiteralPath $prim.Path -NewName (Split-Path $backup -Leaf)
        try {
            Rename-Item -LiteralPath $partial -NewName $prim.Name
        } catch {
            Rename-Item -LiteralPath $backup -NewName $prim.Name   # put the original back
            throw
        }
        $done = $true
    } finally {
        if (-not $done -and (Test-Path -LiteralPath $partial)) { Remove-Item -LiteralPath $partial -Force }
    }

    Write-Title 'Done'
    Write-FileSummary 'Result' (Get-MkvInfo $prim.Path)
    Write-Host ''
    if ($KeepBackup) {
        Write-Mark info "Original kept as $(Split-Path $backup -Leaf). Delete it once you have checked the result."
    } else {
        Remove-Item -LiteralPath $backup -Force
        Write-Mark ok 'Original deleted' "the merged file replaced it and passed verification ($(Format-Size $prim.Size) freed)"
    }
    return $true
}

# Entry point
foreach ($tool in 'mkvmerge', 'ffmpeg') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool was not found on PATH." }
}

$script:TempDirs = [Collections.Generic.List[string]]::new()
$interactive = -not ($Primary -and $Secondary)
Write-Host ''
Write-Host "  $($script:Bold)Merge-MkvAudio$($script:Reset)  $($script:Dim)add $((Get-LanguageCode $Language).Name) audio to an MKV$($script:Reset)"

do {
    if ($interactive) {
        Write-Host ''
        Write-Host "  $($script:Dim)Paste a path or drag the file into this window. Press Enter on an empty line to quit.$($script:Reset)"
        $Primary = Read-MkvPath 'Primary   (the file to merge into)'
        if (-not $Primary) { break }
        $Secondary = Read-MkvPath 'Secondary (the file with the extra language)'
        if (-not $Secondary) { break }
    }
    try {
        $mergeOptions = @{
            PrimaryPath   = $Primary
            SecondaryPath = $Secondary
            Interactive   = $interactive
            LanguageCode  = $Language
            AudioTrackId  = $AudioTrackId
            SyncOffsetMs  = $SyncOffsetMs
            SkipSyncCheck = $SkipSyncCheck.IsPresent
            Force         = $Force.IsPresent
            KeepBackup    = $KeepBackup.IsPresent
            RepairCut     = $RepairCut.IsPresent
            MaxRepairGapS = $MaxRepairGapS
            OutputPath    = $OutputPath
        }
        $null = Invoke-Merge @mergeOptions
    } catch {
        if (-not $interactive) { throw }
        Write-Mark fail $_.Exception.Message
    } finally {
        foreach ($d in $script:TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        $script:TempDirs.Clear()
    }
} while ($interactive -and (Read-YesNo 'Merge another pair?' $false))
Write-Host ''
