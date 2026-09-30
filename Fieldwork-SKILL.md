---
name: google-my-maps-fieldwork-route
description: "Build an ordered Google My Maps fieldwork route from store codes, resolving addresses from the local mapping file, verifying locations on the web, and saving a dated KML route."
---

# Google My Maps Fieldwork Route Workflow

## Use case: Build KML segments from the onsite schedule

When the user provides an onsite date or date range instead of a store-code list, run `get_onsite_store_codes.py` from the workspace root to obtain the assigned store codes. Use the staff member named by the user, or `Baldwin` when none is specified. The script reads `Master List(Checklist).csv` beside itself, matches the `Onsite Date` and `Staff` columns, and returns unique codes in checklist order. It prefers `code from Carman`, then falls back to `Confirmed Site code`, then to the rightmost `Store Code` column when earlier fields are blank or marked as unavailable.

For one date, run:

```powershell
python .\get_onsite_store_codes.py --date 2026-09-14 --staff Baldwin
```

For an inclusive date range, run:

```powershell
python .\get_onsite_store_codes.py --start-date 2026-09-14 --end-date 2026-09-16 --staff Baldwin
```

The staff option may be omitted to use the default. Use ISO dates in commands. The script labels every date's group, including a single-date result. Process each date's codes as its own KML segment and preserve the checklist order within that day's list. If a date has no codes beneath its date label, report that and do not create an empty segment for it.

Continue with the local address lookup in section 1 for every returned code, then verify and geocode those locations using section 2. Plan and save one dated KML segment per onsite date using sections 3–6. Keep the date-specific stop lists separate; do not combine different days into one LineString. If no usable codes are returned for a requested date, tell the user and skip address searches for that date.

## 1. Store-code lookup, input normalisation, and duplicate removal

Start with the user's complete list of store codes.

Remove only **fully identical store codes**: after trimming whitespace and normalising equivalent punctuation. Do **not** remove different shops that share the same building, mall, estate, or address. Examples include separate shop numbers in the same mall and separate station-concourse shops.

Read `DFI_master_housekeeping_unique_address_pairs.md` from the workspace root. It is a Markdown table with `Store code(s)`, `English address`, and `Traditional Chinese address` columns. Search efficiently with ripgrep, combining codes into one call, for example:

```text
rg -n -F -e 'WEHK162' -e 'WEHK070' -- 'DFI_master_housekeeping_unique_address_pairs.md'
```

Treat search results as candidates, then verify that each code is an exact code or exact listed code token in the first table column. Do not accept a substring match from an address or a different code. Extract the address from the matching row and retain the user's input order. 
+ If a code is absent from the Markdown file, tell the user which code was not found; do not infer its address from the code or search the web for the code alone. 
+ If the address is [blank] or #N/A, report that no usable address is listed and do not attempt to geocode. If the address is otherwise incomplete, proceed to search and geocode using the available information, but explicitly flag the result as derived from a partial address so the user can verify its accuracy before relying on it.
+ If the English address conflicts, use the Chinese address.

Resolve codes before searching the web or planning the route. Do not ask the user to provide addresses that are already in the local mapping file.

If one code has multiple rows with different addresses, report all distinct candidates and ask which location is intended before finalising the route. Continue work on unambiguous locations while that clarification is pending. Repeated input occurrences resolving to the same code and address are duplicate stops: keep the first occurrence unless the user explicitly requests repeat visits. Keep different codes as separate stops even when they share an address, building, mall, estate, or station.

Preserve the user's Traditional Chinese names and terminology unless the user asks for translation.

## 2. Web verification and geocoding

Use web search with the address or addresses from the Markdown mapping file to verify **every resolved location** using OpenStreetMap-derived data or Google Places-backed tool, or other authoritative map/address sources. Search the listed address, including its Traditional Chinese form when useful. Prefer, in roughly this order:

