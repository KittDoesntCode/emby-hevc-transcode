#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 KittDoesntCode
# SPDX-License-Identifier: MIT
#
# emby-hevc-transcode.sh
# Version 1.0.2
#
# Serial, VA-API HEVC library converter for Emby media on Linux.
#
# Copyright (c) 2026 KittDoesntCode
#
# Licensed under the MIT License. See the LICENSE file in the
# repository root for the full license text.
#
# Safety model:
#   * Non-destructive operation is the default.
#   * Output is encoded to a unique temporary MKV in the destination directory.
#   * The temporary file is validated with ffprobe, then atomically renamed.
#   * --destructive deletes the source and source-basename sidecars only after
#     the new output has been successfully validated and installed.
#   * Existing output paths are fatal to avoid accidental collisions.
#
# Intended output: MKV, HEVC Main / 8-bit / yuv420p, VA-API CQP.
# Audio, subtitles, attachments, data streams, metadata, and chapters are copied.

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s nullglob

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.2"
readonly DEFAULT_VAAPI_DEVICE="/dev/dri/renderD128"
readonly DEFAULT_QP=22
readonly DEFAULT_MIN_FREE_GB=50
readonly LOCK_FILE_NAME=".emby-hevc-transcode.lock"

MODE=""
SINGLE_FILE=""
TARGET_HEIGHT=""
DESTRUCTIVE=0
DRY_RUN=0
QP="$DEFAULT_QP"
MIN_FREE_GB="$DEFAULT_MIN_FREE_GB"
VAAPI_DEVICE="$DEFAULT_VAAPI_DEVICE"
NICE_LEVEL=10
IONICE_CLASS="idle"
IONICE_LEVEL=7
START_DIR=""
LOG_FILE=""
LOCK_FD=""
CURRENT_TEMP_FILE=""
STOP_REQUESTED=0

EXCLUDES=()

TOTAL_FOUND=0
TOTAL_CONVERTED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0
TOTAL_DELETED=0

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME -f FILE -p {720|1080} [options]
  $SCRIPT_NAME -r -p {720|1080} [options]

Required (choose exactly one):
  -f, --file FILE            Convert one .mkv or .mp4 file.
  -r, --recursive            Recursively scan the current directory for .mkv and .mp4 files.

Required:
  -p, --resolution HEIGHT    Target video height: 720 or 1080.

Options:
  -d, --destructive          Destructive mode; use only after successful output validation.
                             After a validated output is installed, delete the original source
                             and same-basename sidecars (.bif, .jpg, .jpeg, .png, .nfo, .vtt).
  -n, --dry-run              Print planned actions without encoding, renaming, deleting, or
                             writing a log file.
      --qp N                 VA-API HEVC constant-QP quality value (0-51). Default: $DEFAULT_QP.
                             Lower values increase quality and output size.
      --min-free-gb N        Minimum free space required on the destination filesystem before
                             each conversion. Default: $DEFAULT_MIN_FREE_GB GiB.
      --exclude PATH         Exclude a directory subtree during recursive scans. Repeatable.
      --vaapi-device PATH    VA-API render node. Default: $DEFAULT_VAAPI_DEVICE.
      --nice N               nice level for FFmpeg (-20 to 19). Default: 10.
      --ionice CLASS:LEVEL   I/O priority when ionice exists. CLASS: idle, best-effort, or
                             realtime; LEVEL: 0-7. Default: idle:7.
  -h, --help                 Show this help text.

