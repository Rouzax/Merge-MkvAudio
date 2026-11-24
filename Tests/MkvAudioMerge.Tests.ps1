#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\MkvAudioMerge.psm1') -Force

    # Builds a track the way ConvertTo-MkvTrack returns it.
    function New-Track {
        param(
            [int]$Id, [string]$Type = 'audio', [string]$Language = 'eng', [string]$Ietf = '',
            [string]$CodecId = 'A_AC3', [string]$Codec = 'AC-3', [int]$Channels = 6, [long]$Bps = 384000,
            [string]$Name = '', [switch]$Default, [switch]$Forced
        )
        if ($Type -eq 'subtitles' -and $CodecId -eq 'A_AC3') { $CodecId = 'S_TEXT/UTF8'; $Codec = 'SubRip/SRT'; $Channels = 0; $Bps = 0 }
        if ($Type -eq 'video') { $CodecId = 'V_MPEGH/ISO/HEVC'; $Codec = 'HEVC'; $Channels = 0; $Bps = 0 }
        [pscustomobject]@{
            Id = $Id; Type = $Type; Codec = $Codec; CodecId = $CodecId; Language = $Language
            LanguageIetf = $Ietf; Name = $Name; Default = [bool]$Default; Forced = [bool]$Forced
            Channels = $Channels; Bps = $Bps; Dimensions = ''; FrameNs = 0
            IsSrt = $Type -eq 'subtitles' -and $CodecId -in 'S_TEXT/UTF8', 'S_TEXT/ASCII'
        }
    }
    function New-Info {
        param([pscustomobject[]]$Tracks, [int]$Chapters = 0, [string]$Path = 'C:\x.mkv', [double]$DurationS = 6000)
        [pscustomobject]@{ Path = $Path; Name = Split-Path $Path -Leaf; Size = 1GB; DurationS = $DurationS; Fps = 24; Chapters = $Chapters; Tracks = $Tracks }
    }
    $script:nl = Get-LanguageCode 'nl'
    $script:video = New-Track -Id 0 -Type video -Language und
}

Describe 'Get-LanguageCode' {
    It 'resolves <In> to Dutch' -ForEach @(@{ In = 'nl' }, @{ In = 'nld' }, @{ In = 'dut' }) {
        $l = Get-LanguageCode $In
        $l.Ietf | Should -Be 'nl'
        $l.Codes | Should -Contain 'dut'
        $l.Codes | Should -Contain 'nld'
        $l.Name | Should -Be 'Dutch'
    }
    It 'resolves German with both ISO 639-2 codes' {
        (Get-LanguageCode 'de').Codes | Should -Be @('deu', 'ger')
    }
    It 'throws for an unknown language' {
        { Get-LanguageCode 'zz' } | Should -Throw
    }
}

Describe 'ConvertTo-MkvTrack' {
    It 'flattens an mkvmerge audio track' {
        $json = '{"id":2,"type":"audio","codec":"AC-3","properties":{"codec_id":"A_AC3","language":"dut","language_ietf":"nl","track_name":"Nederlands","default_track":false,"forced_track":false,"audio_channels":6,"tag_bps":"384000"}}' | ConvertFrom-Json
        $t = ConvertTo-MkvTrack $json
        $t.Id | Should -Be 2
        $t.Language | Should -Be 'dut'
        $t.Channels | Should -Be 6
        $t.Bps | Should -Be 384000
        $t.IsSrt | Should -BeFalse
    }
    It 'marks SRT subtitles and not PGS' {
        $srt = '{"id":3,"type":"subtitles","codec":"SubRip/SRT","properties":{"codec_id":"S_TEXT/UTF8"}}' | ConvertFrom-Json
        $pgs = '{"id":4,"type":"subtitles","codec":"HDMV PGS","properties":{"codec_id":"S_HDMV/PGS"}}' | ConvertFrom-Json
        (ConvertTo-MkvTrack $srt).IsSrt | Should -BeTrue
        (ConvertTo-MkvTrack $pgs).IsSrt | Should -BeFalse
        (ConvertTo-MkvTrack $srt).Language | Should -Be 'und'
    }
}

