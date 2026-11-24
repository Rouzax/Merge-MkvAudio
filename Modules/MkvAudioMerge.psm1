#Requires -Version 7.0
<#
.SYNOPSIS
    Track selection, sync checking and verification logic for Merge-MkvAudio.

.DESCRIPTION
    Pure functions (track normalization, language matching, merge planning,
    sync verdicts, mkvmerge argument building, output verification and
    formatting) are kept separate from the few functions that call mkvmerge
    or ffmpeg, so the decision logic can be tested without media files.
#>

Set-StrictMode -Version Latest

# ISO 639-2 has two codes for some languages: the bibliographic (B) code that
# Matroska files commonly carry (dut, ger, fre) and the terminology (T) code
# that .NET returns (nld, deu, fra). Map T to B so both are recognized.
$script:BibliographicCodes = @{
    sqi = 'alb'; hye = 'arm'; eus = 'baq'; mya = 'bur'; zho = 'chi'; ces = 'cze'
    nld = 'dut'; fra = 'fre'; kat = 'geo'; deu = 'ger'; ell = 'gre'; isl = 'ice'
    mkd = 'mac'; mri = 'mao'; msa = 'may'; fas = 'per'; ron = 'rum'; slk = 'slo'
    bod = 'tib'; cym = 'wel'
}

# Codec IDs of text subtitles that count as "SRT". Image formats (PGS,
# VobSub, DVB) and styled formats (ASS/SSA) are deliberately not included.
$script:SrtCodecIds = @('S_TEXT/UTF8', 'S_TEXT/ASCII')

# Lossless audio ranks above lossy when two candidates have the same channels.
$script:LosslessCodecIds = @('A_TRUEHD', 'A_FLAC', 'A_PCM/INT/LIT', 'A_PCM/INT/BIG', 'A_PCM/FLOAT/IEEE')

if (-not ('MkvAudioMerge.SyncMath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
namespace MkvAudioMerge {
    public static class SyncMath {
        // Log energy of consecutive frames of 16-bit little-endian mono PCM.
        public static double[] Envelope(byte[] pcm, int frameSamples) {
            int n = pcm.Length / 2 / frameSamples;
            var env = new double[n];
            for (int i = 0; i < n; i++) {
                double sum = 0;
                for (int j = 0; j < frameSamples; j++) {
                    int k = (i * frameSamples + j) * 2;
                    double v = (short)(pcm[k] | (pcm[k + 1] << 8));
                    sum += v * v;
                }
                env[i] = Math.Log10(sum / frameSamples + 1.0);
            }
            return env;
        }

        // Normalized cross-correlation of reference r against candidate c at
        // every lag from 0 to c.Length - r.Length. 1.0 is a perfect match.
        public static double[] Correlate(double[] r, double[] c) {
            int m = r.Length, lags = c.Length - m + 1;
            if (m == 0 || lags <= 0) return new double[0];
            double rm = 0; for (int i = 0; i < m; i++) rm += r[i]; rm /= m;
            double rs = 0; for (int i = 0; i < m; i++) rs += (r[i] - rm) * (r[i] - rm);
            var res = new double[lags];
            for (int l = 0; l < lags; l++) {
                double cm = 0; for (int i = 0; i < m; i++) cm += c[l + i]; cm /= m;
                double num = 0, cs = 0;
                for (int i = 0; i < m; i++) { double d = c[l + i] - cm; num += (r[i] - rm) * d; cs += d * d; }
                res[l] = (rs > 0 && cs > 0) ? num / Math.Sqrt(rs * cs) : 0;
            }
            return res;
        }
    }
}
'@
}

#region Pure logic

function Get-LanguageCode {
    <#
    .SYNOPSIS
        Resolves a language (nl, nld, dut, Dutch) to the set of tags Matroska uses for it.
    .OUTPUTS
        PSCustomObject with Ietf (two-letter), Codes (ISO 639-2 B and T) and Name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Language)

    $culture = $null
    try {
        $culture = [Globalization.CultureInfo]::GetCultureInfo($Language)
    } catch [Globalization.CultureNotFoundException] {
        $culture = $null
    }
    if ($Language.Length -eq 3 -and (-not $culture -or $culture.LCID -eq 4096)) {
        # Three-letter codes are not culture names; find the culture that owns them.
        $reverse = @{}
        foreach ($pair in $script:BibliographicCodes.GetEnumerator()) { $reverse[$pair.Value] = $pair.Key }
        $tCode = $reverse[$Language.ToLowerInvariant()] ?? $Language.ToLowerInvariant()
        $culture = [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::NeutralCultures) |
            Where-Object { $_.ThreeLetterISOLanguageName -eq $tCode } | Select-Object -First 1
    }
    # ICU accepts any well-formed name ("zz") as a culture, but unknown ones have no ISO 639-2 code.
    if (-not $culture -or [string]::IsNullOrEmpty($culture.ThreeLetterISOLanguageName) -or $culture.ThreeLetterISOLanguageName -eq 'ivl') {
        throw "Unknown language '$Language'. Use a code such as nl, de or fr."
    }
    $neutral = $culture.IsNeutralCulture ? $culture : $culture.Parent
    $t = $neutral.ThreeLetterISOLanguageName
    $codes = @($t)
    if ($script:BibliographicCodes.ContainsKey($t)) { $codes += $script:BibliographicCodes[$t] }

    [pscustomobject]@{
        Ietf  = $neutral.TwoLetterISOLanguageName
        Codes = $codes
        Name  = $neutral.EnglishName
    }
}