1. OpenStreetMap / OSM-derived map sources for coordinates and building geometry.
2. Retailer sources: https://www.mannings.com.hk/store-finder?srsltid=AU7gw4V6nQ82_gWzm3ys9_3SlbmYelynoIryihDrchlIkg8GslhHwbwo, https://www.wellcome.com.hk/zh-hant/store_locator?srsltid=AU7gw4Ub9vVd8KRs-lYxZ-q_F1WhsgVPWgEwxkxoGF-miM0ax87KZtk8 and https://www.7-eleven.com.hk/zh/node/90751.
3. Official venue, mall, MTR, Housing Authority, government (https://data.gov.hk/en-data/dataset/hk-landsd-openmap-development-location-search-api) for addresses and shop numbers.
4. Reputable property or directory sources when primary sources do not expose the required detail.

For each row, record the source URL used for the address and/or coordinates.

Try to obtain a verified, store-specific coordinate when a web search or authoritative map source provides an accurate longitude and latitude for the exact shop or branch. Record the source URL and use that position for its marker. Do not treat a street-level geocode, postal-address result, or venue centroid as an accurate shop-door coordinate merely because it has precise-looking decimal places.

When no reliable store-specific coordinate is available, use the relevant building, estate, station, or mall point and state that it is approximate. This is particularly important for shops inside malls and MTR stations, where a street-level geocode cannot represent the actual floor or unit. Do not interrupt the user if no store-specific coordinate can be found.

## 3. Route planning

Plan the route for the requested travel mode, normally walking for fieldwork unless the user says otherwise.

Group points that are physically inside the same mall, estate, station, or complex so they are handled in one visit. Prefer a route that reduces retracing while respecting the user's fixed start and end locations.

Keep distinct store codes as separate stops, even when they share one building or station. If two or more stops have the same or visually overlapping verified/base coordinates, apply a small, consistent display-only displacement to their KML markers so each can be selected on the map. Keep each marker close to its real location, normally within 5–10 metres of the shared base point; use a compact radial or grid arrangement for larger groups. Do not displace markers that already have distinct, reliable store-specific coordinates. Plan route order from the verified/base locations, not from the artificial display offsets.

Use the verified coordinates to check the geographic order. When true road-network routing cannot be retrieved, do not claim that a straight-line optimisation is a real pedestrian shortest path. Describe the LineString as a practical geographic order instead.

## 4. Create the KML route

Save the required KML in the `routes` folder under the workspace root. Use the requested date when the user provides one; otherwise use tomorrow's date in the user's local timezone (Asia/Hong_Kong). Name the file `<day>-<month>.kml` using unpadded numbers, following the example `30-9.kml`; omit the year and any other suffix. Create the `routes` folder if it does not exist.

### KML requirements

Create a valid XML KML document containing:

- One `Placemark` with a `Point` for every location.
- A zero-padded order prefix in every placemark name as `Order｜Store Code｜Shortened Store name in Chinese`, for instance `07｜SEHK0086｜石硤尾邨美山樓（1號舖）` and `01｜SEHK1339｜南昌站 NAC 27`.
- Per-stop `ExtendedData` fields named `順序`, `地名`, `地址`, `緯度(latitude)`, `經度(longitude)`, optional`備註`, and `座標／地址來源`. Keep `來源網址` as a field as well so each researched address or coordinate can be traced to its source. When a marker is display-offset, also include `實際座標緯度(latitude)` and `實際座標經度(longitude)` for the verified/base position.
- A human-readable description containing the address, notes, coordinate/address source, and source URL.
- Numeric latitude and longitude values in `ExtendedData` that match the placemark's `Point` coordinates. KML geometry coordinates must be written in longitude, latitude, altitude order.
- One ordered `LineString` connecting the locations from 01 to the final stop.
- Put every stop `Point` placemark and the ordered route `LineString` placemark inside the same KML `Folder`, so Google My Maps imports them into the same layer. Do not place the route line outside the stops' folder or in a separate folder.

Represent the location name in the placemark name and `地名` field, the address in `地址`, the marker's latitude and longitude in both `緯度(latitude)` / `經度(longitude)` and its `Point`, and any access, geocoding, or display-offset caveats in `備註`. For an offset marker, store the unshifted verified/base latitude and longitude in `實際座標緯度(latitude)` / `實際座標經度(longitude)` and state the approximate offset from that point in `備註`. These coordinate fields must be numeric and the actual-coordinate fields must match the researched position. These data belong in the KML; do not create a CSV for them.

KML must be saved as actual `.kml` XML, not as a `.txt` file containing XML text.

## 5. Validation before delivery

Check the following before returning the KML:

- Order numbers run consecutively from 01 to the final stop, and each placemark name contains its order prefix.
- The KML is saved under `routes` with the correct requested or default date filename.
- KML parses as valid XML.
- KML contains one point placemark per stop.
- Every point placemark contains all required `ExtendedData` fields, and the marker latitude and longitude values match its geometry.
- For display-offset markers, verify that the actual-coordinate fields match the researched/base coordinates, the offset is small and documented, and the placemark remains close enough to the real location to avoid confusion.
- KML LineString coordinates follow the same order as the stops.
- No accidental HTML or non-KML text wrapper has been placed around the KML document.

## 6. Deliverable

Deliver the route KML saved as `routes/<day>-<month>.kml`.
Optionally provide a separate `.kmz` only when a packaged KML asset is genuinely useful.