Describe 'ConvertTo-MkvInfo' {
    It 'reads duration, frame rate and chapters' {
        $json = '{"container":{"properties":{"duration":6106752000000}},"chapters":[{"num_entries":36}],"tracks":[{"id":0,"type":"video","codec":"HEVC","properties":{"codec_id":"V_MPEGH/ISO/HEVC","default_duration":41666666}}]}' | ConvertFrom-Json
        $i = ConvertTo-MkvInfo -Json $json -Path 'C:\a\b.mkv'
        $i.Name | Should -Be 'b.mkv'
        $i.Chapters | Should -Be 36
        $i.Fps | Should -Be 24
        [math]::Round($i.DurationS) | Should -Be 6107
    }
    It 'treats missing chapters as zero' {
        $json = '{"container":{"properties":{"duration":1000000000}},"chapters":[],"tracks":[]}' | ConvertFrom-Json
        (ConvertTo-MkvInfo -Json $json -Path 'C:\x.mkv').Chapters | Should -Be 0
    }
}

Describe 'Test-TrackLanguage' {
    It 'prefers the IETF tag' {
        Test-TrackLanguage (New-Track -Id 1 -Language 'eng' -Ietf 'nl-BE') $nl | Should -BeTrue
    }
    It 'falls back to the ISO 639-2 code' {
        Test-TrackLanguage (New-Track -Id 1 -Language 'dut') $nl | Should -BeTrue
        Test-TrackLanguage (New-Track -Id 1 -Language 'nld') $nl | Should -BeTrue
        Test-TrackLanguage (New-Track -Id 1 -Language 'eng') $nl | Should -BeFalse
    }
    It 'returns null for untagged tracks' {
        Test-TrackLanguage (New-Track -Id 1 -Language 'und' -Ietf 'und') $nl | Should -BeNullOrEmpty
    }
}

Describe 'Select-BestAudioTrack' {
    It 'prefers more channels, then lossless, then bitrate' {
        $stereo = New-Track -Id 1 -Channels 2 -Bps 640000
        $ac3 = New-Track -Id 2 -Channels 6 -Bps 448000
        $eac3 = New-Track -Id 3 -Channels 6 -Bps 768000 -CodecId 'A_EAC3'
        $truehd = New-Track -Id 4 -Channels 6 -Bps 0 -CodecId 'A_TRUEHD'
        (Select-BestAudioTrack @($stereo, $ac3)).Id | Should -Be 2
        (Select-BestAudioTrack @($ac3, $eac3)).Id | Should -Be 3
        (Select-BestAudioTrack @($ac3, $eac3, $truehd)).Id | Should -Be 4
    }
}