Processing policy:
  * Output is always MKV: HEVC Main, 8-bit, yuv420p.
  * Output is 720p or 1080p using VA-API scaling and HEVC encoding.
  * Audio, subtitles, attachments/data streams, metadata, and chapters are copied.
  * Files already HEVC at the requested height are skipped.
  * Sources smaller than the requested height are skipped; no upscaling is performed.
  * HDR/HLG/Dolby Vision, 10-bit, interlaced, and multi-video-stream sources are skipped.
  * Existing expected output files are a fatal error; the script stops immediately.
  * Output naming preserves a terminal source label when present:
      'Episode Bluray-1080p.mkv' -> 'Episode Bluray-HEVC-720p.mkv'
      'Episode WEBDL-2160p.mp4'  -> 'Episode WEBDL-HEVC-1080p.mkv'
      'Episode.mkv'              -> 'Episode HEVC-720p.mkv'
  * A TSV log is written in the directory where the script starts, except in dry-run mode.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

info() {
    printf '%s\n' "$*"
}

log_row() {
    local status="$1" reason="$2" source="$3" output="$4"
    local input_bytes="$5" output_bytes="$6" started="$7" ended="$8" exit_code="$9"
    (( DRY_RUN )) && return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$status" "$reason" "$source" "$output" "$input_bytes" "$output_bytes" \
        "$started" "$ended" "$exit_code" >> "$LOG_FILE"
}

on_signal() {
    local signal="$1"
    STOP_REQUESTED=1
    warn "Received $signal; stopping after cleanup."
    if [[ -n "$CURRENT_TEMP_FILE" && -e "$CURRENT_TEMP_FILE" ]]; then
        warn "Removing incomplete temporary file: $CURRENT_TEMP_FILE"
        rm -f -- "$CURRENT_TEMP_FILE" || true
    fi
    exit 130
}

cleanup() {
    local rc=$?
    if (( rc != 0 )) && [[ -n "$CURRENT_TEMP_FILE" && -e "$CURRENT_TEMP_FILE" ]]; then
        rm -f -- "$CURRENT_TEMP_FILE" || true
    fi
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" || true
    fi
}

trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_integer() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer: $2"
}