function ConvertTo-MkvTrack {
    <#
    .SYNOPSIS
        Flattens one track from mkvmerge -J output into the fields this tool uses.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, ValueFromPipeline)][object]$Track)

    process {
        $p = $Track.properties
        $get = { param($name) ($p.PSObject.Properties[$name])?.Value }
        $codecId = [string](& $get 'codec_id')
        $bps = & $get 'tag_bps'
        [pscustomobject]@{
            Id           = [int]$Track.id
            Type         = [string]$Track.type
            Codec        = [string]$Track.codec
            CodecId      = $codecId
            Language     = [string]((& $get 'language') ?? 'und')
            LanguageIetf = [string]((& $get 'language_ietf') ?? '')
            Name         = [string]((& $get 'track_name') ?? '')
            Default      = [bool](& $get 'default_track')
            Forced       = [bool](& $get 'forced_track')
            Channels     = [int]((& $get 'audio_channels') ?? 0)
            Bps          = [long]($bps ? $bps : 0)
            Dimensions   = [string]((& $get 'pixel_dimensions') ?? '')
            FrameNs      = [long]((& $get 'default_duration') ?? 0)
            IsSrt        = $Track.type -eq 'subtitles' -and $script:SrtCodecIds -contains $codecId
        }
    }
}

function ConvertTo-MkvInfo {
    <#
    .SYNOPSIS
        Turns the parsed JSON of mkvmerge -J into a file summary.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Json,
        [Parameter(Mandatory)][string]$Path,
        [long]$Size = 0
    )

    $props = $Json.container.properties
    $chapters = 0
    foreach ($c in @($Json.chapters)) {
        if ($c) { $chapters += [int]$c.num_entries }
    }
    $tracks = @($Json.tracks | ConvertTo-MkvTrack)
    $video = $tracks | Where-Object Type -eq 'video' | Select-Object -First 1

    [pscustomobject]@{
        Path       = $Path
        Name       = Split-Path $Path -Leaf
        Size       = $Size
        DurationS  = [double](($props.PSObject.Properties['duration'])?.Value ?? 0) / 1e9
        Fps        = ($video -and $video.FrameNs -gt 0) ? [math]::Round(1e9 / $video.FrameNs, 3) : 0
        Chapters   = $chapters
        Tracks     = $tracks
    }
}

function Test-TrackLanguage {
    <#
    .SYNOPSIS
        Tells whether a track is in the given language.
    .OUTPUTS
        $true or $false, or $null when the track has no language tag (und).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Track,
        [Parameter(Mandatory)][pscustomobject]$Language
    )

    if ($Track.LanguageIetf -and $Track.LanguageIetf -ne 'und') {
        return ($Track.LanguageIetf -split '-')[0] -eq $Language.Ietf
    }
    if ($Track.Language -and $Track.Language -ne 'und') {
        return $Language.Codes -contains $Track.Language.ToLowerInvariant()
    }
    return $null
}

