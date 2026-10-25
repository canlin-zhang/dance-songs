#!/usr/bin/env bash
# Convert a scanned PDF (or image) with PaddleOCR-VL, GPU-pinned, via Docker Compose.
#
#   ./ocr.sh                          # convert everything in input/
#   ./ocr.sh scan.pdf                 # one file: cwd first, then input/
#   ./ocr.sh scan.pdf out/custom      # explicit output directory
#   ./ocr.sh --dry-run scan.pdf       # print the command, run nothing
#
# Layout (defaults to this directory; override with OCR_ROOT):
#   input/    drop files here
#   output/   one subdirectory per input file
#   models/   model cache, mounted at /models
#
# Environment:
#   MODE     doc_parser (default) | ocr | pp_structurev3
#   DEVICE   gpu:0 (default) — always passed explicitly
#   OCR_ROOT / OCR_INPUT / OCR_OUTPUT / OCR_MODELS
#
set -euo pipefail

TOOL_DIR=$(dirname "$(readlink -f "$0")")
ROOT="${OCR_ROOT:-$TOOL_DIR}"
INPUT="${OCR_INPUT:-$ROOT/input}"
OUTPUT="${OCR_OUTPUT:-$ROOT/output}"
MODELS="${OCR_MODELS:-$ROOT/models}"
MODE="${MODE:-doc_parser}"
DEVICE="${DEVICE:-gpu:0}"
DRY_RUN=false

export OCR_INPUT="$INPUT" OCR_OUTPUT="$OUTPUT" OCR_MODELS="$MODELS"
# compose substitutes ${UID}/${GID}; neither is in the environment by default,
# and its own :-1000 fallback would be wrong for any other uid.
export UID
GID=$(id -g)
export GID

die() { printf '!! %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true; shift ;;
    --help|-h)    usage; exit 0 ;;
    -*)           die "unknown flag: $1" ;;
    *)            break ;;
  esac
done

# Docker creates a missing bind source as root; create them as ourselves first.
mkdir -p "$INPUT" "$OUTPUT" "$MODELS"

resolve() {
  if [ -f "$1" ]; then readlink -f "$1"
  elif [ -f "$INPUT/$(basename "$1")" ]; then readlink -f "$INPUT/$(basename "$1")"
  else die "not found: $1 (looked in the current directory and in $INPUT)"
  fi
}

convert() {
  local src outdir name cmd src_dir src_path
  src=$(readlink -f "$1")
  name=$(basename "$src")
  src_dir=$(dirname "$src")
  outdir="${2:-$OUTPUT/${name%.*}}"
  mkdir -p "$outdir"
  outdir=$(readlink -f "$outdir")

  # input/ is already mounted read-only at /data/input; a file from anywhere
  # else needs its own directory mounted, or the container gets a path that
  # does not exist.
  local mount=()
  if [ "$src_dir" = "$(readlink -f "$INPUT")" ]; then
    src_path="/data/input/$name"
  else
    mount=(-v "$src_dir:/data/src:ro")
    src_path="/data/src/$name"
  fi

  cmd=(docker compose -f "$TOOL_DIR/compose.yaml" run --rm "${mount[@]}" ocr
    paddleocr "$MODE" -i "$src_path" --device "$DEVICE" --save_path /out)

  printf '== %s -> %s (mode %s, device %s)\n' "$name" "$outdir" "$MODE" "$DEVICE"
  printf '+ OCR_OUTPUT=%q' "$outdir"; printf ' %q' "${cmd[@]}"; printf '\n'
  # OCR_OUTPUT is set for this one call: the /out mount comes from compose
  if $DRY_RUN; then return 0; fi
  OCR_OUTPUT="$outdir" "${cmd[@]}"

  # doc_parser writes markdown; the ocr pipeline writes json/images only.
  if [ "$MODE" = doc_parser ]; then
    [ -n "$(find "$outdir" -maxdepth 1 -name '*.md' -print -quit)" ] \
      || die "no markdown written for $name — check the run log before trusting this output"
  else
    [ -n "$(find "$outdir" -maxdepth 1 -type f -print -quit)" ] \
      || die "no output written for $name (MODE=$MODE) — check the run log"
  fi
}

if [ $# -ge 1 ]; then
  convert "$(resolve "$1")" "${2:-}"
else
  shopt -s nullglob nocaseglob
  files=("$INPUT"/*.pdf "$INPUT"/*.png "$INPUT"/*.jpg "$INPUT"/*.jpeg "$INPUT"/*.tif "$INPUT"/*.tiff)
  shopt -u nullglob nocaseglob
  [ ${#files[@]} -gt 0 ] || die "nothing to do: put PDFs in $INPUT"
  for f in "${files[@]}"; do convert "$f"; done
fi
