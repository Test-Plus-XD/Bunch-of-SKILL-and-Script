#!/usr/bin/env zsh

setopt extended_glob typeset_silent
export LC_NUMERIC=C

root_path="$HOME/Downloads/Mobile Devices"
store_codes=()
anchors=()
folder_count=0
folder_count_text=''
commit_requested=0
tab_character=$'\t'
eligible_extensions=(jpg jpeg png)
expected_code_pattern='^(SEHK|WEHK|MNHK)[0-9]{3,4}$'
digits_only_pattern='^[0-9]+$'
integer_pattern='^-?[0-9]+$'
shorthand_pattern='^([SWMswm])([0-9]{3,4})$'
spaced_code_pattern='([Ss][Ee][Hh][Kk]|[Ww][Ee][Hh][Kk]|[Mm][Nn][Hh][Kk]|[SsWwMm])[[:space:]]+([0-9]{3,4})'
reserved_name_pattern='^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$'
timestamp_pattern='([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$'
folder_label_pattern='^([Ff][Oo][Ll][Dd][Ee][Rr][[:space:]]+)?([0-9]+)$'
anchor_pattern='^(.+)(=|[Ss][Tt][Aa][Rr][Tt][Ss][[:space:]]+[Aa][Tt][[:space:]]+)([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?[[:space:]]*$'
opening_bracket_pattern='[[:space:]]#[[({][[:space:]]#'
closing_bracket_pattern='[[:space:]]#[])}][[:space:]]#'
typeset -A store_code_prefix_by_letter=(S SEHK W WEHK M MNHK)
typeset -A date_counts time_to_folder chosen_boundary_set pinned_position_set table_cells
typeset -a numeric_columns=(1 3 6)
planning_errors=()
warnings=()
failure_sources=()
failure_destinations=()
failure_errors=()

usage() {
  cat <<'EOF'
Usage: Organise-FieldworkPhotos-macOS.zsh [options]

  --root-path PATH        Folder holding the photos (default: ~/Downloads/Mobile Devices)
  --store-codes CODE...   Store Codes, for example S123 W456 MNHK789
  --folder-count NUMBER   Number of folders when no Store Codes are supplied
  --anchors TEXT...       Anchors such as "S123 starts at 10:30" or "folder 3=14:05"
  --commit                Create the folders and move the photos
  -h, --help              Show this help

Without --store-codes and --folder-count, the script prompts interactively.
EOF
}

trim_whitespace() {
  local value="$1"
  value="${value##[[:space:]]#}"
  value="${value%%[[:space:]]#}"
  print -r -- "$value"
}

json_quote() {
  local value="$1" backslash='\' quote='"'
  value="${value//$backslash/$backslash$backslash}"
  value="${value//$quote/$backslash$quote}"
  value="${value//$'\n'/${backslash}n}"
  value="${value//$'\r'/${backslash}r}"
  value="${value//$'\t'/${backslash}t}"
  value="${value//$'\b'/${backslash}b}"
  value="${value//$'\f'/${backslash}f}"
  print -rn -- "\"$value\""
}

json_nullable_string() {
  if [[ -z $1 ]]; then
    print -rn -- null
  else
    json_quote "$1"
  fi
}

json_string_array() {
  local item output='' separator=''
  for item in "$@"; do
    output+="${separator}$(json_quote "$item")"
    separator=','
  done
  print -rn -- "[$output]"
}

json_folder_summaries() {
  local folder_index output='' separator=''
  for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
    output+="${separator}{\"Index\":${folder_index},\"Name\":$(json_quote "${folder_names[folder_index]}"),\"PhotoCount\":${folder_photo_counts[folder_index]:-0},\"Earliest\":$(json_nullable_string "${folder_earliest_times[folder_index]}"),\"Latest\":$(json_nullable_string "${folder_latest_times[folder_index]}")}"
    separator=','
  done
  print -rn -- "[$output]"
}

