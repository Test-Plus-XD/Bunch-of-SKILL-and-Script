---
name: organise-fieldwork-photos
description: Organise fieldwork photos in the Mobile Devices folder into time-ordered folders named after a user-supplied list of Store Codes (or numbered folders when none are given), without inspecting image content. Use whenever the user asks to organise or sort fieldwork photos, mentions the Mobile Devices folder, or gives Store Codes or a folder count.
---

# Organise fieldwork photos

Applies to `C:\Users\Test-Plus\Downloads\Mobile Devices` (the root). The user normally supplies Store Codes in time order: the first code is the earliest folder, the second the next, and so on.

## Inputs

- **Store Codes**: a time-ordered list separated by line breaks, commas or spaces. Keep each code as typed, including capitalisation, and never reorder the list. Codes contain no spaces, so whitespace between a prefix (`SEHK`, `WEHK`, `MNHK`, any case) and its digits is a typo: join them (`WEHK 517` becomes `WEHK517`).
- **Folder count `N`**: the stated count, else the number of Store Codes after joining. A bare integer reply is always the folder count; do not ask the user to repeat it. With neither codes nor a count, ask for the count. With no codes, name the folders `1` to `N`; every other rule still applies.
- If a stated count differs from the number of Store Codes, pause before moving anything and ask which is correct. If the count stands, ask for the corrected list; never invent or drop codes.
- **Anchors** (optional): "WEHK517 starts at 11:20" or "folder 3 starts at 11:20" makes that folder begin with the first photo at or after that time, so the gap before it is a pinned boundary.

## Rules

- Use filenames only: never open, preview, classify, OCR or analyse image content, and never use EXIF or filesystem dates.
- Eligible files are `jpg`, `jpeg`and `png` (any case) in the root or any non-output subfolder. Leave other files alone.
- Skip existing output folders (named with digits only, in Store Code format, or after a supplied code) and everything inside them, and name them in the summary. Reprocess one only if explicitly asked.
- A capture time is a valid `YYYYMMDD_HHMMSS` (real date and time) just before the extension, read as Hong Kong local time.
- Organise only the most common date. Leave other-date and unparseable images where they are and report them.
- Continue despite these abnormalities. Pause only for a missing, impossible or conflicting folder count, an invalid or conflicting folder name, a tied date, contradictory anchors, or a filename collision.
- Create `N` folders directly in the root, the `k`-th named after the `k`-th code (or `k`). Ignore source-folder labels. Move files without renaming; never overwrite, replace or merge; check filename collisions first.

## Boundary selection

Group by timestamp gaps, never by spreading photo counts evenly. Groups are contiguous in time, the first folder holds the earliest photos, and a folder may hold one photo. `N` folders need exactly `N-1` boundaries, chosen deterministically so the same photos always give the same split.

1. Sort the distinct timestamps (identical ones stay together) and measure each consecutive gap.
2. Pin anchored boundaries first. They split the day into stretches (with no anchors, the whole day is one stretch), each needing one boundary fewer than the folders it holds. Fill each stretch with the largest gaps inside it, breaking ties by choosing the earlier gap.
3. If a stretch has too few gaps, or anchors contradict each other, the count is impossible: pause and report how many groups are possible.
4. Flag every chosen unanchored gap under ten minutes as approximate, with its length.
5. Report every unchosen gap of ten minutes or more, with its time range: `N` may be too small, or a long pause may sit inside one visit.

## Store Code rules

Validate the whole list (or the names `1` to `N`) before moving any file. If a check fails, pause, name the offender and change nothing.

- Expected format: `SEHK`, `WEHK` or `MNHK` (any case) plus 3 or 4 digits, no spaces (`SEHK0877`, `WEHK517`). A code that does not match is still accepted, but flag it in the summary in case it is a typo.
- No two names may match, ignoring case (Windows treats `A01` and `a01` as one folder). A store visited twice therefore needs a different second name: ask what to call it.
- No name may match an existing file or folder in the root: ask whether to reorganise that folder or name the new one differently.

## Workflow

1. Inventory eligible filenames and output folders; parse and validate the codes and count.
2. Sort the timestamps, pick the date and choose the boundaries.
3. Check destinations and collisions, create the `N` folders, then move the chosen date's files.
4. Confirm each folder's count and time range. Summarise the folders from first to last in a table or list, each with its name, photo count and earliest to latest capture time (one time for a single photo). Then report corrected or unusual codes, skipped output folders, other-date files, unparseable names, approximate boundaries (anchors can fix these), unchosen gaps of ten minutes or more, and move failures.

Perform the filename analysis, boundary decisions and file moves directly with available tools by default. Use `C:\Users\Test-Plus\Documents\DFI\Organise-FieldworkPhotos.ps1` only when the user explicitly asks to use the script.

## Examples

- If the user supplies `SEHK0877`, `WEHK517`, `MNHK0123` and no count, create three folders with those names, in that order, from earliest to latest photos.
- Gaps of 2, 3, 9, 14, 4, 28 and 6 minutes: `N` = 4 chooses 28, 14 and 9 (flag the 9 as approximate); `N` = 3 chooses 28 and 14 (the 9 is not reported); `N` = 2 chooses 28 and reports the unchosen 14.
- `N` = 4 with "folder 3 starts at 10:30": the gap before the first photo at or after 10:30 is boundary 2; boundary 1 is the largest gap before it and boundary 3 the largest after it.
- Most names begin `20260930_`, one begins `20261001_` and one is `IMG_0042.jpg`: organise 30 September and report the other two.