Describe 'New-MergePlan' {
    BeforeEach {
        $script:primary = New-Info -Chapters 0 -Tracks @(
            $video
            New-Track -Id 1 -Language eng -Default
            New-Track -Id 2 -Type subtitles -Language eng
        )
        $script:secondary = New-Info -Path 'D:\y.mkv' -Chapters 24 -Tracks @(
            $video
            New-Track -Id 1 -Language eng -Default
            New-Track -Id 2 -Language dut -Channels 2
            New-Track -Id 3 -Language dut -Channels 6
            New-Track -Id 4 -Type subtitles -Language dut
            New-Track -Id 5 -Type subtitles -Language dut -CodecId 'S_HDMV/PGS'
            New-Track -Id 6 -Type subtitles -Language dut -Forced
        )
    }

    It 'takes the best Dutch audio and skips the other' {
        $plan = New-MergePlan $primary $secondary $nl
        $plan.Error | Should -BeNullOrEmpty
        $plan.Audio.Id | Should -Be 3
        $plan.Skipped.Track.Id | Should -Contain 2
    }
    It 'takes only the non-forced Dutch SRT when the primary has none' {
        $plan = New-MergePlan $primary $secondary $nl
        $plan.Subtitles.Id | Should -Be @(4)
        ($plan.Skipped | Where-Object { $_.Track.Id -eq 5 }).Reason | Should -Match 'image'
        ($plan.Skipped | Where-Object { $_.Track.Id -eq 6 }).Reason | Should -Match 'forced'
    }
    It 'takes no subtitles when the primary already has a Dutch SRT' {
        $primary.Tracks += New-Track -Id 3 -Type subtitles -Language dut
        $plan = New-MergePlan $primary $secondary $nl
        $plan.Subtitles | Should -BeNullOrEmpty
    }
    It 'still adds the SRT when the primary has only Dutch PGS' {
        $primary.Tracks += New-Track -Id 3 -Type subtitles -Language dut -CodecId 'S_HDMV/PGS'
        (New-MergePlan $primary $secondary $nl).Subtitles.Id | Should -Be @(4)
    }
    It 'still adds the SRT when the primary has only a forced Dutch SRT' {
        $primary.Tracks += New-Track -Id 3 -Type subtitles -Language dut -Forced
        (New-MergePlan $primary $secondary $nl).Subtitles.Id | Should -Be @(4)
    }
    It 'takes chapters only when the primary has none' {
        (New-MergePlan $primary $secondary $nl).Chapters | Should -BeTrue
        $primary.Chapters = 10
        (New-MergePlan $primary $secondary $nl).Chapters | Should -BeFalse
    }
    It 'fails without Dutch audio in the secondary' {
        $secondary.Tracks = @($video, (New-Track -Id 1 -Language eng))
        (New-MergePlan $primary $secondary $nl).Error | Should -Match 'no Dutch audio'
    }
    It 'uses untagged tracks only when confirmed' {
        $secondary.Tracks = @($video, (New-Track -Id 1 -Language und))
        (New-MergePlan $primary $secondary $nl).Error | Should -Not -BeNullOrEmpty
        (New-MergePlan $primary $secondary $nl -UntaggedAs 'Secondary:1').Audio.Id | Should -Be 1
    }
    It 'honours -AudioTrackId' {
        (New-MergePlan $primary $secondary $nl -AudioTrackId 2).Audio.Id | Should -Be 2
        (New-MergePlan $primary $secondary $nl -AudioTrackId 9).Error | Should -Match 'ID 9'
    }
}

Describe 'Get-UntaggedTrack' {
    It 'asks about untagged audio only when no tagged Dutch audio exists' {
        $p = New-Info -Tracks @($video, (New-Track -Id 1 -Language eng))
        $s = New-Info -Tracks @($video, (New-Track -Id 1 -Language und), (New-Track -Id 2 -Language dut))
        @(Get-UntaggedTrack $p $s $nl | Where-Object { $_.Track.Type -eq 'audio' }) | Should -HaveCount 0
        $s.Tracks = @($video, (New-Track -Id 1 -Language und))
        @(Get-UntaggedTrack $p $s $nl | Where-Object { $_.Track.Type -eq 'audio' }) | Should -HaveCount 1
    }
    It 'asks about untagged primary SRT when the primary has no Dutch SRT' {
        $p = New-Info -Tracks @($video, (New-Track -Id 1 -Language eng), (New-Track -Id 2 -Type subtitles -Language und))
        $s = New-Info -Tracks @($video, (New-Track -Id 1 -Language dut))
        $u = @(Get-UntaggedTrack $p $s $nl)
        $u | Should -HaveCount 1
        $u[0].File | Should -Be 'Primary'
    }
}