function Get-UntaggedTrack {
    <#
    .SYNOPSIS
        Lists untagged tracks whose language must be asked before planning.
    .DESCRIPTION
        Only tracks that could change the plan are returned: secondary audio
        when no tagged audio is in the target language, secondary SRT when no
        tagged SRT is, and primary subtitles when the primary has no tagged
        target-language SRT.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Language', Justification = 'Used inside the $isUnd and $isTarget script blocks, which the rule does not follow.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Primary,
        [Parameter(Mandatory)][pscustomobject]$Secondary,
        [Parameter(Mandatory)][pscustomobject]$Language
    )

    $isUnd = { param($t) $null -eq (Test-TrackLanguage -Track $t -Language $Language) }
    $isTarget = { param($t) (Test-TrackLanguage -Track $t -Language $Language) -eq $true }

    $secAudio = @($Secondary.Tracks | Where-Object Type -eq 'audio')
    if (-not ($secAudio | Where-Object { & $isTarget $_ })) {
        $secAudio | Where-Object { & $isUnd $_ } | ForEach-Object { [pscustomobject]@{ File = 'Secondary'; Track = $_ } }
    }

    $primSrt = @($Primary.Tracks | Where-Object { $_.IsSrt -and -not $_.Forced })
    $primaryHasTarget = [bool]($primSrt | Where-Object { & $isTarget $_ })
    if (-not $primaryHasTarget) {
        $primSrt | Where-Object { & $isUnd $_ } | ForEach-Object { [pscustomobject]@{ File = 'Primary'; Track = $_ } }

        $secSrt = @($Secondary.Tracks | Where-Object { $_.IsSrt -and -not $_.Forced })
        if (-not ($secSrt | Where-Object { & $isTarget $_ })) {
            $secSrt | Where-Object { & $isUnd $_ } | ForEach-Object { [pscustomobject]@{ File = 'Secondary'; Track = $_ } }
        }
    }
}

