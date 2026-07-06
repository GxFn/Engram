#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      if [[ $# -lt 2 ]]; then
        echo "usage: $0 [--root PATH]" >&2
        exit 2
      fi
      ROOT_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo "usage: $0 [--root PATH]" >&2
      exit 2
      ;;
  esac
done

FEATURE_IMPORT_PATTERN='^[[:space:]]*import[[:space:]]+(MLXEngine|FMEngine|ClipDigest|ClipPipeline|VectorStoreSQLite|EmbeddingMLX|ModelStore|Persistence)([[:space:]]|$)'
EXTENSION_IMPORT_PATTERN='^[[:space:]]*import[[:space:]]+(AppGroupSupport|AppShell|AskFeature|BenchFeature|ClipDigest|EmbeddingMLX|EngineKit|FMEngine|FoundationNetworking|MemoryFeature|MLX|MLXEngine|MLXLLM|MLXLMCommon|ModelStore|Network|Persistence|RAGCore|SettingsFeature|SwiftData|VectorStoreSQLite)([[:space:]]|$)'
CLIPPIPELINE_IMPORT_PATTERN='^[[:space:]]*import[[:space:]]+(AppKit|AppShell|AskFeature|BenchFeature|ClipDigest|EmbeddingMLX|EngineKit|FMEngine|FoundationNetworking|MemoryFeature|MLX|MLXEngine|MLXLLM|MLXLMCommon|ModelStore|Network|Persistence|RAGCore|SettingsFeature|SwiftData|SwiftUI|UIKit|VectorStoreSQLite)([[:space:]]|$)'

check_swift_imports() {
  local label="$1"
  local root="$2"
  local pattern="$3"
  local match_count=0

  if [[ ! -d "$root" ]]; then
    echo "dependency guard: ${label} path not present; skipped"
    return 0
  fi

  while IFS= read -r -d '' file; do
    while IFS= read -r match; do
      if [[ -n "$match" ]]; then
        if [[ "$match_count" -eq 0 ]]; then
          echo "dependency guard: ${label} has forbidden imports:" >&2
        fi
        echo "${file#"$ROOT_DIR"/}:$match" >&2
        match_count=$((match_count + 1))
      fi
    done < <(grep -En "$pattern" "$file" || true)
  done < <(find "$root" -type f -name '*.swift' -print0)

  if [[ "$match_count" -gt 0 ]]; then
    return 1
  fi

  echo "dependency guard: ${label} passed"
}

discover_extension_roots() {
  find "$ROOT_DIR" \
    \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.build" -o -path "$ROOT_DIR/.swiftpm" \) -prune \
    -o -type d \
    \( -name 'ShareExtension' -o -name '*ShareExtension*' -o -name '*AppExtension*' -o -name '*Extension' \) \
    -print
}

check_swift_imports "Feature modules" "$ROOT_DIR/Sources/Features" "$FEATURE_IMPORT_PATTERN"
check_swift_imports "ClipPipeline module" "$ROOT_DIR/Sources/Infrastructure/ClipPipeline" "$CLIPPIPELINE_IMPORT_PATTERN"

extension_root_count=0
while IFS= read -r extension_root; do
  if [[ -n "$extension_root" ]]; then
    extension_root_count=$((extension_root_count + 1))
    check_swift_imports "Extension module ${extension_root#"$ROOT_DIR"/}" "$extension_root" "$EXTENSION_IMPORT_PATTERN"
  fi
done < <(discover_extension_roots)

if [[ "$extension_root_count" -eq 0 ]]; then
  echo "dependency guard: Extension modules not present; skipped"
fi
