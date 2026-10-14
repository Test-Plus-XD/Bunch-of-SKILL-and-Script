param(
    [string]$RootPath = 'C:\Users\Test-Plus\Downloads\Mobile Devices',
    [string[]]$StoreCodes = @(),
    [int]$FolderCount = 0,
    [string[]]$Anchors = @(),
    [switch]$Commit
)

$ErrorActionPreference = 'Stop'
$dateFormat = 'yyyyMMdd_HHmmss'
$eligibleExtensions = @('.jpg', '.jpeg', '.png')
$expectedCodePattern = '^(SEHK|WEHK|MNHK)\d{3,4}$'
$storeCodePrefixByLetter = @{ S = 'SEHK'; W = 'WEHK'; M = 'MNHK' }
$invalidPathCharacters = [System.IO.Path]::GetInvalidFileNameChars()
$planningErrors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$interactiveMode = ($StoreCodes.Count -eq 0 -and $FolderCount -eq 0)

function Expand-StoreCodeShorthand {
    param([string]$Value)
    $shorthandMatch = [regex]::Match($Value.Trim(), '^(?<letter>[SWM])(?<digits>\d{3,4})$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $shorthandMatch.Success) { return $Value }
    $prefix = $script:storeCodePrefixByLetter[$shorthandMatch.Groups['letter'].Value.ToUpperInvariant()]
    return $prefix + $shorthandMatch.Groups['digits'].Value
}

function Get-NormalizedStoreCodes {
    param([string[]]$Values)
    $joinedValues = [string]::Join("`n", $Values)
    $joinedValues = [regex]::Replace($joinedValues, '(?i)\b(SEHK|WEHK|MNHK|[SWM])\s+(\d{3,4})\b', '$1$2')
    $joinedValues = [regex]::Replace($joinedValues.Trim(), '^\s*[\[\(\{]\s*|\s*[\]\)\}]\s*$', '')
    $codeValues = @($joinedValues -split '[,\s]+' | ForEach-Object { Expand-StoreCodeShorthand -Value ($_.Trim().ToUpperInvariant()) } | Where-Object { $_.Length -gt 0 })
    return $codeValues
}

function Test-OutputFolderName {
    param(
        [string]$Name,
        [string[]]$NamesFromRequest
    )
    if ($Name -match '^\d+$') { return $true }
    if ($Name -match $script:expectedCodePattern) { return $true }
    foreach ($requestedName in $NamesFromRequest) {
        if ([string]::Equals($Name, $requestedName, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-EligibleSourceFiles {
    param(
        [string]$Root,
        [string[]]$NamesFromRequest,
        [System.Collections.Generic.List[string]]$SkippedFolders
    )
    $sourceFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($Root)
    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Pop()
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($currentDirectory)) {
            $attributes = [System.IO.File]::GetAttributes($entry)
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $directoryName = [System.IO.Path]::GetFileName($entry)
                if (Test-OutputFolderName -Name $directoryName -NamesFromRequest $NamesFromRequest) {
                    $SkippedFolders.Add($entry)
                    continue
                }
                if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $pendingDirectories.Push($entry) }
                continue
            }
            $extension = [System.IO.Path]::GetExtension($entry)
            if ($script:eligibleExtensions -contains $extension.ToLowerInvariant()) { $sourceFiles.Add([System.IO.FileInfo]::new($entry)) }
        }
    }
    return $sourceFiles.ToArray()
}

function ConvertFrom-Anchor {
    param(
        [string]$Value,
        [string[]]$Names
    )
    $anchorPattern = '^\s*(?<label>.+?)\s*(?:starts\s+at\s+|=)(?<clock>\d{1,2}:\d{2}(?::\d{2})?)\s*$'
    $match = [regex]::Match($Value, $anchorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { throw "Invalid anchor '$Value'. Use 'CODE starts at HH:mm' or 'folder 3 starts at HH:mm'." }
    $label = $match.Groups['label'].Value.Trim()
    $clock = $match.Groups['clock'].Value
    $anchorTime = [TimeSpan]::Zero
    [string[]]$clockFormats = @('h\:mm', 'hh\:mm', 'h\:mm\:ss', 'hh\:mm\:ss')
    if (-not [TimeSpan]::TryParseExact($clock, $clockFormats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.TimeSpanStyles]::None, [ref]$anchorTime)) {
        throw "Invalid anchor time '$clock' in '$Value'."
    }
    if ($label -match '^(?i:folder\s+)?(?<index>\d+)$') {
        $indexText = $label -replace '(?i)^folder\s+', ''
        $folderIndex = [int]$indexText
        return [pscustomobject]@{ FolderIndex = [int]$folderIndex; Time = $anchorTime; Source = $Value }
    }
    $expandedLabel = Expand-StoreCodeShorthand -Value $label
    for ($nameIndex = 0; $nameIndex -lt $Names.Count; $nameIndex++) {
        if ([string]::Equals($expandedLabel, $Names[$nameIndex], [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ FolderIndex = $nameIndex + 1; Time = $anchorTime; Source = $Value }
        }
    }
    throw "Anchor '$Value' refers to no supplied Store Code or folder number."
}

function Format-FolderLabel {
    param(
        [int]$FolderIndex,
        [string[]]$Names
    )
    $folderName = $Names[$FolderIndex - 1]
    if ($folderName -eq [string]$FolderIndex) { return "folder $FolderIndex" }
    return "$folderName ($FolderIndex)"
}

function Read-NumberedStoreCodeInput {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { Write-Host '> ' -NoNewline; return (Read-Host) }
    $finishedLines = [System.Collections.Generic.List[string]]::new()
    $currentText = ''
    Write-Host '1: ' -NoNewline
    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        $prefixLength = "$($finishedLines.Count + 1): ".Length
        if ($keyInfo.Key -eq [ConsoleKey]::Enter) { break }
        if ($keyInfo.Key -eq [ConsoleKey]::Backspace) {
            if ($currentText.Length -gt 0) { $currentText = $currentText.Substring(0, $currentText.Length - 1); Write-Host "`b `b" -NoNewline; continue }
            if ($finishedLines.Count -eq 0) { continue }
            $currentRow = [Console]::CursorTop
            [Console]::SetCursorPosition(0, $currentRow)
            Write-Host (' ' * $prefixLength) -NoNewline
            $reopenedLine = $finishedLines[$finishedLines.Count - 1]
            $finishedLines.RemoveAt($finishedLines.Count - 1)
            $currentText = $reopenedLine.Substring(0, $reopenedLine.Length - 1)
            $separatorColumn = "$($finishedLines.Count + 1): ".Length + $currentText.Length
            [Console]::SetCursorPosition($separatorColumn, $currentRow - 1)
            Write-Host ' ' -NoNewline
            [Console]::SetCursorPosition($separatorColumn, $currentRow - 1)
            continue
        }
        $typedCharacter = $keyInfo.KeyChar
        if ([char]::IsControl($typedCharacter)) { continue }
        if ($typedCharacter -eq ',' -or $typedCharacter -eq ';') {
            if ([string]::IsNullOrWhiteSpace($currentText)) { continue }
            $finishedLines.Add($currentText + $typedCharacter)
            $currentText = ''
            Write-Host $typedCharacter
            Write-Host "$($finishedLines.Count + 1): " -NoNewline
            continue
        }
        if ($prefixLength + $currentText.Length + 3 -ge [Console]::WindowWidth) { continue }
        $currentText += $typedCharacter
        Write-Host $typedCharacter -NoNewline
    }
    if ($currentText.Length -eq 0 -and $finishedLines.Count -gt 0) {
        [Console]::SetCursorPosition(0, [Console]::CursorTop)
        Write-Host (' ' * $prefixLength) -NoNewline
        [Console]::SetCursorPosition(0, [Console]::CursorTop)
    } else { Write-Host '' }
    return ($finishedLines -join '') + $currentText
}

function Write-JsonResult {
    param([object]$Result)
    [Console]::WriteLine(($Result | ConvertTo-Json -Depth 12 -Compress))
}

function Test-RequestedNames {
    param(
        [string[]]$Names,
        [string]$Root
    )
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name -in @('.', '..')) { $script:planningErrors.Add("Invalid empty or relative folder name '$name'."); continue }
        if ($name.IndexOfAny($script:invalidPathCharacters) -ge 0 -or $name.EndsWith(' ') -or $name.EndsWith('.')) { $script:planningErrors.Add("Invalid Windows folder name '$name'."); continue }
        if ($name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { $script:planningErrors.Add("Reserved Windows device name '$name'."); continue }
        if (-not $seenNames.Add($name)) { $script:planningErrors.Add("Duplicate folder name '$name' (Windows compares names without regard to case).") }
        if ($name -notmatch $script:expectedCodePattern -and $name -notmatch '^\d+$') { $script:warnings.Add("Unusual Store Code or folder name '$name'; check for a typo.") }
        $rootConflict = Get-ChildItem -LiteralPath $Root -Force | Where-Object { [string]::Equals($_.Name, $name, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -ne $rootConflict) {
            $entryType = if ($rootConflict.PSIsContainer) { 'folder' } else { 'file' }
            $script:planningErrors.Add("Destination '$name' already matches a root $entryType; ask whether to reorganise it or choose another name.")
        }
    }
}

try {
    $resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { throw "Root path '$RootPath' is not a directory." }
    if ($interactiveMode) {
        Write-Host 'Enter Store Codes separated by commas or semicolons, or enter only a folder count:'
        $terminalInput = (Read-NumberedStoreCodeInput).Trim()
        if ([string]::IsNullOrWhiteSpace($terminalInput)) {
            Write-Host 'No input was provided. No files were changed.'
            exit 2
        }
        if ($terminalInput -match '^\d+$') {
            $FolderCount = [int]$terminalInput
            if ($FolderCount -lt 1) {
                Write-Host 'Folder count must be a positive integer. No files were changed.'
                exit 2
            }
        } else {
            $StoreCodes = @($terminalInput -split '[,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
        }
    }
    do {
        $reprocessRequested = $false
        $planningErrors.Clear()
        $warnings.Clear()
        $normalisedCodes = @(Get-NormalizedStoreCodes -Values $StoreCodes)
        if ($FolderCount -lt 0) { $planningErrors.Add('Folder count cannot be negative.') }
        if ($normalisedCodes.Count -eq 0 -and $FolderCount -eq 0) {
            Write-JsonResult ([pscustomobject]@{ Status = 'needs_input'; Question = 'Provide Store Codes or a positive folder count.'; Root = $resolvedRoot })
            exit 2
        }
        if ($FolderCount -eq 0) { $FolderCount = $normalisedCodes.Count }
        if ($normalisedCodes.Count -gt 0 -and $FolderCount -ne $normalisedCodes.Count) { $planningErrors.Add("Folder count $FolderCount differs from the $($normalisedCodes.Count) Store Codes; provide a corrected count or list.") }
        if ($normalisedCodes.Count -eq 0 -and $FolderCount -gt 0) { $normalisedCodes = @(1..$FolderCount | ForEach-Object { [string]$_ }) }
        $folderNames = @($normalisedCodes)
        Test-RequestedNames -Names $folderNames -Root $resolvedRoot
        $requestedCodeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($folderName in $folderNames) { [void]$requestedCodeSet.Add($folderName) }
        $skippedFolderPaths = [System.Collections.Generic.List[string]]::new()
        $eligibleFiles = @(Get-EligibleSourceFiles -Root $resolvedRoot -NamesFromRequest $folderNames -SkippedFolders $skippedFolderPaths)
        $parsedFiles = [System.Collections.Generic.List[object]]::new()
        $unparseableNames = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $eligibleFiles) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $timestampMatch = [regex]::Match($stem, '(?<stamp>\d{8}_\d{6})$')
            $captureTime = [datetime]::MinValue
            $isValidTimestamp = $timestampMatch.Success -and [datetime]::TryParseExact($timestampMatch.Groups['stamp'].Value, $dateFormat, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$captureTime)
            if (-not $isValidTimestamp) { $unparseableNames.Add($file.FullName); continue }
            $parsedFiles.Add([pscustomobject]@{ Path = $file.FullName; Name = $file.Name; CaptureTime = $captureTime; CaptureDate = $captureTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) })
        }
        $dateGroups = @($parsedFiles | Group-Object CaptureDate | Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
        if ($dateGroups.Count -eq 0) { $planningErrors.Add('No eligible image filenames contain a valid YYYYMMDD_HHMMSS timestamp.') }
        if ($dateGroups.Count -gt 1 -and $dateGroups[0].Count -eq $dateGroups[1].Count) { $planningErrors.Add('The most common capture date is tied; choose which date to organise.') }
        if ($dateGroups.Count -gt 0 -and $dateGroups[0].Count -lt $FolderCount) { $planningErrors.Add("Only $($dateGroups[0].Count) timestamped photos exist on the most common date, fewer than the $FolderCount requested folders.") }
        $selectedDate = if ($dateGroups.Count -gt 0) { $dateGroups[0].Name } else { $null }
        $selectedFiles = if ($selectedDate) { @($parsedFiles | Where-Object { $_.CaptureDate -eq $selectedDate } | Sort-Object CaptureTime, Name) } else { @() }
        $uniqueTimes = @($selectedFiles | Group-Object { $_.CaptureTime.Ticks } | ForEach-Object { [datetime]::new([long]$_.Name) } | Sort-Object)
        if ($uniqueTimes.Count -lt $FolderCount) { $planningErrors.Add("Only $($uniqueTimes.Count) distinct timestamps can form groups, fewer than the $FolderCount requested folders.") }
        $gapRecords = [System.Collections.Generic.List[object]]::new()
        for ($timeIndex = 1; $timeIndex -lt $uniqueTimes.Count; $timeIndex++) {
            $gapLength = $uniqueTimes[$timeIndex] - $uniqueTimes[$timeIndex - 1]
            $gapRecords.Add([pscustomobject]@{ Position = $timeIndex; From = $uniqueTimes[$timeIndex - 1]; To = $uniqueTimes[$timeIndex]; Minutes = $gapLength.TotalMinutes; Ticks = $gapLength.Ticks })
        }
        $anchorRecords = [System.Collections.Generic.List[object]]::new()
        foreach ($anchorText in $Anchors) {
            try { $anchorRecords.Add((ConvertFrom-Anchor -Value $anchorText -Names $folderNames)) }
            catch { $planningErrors.Add($_.Exception.Message) }
        }
        $pinnedBoundaries = [System.Collections.Generic.List[object]]::new()
        foreach ($anchor in $anchorRecords) {
            if ($anchor.FolderIndex -lt 2 -or $anchor.FolderIndex -gt $FolderCount) { $planningErrors.Add("Anchor '$($anchor.Source)' must identify a folder from 2 through $FolderCount."); continue }
            $matchingTimeIndex = -1
            for ($timeIndex = 0; $timeIndex -lt $uniqueTimes.Count; $timeIndex++) {
                if ($uniqueTimes[$timeIndex].TimeOfDay -ge $anchor.Time) { $matchingTimeIndex = $timeIndex; break }
            }
            if ($matchingTimeIndex -le 0) { $planningErrors.Add("Anchor '$($anchor.Source)' has no valid gap before the first photo at or after its time."); continue }
            $boundaryPosition = $matchingTimeIndex
            $existingPin = @($pinnedBoundaries | Where-Object { $_.FolderIndex -eq $anchor.FolderIndex -or $_.Position -eq $boundaryPosition }) | Select-Object -First 1
            if ($null -ne $existingPin) {
                if ($existingPin.FolderIndex -ne $anchor.FolderIndex -or $existingPin.Position -ne $boundaryPosition) { $planningErrors.Add("Anchor '$($anchor.Source)' contradicts another pinned boundary.") }
                continue
            }
            $pinnedBoundaries.Add([pscustomobject]@{ FolderIndex = $anchor.FolderIndex; Position = $boundaryPosition; Source = $anchor.Source })
        }
        $sortedPins = @($pinnedBoundaries | Sort-Object FolderIndex)
        for ($pinIndex = 1; $pinIndex -lt $sortedPins.Count; $pinIndex++) {
            if ($sortedPins[$pinIndex].Position -le $sortedPins[$pinIndex - 1].Position) { $planningErrors.Add('Anchors are contradictory or leave no timestamp gap between their folders.') }
        }
        $chosenBoundaries = [System.Collections.Generic.List[int]]::new()
        foreach ($pin in $sortedPins) { $chosenBoundaries.Add([int]$pin.Position) }
        $stretchPins = [System.Collections.Generic.List[object]]::new()
        $stretchPins.Add([pscustomobject]@{ FolderIndex = 1; Position = 0 })
        foreach ($pin in $sortedPins) { $stretchPins.Add($pin) }
        $stretchPins.Add([pscustomobject]@{ FolderIndex = $FolderCount + 1; Position = $uniqueTimes.Count })
        for ($stretchIndex = 0; $stretchIndex -lt $stretchPins.Count - 1; $stretchIndex++) {
            $leftPin = $stretchPins[$stretchIndex]
            $rightPin = $stretchPins[$stretchIndex + 1]
            $neededBoundaries = $rightPin.FolderIndex - $leftPin.FolderIndex - 1
            $candidateGaps = @($gapRecords | Where-Object { $_.Position -gt $leftPin.Position -and $_.Position -lt $rightPin.Position } | Sort-Object @{ Expression = 'Ticks'; Descending = $true }, @{ Expression = 'Position'; Descending = $false })
            if ($candidateGaps.Count -lt $neededBoundaries) { $planningErrors.Add("Between folder $($leftPin.FolderIndex) and folder $($rightPin.FolderIndex), only $($candidateGaps.Count) gap(s) are available for $neededBoundaries required boundary/boundaries."); continue }
            for ($gapIndex = 0; $gapIndex -lt $neededBoundaries; $gapIndex++) { $chosenBoundaries.Add([int]$candidateGaps[$gapIndex].Position) }
        }
        $chosenBoundarySet = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($boundaryPosition in $chosenBoundaries) { [void]$chosenBoundarySet.Add($boundaryPosition) }
        $groupedPlan = [System.Collections.Generic.List[object]]::new()
        $currentFolderIndex = 1
        $timeToFolder = @{}
        for ($timeIndex = 0; $timeIndex -lt $uniqueTimes.Count; $timeIndex++) {
            if ($timeIndex -gt 0 -and $chosenBoundarySet.Contains($timeIndex)) { $currentFolderIndex++ }
            $timeToFolder[$uniqueTimes[$timeIndex].Ticks] = $currentFolderIndex
        }
        $boundarySummary = [System.Collections.Generic.List[object]]::new()
        foreach ($gap in $gapRecords) {
            $isPinned = @($sortedPins | Where-Object { $_.Position -eq $gap.Position }).Count -gt 0
            $isChosen = $chosenBoundarySet.Contains([int]$gap.Position)
            if ($isChosen) {
                $summary = [pscustomobject]@{ From = $gap.From.ToString('HH:mm:ss'); To = $gap.To.ToString('HH:mm:ss'); GapMinutes = [math]::Round($gap.Minutes, 2); Pinned = $isPinned; Approximate = (-not $isPinned -and $gap.Minutes -lt 10) }
                $boundarySummary.Add($summary)
                if ($summary.Approximate) {
                    $previousFolderLabel = Format-FolderLabel -FolderIndex ([int]$timeToFolder[$gap.From.Ticks]) -Names $folderNames
                    $nextFolderLabel = Format-FolderLabel -FolderIndex ([int]$timeToFolder[$gap.To.Ticks]) -Names $folderNames
                    $warnings.Add("Approximate unanchored boundary: $previousFolderLabel to $nextFolderLabel, $($summary.GapMinutes) minutes.")
                }
            } elseif ($gap.Minutes -ge 10) {
                $boundarySummary.Add([pscustomobject]@{ From = $gap.From.ToString('HH:mm:ss'); To = $gap.To.ToString('HH:mm:ss'); GapMinutes = [math]::Round($gap.Minutes, 2); Pinned = $false; Approximate = $false; UnchosenLongGap = $true })
            }
        }
        $plannedFolders = [System.Collections.Generic.List[object]]::new()
        for ($folderIndex = 1; $folderIndex -le $FolderCount; $folderIndex++) {
            $folderFiles = @($selectedFiles | Where-Object { $timeToFolder[$_.CaptureTime.Ticks] -eq $folderIndex } | Sort-Object CaptureTime, Name)
            if ($folderFiles.Count -eq 0) { $planningErrors.Add("Folder $folderIndex ('$($folderNames[$folderIndex - 1])') would be empty.") }
            $earliestTime = if ($folderFiles.Count -gt 0) { $folderFiles[0].CaptureTime.ToString('HH:mm:ss') } else { $null }
            $latestTime = if ($folderFiles.Count -gt 0) { $folderFiles[-1].CaptureTime.ToString('HH:mm:ss') } else { $null }
            $plannedFolders.Add([pscustomobject]@{
                Index = $folderIndex
                Name = $folderNames[$folderIndex - 1]
                PhotoCount = $folderFiles.Count
                Earliest = $earliestTime
                Latest = $latestTime
                Files = @($folderFiles | ForEach-Object { $_.Path })
            })
        }
        $destinationCollisionPaths = [System.Collections.Generic.List[string]]::new()
        foreach ($folderPlan in $plannedFolders) {
            $seenFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($sourcePath in $folderPlan.Files) {
                $sourceName = [System.IO.Path]::GetFileName($sourcePath)
                if (-not $seenFileNames.Add($sourceName)) { $destinationCollisionPaths.Add("Two source photos named '$sourceName' would collide in destination '$($folderPlan.Name)'.") }
            }
        }
        foreach ($collision in $destinationCollisionPaths) { $planningErrors.Add($collision) }
        if ($planningErrors.Count -gt 0) {
            Write-JsonResult ([pscustomobject]@{ Status = 'blocked'; Root = $resolvedRoot; Errors = @($planningErrors); Warnings = @($warnings); SkippedOutputFolders = @($skippedFolderPaths); OtherDateFiles = @($parsedFiles | Where-Object { $_.CaptureDate -ne $selectedDate } | ForEach-Object { $_.Path }); UnparseableFiles = @($unparseableNames); PlannedFolders = @($plannedFolders | Select-Object Index, Name, PhotoCount, Earliest, Latest); Boundaries = @($boundarySummary) })
            exit 2
        }
        $shouldCommit = [bool]$Commit
        if (-not $shouldCommit) {
            $planResult = [pscustomobject]@{ Status = 'plan'; Root = $resolvedRoot; SelectedDate = $selectedDate; PlannedFolders = @($plannedFolders | Select-Object Index, Name, PhotoCount, Earliest, Latest); Boundaries = @($boundarySummary); Warnings = @($warnings); SkippedOutputFolders = @($skippedFolderPaths); OtherDateFiles = @($parsedFiles | Where-Object { $_.CaptureDate -ne $selectedDate } | ForEach-Object { $_.Path }); UnparseableFiles = @($unparseableNames); MoveFailures = @() }
            if (-not $interactiveMode) {
                Write-JsonResult $planResult
                exit 0
            }
            Write-Host "`nPlanned organisation for $selectedDate"
            $mergedRows = foreach ($folderPlan in $plannedFolders) {
                $openingBoundary = $boundarySummary | Where-Object { -not $_.UnchosenLongGap -and $_.To -eq $folderPlan.Earliest } | Select-Object -First 1
                $unchosenGapTexts = @($boundarySummary | Where-Object { $_.UnchosenLongGap -and [string]::CompareOrdinal($_.From, $folderPlan.Earliest) -ge 0 -and [string]::CompareOrdinal($_.To, $folderPlan.Latest) -le 0 } | ForEach-Object { "$($_.From) to $($_.To) ($($_.GapMinutes) min)" })
                [pscustomobject]@{
                    Index = $folderPlan.Index
                    Name = $folderPlan.Name
                    PhotoCount = $folderPlan.PhotoCount
                    Earliest = $folderPlan.Earliest
                    Latest = $folderPlan.Latest
                    GapMinutes = if ($null -ne $openingBoundary) { $openingBoundary.GapMinutes } else { $null }
                    Pinned = if ($null -ne $openingBoundary) { $openingBoundary.Pinned } else { $null }
                    Approximate = if ($null -ne $openingBoundary) { $openingBoundary.Approximate } else { $null }
                    LongGaps = $unchosenGapTexts -join '; '
                }
            }
            @($mergedRows) | Format-Table Index, Name, PhotoCount, Earliest, Latest, GapMinutes, Pinned, Approximate, LongGaps -AutoSize -Wrap | Out-Host
            if ($warnings.Count -gt 0) {
                Write-Host 'Warnings:'
                foreach ($warning in $warnings) { Write-Host "- $warning" }
            }
            if ($skippedFolderPaths.Count -gt 0) {
                Write-Host 'Skipped existing output folders:'
                foreach ($skippedPath in $skippedFolderPaths) { Write-Host "- $skippedPath" }
            }
            $otherDatePaths = @($parsedFiles | Where-Object { $_.CaptureDate -ne $selectedDate } | ForEach-Object { $_.Path })
            if ($otherDatePaths.Count -gt 0) {
                Write-Host 'Other-date photos left in place:'
                foreach ($otherDatePath in $otherDatePaths) { Write-Host "- $otherDatePath" }
            }
            if ($unparseableNames.Count -gt 0) {
                Write-Host 'Unparseable image filenames left in place:'
                foreach ($unparseableName in $unparseableNames) { Write-Host "- $unparseableName" }
            }
            Write-Host 'Press Enter to create the folders and move the planned photos, or Space to reprocess the photos.'
            while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
            do { $confirmationKey = [Console]::ReadKey($true) } while ($confirmationKey.Key -notin @([ConsoleKey]::Enter, [ConsoleKey]::Spacebar))
            if ($confirmationKey.Key -eq [ConsoleKey]::Spacebar) { $reprocessRequested = $true; Write-Host "`nReprocessing photos..." } else { $shouldCommit = $true }
        }
    } while ($reprocessRequested)
    $createdDirectories = [System.Collections.Generic.List[string]]::new()
    $moveFailures = [System.Collections.Generic.List[object]]::new()
    foreach ($folderPlan in $plannedFolders) {
        $destinationDirectory = Join-Path -Path $resolvedRoot -ChildPath $folderPlan.Name
        [void][System.IO.Directory]::CreateDirectory($destinationDirectory)
        $createdDirectories.Add($destinationDirectory)
    }
    foreach ($folderPlan in $plannedFolders) {
        $destinationDirectory = Join-Path -Path $resolvedRoot -ChildPath $folderPlan.Name
        foreach ($sourcePath in $folderPlan.Files) {
            $destinationPath = Join-Path -Path $destinationDirectory -ChildPath ([System.IO.Path]::GetFileName($sourcePath))
            try { [System.IO.File]::Move($sourcePath, $destinationPath) }
            catch { $moveFailures.Add([pscustomobject]@{ Source = $sourcePath; Destination = $destinationPath; Error = $_.Exception.Message }) }
        }
    }
    $finalFolderSummaries = [System.Collections.Generic.List[object]]::new()
    foreach ($folderPlan in $plannedFolders) {
        $destinationDirectory = Join-Path -Path $resolvedRoot -ChildPath $folderPlan.Name
        $movedFiles = @($folderPlan.Files | ForEach-Object { Join-Path -Path $destinationDirectory -ChildPath ([System.IO.Path]::GetFileName($_)) } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        $movedTimes = @($movedFiles | ForEach-Object {
            $fileName = [System.IO.Path]::GetFileName($_)
            $fileStem = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $stampMatch = [regex]::Match($fileStem, '(?<stamp>\d{8}_\d{6})$')
            $parsedTime = [datetime]::MinValue
            if ($stampMatch.Success -and [datetime]::TryParseExact($stampMatch.Groups['stamp'].Value, $dateFormat, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedTime)) { $parsedTime }
        } | Sort-Object)
        $finalEarliestTime = if ($movedTimes.Count -gt 0) { $movedTimes[0].ToString('HH:mm:ss') } else { $null }
        $finalLatestTime = if ($movedTimes.Count -gt 0) { $movedTimes[-1].ToString('HH:mm:ss') } else { $null }
        $finalFolderSummaries.Add([pscustomobject]@{ Index = $folderPlan.Index; Name = $folderPlan.Name; PhotoCount = $movedFiles.Count; Earliest = $finalEarliestTime; Latest = $finalLatestTime })
    }
    $resultStatus = if ($moveFailures.Count -gt 0) { 'partial' } else { 'completed' }
    Write-JsonResult ([pscustomobject]@{ Status = $resultStatus; Root = $resolvedRoot; SelectedDate = $selectedDate; Folders = @($finalFolderSummaries); Boundaries = @($boundarySummary); Warnings = @($warnings); SkippedOutputFolders = @($skippedFolderPaths); OtherDateFiles = @($parsedFiles | Where-Object { $_.CaptureDate -ne $selectedDate } | ForEach-Object { $_.Path }); UnparseableFiles = @($unparseableNames); MoveFailures = @($moveFailures) })
} catch {
    Write-JsonResult ([pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message; Root = $RootPath })
    exit 1
}