function Select-BestAudioTrack {
    <#
    .SYNOPSIS
        Picks the best audio track: most channels, then lossless, then highest bitrate.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Track)

    $Track | Sort-Object -Stable -Descending -Property `
        @{ Expression = { $_.Channels } },
        @{ Expression = { $script:LosslessCodecIds -contains $_.CodecId } },
        @{ Expression = { $_.Bps } } |
        Select-Object -First 1
}

function New-MergePlan {
    <#
    .SYNOPSIS
        Decides which secondary tracks and chapters go into the merged file.
    .DESCRIPTION
        Rules:
          - Audio: the best target-language audio track of the secondary. Required.
          - Subtitles: every non-forced target-language SRT of the secondary, but
            only when the primary has no non-forced target-language SRT. Image
            subtitles in the primary do not count, and are never taken.
            When neither file has one embedded, a sidecar SRT (from -Sidecar,
            as found by Find-SidecarSubtitle) is used instead, preferring the
            one next to the primary.
          - Chapters: from the secondary only when the primary has none.
        UntaggedAs lists "<File>:<Id>" keys (for example "Secondary:2") of
        untagged tracks the user confirmed are in the target language.
    .OUTPUTS
        PSCustomObject with Audio, Subtitles, Chapters, Notes, Skipped, Error.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UntaggedAs', Justification = 'Used inside the $isTarget script block, which the rule does not follow.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Primary,
        [Parameter(Mandatory)][pscustomobject]$Secondary,
        [Parameter(Mandatory)][pscustomobject]$Language,
        [string[]]$UntaggedAs = @(),
        [int]$AudioTrackId = -1,
        [AllowEmptyCollection()][pscustomobject[]]$Sidecar = @()
    )

    $isTarget = {
        param($file, $t)
        $r = Test-TrackLanguage -Track $t -Language $Language
        ($r -eq $true) -or ($null -eq $r -and $UntaggedAs -contains "${file}:$($t.Id)")
    }
    $name = $Language.Name
    $notes = [Collections.Generic.List[string]]::new()
    $skipped = [Collections.Generic.List[pscustomobject]]::new()
    $plan = [pscustomobject]@{
        Audio     = $null
        Subtitles = @()
        SidecarSubtitle = $null
        Chapters  = $false
        Notes     = $notes
        Skipped   = $skipped
        Error     = $null
    }

    # Audio
    $secAudio = @($Secondary.Tracks | Where-Object Type -eq 'audio')
    if ($AudioTrackId -ge 0) {
        $plan.Audio = $secAudio | Where-Object Id -eq $AudioTrackId | Select-Object -First 1
        if (-not $plan.Audio) {
            $plan.Error = "The secondary file has no audio track with ID $AudioTrackId."
            return $plan
        }
        $notes.Add("audio track chosen with -AudioTrackId")
    } else {
        $candidates = @($secAudio | Where-Object { & $isTarget 'Secondary' $_ })
        if ($candidates.Count -eq 0) {
            $plan.Error = "The secondary file has no $name audio track."
            return $plan
        }
        $plan.Audio = Select-BestAudioTrack -Track $candidates
        $notes.Add(($candidates.Count -eq 1) ? "the only $name audio track" : "best of $($candidates.Count) $name audio tracks")
        foreach ($c in $candidates | Where-Object Id -ne $plan.Audio.Id) {
            $skipped.Add([pscustomobject]@{ Track = $c; Reason = "a better $name audio track was chosen" })
        }
    }

    # Subtitles
    $primaryTargetSrt = @($Primary.Tracks | Where-Object { $_.IsSrt -and -not $_.Forced -and (& $isTarget 'Primary' $_) })
    $secTargetSubs = @($Secondary.Tracks | Where-Object { $_.Type -eq 'subtitles' -and (& $isTarget 'Secondary' $_) })
    if ($primaryTargetSrt.Count -gt 0) {
        $notes.Add("primary already has $name SRT subtitles")
        foreach ($s in $secTargetSubs) {
            $skipped.Add([pscustomobject]@{ Track = $s; Reason = "primary already has $name SRT subtitles" })
        }
    } else {
        foreach ($s in $secTargetSubs) {
            if (-not $s.IsSrt) {
                $skipped.Add([pscustomobject]@{ Track = $s; Reason = 'image subtitles are never merged' })
            } elseif ($s.Forced) {
                $skipped.Add([pscustomobject]@{ Track = $s; Reason = 'forced subtitles are not merged' })
            } else {
                $plan.Subtitles += $s
            }
        }
        if ($plan.Subtitles.Count -eq 0) {
            # Last resort: a sidecar .srt file, preferring the one next to the primary.
            $pick = @($Sidecar | Where-Object Origin -eq 'Primary') + @($Sidecar | Where-Object Origin -eq 'Secondary') |
                Select-Object -First 1
            if ($pick) {
                $plan.SidecarSubtitle = $pick
            } else {
                $notes.Add("no $name SRT subtitles in either file or next to them")
            }
        }
    }

    # Chapters
    if ($Primary.Chapters -gt 0) {
        $notes.Add("primary keeps its own $($Primary.Chapters) chapters")
    } elseif ($Secondary.Chapters -gt 0) {
        $plan.Chapters = $true
    } else {
        $notes.Add('neither file has chapters')
    }

    return $plan
}

function Get-SyncVerdict {
    <#
    .SYNOPSIS
        Judges a set of offset measurements taken across the film.
    .DESCRIPTION
        With five or more clear points, a single point that disagrees with the rest
        and has a weak match (below MaxStrayPeak) is set aside as noise and counted
        in Outliers. A strong match that disagrees is never set aside.
        Each point has TimeS, OffsetMs (residual, after any applied offset),
        Peak and RunnerUp (correlation scores). A point is reliable when its
        peak is clearly above the runner-up and not at the edge of the search.
        Verdicts:
          InSync        every reliable point is within the tolerance of zero
          Offset        every point agrees on one non-zero offset
          Drift         the offset grows steadily (speed mismatch, such as PAL)
          Inconsistent  offsets jump around (different cut, or edits)
          Inconclusive  too few reliable points to judge
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Point,
        [int]$ToleranceMs = 40,
        [double]$MinPeak = 0.45,
        [double]$MinMargin = 0.1,
        [double]$MaxStrayPeak = 0.6
    )

    $reliable = @($Point | Where-Object { $_.Peak -ge $MinPeak -and ($_.Peak - $_.RunnerUp) -ge $MinMargin -and -not $_.AtEdge })
    $needed = [math]::Max(3, [math]::Ceiling($Point.Count / 2))
    $result = [pscustomobject]@{
        Verdict     = 'Inconclusive'
        Reliable    = $reliable.Count
        Total       = $Point.Count
        OffsetMs    = 0
        DeviationMs = 0
        DriftMsPerHour = 0
        Outliers    = 0
    }
    if ($reliable.Count -lt $needed) { return $result }

    $getMedian = {
        param([double[]]$v)
        $s = @($v | Sort-Object); $m = [int][math]::Floor($s.Count / 2)
        ($s.Count % 2) ? $s[$m] : ($s[$m - 1] + $s[$m]) / 2
    }
    $median = & $getMedian @($reliable.OffsetMs)

    # With enough clear points, one stray measurement with a weak match (a
    # quiet, dialogue-only scene) is noise: set it aside. A stray point with a
    # strong match is real: the films differ there (an extra logo or scene),
    # and hiding it would merge part of the film out of sync.
    if ($reliable.Count -ge 5) {
        $stray = @($reliable | Where-Object { [math]::Abs($_.OffsetMs - $median) -gt $ToleranceMs })
        if ($stray.Count -eq 1 -and $stray[0].Peak -lt $MaxStrayPeak) {
            $reliable = @($reliable | Where-Object { $_ -ne $stray[0] })
            $result.Outliers = 1
            $median = & $getMedian @($reliable.OffsetMs)
        }
    }
    $offsets = @($reliable | ForEach-Object OffsetMs | Sort-Object)
    $result.OffsetMs = [int][math]::Round($median)
    $result.DeviationMs = [int]($offsets | ForEach-Object { [math]::Abs($_ - $median) } | Measure-Object -Maximum).Maximum

    if (-not ($offsets | Where-Object { [math]::Abs($_) -gt $ToleranceMs })) {
        $result.Verdict = 'InSync'
        $result.DeviationMs = [int]($offsets | ForEach-Object { [math]::Abs($_) } | Measure-Object -Maximum).Maximum
        return $result
    }
    if ($result.DeviationMs -le $ToleranceMs) {
        $result.Verdict = 'Offset'
        return $result
    }

    # Least-squares line through (time, offset): steady drift fits it closely.
    $n = $reliable.Count
    $mx = ($reliable | Measure-Object TimeS -Average).Average
    $my = ($reliable | Measure-Object OffsetMs -Average).Average
    $sxx = 0.0; $sxy = 0.0
    foreach ($p in $reliable) { $sxx += ($p.TimeS - $mx) * ($p.TimeS - $mx); $sxy += ($p.TimeS - $mx) * ($p.OffsetMs - $my) }
    $slope = ($sxx -gt 0) ? $sxy / $sxx : 0
    $worst = 0.0
    foreach ($p in $reliable) { $worst = [math]::Max($worst, [math]::Abs($p.OffsetMs - ($my + $slope * ($p.TimeS - $mx)))) }
    if ($n -ge 3 -and $worst -le $ToleranceMs) {
        $result.Verdict = 'Drift'
        $result.DriftMsPerHour = [int][math]::Round($slope * 3600)
        return $result
    }
    $result.Verdict = 'Inconsistent'
    return $result
}

function New-MkvMergeArgument {
    <#
    .SYNOPSIS
        Builds the mkvmerge argument list for a merge plan.
    .DESCRIPTION
        The primary goes in whole. From the secondary only the planned tracks
        are taken; video, attachments, global tags, buttons and (unless the plan
        wants them) chapters are excluded, because mkvmerge would otherwise
        merge them from every input. Added tracks get default and forced flags
        cleared so the primary's original audio stays the default.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Primary,
        [Parameter(Mandatory)][pscustomobject]$Secondary,
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$SyncOffsetMs = 0
    )

    $added = @($Plan.Audio) + @($Plan.Subtitles)
    $a = [Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('--gui-mode', '--output', $OutputPath))

    # Primary: everything, unchanged.
    $a.Add($Primary.Path)

    # Secondary: only the planned tracks.
    $a.AddRange([string[]]@('--no-video', '--no-attachments', '--no-global-tags', '--no-buttons'))
    $a.AddRange([string[]]@('--audio-tracks', [string]$Plan.Audio.Id))
    if ($Plan.Subtitles.Count -gt 0) {
        $a.AddRange([string[]]@('--subtitle-tracks', (($Plan.Subtitles | ForEach-Object Id) -join ',')))
    } else {
        $a.Add('--no-subtitles')
    }
    if (-not $Plan.Chapters) { $a.Add('--no-chapters') }
    foreach ($t in $added) {
        $a.AddRange([string[]]@('--default-track-flag', "$($t.Id):no", '--forced-display-flag', "$($t.Id):no"))
        if ($SyncOffsetMs -ne 0) { $a.AddRange([string[]]@('--sync', "$($t.Id):$SyncOffsetMs")) }
    }
    if ($Plan.Chapters -and $SyncOffsetMs -ne 0) { $a.AddRange([string[]]@('--chapter-sync', [string]$SyncOffsetMs)) }
    $a.Add($Secondary.Path)

    # Sidecar SRT: a third input with one track (ID 0). Only one next to the
    # secondary shares the secondary's timeline and gets its offset.
    $side = ($Plan.PSObject.Properties['SidecarSubtitle'])?.Value
    if ($side) {
        $a.AddRange([string[]]@('--language', "0:$($side.LanguageIetf)", '--default-track-flag', '0:no', '--forced-display-flag', '0:no'))
        if ($side.Charset) { $a.AddRange([string[]]@('--sub-charset', "0:$($side.Charset)")) }
        if ($SyncOffsetMs -ne 0 -and $side.Origin -eq 'Secondary') { $a.AddRange([string[]]@('--sync', "0:$SyncOffsetMs")) }
        $a.Add($side.Path)
    }

    # Order: video, primary audio, added audio, primary subtitles, added subtitles, the rest.
    $order = [Collections.Generic.List[string]]::new()
    $prim = $Primary.Tracks
    $prim | Where-Object Type -eq 'video' | ForEach-Object { $order.Add("0:$($_.Id)") }
    $prim | Where-Object Type -eq 'audio' | ForEach-Object { $order.Add("0:$($_.Id)") }
    $order.Add("1:$($Plan.Audio.Id)")
    $prim | Where-Object Type -eq 'subtitles' | ForEach-Object { $order.Add("0:$($_.Id)") }
    $Plan.Subtitles | ForEach-Object { $order.Add("1:$($_.Id)") }
    if ($side) { $order.Add('2:0') }
    $prim | Where-Object Type -notin 'video', 'audio', 'subtitles' | ForEach-Object { $order.Add("0:$($_.Id)") }
    $a.AddRange([string[]]@('--track-order', ($order -join ',')))

    return , $a.ToArray()
}

function Test-MergedOutput {
    <#
    .SYNOPSIS
        Compares the merged file with what the plan promised.
    .OUTPUTS
        A list of problems; empty when the output is as expected.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Primary,
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][pscustomobject]$Output
    )

    $problems = [Collections.Generic.List[string]]::new()
    $addedSubs = $Plan.Subtitles.Count + ((($Plan.PSObject.Properties['SidecarSubtitle'])?.Value) ? 1 : 0)
    $expected = $Primary.Tracks.Count + 1 + $addedSubs
    if ($Output.Tracks.Count -ne $expected) {
        $problems.Add("expected $expected tracks, found $($Output.Tracks.Count)")
    }
    if ([math]::Abs($Output.DurationS - $Primary.DurationS) -gt 2) {
        $problems.Add(('duration changed from {0} to {1}' -f (Format-Duration $Primary.DurationS), (Format-Duration $Output.DurationS)))
    }
    $want = $Plan.Audio
    if (-not ($Output.Tracks | Where-Object { $_.Type -eq 'audio' -and $_.CodecId -eq $want.CodecId -and $_.Language -eq $want.Language -and $_.Channels -eq $want.Channels })) {
        $problems.Add("added $($want.Language) audio track is missing")
    }
    $outSubs = @($Output.Tracks | Where-Object Type -eq 'subtitles')
    $primSubs = @($Primary.Tracks | Where-Object Type -eq 'subtitles')
    if ($outSubs.Count -ne $primSubs.Count + $addedSubs) {
        $problems.Add("expected $($primSubs.Count + $addedSubs) subtitle tracks, found $($outSubs.Count)")
    }
    $wantChapters = $Primary.Chapters -gt 0 -or $Plan.Chapters
    if ($wantChapters -and $Output.Chapters -eq 0) { $problems.Add('chapters are missing') }
    if ($Primary.Chapters -gt 0 -and $Output.Chapters -ne $Primary.Chapters) {
        $problems.Add("chapter count changed from $($Primary.Chapters) to $($Output.Chapters)")
    }
    $primDefault = $Primary.Tracks | Where-Object { $_.Type -eq 'audio' -and $_.Default } | Select-Object -First 1
    $outDefault = @($Output.Tracks | Where-Object { $_.Type -eq 'audio' -and $_.Default })
    if ($primDefault -and ($outDefault.Count -ne 1 -or $outDefault[0].Language -ne $primDefault.Language)) {
        $problems.Add("default audio should be the primary's $($primDefault.Language) track only")
    }
    return , $problems.ToArray()
}

function Find-SidecarSubtitle {
    <#
    .SYNOPSIS
        Picks the sidecar SRT files in a folder that belong to a movie and are in the language.
    .DESCRIPTION
        Matches "<BaseName>.<tag>.srt" and "<BaseName>.<tag>.sdh.srt" (also .hi
        and .cc), where tag is the language's two- or three-letter code or its
        English name (nl, nld, dut, dutch). Forced sidecars are not matched.
        Non-SDH files come first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FileName,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][pscustomobject]$Language,
        [Parameter(Mandatory)][ValidateSet('Primary', 'Secondary')][string]$Origin
    )

    $tags = @($Language.Ietf) + $Language.Codes + $Language.Name.ToLowerInvariant() | ForEach-Object { [regex]::Escape($_) }
    $pattern = '^{0}\.({1})(\.(sdh|hi|cc))?\.srt$' -f [regex]::Escape($BaseName), ($tags -join '|')
    $FileName | Where-Object { $_ -match $pattern } |
        ForEach-Object {
            [pscustomobject]@{
                Path   = Join-Path $Directory $_
                Name   = $_
                Origin = $Origin
                Sdh    = $_ -match '\.(sdh|hi|cc)\.srt$'
                LanguageIetf = $Language.Ietf
                Charset = $null
            }
        } |
        Sort-Object -Stable Sdh
}

function Get-TextCharset {
    <#
    .SYNOPSIS
        Tells mkvmerge which character set a subtitle file uses: UTF-8 (with or without BOM) or Windows-1252.
    .DESCRIPTION
        Older Dutch SRT files are often Windows-1252; read as UTF-8 their
        accented letters (é, ë) turn into garbage, so the charset is passed
        explicitly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    if ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))) {
        return 'UTF-16'
    }
    try {
        $null = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        return 'UTF-8'
    } catch [Text.DecoderFallbackException] {
        return 'windows-1252'
    }
}

function ConvertFrom-PastedPath {
    <#
    .SYNOPSIS
        Cleans a path that was pasted or dragged into the terminal.
    .DESCRIPTION
        Strips surrounding whitespace, a leading "& " (added when a file is
        dragged into a PowerShell prompt) and one pair of matching quotes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $s = $Text.Trim()
    if ($s.StartsWith('& ')) { $s = $s.Substring(2).TrimStart() }
    if ($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[-1] -eq '"') -or ($s[0] -eq "'" -and $s[-1] -eq "'"))) {
        $s = $s.Substring(1, $s.Length - 2)
    }
    return $s.Trim()
}

function Format-Duration {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    return '{0}:{1:mm}:{1:ss}' -f [int][math]::Floor($ts.TotalHours), $ts
}

function Format-Size {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][double]$Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return ($Bytes / 1GB).ToString('0.0', $inv) + ' GB' }
    if ($Bytes -ge 1MB) { return ($Bytes / 1MB).ToString('0', $inv) + ' MB' }
    return ($Bytes / 1KB).ToString('0', $inv) + ' KB'
}

function Format-ChannelLayout {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Channels)
    switch ($Channels) {
        0 { return '' }
        1 { return 'mono' }
        2 { return '2.0' }
        6 { return '5.1' }
        8 { return '7.1' }
        default { return "$Channels ch" }
    }
}

function Format-TrackLine {
    <#
    .SYNOPSIS
        One-line description of a track, such as "#2  dut  AC-3 5.1  384 kb/s  'Nederlands'".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Track,
        [switch]$NoFlags
    )

    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add(('#{0,-2}' -f $Track.Id))
    $parts.Add(('{0,-3}' -f $Track.Language))
    $codec = switch ($Track.CodecId) {
        { $_ -in $script:SrtCodecIds } { 'SRT'; break }
        'S_HDMV/PGS' { 'PGS (image)'; break }
        'S_VOBSUB' { 'VobSub (image)'; break }
        default { $Track.Codec }
    }
    if ($Track.Type -eq 'audio') { $codec = "$codec $(Format-ChannelLayout $Track.Channels)".Trim() }
    if ($Track.Type -eq 'video' -and $Track.Dimensions) { $codec = "$codec $($Track.Dimensions)" }
    $parts.Add($codec)
    if ($Track.Type -eq 'audio' -and $Track.Bps -gt 0) { $parts.Add("$([math]::Round($Track.Bps / 1000)) kb/s") }
    if ($Track.Name) { $parts.Add("'$($Track.Name)'") }
    $flags = @()
    if ($Track.Default) { $flags += 'default' }
    if ($Track.Forced) { $flags += 'forced' }
    if ($flags -and -not $NoFlags) { $parts.Add("[$($flags -join ', ')]") }
    return $parts -join '  '
}

#endregion

#region External tools

function Get-MkvInfo {
    <#
    .SYNOPSIS
        Reads a Matroska file with mkvmerge -J.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $raw = & mkvmerge -J $item.FullName
    if ($LASTEXITCODE -ne 0) { throw "mkvmerge could not read '$($item.FullName)' (exit code $LASTEXITCODE)." }
    $json = ($raw -join "`n") | ConvertFrom-Json
    if (-not $json.container.recognized -or $json.container.type -ne 'Matroska') {
        throw "'$($item.Name)' is not a Matroska (MKV) file."
    }
    return ConvertTo-MkvInfo -Json $json -Path $item.FullName -Size $item.Length
}