Describe 'Get-SyncVerdict' {
    BeforeAll {
        function New-SyncPoint([int[]]$Offsets, [double]$Peak = 0.8) {
            $i = 0
            foreach ($o in $Offsets) { [pscustomobject]@{ TimeS = 600 + 900 * $i++; OffsetMs = $o; Peak = $Peak; RunnerUp = 0.3; AtEdge = $false } }
        }
    }
    It 'is in sync when every point is near zero' {
        (Get-SyncVerdict (New-SyncPoint 0, 10, -10, 0, 20, 0, 0)).Verdict | Should -Be 'InSync'
    }
    It 'finds a fixed offset' {
        $v = Get-SyncVerdict (New-SyncPoint 480, 470, 490, 480, 480, 480, 480)
        $v.Verdict | Should -Be 'Offset'
        $v.OffsetMs | Should -Be 480
    }
    It 'finds drift' {
        # 900 s between points, 200 ms per point = 800 ms per hour.
        $v = Get-SyncVerdict (New-SyncPoint 0, 200, 400, 600, 800, 1000, 1200)
        $v.Verdict | Should -Be 'Drift'
        $v.DriftMsPerHour | Should -Be 800
    }
    It 'flags offsets that jump around' {
        (Get-SyncVerdict (New-SyncPoint 0, 0, 0, 3000, 3000, -2000, 500)).Verdict | Should -Be 'Inconsistent'
    }
    It 'ignores one weak stray point among five or more clear ones' {
        $pts = @(New-SyncPoint 0, 0, 0, 0, 60, 0, 0)
        $pts[4].Peak = 0.5
        $v = Get-SyncVerdict $pts
        $v.Verdict | Should -Be 'InSync'
        $v.Outliers | Should -Be 1
    }
    It 'never ignores a strong stray point (an extra scene early in one release)' {
        # Real case: -1010 ms at the first point, -7760 ms from then on.
        $pts = @(New-SyncPoint -1010, -7760, -7760, -7760, -7760, -7760, -7760)
        $pts[0].Peak = 0.79
        $v = Get-SyncVerdict $pts
        $v.Verdict | Should -Be 'Inconsistent'
        $v.Outliers | Should -Be 0
    }
    It 'does not ignore two stray points' {
        (Get-SyncVerdict (New-SyncPoint 0, 0, 0, 0, 900, 0, 1500)).Verdict | Should -Be 'Inconsistent'
    }
    It 'is inconclusive when the matches are weak' {
        (Get-SyncVerdict (New-SyncPoint 0, 0, 0, 0, 0, 0, 0 -Peak 0.2)).Verdict | Should -Be 'Inconclusive'
    }
    It 'ignores points at the edge of the search window' {
        $pts = @(New-SyncPoint 0, 0, 0, 0, 5000, 5000, 5000)
        $pts[4..6] | ForEach-Object { $_.AtEdge = $true }
        (Get-SyncVerdict $pts).Verdict | Should -Be 'InSync'
    }
}

Describe 'New-MkvMergeArgument' {
    BeforeAll {
        $script:p = New-Info -Path 'C:\p.mkv' -Chapters 0 -Tracks @($video, (New-Track -Id 1 -Language eng -Default), (New-Track -Id 2 -Type subtitles))
        $script:s = New-Info -Path 'C:\s.mkv' -Tracks @($video, (New-Track -Id 1), (New-Track -Id 2 -Language dut), (New-Track -Id 3 -Type subtitles -Language dut))
    }
    It 'takes only the planned tracks from the secondary' {
        $plan = [pscustomobject]@{ Audio = $s.Tracks[2]; Subtitles = @($s.Tracks[3]); Chapters = $false }
        $a = New-MkvMergeArgument $p $s $plan 'C:\out.partial'
        $secondaryPart = $a[($a.IndexOf('C:\p.mkv') + 1)..($a.IndexOf('C:\s.mkv'))]
        $secondaryPart | Should -Contain '--no-video'
        $secondaryPart | Should -Contain '--no-chapters'
        $secondaryPart | Should -Contain '--no-attachments'
        $secondaryPart[$secondaryPart.IndexOf('--audio-tracks') + 1] | Should -Be '2'
        $secondaryPart[$secondaryPart.IndexOf('--subtitle-tracks') + 1] | Should -Be '3'
        $secondaryPart | Should -Contain '2:no'
        $a[-1] | Should -Be '0:0,0:1,1:2,0:2,1:3'
    }
    It 'keeps chapters and applies sync when asked' {
        $plan = [pscustomobject]@{ Audio = $s.Tracks[2]; Subtitles = @(); Chapters = $true }
        $a = New-MkvMergeArgument $p $s $plan 'C:\out.partial' -SyncOffsetMs -480
        $a | Should -Not -Contain '--no-chapters'
        $a | Should -Contain '--no-subtitles'
        $a | Should -Contain '2:-480'
        $a[$a.IndexOf('--chapter-sync') + 1] | Should -Be '-480'
    }
}

