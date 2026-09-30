---
name: organise-fieldwork-photos
description: Organise fieldwork images in the Mobile Devices folder into user-numbered, time-ordered batches without opening or analysing image content.
---

# Organise fieldwork photos

Use this skill when the user wants photos from `C:\Users\Test-Plus\Downloads\Mobile Devices` organised into a specified number of numbered folders after fieldwork.

## Requirements

- Never open, preview, classify, OCR, or otherwise inspect image content. Use filenames and filesystem metadata only.
- Treat image extensions case-insensitively, including JPG/JPEG, PNG, HEIC/HEIF, TIFF, BMP, and WEBP. Include only recognised image files.
- Expect loose image files directly in the Mobile Devices root by default. If images are in unorganised source subfolders, include those too. Do not treat existing numbered output folders as source folders or recursively reprocess an already organised result unless the user explicitly asks to reorganise it.
- When this skill is active and the user provides only an integer in the photo-organising context, treat it as the requested number of output folders. Do not ask them to restate the task or provide the folder count again.
- Parse capture time from filenames matching `YYYYMMDD_HHMMSS` before the extension. Interpret this filename timestamp as Hong Kong local time. Do not substitute file modified/created time or image EXIF metadata.
- Create folders named `1` through the requested number directly under the Mobile Devices root. Ignore source subfolder names when forming groups; their labels are not authoritative for the new numbering.
- Group photos in timestamp order into that many contiguous batches. Use gaps of about ten minutes as useful boundary cues, favouring longer pauses when choosing boundaries. Keep all photos with the same timestamp together. The user may provide timestamp-to-folder anchors; honour those anchors while making the remaining assignments chronologically. Folder 1 starts with the earliest included timestamp.
- Use best judgement to form the requested number of chronological groups when gap lengths are uneven. Do not pause just because boundaries are approximate or some photos are abnormal. Continue organising valid, parseable photos, then report abnormalities. Pause only for a genuine blocker such as an impossible folder count or a destination collision that risks overwriting existing files.
- Find the majority capture date from valid filename timestamps. Organise the majority-date photos into the numbered batches. Flag other-date images after the organisation and leave them in their current locations unless the user specifies another destination.
- Leave images with unparseable filenames where they are and report them after organising the valid photos.

## Workflow

1. Inspect image filenames directly in the Mobile Devices root. Also inspect unorganised source subfolders when present, but exclude numbered output folders and their contents. Identify any existing numbered folders that could conflict. Do not enumerate or read image pixels.
2. Build a timestamp-sorted inventory from filenames. Determine the majority date, earliest and latest timestamps, and a practical set of batch boundaries guided by pauses near ten minutes. Keep a brief internal list of out-of-day, unparseable, and ambiguous files for the completion report.
3. Check for destination filename collisions and whether numbered folders already contain files. Never overwrite, replace, or merge with pre-existing numbered-folder contents. If an actual collision or already organised result makes the requested move unsafe or ambiguous, report that blocker before moving files. Ordinary out-of-day or unparseable images are not blockers.
4. Create folders `1` through `N` and move the majority-date, parseable images into the contiguous batches, preserving original filenames. Do not rename photos or retain source subfolder labels in the grouping logic. If timing does not yield clean boundaries, use the closest reasonable chronological split and continue.
5. Confirm completion by listing each numbered folder's file count and timestamp range. Then report out-of-day images, unparseable filenames, approximate or uneven boundaries, and any move failures. Abnormalities should normally appear after the completed organisation summary, not interrupt it.

## Examples

- **Loose files at the root:** `20260930_090751.jpg`, `20260930_090851.png`, and `20260930_092108.jpg` are inventoried by their filename timestamps, regardless of extension. No source folder names are needed to sort or group them.
- **Calculating a time gap:** `20260930_101900.jpg` encodes 10:19:00 and `20260930_103005.png` encodes 10:30:05. The gap is 11 minutes and 5 seconds, so it is a plausible boundary between batches. The filename pattern is `YYYYMMDD_HHMMSS`; compare the date and time portion before the extension.
- **A shorter gap:** `20260930_101900.jpg` followed by `20260930_102325.jpg` is a 4-minute-25-second gap. This is usually evidence to keep the images in the same time cluster, unless the requested number of folders or the full day's sequence calls for a nearby split.
- **Choosing among several pauses:** If gaps are 3, 9, 14, and 28 minutes, prefer the 14- and 28-minute pauses as candidate boundaries before the 9-minute pause. Use enough boundaries to make the requested number of groups while preserving chronological order.
- **Date outlier:** If most filenames begin `20260930_` but one begins `20261001_`, organise the 30 September photos first, then report the 1 October image and leave it where it is.
- **Unparseable filename:** A file named `IMG_0042.jpg` has no timestamp in the expected pattern. Organise the valid timestamped photos first, then report `IMG_0042.jpg` and leave it where it is.
- **Bare folder count:** If the user invokes this workflow and replies `13`, treat that as a request for folders `1` through `13`. Do not ask what the number means.
- **Already organised files:** If the root contains numbered folders `1`, `2`, and so on with photos inside, do not treat those contents as fresh loose-photo input. Report that the folder looks organised already and ask whether the user wants to reorganise it.
