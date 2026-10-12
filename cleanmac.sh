#!/usr/bin/env bash
# cleanmac - macOS 只读存储扫描器
# 只读取扫描范围；仅在报告输出目录写入 Markdown 和 CSV 报告。
set -o pipefail

VERSION="2.0.0"
LARGE_MB=500
OLD_DAYS=90
OUTPUT_DIR="$PWD"

usage() {
  cat <<USAGE
cleanmac v${VERSION} - macOS 只读存储扫描器

用法: $(basename "$0") [选项]

选项:
  --output-dir DIR  报告输出目录（默认当前目录）
  --large-mb N      大文件阈值，单位 MB（默认 500）
  --old-days N      下载文件的旧文件天数（默认 90）
  --help            显示帮助

扫描范围包括用户缓存、用户日志、Chrome 缓存、Xcode DerivedData、废纸篓、
大文件，以及超过指定天数或超过大文件阈值的下载文件。Docker 数据会跳过。
只在输出目录生成 cleanmac-scan-report.md 和 cleanmac-scan-report.csv。
本工具没有删除或清理功能。
USAGE
}

error() {
  printf '错误：%s\n' "$*" >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --output-dir)
      (($# >= 2)) || error "--output-dir 需要目录参数"
      OUTPUT_DIR=$2
      shift 2
      ;;
    --large-mb)
      (($# >= 2)) || error "--large-mb 需要数字参数"
      [[ $2 =~ ^[0-9]+$ ]] && (( $2 > 0 )) || error "--large-mb 必须为正整数"
      LARGE_MB=$2
      shift 2
      ;;
    --old-days)
      (($# >= 2)) || error "--old-days 需要数字参数"
      [[ $2 =~ ^[0-9]+$ ]] && (( $2 > 0 )) || error "--old-days 必须为正整数"
      OLD_DAYS=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      error "未知选项：$1（使用 --help 查看用法）"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || error "本工具只能在 macOS 上运行"

LARGE_BYTES=$((LARGE_MB * 1000000))
# BSD find uses KiB-sized blocks. Exact byte sizes are checked again with stat.
LARGE_FIND_K=$((LARGE_BYTES / 1024))
OLD_SECONDS=$((OLD_DAYS * 86400))
NOW=$(date +%s)
TAB=$(printf '\t')
ROWS=()
SORTED_ROWS=()

human_size() {
  awk -v bytes="$1" 'BEGIN {
    if (bytes >= 1073741824) printf "%.2f GB", bytes / 1073741824
    else if (bytes >= 1048576) printf "%.1f MB", bytes / 1048576
    else if (bytes >= 1024) printf "%.1f KB", bytes / 1024
    else printf "%d B", bytes
  }'
}

path_bytes() {
  local path=$1 result
  if [[ -f "$path" ]]; then
    stat -f '%z' "$path" 2>/dev/null || return 1
  elif [[ -d "$path" ]]; then
    result=$(du -sk "$path" 2>/dev/null) || return 1
    awk 'NR == 1 { printf "%.0f", $1 * 1024 }' <<< "$result"
  else
    return 1
  fi
}

add_item() {
  local path=$1 bytes=$2 category=$3 risk_rank=$4 risk=$5 explanation=$6 display encoded
  case "$path" in
    "$HOME") display='~' ;;
    "$HOME"/*) display="~${path#"$HOME"}" ;;
    *) display=$path ;;
  esac
  encoded=$(printf '%s' "$display" | base64 | tr -d '\n')
  ROWS[${#ROWS[@]}]="${risk_rank}${TAB}${bytes}${TAB}${encoded}${TAB}${category}${TAB}${risk}${TAB}${explanation}"
}

scan_children() {
  local root=$1 category=$2 risk_rank=$3 risk=$4 explanation=$5 item bytes
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' item; do
    bytes=$(path_bytes "$item") || {
      printf '跳过无法完整读取的路径：%s\n' "$item" >&2
      continue
    }
    add_item "$item" "$bytes" "$category" "$risk_rank" "$risk" "$explanation"
  done < <(find "$root" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0)
}

scan_user_caches() {
  local root="$HOME/Library/Caches" item child bytes google_root="$HOME/Library/Caches/Google"
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' item; do
    if [[ "$item" == "$google_root" && -d "$item" ]]; then
      while IFS= read -r -d '' child; do
        [[ "$child" == "$google_root/Chrome" ]] && continue
        bytes=$(path_bytes "$child") || {
          printf '跳过无法完整读取的路径：%s\n' "$child" >&2
          continue
        }
        add_item "$child" "$bytes" '用户缓存' 0 '低' '缓存通常可由应用重新生成；请先确认应用状态。'
      done < <(find "$google_root" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0)
    else
      bytes=$(path_bytes "$item") || {
        printf '跳过无法完整读取的路径：%s\n' "$item" >&2
        continue
      }
      add_item "$item" "$bytes" '用户缓存' 0 '低' '缓存通常可由应用重新生成；请先确认应用状态。'
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0)
}

scan_chrome_caches() {
  local root="$HOME/Library/Caches/Google/Chrome" item bytes
  if [[ -d "$root" ]]; then
    bytes=$(path_bytes "$root") && add_item "$root" "$bytes" 'Chrome 浏览器缓存' 0 '低' 'Chrome 缓存目录；不包含浏览历史或 Cookie 的清理操作。'
  fi
  root="$HOME/Library/Application Support/Google/Chrome"
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' item; do
    bytes=$(path_bytes "$item") || {
      printf '跳过无法完整读取的路径：%s\n' "$item" >&2
      continue
    }
    add_item "$item" "$bytes" 'Chrome 浏览器缓存' 0 '低' 'Chrome 可重建缓存；请确认浏览器已关闭后再自行处理。'
  done < <(find "$root" -type d \( -name Cache -o -name Cache_Data -o -name 'Code Cache' -o -name GPUCache \) -prune -print0)
}

scan_downloads() {
  local root="$HOME/Downloads" item bytes modified description
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' item; do
    bytes=$(path_bytes "$item") || {
      printf '跳过无法读取的文件：%s\n' "$item" >&2
      continue
    }
    modified=$(stat -f '%m' "$item" 2>/dev/null) || continue
    if (( NOW - modified >= OLD_SECONDS )); then
      description="下载文件超过 ${OLD_DAYS} 天未修改；可能仍有个人用途，请人工核对。"
    elif (( bytes > LARGE_BYTES )); then
      description="下载目录中的大文件；可能仍有个人用途，请人工核对。"
    else
      continue
    fi
    add_item "$item" "$bytes" '下载文件' 2 '高' "$description"
  done < <(find "$root" -type f \( -mtime "+$((OLD_DAYS - 1))" -o -size "+${LARGE_FIND_K}k" \) -print0)
}

scan_large_home_files() {
  local item bytes
  local prune_paths=(
    "$HOME/Downloads"
    "$HOME/.Trash"
    "$HOME/Library/Caches"
    "$HOME/Library/Logs"
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$HOME/Library/Application Support/Google/Chrome"
    "$HOME/.docker"
    "$HOME/Library/Caches/com.docker.docker"
    "$HOME/Library/Containers/com.docker.docker"
    "$HOME/Library/Group Containers/group.com.docker"
    "$HOME/Library/Application Support/Docker Desktop"
    "$HOME/Library/Application Support/com.docker.docker"
  )
  local find_args=( '(' ) path first=1
  for path in "${prune_paths[@]}"; do
    (( first )) || find_args+=( -o )
    find_args+=( -path "$path" )
    first=0
  done
  find_args+=( -o -type d '(' -name '*.epub' -o -name '*.photoslibrary' -o -name '*.photolibrary' -o -name '*.app' -o -name '*.bundle' -o -name '*.framework' ')' )
  find_args+=( ')' -prune -o -type f -size "+${LARGE_FIND_K}k" -print0 )
  while IFS= read -r -d '' item; do
    bytes=$(path_bytes "$item") || {
      printf '跳过无法读取的文件：%s\n' "$item" >&2
      continue
    }
    (( bytes > LARGE_BYTES )) || continue
    add_item "$item" "$bytes" "大文件（>${LARGE_MB}MB）" 2 '高' '个人文件；请先人工核对内容和备份，扫描器不会处理文件。'
  done < <(find "$HOME" "${find_args[@]}")
}

scan_children "$HOME/Library/Logs" '应用日志' 1 '中' '日志可能用于排查问题；请先确认没有诊断需求。'
scan_user_caches
scan_chrome_caches
scan_children "$HOME/Library/Developer/Xcode/DerivedData" 'Xcode DerivedData' 0 '低' 'Xcode 构建产物可重新生成；当前构建或索引期间请勿处理。'
if [[ -d "$HOME/.Trash" ]]; then
  trash_bytes=$(path_bytes "$HOME/.Trash") || trash_bytes=''
  if [[ -n "$trash_bytes" ]]; then
    add_item "$HOME/.Trash" "$trash_bytes" '废纸篓' 2 '高' '废纸篓中的文件可能仍需恢复；请逐项检查。'
  fi
fi
scan_downloads
scan_large_home_files

for row in "${ROWS[@]}"; do
  SORTED_ROWS[${#SORTED_ROWS[@]}]=$row
done
if ((${#SORTED_ROWS[@]})); then
  SORTED_ROWS=()
  while IFS= read -r row; do
    SORTED_ROWS[${#SORTED_ROWS[@]}]=$row
  done < <(printf '%s\n' "${ROWS[@]}" | LC_ALL=C sort -t "$TAB" -k1,1n -k2,2nr)
fi

mkdir -p "$OUTPUT_DIR" || error "无法创建报告目录：$OUTPUT_DIR"
REPORT_MD="$OUTPUT_DIR/cleanmac-scan-report.md"
REPORT_CSV="$OUTPUT_DIR/cleanmac-scan-report.csv"
[[ ! -e "$REPORT_MD" ]] || error "报告已存在，为避免覆盖而停止：$REPORT_MD"
[[ ! -e "$REPORT_CSV" ]] || error "报告已存在，为避免覆盖而停止：$REPORT_CSV"

printf '路径,大小（字节；目录为 du 估算）,类别,风险,说明\n' > "$REPORT_CSV"
printf '# cleanmac 扫描报告\n\n' > "$REPORT_MD"
printf -- '- 扫描时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$REPORT_MD"
printf -- '- 扫描器版本：%s\n' "$VERSION" >> "$REPORT_MD"
printf -- '- 大文件阈值：超过 %s MB\n' "$LARGE_MB" >> "$REPORT_MD"
printf -- '- 旧下载阈值：超过 %s 天未修改\n' "$OLD_DAYS" >> "$REPORT_MD"
printf -- '- 安全边界：只读扫描；不会删除、移动或修改扫描范围内的内容；Docker 数据已排除。\n' >> "$REPORT_MD"
printf -- '- 扫描范围：大文件扫描会跳过资料包目录（如 .epub、照片图库、应用程序），并排除缓存、日志、下载、废纸篓、Chrome 资料目录与 DerivedData，避免重复计数。\n' >> "$REPORT_MD"
printf -- '- 权限说明：macOS 拒绝读取的路径会跳过并在终端显示；报告只汇总实际可读到的项目。\n\n' >> "$REPORT_MD"
printf '## 分类汇总\n\n| 类别 | 项目数 | 扫描大小 |\n|---|---:|---:|\n' >> "$REPORT_MD"

SUMMARY=$(printf '%s\n' "${SORTED_ROWS[@]}" | awk -F '\t' 'NF >= 6 { count[$4]++; bytes[$4] += $2 } END { for (category in count) printf "%s\t%d\t%.0f\n", category, count[category], bytes[category] }' | LC_ALL=C sort -t "$TAB" -k1,1)
if [[ -n "$SUMMARY" ]]; then
  while IFS="$TAB" read -r category count bytes; do
    printf '| %s | %s | %s |\n' "$category" "$count" "$(human_size "$bytes")" >> "$REPORT_MD"
  done <<< "$SUMMARY"
else
  printf '| 未发现匹配项目 | 0 | 0 B |\n' >> "$REPORT_MD"
fi

LOW_BYTES=$(printf '%s\n' "${SORTED_ROWS[@]}" | awk -F '\t' '$1 == 0 { total += $2 } END { printf "%.0f", total }')
printf '\n低风险项目扫描大小合计：**%s**。此数值仅供人工评估；扫描器不会自动释放空间。\n\n' "$(human_size "${LOW_BYTES:-0}")" >> "$REPORT_MD"
printf '## 扫描明细\n\n| 路径 | 大小 | 类别 | 风险 | 说明 |\n|---|---:|---|---|---|\n' >> "$REPORT_MD"

for row in "${SORTED_ROWS[@]}"; do
  IFS="$TAB" read -r rank bytes encoded category risk explanation <<< "$row"
  if [[ -n "$encoded" ]]; then
    display=$(printf '%s' "$encoded" | base64 -D 2>/dev/null) || display='[路径编码失败]'
  else
    display='[未知路径]'
  fi
  md_path=$(printf '%s' "$display" | tr '\n' ' ' | sed 's/|/\\|/g')
  md_explanation=$(printf '%s' "$explanation" | sed 's/|/\\|/g')
  printf '| `%s` | %s | %s | %s | %s |\n' "$md_path" "$(human_size "$bytes")" "$category" "$risk" "$md_explanation" >> "$REPORT_MD"
  csv_path=$(printf '%s' "$display" | sed 's/"/""/g')
  csv_category=$(printf '%s' "$category" | sed 's/"/""/g')
  csv_risk=$(printf '%s' "$risk" | sed 's/"/""/g')
  csv_explanation=$(printf '%s' "$explanation" | sed 's/"/""/g')
  printf '"%s","%s","%s","%s","%s"\n' "$csv_path" "$bytes" "$csv_category" "$csv_risk" "$csv_explanation" >> "$REPORT_CSV"
done

printf '\n扫描完成。\nMarkdown：%s\nCSV：%s\n' "$REPORT_MD" "$REPORT_CSV"