Describe 'Test-MergedOutput' {
    BeforeAll {
        $script:p = New-Info -Chapters 36 -Tracks @($video, (New-Track -Id 1 -Language eng -Default -CodecId 'A_EAC3'), (New-Track -Id 2 -Type subtitles))
        $script:dut = New-Track -Id 2 -Language dut
        $script:dutSrt = New-Track -Id 3 -Type subtitles -Language dut
        $script:plan = [pscustomobject]@{ Audio = $dut; Subtitles = @($dutSrt); Chapters = $false }
    }
    It 'passes a correct merge' {
        $out = New-Info -Chapters 36 -Tracks @($video, (New-Track -Id 1 -Language eng -Default -CodecId 'A_EAC3'), (New-Track -Id 2 -Language dut), (New-Track -Id 3 -Type subtitles), (New-Track -Id 4 -Type subtitles -Language dut))
        Test-MergedOutput $p $plan $out | Should -BeNullOrEmpty
    }
    It 'reports missing tracks, lost chapters and a second default' {
        $out = New-Info -Chapters 0 -Tracks @($video, (New-Track -Id 1 -Language eng -Default -CodecId 'A_EAC3'), (New-Track -Id 2 -Language dut -Default), (New-Track -Id 3 -Type subtitles))
        $problems = Test-MergedOutput $p $plan $out
        $problems | Should -Contain 'expected 5 tracks, found 4'
        $problems | Should -Contain 'chapters are missing'
        ($problems -match 'default audio') | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-PastedPath' {
    It 'cleans <In>' -ForEach @(
        @{ In = '"C:\a b\c.mkv"'; Out = 'C:\a b\c.mkv' }
        @{ In = "  'C:\a b\c.mkv'  "; Out = 'C:\a b\c.mkv' }
        @{ In = "& 'C:\a b\c.mkv'"; Out = 'C:\a b\c.mkv' }
        @{ In = 'C:\plain.mkv'; Out = 'C:\plain.mkv' }
        @{ In = ''; Out = '' }
    ) {
        ConvertFrom-PastedPath $In | Should -Be $Out
    }
}

Describe 'Formatting' {
    It 'formats durations, sizes and channels' {
        Format-Duration 6106.75 | Should -Be '1:41:47'
        Format-Duration 59 | Should -Be '0:00:59'
        Format-Size (18.2 * 1GB) | Should -Be '18.2 GB'
        Format-ChannelLayout 6 | Should -Be '5.1'
        Format-ChannelLayout 8 | Should -Be '7.1'
    }
    It 'describes a track on one line' {
        $line = Format-TrackLine (New-Track -Id 2 -Language dut -Name 'Nederlands' -Default)
        $line | Should -Match '#2\s+dut\s+AC-3 5\.1\s+384 kb/s\s+''Nederlands''\s+\[default\]'
        Format-TrackLine (New-Track -Id 2 -Default) -NoFlags | Should -Not -Match 'default'
    }
}

Describe 'Find-SidecarSubtitle' {
    It 'finds the movie''s Dutch sidecars, non-SDH first, and ignores others' {
        $names = 'Film.nl.sdh.srt', 'Film.en.srt', 'Film.nl.srt', 'Film.nl.forced.srt', 'Other.nl.srt', 'Film.dut.srt', 'Film.Dutch.srt'
        $found = @(Find-SidecarSubtitle -FileName $names -Directory 'C:\m' -BaseName 'Film' -Language $nl -Origin Primary)
        $found.Name | Should -Be @('Film.nl.srt', 'Film.dut.srt', 'Film.Dutch.srt', 'Film.nl.sdh.srt')
        $found[0].Path | Should -Be 'C:\m\Film.nl.srt'
        $found[0].LanguageIetf | Should -Be 'nl'
    }
    It 'escapes brackets and dots in the movie name' {
        $names = 'Film (2026) - [WEBDL-2160p].nl.srt', 'Film (2026) - X.nl.srt'
        @(Find-SidecarSubtitle -FileName $names -Directory 'C:\m' -BaseName 'Film (2026) - [WEBDL-2160p]' -Language $nl -Origin Primary).Name |
            Should -Be @('Film (2026) - [WEBDL-2160p].nl.srt')
    }
}

Describe 'Get-TextCharset' {
    It 'detects UTF-8, Windows-1252 and UTF-16' {
        Get-TextCharset ([Text.Encoding]::UTF8.GetBytes('één')) | Should -Be 'UTF-8'
        Get-TextCharset ([Text.Encoding]::GetEncoding(1252).GetBytes('één')) | Should -Be 'windows-1252'
        Get-TextCharset ([byte[]](0xFF, 0xFE, 0x41, 0x00)) | Should -Be 'UTF-16'
    }
}

Describe 'New-MergePlan with sidecars' {
    BeforeEach {
        $script:primary = New-Info -Tracks @($video, (New-Track -Id 1 -Language eng -Default))
        $script:secondary = New-Info -Path 'D:\y.mkv' -Tracks @($video, (New-Track -Id 1 -Language dut))
        $script:sidePrim = [pscustomobject]@{ Path = 'C:\Film.nl.srt'; Name = 'Film.nl.srt'; Origin = 'Primary'; Sdh = $false; LanguageIetf = 'nl'; Charset = $null }
        $script:sideSec = [pscustomobject]@{ Path = 'D:\y.nl.srt'; Name = 'y.nl.srt'; Origin = 'Secondary'; Sdh = $false; LanguageIetf = 'nl'; Charset = $null }
    }
    It 'uses a sidecar when neither file has a Dutch SRT embedded, preferring the primary''s' {
        (New-MergePlan $primary $secondary $nl -Sidecar $sideSec, $sidePrim).SidecarSubtitle.Origin | Should -Be 'Primary'
        (New-MergePlan $primary $secondary $nl -Sidecar $sideSec).SidecarSubtitle.Origin | Should -Be 'Secondary'
    }
    It 'prefers an embedded SRT in the secondary over a sidecar' {
        $secondary.Tracks += New-Track -Id 2 -Type subtitles -Language dut
        $plan = New-MergePlan $primary $secondary $nl -Sidecar $sidePrim
        $plan.SidecarSubtitle | Should -BeNullOrEmpty
        $plan.Subtitles.Id | Should -Be @(2)
    }
    It 'uses no sidecar when the primary already has a Dutch SRT' {
        $primary.Tracks += New-Track -Id 2 -Type subtitles -Language dut
        (New-MergePlan $primary $secondary $nl -Sidecar $sidePrim).SidecarSubtitle | Should -BeNullOrEmpty
    }
    It 'adds the sidecar as a third input with language, charset and order' {
        $plan = New-MergePlan $primary $secondary $nl -Sidecar $sideSec
        $plan.SidecarSubtitle.Charset = 'windows-1252'
        $a = New-MkvMergeArgument $primary $secondary $plan 'C:\out.partial' -SyncOffsetMs 200
        $side = $a[($a.IndexOf('D:\y.mkv') + 1)..($a.IndexOf('D:\y.nl.srt'))]
        $side | Should -Contain '0:nl'
        $side | Should -Contain '0:windows-1252'
        $side | Should -Contain '0:200'
        $a[-1] | Should -Be '0:0,0:1,1:1,2:0'
    }
    It 'does not shift a sidecar that sits next to the primary' {
        $plan = New-MergePlan $primary $secondary $nl -Sidecar $sidePrim
        $a = New-MkvMergeArgument $primary $secondary $plan 'C:\out.partial' -SyncOffsetMs 200
        $a[($a.IndexOf('D:\y.mkv') + 1)..($a.Count - 1)] | Should -Not -Contain '0:200'
    }
}
Describe 'Convert-SrtCut' {
    BeforeAll {
        $script:srt = "1`r`n00:12:20,000 --> 00:12:22,500`r`nVoor`r`n`r`n2`r`n00:12:29,000 --> 00:12:31,000`r`nOver de knip`r`n`r`n3`r`n00:12:32,000 --> 00:12:34,000`r`nIn het gat`r`n`r`n4`r`n01:00:00,100 --> 01:00:02,000`r`nNa`r`n"
    }
    It 'moves cues from the cut on later when footage is inserted' {
        $out = Convert-SrtCut -Text $srt -CutS 749.67 -GapS 6.76 -Mode Insert
        $out | Should -Match '00:12:20,000 --> 00:12:22,500'
        $out | Should -Match '00:12:29,000 --> 00:12:31,000'   # starts before the cut: unchanged
        $out | Should -Match '00:12:38,760 --> 00:12:40,760'
        $out | Should -Match '01:00:06,860 --> 01:00:08,760'
    }
    It 'drops, clips and moves cues when footage is removed' {
        $out = Convert-SrtCut -Text $srt -CutS 750 -GapS 5 -Mode Remove
        $out | Should -Match "1`r`n00:12:20,000 --> 00:12:22,500"
        $out | Should -Match '00:12:29,000 --> 00:12:30,000'   # clipped at the cut
        $out | Should -Not -Match 'In het gat'                   # inside the removed part
        $out | Should -Match "3`r`n00:59:55,100 --> 00:59:57,000"
    }
    It 'accepts LF line endings, a BOM and dot milliseconds' {
        $text = [char]0xFEFF + "1`n00:00:01.5 --> 00:00:02.250`nHoi`n"
        Convert-SrtCut -Text $text -CutS 0 -GapS 1 -Mode Insert | Should -Match '00:00:02,500 --> 00:00:03,250'
    }
}

Describe 'Get-SyncStep' {
    BeforeAll {
        function New-StepPoint([int[]]$Offsets) {
            $i = 0
            foreach ($o in $Offsets) { [pscustomobject]@{ TimeS = 268 + 804 * $i++; OffsetMs = $o; Peak = 0.85; RunnerUp = 0.3; AtEdge = $false } }
        }
    }
    It 'finds one jump, even with a single point before it' {
        $step = Get-SyncStep (New-StepPoint 0, -6760, -6760, -6760, -6760, -6760, -6760)
        $step.BeforeMs | Should -Be 0
        $step.AfterMs | Should -Be -6760
        $step.LastBeforeS | Should -Be 268
        $step.FirstAfterS | Should -Be 1072
    }
    It 'finds a jump the other way' {
        (Get-SyncStep (New-StepPoint -500, -500, -500, 2500, 2500, 2500, 2500)).AfterMs | Should -Be 2500
    }
    It 'returns nothing for two jumps or no jump' {
        Get-SyncStep (New-StepPoint 0, 0, 3000, 3000, -2000, -2000, -2000) | Should -BeNullOrEmpty
        Get-SyncStep (New-StepPoint 0, 0, 0, 0, 0, 0, 0) | Should -BeNullOrEmpty
    }
}

Describe 'CutMath' {
    It 'finds the cut between two alignments, skipping the gap' {
        # 0..299 agrees before, 300..349 is the gap, 350.. agrees after.
        $before = [double[]](@(1.0) * 300 + @(0.0) * 200)
        $after = [double[]](@(0.0) * 350 + @(1.0) * 150)
        [MkvAudioMerge.CutMath]::FindCut($before, $after, 50) | Should -Be 300
    }
    It 'correlates identical signals as 1 and opposite ones as -1' {
        $a = [double[]](1..200 | ForEach-Object { [math]::Sin($_ / 5) })
        $b = [double[]]($a | ForEach-Object { -$_ })
        $same = [MkvAudioMerge.CutMath]::LocalCorrelation($a, $a, 20)
        $opp = [MkvAudioMerge.CutMath]::LocalCorrelation($a, $b, 20)
        [math]::Round($same[100], 6) | Should -Be 1
        [math]::Round($opp[100], 6) | Should -Be -1
    }
}

Describe 'New-MkvMergeArgument with repaired tracks' {
    It 'leaves the secondary out and adds the rebuilt files with their offset' {
        $p = New-Info -Path 'C:\p.mkv' -Chapters 10 -Tracks @($video, (New-Track -Id 1 -Language eng -Default), (New-Track -Id 2 -Type subtitles))
        $s = New-Info -Path 'C:\s.mkv' -Tracks @($video, (New-Track -Id 1 -Language dut))
        $plan = [pscustomobject]@{
            Audio = $null; Subtitles = @(); SidecarSubtitle = $null; Chapters = $false
            External = @(
                [pscustomobject]@{ Type = 'audio'; Path = 'T:\audio.mka'; LanguageIetf = 'nl'; Name = 'Nederlands'; Channels = 6; SyncMs = 0 }
                [pscustomobject]@{ Type = 'subtitles'; Path = 'T:\sub.srt'; LanguageIetf = 'nl'; Name = ''; Charset = 'UTF-8'; SyncMs = 120 }
            )
        }
        $a = New-MkvMergeArgument $p $s $plan 'C:\out.partial'
        $a | Should -Not -Contain 'C:\s.mkv'
        $a | Should -Contain 'T:\audio.mka'
        $a | Should -Contain '0:Nederlands'
        $a | Should -Contain '0:120'
        $a[-1] | Should -Be '0:0,0:1,1:0,0:2,2:0'
    }
    It 'verifies a repaired audio track by language and channels' {
        $p = New-Info -Chapters 0 -Tracks @($video, (New-Track -Id 1 -Language eng -Default))
        $plan = [pscustomobject]@{ Audio = $null; Subtitles = @(); Chapters = $false
            External = @([pscustomobject]@{ Type = 'audio'; Path = 'x'; LanguageIetf = 'nl'; Name = 'NL'; Channels = 6; SyncMs = 0 }) }
        $good = New-Info -Chapters 0 -Tracks @($video, (New-Track -Id 1 -Language eng -Default), (New-Track -Id 2 -Language dut -Ietf nl))
        Test-MergedOutput $p $plan $good | Should -BeNullOrEmpty
        $bad = New-Info -Chapters 0 -Tracks @($video, (New-Track -Id 1 -Language eng -Default), (New-Track -Id 2 -Language dut -Ietf nl -Channels 2))
        (Test-MergedOutput $p $plan $bad) -match 'missing' | Should -Not -BeNullOrEmpty
    }
}
Describe 'Select-SyncReferenceTrack' {
    It 'uses the default track unless it is TrueHD' {
        $eac3 = New-Track -Id 1 -Language eng -CodecId 'A_EAC3' -Default
        (Select-SyncReferenceTrack @($video, $eac3)).Id | Should -Be 1
    }
    It 'prefers a same-language lossy track over a TrueHD default' {
        $thd = New-Track -Id 1 -Language eng -CodecId 'A_TRUEHD' -Channels 8 -Default
        $eac3 = New-Track -Id 2 -Language eng -CodecId 'A_EAC3'
        $fre = New-Track -Id 3 -Language fre -CodecId 'A_AC3'
        (Select-SyncReferenceTrack @($video, $thd, $fre, $eac3)).Id | Should -Be 2
        (Select-SyncReferenceTrack @($video, $thd, $fre)).Id | Should -Be 1
    }
}