parse_ionice() {
    local value="$1"
    if [[ ! "$value" =~ ^(idle|best-effort|realtime):([0-7])$ ]]; then
        die "--ionice must be CLASS:LEVEL, where CLASS is idle, best-effort, or realtime and LEVEL is 0-7."
    fi
    IONICE_CLASS="${BASH_REMATCH[1]}"
    IONICE_LEVEL="${BASH_REMATCH[2]}"
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -f|--file)
                (( $# >= 2 )) || die "Missing value for $1."
                [[ -z "$MODE" ]] || die "Use exactly one of --file or --recursive."
                MODE="file"
                SINGLE_FILE="$2"
                shift 2
                ;;
            -r|--recursive)
                [[ -z "$MODE" ]] || die "Use exactly one of --file or --recursive."
                MODE="recursive"
                shift
                ;;
            -p|--resolution)
                (( $# >= 2 )) || die "Missing value for $1."
                TARGET_HEIGHT="$2"
                shift 2
                ;;
            -d|--destructive)
                DESTRUCTIVE=1
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            --qp)
                (( $# >= 2 )) || die "Missing value for $1."
                QP="$2"
                shift 2
                ;;
            --min-free-gb)
                (( $# >= 2 )) || die "Missing value for $1."
                MIN_FREE_GB="$2"
                shift 2
                ;;
            --exclude)
                (( $# >= 2 )) || die "Missing value for $1."
                EXCLUDES+=("$2")
                shift 2
                ;;
            --vaapi-device)
                (( $# >= 2 )) || die "Missing value for $1."
                VAAPI_DEVICE="$2"
                shift 2
                ;;
            --nice)
                (( $# >= 2 )) || die "Missing value for $1."
                NICE_LEVEL="$2"
                shift 2
                ;;
            --ionice)
                (( $# >= 2 )) || die "Missing value for $1."
                parse_ionice "$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (( $# == 0 )) || die "Unexpected positional arguments after --: $*"
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        usage >&2
        die "Missing required mode: specify --file FILE or --recursive."
    fi
    if [[ -z "$TARGET_HEIGHT" ]]; then
        usage >&2
        die "Missing required --resolution: specify 720 or 1080."
    fi
    [[ "$TARGET_HEIGHT" == "720" || "$TARGET_HEIGHT" == "1080" ]] || die "--resolution must be 720 or 1080."

    validate_integer "--qp" "$QP"
    (( QP <= 51 )) || die "--qp must be in the range 0-51."
    validate_integer "--min-free-gb" "$MIN_FREE_GB"
    [[ "$NICE_LEVEL" =~ ^-?[0-9]+$ ]] || die "--nice must be an integer in the range -20 to 19."
    (( NICE_LEVEL >= -20 && NICE_LEVEL <= 19 )) || die "--nice must be in the range -20 to 19."
}

validate_environment() {
    require_command ffmpeg
    require_command ffprobe
    require_command find
    require_command awk
    require_command df
    require_command flock
    require_command stat
    require_command nice

    [[ -c "$VAAPI_DEVICE" ]] || die "VA-API device is not a character device: $VAAPI_DEVICE"
    [[ -r "$VAAPI_DEVICE" && -w "$VAAPI_DEVICE" ]] || die "VA-API device is not readable/writable by the current user: $VAAPI_DEVICE"

    ffmpeg -hide_banner -h encoder=hevc_vaapi >/dev/null 2>&1 \
        || die "This FFmpeg build does not expose the hevc_vaapi encoder."
    ffmpeg -hide_banner -h filter=scale_vaapi >/dev/null 2>&1 \
        || die "This FFmpeg build does not expose the scale_vaapi filter."

    if [[ "$MODE" == "file" ]]; then
        [[ -f "$SINGLE_FILE" ]] || die "Input file does not exist or is not a regular file: $SINGLE_FILE"
    fi
}

setup_run() {
    START_DIR="$(pwd -P)"

    if (( ! DRY_RUN )); then
        LOG_FILE="$START_DIR/emby-hevc-transcode-$(date +%Y%m%d-%H%M%S).tsv"
        {
            printf '# script=%s\n' "$SCRIPT_NAME"
            printf '# version=%s\n' "$SCRIPT_VERSION"
            printf '# started=%s\n' "$(date --iso-8601=seconds)"
            printf '# mode=%s\n' "$MODE"
            printf '# target_height=%s\n' "$TARGET_HEIGHT"
            printf '# qp=%s\n' "$QP"
            printf '# destructive=%s\n' "$DESTRUCTIVE"
            printf '# start_dir=%s\n' "$START_DIR"
            printf 'status\treason\tsource\toutput\tinput_bytes\toutput_bytes\tstarted\tended\tffmpeg_exit_code\n'
        } > "$LOG_FILE"
    fi

    exec {LOCK_FD}>"$START_DIR/$LOCK_FILE_NAME"
    flock -n "$LOCK_FD" || die "Another $SCRIPT_NAME process holds the lock for $START_DIR."
}

is_excluded() {
    local path="$1" exclude
    for exclude in "${EXCLUDES[@]}"; do
        [[ -n "$exclude" ]] || continue
        if [[ "$path" == "$exclude" || "$path" == "$exclude"/* ]]; then
            return 0
        fi
    done
    case "$path" in
        */@eaDir/*|*/.Recycle.Bin/*|*/#recycle/*|*/.emby-hevc-tmp-* ) return 0 ;;
    esac
    return 1
}

get_probe_value() {
    local file="$1" entry="$2"
    ffprobe -v error -select_streams v:0 -show_entries "stream=$entry" \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -n 1 || true
}

count_video_streams() {
    local file="$1"
    ffprobe -v error -select_streams v -show_entries stream=index \
        -of csv=p=0 "$file" 2>/dev/null | awk 'NF { count++ } END { print count + 0 }'
}

has_hdr_or_10bit() {
    local file="$1" pix_fmt color_transfer color_primaries side_data
    pix_fmt="$(get_probe_value "$file" "pix_fmt")"
    color_transfer="$(get_probe_value "$file" "color_transfer")"
    color_primaries="$(get_probe_value "$file" "color_primaries")"
    side_data="$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"

    [[ "$pix_fmt" == *10* || "$pix_fmt" == *12* || "$pix_fmt" == *16* ]] && return 0
    [[ "$color_transfer" == "smpte2084" || "$color_transfer" == "arib-std-b67" ]] && return 0
    [[ "$color_primaries" == "bt2020" ]] && return 0
    grep -qiE 'DOVI|Dolby Vision|HDR' <<< "$side_data" && return 0
    return 1
}

source_is_interlaced() {
    case "$1" in
        progressive|unknown|"") return 1 ;;
        *) return 0 ;;
    esac
}

make_output_path() {
    # Case-insensitive pattern matching is used only to recognize accepted source
    # labels. BASH_REMATCH captures the original spelling, so filenames preserve
    # labels such as Bluray, WEBDL, WebDL, WEB-DL, and HDTV exactly as supplied.
    local source="$1" dir filename stem prefix source_label
    dir="$(dirname -- "$source")"
    filename="$(basename -- "$source")"
    stem="${filename%.*}"

    if [[ "$stem" =~ ^(.*)([[:space:]-])(Bluray|Blu-ray|WEBDL|WEB-DL|WEBRip|WEB-RIP|HDTV|REMUX|DVD|DVDRip|BDRip|BRRip)-[0-9]{3,4}[pP]$ ]]; then
        prefix="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        source_label="${BASH_REMATCH[3]}"
        printf '%s/%s%s-HEVC-%sp.mkv' "$dir" "$prefix" "$source_label" "$TARGET_HEIGHT"
    elif [[ "$stem" =~ ^(.*)-[0-9]{3,4}[pP]$ ]]; then
        # An unrecognized terminal resolution label is replaced. Retaining an
        # arbitrary unrecognized token can produce misleading output naming.
        printf '%s/%s HEVC-%sp.mkv' "$dir" "${BASH_REMATCH[1]}" "$TARGET_HEIGHT"
    else
        printf '%s/%s HEVC-%sp.mkv' "$dir" "$stem" "$TARGET_HEIGHT"
    fi
}

check_free_space() {
    local destination_dir="$1" available_kib required_kib
    available_kib="$(df -Pk -- "$destination_dir" | awk 'NR == 2 { print $4 }')"
    [[ "$available_kib" =~ ^[0-9]+$ ]] || die "Could not determine free space for: $destination_dir"
    required_kib=$(( MIN_FREE_GB * 1024 * 1024 ))
    (( available_kib >= required_kib )) || die "Free-space safeguard triggered for $destination_dir: available ${available_kib} KiB; require at least ${MIN_FREE_GB} GiB."
}

make_temp_path() {
    local output="$1" output_dir output_base
    output_dir="$(dirname -- "$output")"
    output_base="$(basename -- "$output")"
    printf '%s/.emby-hevc-tmp-%s.%s.%s.mkv' "$output_dir" "$output_base" "$$" "$(date +%s%N)"
}

validate_output() {
    local output="$1" codec profile pix_fmt height
    codec="$(get_probe_value "$output" "codec_name")"
    profile="$(get_probe_value "$output" "profile")"
    pix_fmt="$(get_probe_value "$output" "pix_fmt")"
    height="$(get_probe_value "$output" "height")"
    [[ "$codec" == "hevc" && "$profile" == "Main" && "$pix_fmt" == "yuv420p" && "$height" == "$TARGET_HEIGHT" ]]
}

remove_sidecars() {
    local source="$1" dir filename stem candidate candidate_name suffix
    dir="$(dirname -- "$source")"
    filename="$(basename -- "$source")"
    stem="${filename%.*}"

    for candidate in "$dir"/"$stem".* "$dir"/"$stem"-*; do
        [[ -f "$candidate" ]] || continue
        [[ "$candidate" != "$source" ]] || continue
        candidate_name="$(basename -- "$candidate")"
        suffix="${candidate_name##*.}"
        suffix="${suffix,,}"
        case "$suffix" in
            bif|jpg|jpeg|png|nfo|vtt)
                if (( DRY_RUN )); then
                    info "DRY-RUN: would delete sidecar: $candidate"
                else
                    rm -f -- "$candidate"
                    ((TOTAL_DELETED+=1))
                    info "Deleted sidecar: $candidate"
                fi
                ;;
        esac
    done
}

run_ffmpeg() {
    local source="$1" temp="$2"
    local -a cmd=(
        ffmpeg
        -hide_banner
        -nostdin
        -n
        -vaapi_device "$VAAPI_DEVICE"
        -i "$source"
        -map 0
        -map_metadata 0
        -map_chapters 0
        -vf:v:0 "format=nv12,hwupload,scale_vaapi=w=-2:h=${TARGET_HEIGHT}"
        -c:v:0 hevc_vaapi
        -profile:v:0 main
        -rc_mode:v:0 CQP
        -qp:v:0 "$QP"
        -c:a copy
        -c:s copy
        -c:d copy
        -c:t copy
        "$temp"
    )

    if command -v ionice >/dev/null 2>&1; then
        case "$IONICE_CLASS" in
            idle) cmd=(ionice -c 3 "${cmd[@]}") ;;
            best-effort) cmd=(ionice -c 2 -n "$IONICE_LEVEL" "${cmd[@]}") ;;
            realtime) cmd=(ionice -c 1 -n "$IONICE_LEVEL" "${cmd[@]}") ;;
        esac
    else
        warn "ionice is unavailable; continuing without I/O-priority adjustment."
    fi
    cmd=(nice -n "$NICE_LEVEL" "${cmd[@]}")

    info "FFmpeg command: $(printf '%q ' "${cmd[@]}")"
    "${cmd[@]}"
}

skip_file() {
    local reason="$1" source="$2" source_bytes="$3" started="$4"
    info "SKIP: $reason"
    ((TOTAL_SKIPPED+=1))
    log_row "SKIPPED" "$reason" "$source" "" "$source_bytes" "" "$started" "$(date --iso-8601=seconds)" ""
}

process_file() {
    local source="$1" source_lower started ended source_bytes output_bytes
    local codec height width field_order video_count output temp rc reason

    (( STOP_REQUESTED )) && return 0
    [[ -f "$source" ]] || return 0

    source_lower="${source,,}"
    case "$source_lower" in
        *.mkv|*.mp4) ;;
        *) return 0 ;;
    esac

    is_excluded "$source" && return 0

    ((TOTAL_FOUND+=1))
    info "Processing: $source"
    started="$(date --iso-8601=seconds)"
    source_bytes="$(stat -c '%s' -- "$source" 2>/dev/null || printf '0')"

    video_count="$(count_video_streams "$source")"
    if [[ "$video_count" != "1" ]]; then
        skip_file "expected exactly one video stream; found $video_count" "$source" "$source_bytes" "$started"
        return 0
    fi

    codec="$(get_probe_value "$source" "codec_name")"
    height="$(get_probe_value "$source" "height")"
    width="$(get_probe_value "$source" "width")"
    field_order="$(get_probe_value "$source" "field_order")"

    if [[ -z "$codec" || -z "$height" || -z "$width" ]]; then
        skip_file "unable to probe primary video stream" "$source" "$source_bytes" "$started"
        return 0
    fi

    if source_is_interlaced "$field_order"; then
        skip_file "interlaced source (field_order=$field_order)" "$source" "$source_bytes" "$started"
        return 0
    fi

    if has_hdr_or_10bit "$source"; then
        skip_file "HDR/HLG/Dolby Vision or >8-bit source; dedicated HDR workflow required" "$source" "$source_bytes" "$started"
        return 0
    fi

    if (( height < TARGET_HEIGHT )); then
        skip_file "source height ${height} is below requested ${TARGET_HEIGHT}; no upscaling" "$source" "$source_bytes" "$started"
        return 0
    fi

    if [[ "$codec" == "hevc" && "$height" == "$TARGET_HEIGHT" ]]; then
        skip_file "already HEVC at requested ${TARGET_HEIGHT}p height" "$source" "$source_bytes" "$started"
        return 0
    fi

    output="$(make_output_path "$source")"
    if [[ -e "$output" ]]; then
        die "Expected output already exists; refusing to continue: $output"
    fi

    if (( DRY_RUN )); then
        info "DRY-RUN: would convert: $source"
        info "DRY-RUN: output would be: $output"
        if (( DESTRUCTIVE )); then
            info "DRY-RUN: after validation, would delete original and matching sidecars."
            remove_sidecars "$source"
            info "DRY-RUN: would delete source: $source"
        fi
        ((TOTAL_CONVERTED+=1))
        return 0
    fi

    check_free_space "$(dirname -- "$output")"
    temp="$(make_temp_path "$output")"
    CURRENT_TEMP_FILE="$temp"
    info "Output: $output"
    info "Temporary output: $temp"

    set +e
    run_ffmpeg "$source" "$temp"
    rc=$?
    set -e

    if (( rc != 0 )); then
        reason="ffmpeg failed with exit code $rc"
        warn "$reason: $source"
        rm -f -- "$temp" || true
        CURRENT_TEMP_FILE=""
        ((TOTAL_FAILED+=1))
        log_row "FAILED" "$reason" "$source" "$output" "$source_bytes" "" "$started" "$(date --iso-8601=seconds)" "$rc"
        return 0
    fi

    if ! validate_output "$temp"; then
        reason="output validation failed (expected HEVC Main yuv420p ${TARGET_HEIGHT}p)"
        warn "$reason: $temp"
        rm -f -- "$temp" || true
        CURRENT_TEMP_FILE=""
        ((TOTAL_FAILED+=1))
        log_row "FAILED" "$reason" "$source" "$output" "$source_bytes" "" "$started" "$(date --iso-8601=seconds)" "0"
        return 0
    fi

    mv -- "$temp" "$output"
    CURRENT_TEMP_FILE=""
    output_bytes="$(stat -c '%s' -- "$output" 2>/dev/null || printf '0')"
    info "Completed: $output"

    if (( DESTRUCTIVE )); then
        remove_sidecars "$source"
        rm -f -- "$source"
        ((TOTAL_DELETED+=1))
        info "Deleted source: $source"
    fi

    ended="$(date --iso-8601=seconds)"
    ((TOTAL_CONVERTED+=1))
    log_row "CONVERTED" "success" "$source" "$output" "$source_bytes" "$output_bytes" "$started" "$ended" "0"
}

scan_recursive() {
    local path
    while IFS= read -r -d '' path; do
        process_file "$path"
    done < <(find . -type f \( -iname '*.mkv' -o -iname '*.mp4' \) -print0)
}

main() {
    parse_args "$@"
    validate_environment
    setup_run

    info "Script: $SCRIPT_NAME (v$SCRIPT_VERSION)"
    info "Mode: $MODE"
    info "Target: ${TARGET_HEIGHT}p HEVC Main / VA-API CQP QP $QP"
    info "Destructive: $DESTRUCTIVE"
    info "Dry run: $DRY_RUN"
    (( DRY_RUN )) || info "Log: $LOG_FILE"

    if [[ "$MODE" == "file" ]]; then
        process_file "$SINGLE_FILE"
    else
        scan_recursive
    fi

    info "Summary: found=$TOTAL_FOUND converted_or_planned=$TOTAL_CONVERTED skipped=$TOTAL_SKIPPED failed=$TOTAL_FAILED deleted=$TOTAL_DELETED"
    (( TOTAL_FAILED == 0 )) || exit 2
}

main "$@"