json_boundaries() {
  local boundary_index output='' separator='' object
  for (( boundary_index = 1; boundary_index <= ${#boundary_from}; boundary_index++ )); do
    object="{\"From\":$(json_quote "${boundary_from[boundary_index]}"),\"To\":$(json_quote "${boundary_to[boundary_index]}"),\"GapMinutes\":${boundary_gap[boundary_index]},\"Pinned\":${boundary_pinned[boundary_index]},\"Approximate\":${boundary_approximate[boundary_index]}"
    if [[ ${boundary_unchosen[boundary_index]} == true ]]; then
      object+=',"UnchosenLongGap":true'
    fi
    output+="${separator}${object}}"
    separator=','
  done
  print -rn -- "[$output]"
}

json_move_failures() {
  local failure_index output='' separator=''
  for (( failure_index = 1; failure_index <= ${#failure_sources}; failure_index++ )); do
    output+="${separator}{\"Source\":$(json_quote "${failure_sources[failure_index]}"),\"Destination\":$(json_quote "${failure_destinations[failure_index]}"),\"Error\":$(json_quote "${failure_errors[failure_index]}")}"
    separator=','
  done
  print -rn -- "[$output]"
}

fail_with_error() {
  print -r -- "{\"Status\":\"error\",\"Error\":$(json_quote "$1"),\"Root\":$(json_quote "$root_path")}"
  exit 1
}

is_word_character() {
  [[ $1 == [[:alnum:]_] ]]
}

format_clock_text() {
  printf -v clock_text '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 ))
}

format_minutes_text() {
  local value
  printf -v value '%.2f' $(( $1 / 60.0 ))
  value="${value%%0#}"
  value="${value%.}"
  minutes_text="$value"
}

is_valid_timestamp() {
  local year=$(( 10#$1 )) month=$(( 10#$2 )) day=$(( 10#$3 ))
  local hour=$(( 10#$4 )) minute=$(( 10#$5 )) second_value=$(( 10#$6 ))
  local -a month_lengths=(31 28 31 30 31 30 31 31 30 31 30 31)
  local maximum_day
  (( year >= 1 && month >= 1 && month <= 12 )) || return 1
  maximum_day=${month_lengths[month]}
  if (( month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) )); then
    maximum_day=29
  fi
  (( day >= 1 && day <= maximum_day && hour <= 23 && minute <= 59 && second_value <= 59 ))
}

expand_store_code_shorthand() {
  local value="$1" trimmed letter digits
  trimmed="$(trim_whitespace "$value")"
  if [[ $trimmed =~ $shorthand_pattern ]]; then
    letter="${(U)match[1]}"
    digits="${match[2]}"
    print -r -- "${store_code_prefix_by_letter[$letter]}${digits}"
  else
    print -r -- "$value"
  fi
}

join_spaced_store_codes() {
  local remainder="$1" output='' preceding following prefix_text digits_text
  local match_start match_end boundary_acceptable
  while [[ -n $remainder ]] && [[ $remainder =~ $spaced_code_pattern ]]; do
    match_start=$MBEGIN
    match_end=$MEND
    prefix_text="${match[1]}"
    digits_text="${match[2]}"
    if (( match_start > 1 )); then
      preceding="${remainder[match_start-1]}"
    else
      preceding="${output[-1]}"
    fi
    following="${remainder[match_end+1]}"
    boundary_acceptable=1
    [[ -n $preceding ]] && is_word_character "$preceding" && boundary_acceptable=0
    [[ -n $following ]] && is_word_character "$following" && boundary_acceptable=0
    if (( boundary_acceptable )); then
      output+="${remainder[1,match_start-1]}${prefix_text}${digits_text}"
      remainder="${remainder[match_end+1,-1]}"
    else
      output+="${remainder[1,match_start]}"
      remainder="${remainder[match_start+1,-1]}"
    fi
  done
  print -r -- "${output}${remainder}"
}

normalise_store_codes() {
  local joined="${(F)@}" flattened token expanded
  local -a tokens
  joined="$(join_spaced_store_codes "$joined")"
  joined="$(trim_whitespace "$joined")"
  joined="${joined##$~opening_bracket_pattern}"
  joined="${joined%%$~closing_bracket_pattern}"
  flattened="${joined//,/ }"
  tokens=( ${=flattened} )
  normalised_codes=()
  for token in "${tokens[@]}"; do
    expanded="$(expand_store_code_shorthand "${(U)token}")"
    [[ -n $expanded ]] && normalised_codes+=("$expanded")
  done
}

is_output_folder_name() {
  local name="$1" requested_name
  local uppercase_name="${(U)1}"
  [[ $name =~ $digits_only_pattern ]] && return 0
  [[ $uppercase_name =~ $expected_code_pattern ]] && return 0
  for requested_name in "${folder_names[@]}"; do
    [[ "${(L)name}" == "${(L)requested_name}" ]] && return 0
  done
  return 1
}

find_eligible_source_files() {
  local root="$1" current_directory entry entry_name extension
  local -a pending_directories=("$root") entries
  eligible_files=()
  skipped_folder_paths=()
  while (( ${#pending_directories} > 0 )); do
    current_directory="${pending_directories[-1]}"
    pending_directories[-1]=()
    entries=( "$current_directory"/*(DN) )
    for entry in "${entries[@]}"; do
      entry_name="${entry:t}"
      if [[ -d $entry ]]; then
        if is_output_folder_name "$entry_name"; then
          skipped_folder_paths+=("$entry")
          continue
        fi
        [[ -L $entry ]] || pending_directories+=("$entry")
        continue
      fi
      extension="${entry_name:e}"
      extension="${(L)extension}"
      if (( ${eligible_extensions[(Ie)$extension]} )); then
        eligible_files+=("$entry")
      fi
    done
  done
}

parse_anchor() {
  local value="$1" trimmed label expanded_label clock_description
  local hour minute second_value name_index
  anchor_error=''
  trimmed="$(trim_whitespace "$value")"
  if [[ ! $trimmed =~ $anchor_pattern ]]; then
    anchor_error="Invalid anchor '$value'. Use 'CODE starts at HH:mm' or 'folder 3 starts at HH:mm'."
    return 1
  fi
  label="$(trim_whitespace "${match[1]}")"
  hour=$(( 10#${match[3]} ))
  minute=$(( 10#${match[4]} ))
  second_value=0
  [[ -n ${match[6]} ]] && second_value=$(( 10#${match[6]} ))
  clock_description="${match[3]}:${match[4]}${match[5]}"
  if (( hour > 23 || minute > 59 || second_value > 59 )); then
    anchor_error="Invalid anchor time '$clock_description' in '$value'."
    return 1
  fi
  anchor_seconds=$(( hour * 3600 + minute * 60 + second_value ))
  anchor_source="$value"
  if [[ $label =~ $folder_label_pattern ]]; then
    anchor_folder_index=$(( 10#${match[2]} ))
    return 0
  fi
  expanded_label="$(expand_store_code_shorthand "$label")"
  for (( name_index = 1; name_index <= ${#folder_names}; name_index++ )); do
    if [[ "${(L)expanded_label}" == "${(L)folder_names[name_index]}" ]]; then
      anchor_folder_index=$name_index
      return 0
    fi
  done
  anchor_error="Anchor '$value' refers to no supplied Store Code or folder number."
  return 1
}

format_folder_label() {
  local folder_index="$1" folder_name="${folder_names[$1]}"
  if [[ $folder_name == "$folder_index" ]]; then
    print -r -- "folder $folder_index"
  else
    print -r -- "$folder_name ($folder_index)"
  fi
}

read_numbered_store_code_input() {
  local -a finished_lines=()
  local current_text='' key_character swallowed_key prefix_label reopened_line
  local separator_column prefix_length=3 terminal_width
  terminal_input=''
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf '> '
    IFS= read -r terminal_input
    return
  fi
  terminal_width="$(tput cols 2>/dev/null)"
  [[ $terminal_width == <-> ]] || terminal_width=80
  printf '1: '
  while IFS= read -rsk 1 key_character; do
    prefix_label="$(( ${#finished_lines} + 1 )): "
    prefix_length=${#prefix_label}
    if [[ $key_character == $'\n' || $key_character == $'\r' ]]; then
      break
    fi
    if [[ $key_character == $'\e' ]]; then
      if IFS= read -rsk 1 -t 0.05 swallowed_key; then
        if [[ $swallowed_key == '[' || $swallowed_key == 'O' ]]; then
          while IFS= read -rsk 1 -t 0.05 swallowed_key; do
            [[ $swallowed_key == [A-Za-z~] ]] && break
          done
        fi
      fi
      continue
    fi
    if [[ $key_character == $'\177' || $key_character == $'\b' ]]; then
      if (( ${#current_text} > 0 )); then
        current_text="${current_text[1,-2]}"
        printf '\b \b'
        continue
      fi
      (( ${#finished_lines} == 0 )) && continue
      printf '\r%*s' $prefix_length ''
      reopened_line="${finished_lines[-1]}"
      finished_lines[-1]=()
      current_text="${reopened_line[1,-2]}"
      prefix_label="$(( ${#finished_lines} + 1 )): "
      separator_column=$(( ${#prefix_label} + ${#current_text} + 1 ))
      printf '\e[A\e[%dG \e[%dG' $separator_column $separator_column
      continue
    fi
    [[ $key_character == [[:cntrl:]] ]] && continue
    if [[ $key_character == ',' || $key_character == ';' ]]; then
      [[ -z ${current_text//[[:space:]]/} ]] && continue
      finished_lines+=("${current_text}${key_character}")
      current_text=''
      printf '%s\n' "$key_character"
      printf '%d: ' $(( ${#finished_lines} + 1 ))
      continue
    fi
    (( prefix_length + ${#current_text} + 3 >= terminal_width )) && continue
    current_text+="$key_character"
    printf '%s' "$key_character"
  done
  if [[ -z $current_text ]] && (( ${#finished_lines} > 0 )); then
    printf '\r%*s\r' $prefix_length ''
  else
    printf '\n'
  fi
  terminal_input="${(j::)finished_lines}${current_text}"
}

render_table_row() {
  local row_index="$1" column cell_key cell_text line=''
  for (( column = 1; column <= 9; column++ )); do
    cell_key="${row_index}_${column}"
    if (( ${numeric_columns[(Ie)$column]} )); then
      printf -v cell_text '%*s' ${column_widths[column]} "${table_cells[$cell_key]}"
    else
      printf -v cell_text '%-*s' ${column_widths[column]} "${table_cells[$cell_key]}"
    fi
    line+="${cell_text}  "
  done
  print -r -- "${line%%[[:space:]]#}"
}

print_plan_table() {
  local -a headers=(Index Name PhotoCount Earliest Latest GapMinutes Pinned Approximate LongGaps)
  local folder_index column boundary_index cell_key cell_value
  local opening_gap opening_pinned opening_approximate long_gap_text
  table_cells=()
  column_widths=()
  for (( column = 1; column <= 9; column++ )); do
    table_cells[0_${column}]="${headers[column]}"
    column_widths[column]=${#headers[column]}
  done
  for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
    opening_gap=''
    opening_pinned=''
    opening_approximate=''
    long_gap_text=''
    for (( boundary_index = 1; boundary_index <= ${#boundary_from}; boundary_index++ )); do
      if [[ ${boundary_unchosen[boundary_index]} == false && -z $opening_gap && ${boundary_to[boundary_index]} == "${folder_earliest_times[folder_index]}" ]]; then
        opening_gap="${boundary_gap[boundary_index]}"
        [[ ${boundary_pinned[boundary_index]} == true ]] && opening_pinned=True || opening_pinned=False
        [[ ${boundary_approximate[boundary_index]} == true ]] && opening_approximate=True || opening_approximate=False
      fi
      if [[ ${boundary_unchosen[boundary_index]} == true ]] && [[ ! ${boundary_from[boundary_index]} < ${folder_earliest_times[folder_index]} ]] && [[ ! ${boundary_to[boundary_index]} > ${folder_latest_times[folder_index]} ]]; then
        [[ -n $long_gap_text ]] && long_gap_text+='; '
        long_gap_text+="${boundary_from[boundary_index]} to ${boundary_to[boundary_index]} (${boundary_gap[boundary_index]} min)"
      fi
    done
    table_cells[${folder_index}_1]="$folder_index"
    table_cells[${folder_index}_2]="${folder_names[folder_index]}"
    table_cells[${folder_index}_3]="${folder_photo_counts[folder_index]}"
    table_cells[${folder_index}_4]="${folder_earliest_times[folder_index]}"
    table_cells[${folder_index}_5]="${folder_latest_times[folder_index]}"
    table_cells[${folder_index}_6]="$opening_gap"
    table_cells[${folder_index}_7]="$opening_pinned"
    table_cells[${folder_index}_8]="$opening_approximate"
    table_cells[${folder_index}_9]="$long_gap_text"
    for (( column = 1; column <= 9; column++ )); do
      cell_key="${folder_index}_${column}"
      cell_value="${table_cells[$cell_key]}"
      (( ${#cell_value} > column_widths[column] )) && column_widths[column]=${#cell_value}
    done
  done
  render_table_row 0
  for (( column = 1; column <= 9; column++ )); do
    table_cells[rule_${column}]="${(l:${#headers[column]}::-:)}"
  done
  render_table_row rule
  for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
    render_table_row $folder_index
  done
}

validate_requested_names() {
  local name lowercase_name root_entry entry_type
  local -a seen_names root_entries
  root_entries=( "$resolved_root"/*(DN) )
  for name in "${folder_names[@]}"; do
    if [[ -z ${name//[[:space:]]/} || $name == . || $name == .. ]]; then
      planning_errors+=("Invalid empty or relative folder name '$name'.")
      continue
    fi
    if [[ $name == */* || $name == *' ' || $name == *. ]]; then
      planning_errors+=("Invalid Windows folder name '$name'.")
      continue
    fi
    if [[ ${(U)name} =~ $reserved_name_pattern ]]; then
      planning_errors+=("Reserved Windows device name '$name'.")
      continue
    fi
    lowercase_name="${(L)name}"
    if (( ${seen_names[(Ie)$lowercase_name]} )); then
      planning_errors+=("Duplicate folder name '$name' (Windows compares names without regard to case).")
    else
      seen_names+=("$lowercase_name")
    fi
    if [[ ! ${(U)name} =~ $expected_code_pattern && ! $name =~ $digits_only_pattern ]]; then
      warnings+=("Unusual Store Code or folder name '$name'; check for a typo.")
    fi
    for root_entry in "${root_entries[@]}"; do
      if [[ "${(L)root_entry:t}" == "$lowercase_name" ]]; then
        [[ -d $root_entry ]] && entry_type=folder || entry_type=file
        planning_errors+=("Destination '$name' already matches a root $entry_type; ask whether to reorganise it or choose another name.")
        break
      fi
    done
  done
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --commit) commit_requested=1; shift ;;
    --root-path=*) root_path="${1#*=}"; shift ;;
    --root-path)
      (( $# >= 2 )) || fail_with_error "Option --root-path needs a value."
      root_path="$2"
      shift 2 ;;
    --folder-count=*) folder_count_text="${1#*=}"; shift ;;
    --folder-count)
      (( $# >= 2 )) || fail_with_error "Option --folder-count needs a value."
      folder_count_text="$2"
      shift 2 ;;
    --store-codes=*) store_codes+=("${1#*=}"); shift ;;
    --store-codes)
      shift
      while (( $# > 0 )) && [[ $1 != --* ]]; do
        store_codes+=("$1")
        shift
      done ;;
    --anchors=*) anchors+=("${1#*=}"); shift ;;
    --anchors)
      shift
      while (( $# > 0 )) && [[ $1 != --* ]]; do
        anchors+=("$1")
        shift
      done ;;
    *) fail_with_error "Unknown option '$1'." ;;
  esac
done

if [[ -n $folder_count_text ]]; then
  [[ $folder_count_text =~ $integer_pattern ]] || fail_with_error "Folder count '$folder_count_text' is not an integer."
  folder_count=$(( 10#${folder_count_text#-} ))
  [[ $folder_count_text == -* ]] && folder_count=$(( -folder_count ))
fi

interactive_mode=0
(( ${#store_codes} == 0 && folder_count == 0 )) && interactive_mode=1
resolved_root="${root_path:A}"
[[ -d $resolved_root ]] || fail_with_error "Root path '$root_path' is not a directory."

if (( interactive_mode )); then
  print -r -- 'Enter Store Codes separated by commas or semicolons, or enter only a folder count:'
  read_numbered_store_code_input
  terminal_input="$(trim_whitespace "$terminal_input")"
  if [[ -z $terminal_input ]]; then
    print -r -- 'No input was provided. No files were changed.'
    exit 2
  fi
  if [[ $terminal_input =~ $digits_only_pattern ]]; then
    folder_count=$(( 10#$terminal_input ))
    if (( folder_count < 1 )); then
      print -r -- 'Folder count must be a positive integer. No files were changed.'
      exit 2
    fi
  else
    store_codes=()
    normalised_input="${terminal_input//;/,}"
    for input_piece in "${(@s:,:)normalised_input}"; do
      input_piece="$(trim_whitespace "$input_piece")"
      [[ -n $input_piece ]] && store_codes+=("$input_piece")
    done
  fi
fi

while true; do
  reprocess_requested=0
  planning_errors=()
  warnings=()
  normalise_store_codes "${store_codes[@]}"
  (( folder_count < 0 )) && planning_errors+=('Folder count cannot be negative.')
  if (( ${#normalised_codes} == 0 && folder_count == 0 )); then
    print -r -- "{\"Status\":\"needs_input\",\"Question\":\"Provide Store Codes or a positive folder count.\",\"Root\":$(json_quote "$resolved_root")}"
    exit 2
  fi
  (( folder_count == 0 )) && folder_count=${#normalised_codes}
  if (( ${#normalised_codes} > 0 && folder_count != ${#normalised_codes} )); then
    planning_errors+=("Folder count $folder_count differs from the ${#normalised_codes} Store Codes; provide a corrected count or list.")
  fi
  if (( ${#normalised_codes} == 0 && folder_count > 0 )); then
    normalised_codes=( {1..$folder_count} )
  fi
  folder_names=( "${normalised_codes[@]}" )
  validate_requested_names
  find_eligible_source_files "$resolved_root"
  parsed_paths=()
  parsed_names=()
  parsed_dates=()
  parsed_seconds=()
  unparseable_names=()
  for file_path in "${eligible_files[@]}"; do
    file_name="${file_path:t}"
    file_stem="${file_name:r}"
    if [[ $file_stem =~ $timestamp_pattern ]] && is_valid_timestamp "${match[1]}" "${match[2]}" "${match[3]}" "${match[4]}" "${match[5]}" "${match[6]}"; then
      parsed_paths+=("$file_path")
      parsed_names+=("$file_name")
      parsed_dates+=("${match[1]}-${match[2]}-${match[3]}")
      parsed_seconds+=( $(( 10#${match[4]} * 3600 + 10#${match[5]} * 60 + 10#${match[6]} )) )
    else
      unparseable_names+=("$file_path")
    fi
  done
  date_counts=()
  for (( index = 1; index <= ${#parsed_dates}; index++ )); do
    date_text="${parsed_dates[index]}"
    date_counts[$date_text]=$(( ${date_counts[$date_text]:-0} + 1 ))
  done
  date_group_lines=()
  for date_text in "${(@k)date_counts}"; do
    printf -v group_line '%09d|%s' $(( 999999999 - ${date_counts[$date_text]} )) "$date_text"
    date_group_lines+=("$group_line")
  done
  date_group_lines=( ${(o)date_group_lines} )
  selected_date=''
  top_count=0
  if (( ${#date_group_lines} > 0 )); then
    selected_date="${date_group_lines[1]#*|}"
    top_count=${date_counts[$selected_date]}
  else
    planning_errors+=('No eligible image filenames contain a valid YYYYMMDD_HHMMSS timestamp.')
  fi
  if (( ${#date_group_lines} > 1 )); then
    second_date="${date_group_lines[2]#*|}"
    (( ${date_counts[$second_date]} == top_count )) && planning_errors+=('The most common capture date is tied; choose which date to organise.')
  fi
  if (( ${#date_group_lines} > 0 && top_count < folder_count )); then
    planning_errors+=("Only $top_count timestamped photos exist on the most common date, fewer than the $folder_count requested folders.")
  fi
  selected_keys=()
  for (( index = 1; index <= ${#parsed_paths}; index++ )); do
    [[ "${parsed_dates[index]}" == "$selected_date" ]] || continue
    printf -v sort_key '%06d\t%s\t%09d' ${parsed_seconds[index]} "${(L)parsed_names[index]}" $index
    selected_keys+=("$sort_key")
  done
  selected_keys=( ${(o)selected_keys} )
  selected_paths=()
  selected_names=()
  selected_seconds=()
  for sort_key in "${selected_keys[@]}"; do
    original_index=$(( 10#${sort_key##*$tab_character} ))
    selected_paths+=("${parsed_paths[original_index]}")
    selected_names+=("${parsed_names[original_index]}")
    selected_seconds+=("${parsed_seconds[original_index]}")
  done
  unique_times=( ${(u)selected_seconds} )
  unique_time_texts=()
  for (( index = 1; index <= ${#unique_times}; index++ )); do
    format_clock_text ${unique_times[index]}
    unique_time_texts[index]="$clock_text"
  done
  if (( ${#unique_times} < folder_count )); then
    planning_errors+=("Only ${#unique_times} distinct timestamps can form groups, fewer than the $folder_count requested folders.")
  fi
  gap_seconds=()
  for (( position = 1; position < ${#unique_times}; position++ )); do
    gap_seconds[position]=$(( unique_times[position + 1] - unique_times[position] ))
  done
  anchor_folders=()
  anchor_clocks=()
  anchor_sources=()
  for anchor_text in "${anchors[@]}"; do
    if parse_anchor "$anchor_text"; then
      anchor_folders+=("$anchor_folder_index")
      anchor_clocks+=("$anchor_seconds")
      anchor_sources+=("$anchor_source")
    else
      planning_errors+=("$anchor_error")
    fi
  done
  pin_folders=()
  pin_positions=()
  for (( anchor_index = 1; anchor_index <= ${#anchor_folders}; anchor_index++ )); do
    anchor_folder=${anchor_folders[anchor_index]}
    anchor_clock=${anchor_clocks[anchor_index]}
    anchor_source_text="${anchor_sources[anchor_index]}"
    if (( anchor_folder < 2 || anchor_folder > folder_count )); then
      planning_errors+=("Anchor '$anchor_source_text' must identify a folder from 2 through $folder_count.")
      continue
    fi
    matching_time_index=-1
    for (( time_index = 0; time_index < ${#unique_times}; time_index++ )); do
      if (( unique_times[time_index + 1] >= anchor_clock )); then
        matching_time_index=$time_index
        break
      fi
    done
    if (( matching_time_index <= 0 )); then
      planning_errors+=("Anchor '$anchor_source_text' has no valid gap before the first photo at or after its time.")
      continue
    fi
    existing_pin_found=0
    for (( pin_index = 1; pin_index <= ${#pin_folders}; pin_index++ )); do
      if (( pin_folders[pin_index] == anchor_folder || pin_positions[pin_index] == matching_time_index )); then
        existing_pin_found=1
        if (( pin_folders[pin_index] != anchor_folder || pin_positions[pin_index] != matching_time_index )); then
          planning_errors+=("Anchor '$anchor_source_text' contradicts another pinned boundary.")
        fi
        break
      fi
    done
    (( existing_pin_found )) && continue
    pin_folders+=("$anchor_folder")
    pin_positions+=("$matching_time_index")
  done
  pin_lines=()
  for (( pin_index = 1; pin_index <= ${#pin_folders}; pin_index++ )); do
    printf -v pin_line '%09d|%09d' ${pin_folders[pin_index]} ${pin_positions[pin_index]}
    pin_lines+=("$pin_line")
  done
  pin_lines=( ${(o)pin_lines} )
  sorted_pin_folders=()
  sorted_pin_positions=()
  for pin_line in "${pin_lines[@]}"; do
    sorted_pin_folders+=( $(( 10#${pin_line%%|*} )) )
    sorted_pin_positions+=( $(( 10#${pin_line##*|} )) )
  done
  for (( pin_index = 2; pin_index <= ${#sorted_pin_positions}; pin_index++ )); do
    if (( sorted_pin_positions[pin_index] <= sorted_pin_positions[pin_index - 1] )); then
      planning_errors+=('Anchors are contradictory or leave no timestamp gap between their folders.')
    fi
  done
  pinned_position_set=()
  chosen_boundary_set=()
  chosen_boundaries=( "${sorted_pin_positions[@]}" )
  for position in "${sorted_pin_positions[@]}"; do
    pinned_position_set[$position]=1
  done
  stretch_folders=(1 "${sorted_pin_folders[@]}" $(( folder_count + 1 )))
  stretch_positions=(0 "${sorted_pin_positions[@]}" ${#unique_times})
  for (( stretch_index = 1; stretch_index < ${#stretch_folders}; stretch_index++ )); do
    left_folder=${stretch_folders[stretch_index]}
    left_position=${stretch_positions[stretch_index]}
    right_folder=${stretch_folders[stretch_index + 1]}
    right_position=${stretch_positions[stretch_index + 1]}
    needed_boundaries=$(( right_folder - left_folder - 1 ))
    candidate_keys=()
    for (( position = left_position + 1; position < right_position; position++ )); do
      printf -v candidate_key '%012d|%09d' $(( 999999999999 - gap_seconds[position] )) $position
      candidate_keys+=("$candidate_key")
    done
    candidate_keys=( ${(o)candidate_keys} )
    if (( ${#candidate_keys} < needed_boundaries )); then
      planning_errors+=("Between folder $left_folder and folder $right_folder, only ${#candidate_keys} gap(s) are available for $needed_boundaries required boundary/boundaries.")
      continue
    fi
    for (( pick_index = 1; pick_index <= needed_boundaries; pick_index++ )); do
      chosen_boundaries+=( $(( 10#${candidate_keys[pick_index]##*|} )) )
    done
  done
  for position in "${chosen_boundaries[@]}"; do
    chosen_boundary_set[$position]=1
  done
  time_to_folder=()
  current_folder_index=1
  for (( time_index = 0; time_index < ${#unique_times}; time_index++ )); do
    if (( time_index > 0 && ${+chosen_boundary_set[$time_index]} )); then
      current_folder_index=$(( current_folder_index + 1 ))
    fi
    time_to_folder[${unique_times[time_index + 1]}]=$current_folder_index
  done
  boundary_from=()
  boundary_to=()
  boundary_gap=()
  boundary_pinned=()
  boundary_approximate=()
  boundary_unchosen=()
  for (( position = 1; position < ${#unique_times}; position++ )); do
    gap_value=${gap_seconds[position]}
    from_seconds=${unique_times[position]}
    to_seconds=${unique_times[position + 1]}
    format_minutes_text $gap_value
    is_pinned=false
    (( ${+pinned_position_set[$position]} )) && is_pinned=true
    if (( ${+chosen_boundary_set[$position]} )); then
      is_approximate=false
      [[ $is_pinned == false ]] && (( gap_value < 600 )) && is_approximate=true
      boundary_from+=("${unique_time_texts[position]}")
      boundary_to+=("${unique_time_texts[position + 1]}")
      boundary_gap+=("$minutes_text")
      boundary_pinned+=("$is_pinned")
      boundary_approximate+=("$is_approximate")
      boundary_unchosen+=(false)
      if [[ $is_approximate == true ]]; then
        previous_folder_label="$(format_folder_label ${time_to_folder[$from_seconds]})"
        next_folder_label="$(format_folder_label ${time_to_folder[$to_seconds]})"
        warnings+=("Approximate unanchored boundary: $previous_folder_label to $next_folder_label, $minutes_text minutes.")
      fi
    elif (( gap_value >= 600 )); then
      boundary_from+=("${unique_time_texts[position]}")
      boundary_to+=("${unique_time_texts[position + 1]}")
      boundary_gap+=("$minutes_text")
      boundary_pinned+=(false)
      boundary_approximate+=(false)
      boundary_unchosen+=(true)
    fi
  done
  file_folders=()
  for (( index = 1; index <= ${#selected_paths}; index++ )); do
    file_folders[index]=${time_to_folder[${selected_seconds[index]}]}
  done
  folder_photo_counts=()
  folder_earliest_times=()
  folder_latest_times=()
  for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
    photo_count=0
    earliest_seconds=''
    latest_seconds=''
    for (( index = 1; index <= ${#selected_paths}; index++ )); do
      (( file_folders[index] == folder_index )) || continue
      (( photo_count == 0 )) && earliest_seconds=${selected_seconds[index]}
      latest_seconds=${selected_seconds[index]}
      photo_count=$(( photo_count + 1 ))
    done
    folder_photo_counts[folder_index]=$photo_count
    folder_earliest_times[folder_index]=''
    folder_latest_times[folder_index]=''
    if (( photo_count > 0 )); then
      format_clock_text $earliest_seconds
      folder_earliest_times[folder_index]="$clock_text"
      format_clock_text $latest_seconds
      folder_latest_times[folder_index]="$clock_text"
    else
      planning_errors+=("Folder $folder_index ('${folder_names[folder_index]}') would be empty.")
    fi
  done
  for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
    seen_file_names=()
    for (( index = 1; index <= ${#selected_paths}; index++ )); do
      (( file_folders[index] == folder_index )) || continue
      lowercase_file_name="${(L)selected_names[index]}"
      if (( ${seen_file_names[(Ie)$lowercase_file_name]} )); then
        planning_errors+=("Two source photos named '${selected_names[index]}' would collide in destination '${folder_names[folder_index]}'.")
      else
        seen_file_names+=("$lowercase_file_name")
      fi
    done
  done
  other_date_paths=()
  for (( index = 1; index <= ${#parsed_paths}; index++ )); do
    [[ "${parsed_dates[index]}" == "$selected_date" ]] || other_date_paths+=("${parsed_paths[index]}")
  done
  if (( ${#planning_errors} > 0 )); then
    print -r -- "{\"Status\":\"blocked\",\"Root\":$(json_quote "$resolved_root"),\"Errors\":$(json_string_array "${planning_errors[@]}"),\"Warnings\":$(json_string_array "${warnings[@]}"),\"SkippedOutputFolders\":$(json_string_array "${skipped_folder_paths[@]}"),\"OtherDateFiles\":$(json_string_array "${other_date_paths[@]}"),\"UnparseableFiles\":$(json_string_array "${unparseable_names[@]}"),\"PlannedFolders\":$(json_folder_summaries),\"Boundaries\":$(json_boundaries)}"
    exit 2
  fi
  should_commit=$commit_requested
  if (( ! should_commit )); then
    if (( ! interactive_mode )); then
      print -r -- "{\"Status\":\"plan\",\"Root\":$(json_quote "$resolved_root"),\"SelectedDate\":$(json_quote "$selected_date"),\"PlannedFolders\":$(json_folder_summaries),\"Boundaries\":$(json_boundaries),\"Warnings\":$(json_string_array "${warnings[@]}"),\"SkippedOutputFolders\":$(json_string_array "${skipped_folder_paths[@]}"),\"OtherDateFiles\":$(json_string_array "${other_date_paths[@]}"),\"UnparseableFiles\":$(json_string_array "${unparseable_names[@]}"),\"MoveFailures\":[]}"
      exit 0
    fi
    print -r -- ''
    print -r -- "Planned organisation for $selected_date"
    print_plan_table
    if (( ${#warnings} > 0 )); then
      print -r -- 'Warnings:'
      for warning_text in "${warnings[@]}"; do
        print -r -- "- $warning_text"
      done
    fi
    if (( ${#skipped_folder_paths} > 0 )); then
      print -r -- 'Skipped existing output folders:'
      for listed_path in "${skipped_folder_paths[@]}"; do
        print -r -- "- $listed_path"
      done
    fi
    if (( ${#other_date_paths} > 0 )); then
      print -r -- 'Other-date photos left in place:'
      for listed_path in "${other_date_paths[@]}"; do
        print -r -- "- $listed_path"
      done
    fi
    if (( ${#unparseable_names} > 0 )); then
      print -r -- 'Unparseable image filenames left in place:'
      for listed_path in "${unparseable_names[@]}"; do
        print -r -- "- $listed_path"
      done
    fi
    print -r -- 'Press Enter to create the folders and move the planned photos, or Space to reprocess the photos.'
    while IFS= read -rsk 1 -t 0.05 discarded_key; do :; done
    while true; do
      if ! IFS= read -rsk 1 confirmation_key; then
        print -r -- 'No confirmation was received. No files were changed.'
        exit 2
      fi
      [[ $confirmation_key == $'\n' || $confirmation_key == $'\r' || $confirmation_key == ' ' ]] && break
    done
    if [[ $confirmation_key == ' ' ]]; then
      reprocess_requested=1
      print -r -- ''
      print -r -- 'Reprocessing photos...'
    else
      should_commit=1
    fi
  fi
  (( reprocess_requested )) || break
done

for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
  destination_directory="$resolved_root/${folder_names[folder_index]}"
  mkdir -p -- "$destination_directory" || fail_with_error "Could not create folder '$destination_directory'."
done

for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
  destination_directory="$resolved_root/${folder_names[folder_index]}"
  for (( index = 1; index <= ${#selected_paths}; index++ )); do
    (( file_folders[index] == folder_index )) || continue
    source_path="${selected_paths[index]}"
    destination_path="$destination_directory/${selected_names[index]}"
    if [[ -e $destination_path || -L $destination_path ]]; then
      move_error="The file '$destination_path' already exists."
      move_status=1
    else
      move_error="$(command mv -- "$source_path" "$destination_path" 2>&1)"
      move_status=$?
    fi
    if (( move_status != 0 )); then
      failure_sources+=("$source_path")
      failure_destinations+=("$destination_path")
      failure_errors+=("$move_error")
    fi
  done
done

folder_photo_counts=()
folder_earliest_times=()
folder_latest_times=()
for (( folder_index = 1; folder_index <= folder_count; folder_index++ )); do
  destination_directory="$resolved_root/${folder_names[folder_index]}"
  moved_count=0
  earliest_seconds=''
  latest_seconds=''
  for (( index = 1; index <= ${#selected_paths}; index++ )); do
    (( file_folders[index] == folder_index )) || continue
    [[ -f "$destination_directory/${selected_names[index]}" ]] || continue
    (( moved_count == 0 )) && earliest_seconds=${selected_seconds[index]}
    latest_seconds=${selected_seconds[index]}
    moved_count=$(( moved_count + 1 ))
  done
  folder_photo_counts[folder_index]=$moved_count
  folder_earliest_times[folder_index]=''
  folder_latest_times[folder_index]=''
  if (( moved_count > 0 )); then
    format_clock_text $earliest_seconds
    folder_earliest_times[folder_index]="$clock_text"
    format_clock_text $latest_seconds
    folder_latest_times[folder_index]="$clock_text"
  fi
done

result_status=completed
(( ${#failure_sources} > 0 )) && result_status=partial
print -r -- "{\"Status\":\"$result_status\",\"Root\":$(json_quote "$resolved_root"),\"SelectedDate\":$(json_quote "$selected_date"),\"Folders\":$(json_folder_summaries),\"Boundaries\":$(json_boundaries),\"Warnings\":$(json_string_array "${warnings[@]}"),\"SkippedOutputFolders\":$(json_string_array "${skipped_folder_paths[@]}"),\"OtherDateFiles\":$(json_string_array "${other_date_paths[@]}"),\"UnparseableFiles\":$(json_string_array "${unparseable_names[@]}"),\"MoveFailures\":$(json_move_failures)}"