#!/usr/bin/env bash
# scripts/agent-voice.sh — Local host-side voice control using containerized Whisper STT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"

# Check for ffmpeg on host
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg is not installed on the host." >&2
  echo "Please install it using Homebrew:" >&2
  echo "  brew install ffmpeg" >&2
  exit 1
fi

# Ensure container is running
if ! docker inspect -f '{{.State.Running}}' "${DOCKER_NAME}" >/dev/null 2>&1; then
  echo "ERROR: Container ${DOCKER_NAME} is not running." >&2
  echo "Please start the agent stack first using:" >&2
  echo "  make agent-start" >&2
  exit 1
fi

# Resolve AGENT_DATA_DIR
DATA_DIR="${AGENT_DATA_DIR:-}"
if [[ -z "${DATA_DIR}" ]]; then
  DATA_DIR="${PROJECT_ROOT}/.runtime/agent"
else
  case "${DATA_DIR}" in
    /*) ;;
    *) DATA_DIR="${PROJECT_ROOT}/${DATA_DIR}" ;;
  esac
fi

mkdir -p "${DATA_DIR}"

temp_wav="/tmp/omlx-voice.wav"
rm -f "${temp_wav}"

echo "==> Recording from default microphone..."
echo "Press [Enter] to stop recording."
echo

# Run ffmpeg in background
ffmpeg -y -f avfoundation -i ":default" "${temp_wav}" >/dev/null 2>&1 &
FFMPEG_PID=$!

# Wait for user input
read -r || true

# Terminate recording
kill "${FFMPEG_PID}" 2>/dev/null || true
wait "${FFMPEG_PID}" 2>/dev/null || true

if [[ ! -f "${temp_wav}" || ! -s "${temp_wav}" ]]; then
  echo "ERROR: Recording failed or no audio was captured." >&2
  exit 1
fi

# Copy wav to shared data folder
cp "${temp_wav}" "${DATA_DIR}/voice.wav"
rm -f "${temp_wav}"

echo "==> Transcribing audio using containerized Whisper..."
transcription=$(docker exec -e HF_HOME=/opt/data/.cache/huggingface "${DOCKER_NAME}" /opt/hermes/.venv/bin/python3 -c "
from faster_whisper import WhisperModel
try:
    model = WhisperModel('base', device='cpu', local_files_only=True)
    segments, info = model.transcribe('/opt/data/voice.wav')
    text = ''.join(seg.text for seg in segments).strip()
    print(text)
except Exception as e:
    import sys
    print(f'Error during transcription: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || true)

if [[ -z "${transcription}" ]]; then
  echo "ERROR: Transcription is empty or speech was not recognized." >&2
  exit 1
fi

echo "--------------------------------------------------"
echo "Transcribed: \"${transcription}\""
echo "--------------------------------------------------"
echo

# Confirm sending (respect YOLO mode)
YOLO_MODE="${HERMES_YOLO_MODE:-0}"
if [[ "${YOLO_MODE}" != "1" && "${YOLO_MODE}" != "true" ]]; then
  printf "Send this prompt to the agent? [Y/n]: "
  read -r confirm || confirm="n"
  if [[ "${confirm}" =~ ^[nN] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "==> Sending prompt to agent..."
echo

# Determine tty parameters
tty_args=()
if [[ -t 0 && -t 1 ]]; then
  tty_args+=(-it)
else
  tty_args+=(-i)
fi

exec docker exec "${tty_args[@]}" "${DOCKER_NAME}" /opt/hermes/bin/hermes "$@" -z "${transcription}"