function Read-AudioWindow {
    <#
    .SYNOPSIS
        Decodes a stretch of one audio track to 8 kHz mono 16-bit PCM with ffmpeg.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$TrackId,
        [Parameter(Mandatory)][double]$StartS,
        [Parameter(Mandatory)][double]$LengthS
    )

    $tmp = [IO.Path]::GetTempFileName()
    try {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        # mkvmerge track IDs follow the file's track order, as ffmpeg stream indexes do.
        & ffmpeg -v error -nostdin -y -ss ([math]::Max(0.0, $StartS).ToString('0.000', $inv)) -t $LengthS.ToString('0.000', $inv) `
            -i $Path -map "0:$TrackId" -vn -sn -ac 1 -ar 8000 -f s16le $tmp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg could not decode track $TrackId of '$Path' (exit code $LASTEXITCODE)." }
        return , [IO.File]::ReadAllBytes($tmp)
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

function Measure-AudioOffset {
    <#
    .SYNOPSIS
        Measures, at several points in the film, how far the secondary audio is from the primary.
    .DESCRIPTION
        At each point a window of the primary audio is compared with a wider
        window of the secondary audio, using the loudness envelope at 10 ms
        resolution. Dialogue differs between languages, but music and effects
        are shared, so a correct pairing still shows a clear peak.
        OffsetMs is the residual offset after AppliedOffsetMs (the -SyncOffsetMs
        value) is taken into account: 0 means in sync. A positive value means
        the secondary audio is late.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Primary,
        [Parameter(Mandatory)][int]$PrimaryTrackId,
        [Parameter(Mandatory)][pscustomobject]$Secondary,
        [Parameter(Mandatory)][int]$SecondaryTrackId,
        [int]$AppliedOffsetMs = 0,
        [double[]]$At = @(0.05, 0.2, 0.35, 0.5, 0.65, 0.8, 0.95),
        [double]$WindowS = 30,
        [double]$SearchS = 15,
        [scriptblock]$OnPoint
    )

    $frame = 80   # 10 ms at 8 kHz
    $duration = [math]::Min($Primary.DurationS, $Secondary.DurationS)
    $i = 0
    foreach ($fraction in $At) {
        $i++
        $t = [math]::Round(($duration - $WindowS) * $fraction)
        # Content at primary time t sits at secondary time t - applied offset.
        $centre = $t - $AppliedOffsetMs / 1000.0
        $candStart = $centre - $SearchS
        $lead = 0.0
        if ($candStart -lt 0) { $lead = -$candStart; $candStart = 0 }

        $ref = [MkvAudioMerge.SyncMath]::Envelope((Read-AudioWindow -Path $Primary.Path -TrackId $PrimaryTrackId -StartS $t -LengthS $WindowS), $frame)
        $cand = [MkvAudioMerge.SyncMath]::Envelope((Read-AudioWindow -Path $Secondary.Path -TrackId $SecondaryTrackId -StartS $candStart -LengthS ($WindowS + 2 * $SearchS - $lead)), $frame)
        $scores = [MkvAudioMerge.SyncMath]::Correlate($ref, $cand)

        $point = [pscustomobject]@{ TimeS = $t; OffsetMs = 0; Peak = 0.0; RunnerUp = 0.0; AtEdge = $true }
        if ($scores.Length -gt 0) {
            $best = 0
            for ($k = 1; $k -lt $scores.Length; $k++) { if ($scores[$k] -gt $scores[$best]) { $best = $k } }
            $runner = -1.0
            for ($k = 0; $k -lt $scores.Length; $k++) {
                if ([math]::Abs($k - $best) -gt 50 -and $scores[$k] -gt $runner) { $runner = $scores[$k] }
            }
            # Secondary time of the match, relative to where it should be.
            $matchS = $candStart + $best * $frame / 8000.0
            $point.OffsetMs = [int][math]::Round(($matchS - $centre) * 1000)
            $point.Peak = [math]::Round($scores[$best], 3)
            $point.RunnerUp = [math]::Round([math]::Max(0.0, $runner), 3)
            $point.AtEdge = $best -le 1 -or $best -ge $scores.Length - 2
        }
        if ($OnPoint) { & $OnPoint $point $i $At.Count }
        $point
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-LanguageCode', 'ConvertTo-MkvTrack', 'ConvertTo-MkvInfo', 'Test-TrackLanguage', 'Get-UntaggedTrack'
    'Select-BestAudioTrack', 'New-MergePlan', 'Get-SyncVerdict', 'New-MkvMergeArgument', 'Test-MergedOutput'
    'Find-SidecarSubtitle', 'Get-TextCharset', 'ConvertFrom-PastedPath', 'Format-Duration', 'Format-Size', 'Format-ChannelLayout', 'Format-TrackLine'
    'Get-MkvInfo', 'Read-AudioWindow', 'Measure-AudioOffset'
)
