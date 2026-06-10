#!/usr/bin/env bash
#
# cleanmac - 安全清理 macOS 存储空间的命令行工具
#
# 默认以预览(dry-run)模式运行,只报告可释放的空间,不删除任何文件。
# 加 --clean 才会真正执行清理,且只清理公认可安全删除的缓存/临时文件。
#
# 用法:
#   ./cleanmac.sh                 预览所有类别可释放的空间
#   ./cleanmac.sh --clean         清理所有默认类别(逐类确认)
#   ./cleanmac.sh --clean --yes   清理所有默认类别(跳过确认)
#   ./cleanmac.sh --clean xcode brew   只清理指定类别
#   ./cleanmac.sh --list          列出所有支持的类别
#
set -euo pipefail

VERSION="1.0.0"

# ---------- 颜色输出 ----------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi

info()  { printf '%s\n' "${CYAN}==>${RESET} ${BOLD}$*${RESET}"; }
warn()  { printf '%s\n' "${YELLOW}警告:${RESET} $*" >&2; }
error() { printf '%s\n' "${RED}错误:${RESET} $*" >&2; }

# ---------- 全局状态 ----------
DRY_RUN=1
ASSUME_YES=0
TOTAL_FREED_KB=0

# 类别名 -> 描述(用普通数组保证遍历顺序,兼容 macOS 自带的 bash 3.2)
CATEGORIES=(
  "caches:用户应用缓存 (~/Library/Caches)"
  "logs:用户日志文件 (~/Library/Logs)"
  "trash:废纸篓 (~/.Trash)"
  "xcode:Xcode 派生数据与旧设备支持文件"
  "simulators:不可用的 iOS 模拟器"
  "brew:Homebrew 旧版本与下载缓存"
  "npm:npm / yarn / pnpm 缓存"
  "pip:pip 缓存"
  "docker:Docker 悬空镜像与构建缓存"
  "saved-state:应用窗口恢复状态 (~/Library/Saved Application State)"
  "quicklook:QuickLook 缩略图缓存"
)

# ---------- 工具函数 ----------
require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "本工具只能在 macOS 上运行。"
    exit 1
  fi
}

# 计算路径占用的 KB(路径不存在时输出 0)
size_kb() {
  local total=0 s
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    s=$(du -sk "$p" 2>/dev/null | awk '{print $1}') || s=0
    total=$((total + ${s:-0}))
  done
  printf '%s' "$total"
}

human_kb() {
  local kb=$1
  if   (( kb >= 1048576 )); then awk -v k="$kb" 'BEGIN{printf "%.2f GB", k/1048576}'
  elif (( kb >= 1024 ));    then awk -v k="$kb" 'BEGIN{printf "%.1f MB", k/1024}'
  else printf '%d KB' "$kb"
  fi
}

confirm() {
  (( ASSUME_YES )) && return 0
  local reply
  printf '%s' "    确认清理?[y/N] "
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# 删除一组路径的"内容"(保留目录本身),带统计
clean_paths() {
  local label=$1; shift
  local kb
  kb=$(size_kb "$@")
  if (( kb == 0 )); then
    printf '    %s%-46s%s 无可清理内容\n' "${BOLD}" "$label" "${RESET}"
    return 0
  fi
  printf '    %s%-46s%s %s%s%s\n' "${BOLD}" "$label" "${RESET}" "${GREEN}" "$(human_kb "$kb")" "${RESET}"
  if (( DRY_RUN )); then
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + kb))
    return 0
  fi
  confirm || { printf '    已跳过\n'; return 0; }
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    if [[ -d "$p" && ! -L "$p" ]]; then
      # 只清空目录内容,目录本身保留,避免破坏应用对目录的引用
      find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    else
      rm -f "$p" 2>/dev/null || true
    fi
  done
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + kb))
  printf '    %s已清理%s\n' "${GREEN}" "${RESET}"
}

# 执行外部命令型清理(brew/docker 等自带安全清理命令的工具)
clean_with_cmd() {
  local label=$1 size_hint=$2; shift 2
  printf '    %s%-46s%s %s\n' "${BOLD}" "$label" "${RESET}" "$size_hint"
  if (( DRY_RUN )); then
    printf '    预览模式,将执行: %s\n' "$*"
    return 0
  fi
  confirm || { printf '    已跳过\n'; return 0; }
  "$@" || warn "命令执行失败: $*"
}

# ---------- 各类别清理 ----------
clean_caches() {
  info "用户应用缓存"
  clean_paths "~/Library/Caches" "$HOME/Library/Caches"
}

clean_logs() {
  info "用户日志"
  clean_paths "~/Library/Logs" "$HOME/Library/Logs"
}

clean_trash() {
  info "废纸篓"
  clean_paths "~/.Trash" "$HOME/.Trash"
}

clean_xcode() {
  info "Xcode"
  local dev="$HOME/Library/Developer"
  [[ -d "$dev" ]] || { printf '    未检测到 Xcode 开发目录,跳过\n'; return 0; }
  clean_paths "DerivedData(构建产物)" "$dev/Xcode/DerivedData"
  clean_paths "Archives(旧归档,删除前请确认无需 dSYM)" "$dev/Xcode/Archives"
  clean_paths "iOS DeviceSupport(旧设备符号文件)" "$dev/Xcode/iOS DeviceSupport"
  clean_paths "CoreSimulator Caches" "$dev/CoreSimulator/Caches"
}

clean_simulators() {
  info "iOS 模拟器"
  if ! command -v xcrun >/dev/null 2>&1; then
    printf '    未安装 Xcode 命令行工具,跳过\n'; return 0
  fi
  clean_with_cmd "删除不可用的模拟器" "(大小由 simctl 决定)" \
    xcrun simctl delete unavailable
}

clean_brew() {
  info "Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    printf '    未安装 Homebrew,跳过\n'; return 0
  fi
  local cache_kb
  cache_kb=$(size_kb "$(brew --cache 2>/dev/null)")
  clean_with_cmd "brew cleanup(旧版本+下载缓存)" "$(human_kb "$cache_kb")+" \
    brew cleanup --prune=all -s
}

clean_npm() {
  info "JavaScript 包管理器缓存"
  clean_paths "npm (~/.npm/_cacache)" "$HOME/.npm/_cacache"
  clean_paths "yarn 缓存" "$HOME/Library/Caches/Yarn" "$HOME/.yarn/cache"
  clean_paths "pnpm store" "$HOME/Library/pnpm/store" "$HOME/.pnpm-store"
}

clean_pip() {
  info "Python pip 缓存"
  clean_paths "pip (~/Library/Caches/pip)" "$HOME/Library/Caches/pip" "$HOME/.cache/pip"
}

clean_docker() {
  info "Docker"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    printf '    Docker 未运行,跳过\n'; return 0
  fi
  local reclaimable
  reclaimable=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1) || reclaimable="未知"
  clean_with_cmd "docker system prune(悬空镜像/停止容器/构建缓存)" "约 ${reclaimable:-未知}" \
    docker system prune -f
}

clean_saved_state() {
  info "应用窗口恢复状态"
  clean_paths "~/Library/Saved Application State" "$HOME/Library/Saved Application State"
}

clean_quicklook() {
  info "QuickLook 缩略图缓存"
  if (( DRY_RUN )); then
    printf '    预览模式,将执行: qlmanage -r cache\n'
  else
    clean_with_cmd "重置 QuickLook 缓存" "(系统管理,大小不定)" qlmanage -r cache
  fi
}

# ---------- 大文件报告(只报告,绝不删除) ----------
report_large_files() {
  info "大文件 Top 15(仅报告,不会删除;路径:~/Downloads ~/Documents ~/Desktop ~/Movies)"
  find "$HOME/Downloads" "$HOME/Documents" "$HOME/Desktop" "$HOME/Movies" \
       -type f -size +500M 2>/dev/null -exec du -h {} + 2>/dev/null \
    | sort -rh | head -15 \
    | sed 's/^/    /' || true
  printf '\n'
}

# ---------- 主流程 ----------
run_category() {
  case "$1" in
    caches)      clean_caches ;;
    logs)        clean_logs ;;
    trash)       clean_trash ;;
    xcode)       clean_xcode ;;
    simulators)  clean_simulators ;;
    brew)        clean_brew ;;
    npm)         clean_npm ;;
    pip)         clean_pip ;;
    docker)      clean_docker ;;
    saved-state) clean_saved_state ;;
    quicklook)   clean_quicklook ;;
    *) error "未知类别: $1(用 --list 查看所有类别)"; exit 1 ;;
  esac
  printf '\n'
}

list_categories() {
  printf '%s\n' "${BOLD}支持的清理类别:${RESET}"
  for entry in "${CATEGORIES[@]}"; do
    printf '  %s%-12s%s %s\n' "${GREEN}" "${entry%%:*}" "${RESET}" "${entry#*:}"
  done
}

usage() {
  cat <<EOF
cleanmac v${VERSION} - 安全清理 macOS 存储空间

用法: $(basename "$0") [选项] [类别...]

选项:
  --clean        真正执行清理(默认只预览,不删除任何文件)
  --yes, -y      跳过逐项确认(配合 --clean 使用)
  --list, -l     列出所有支持的类别
  --help, -h     显示本帮助

示例:
  $(basename "$0")                  预览所有类别可释放的空间
  $(basename "$0") --clean          交互式清理所有类别
  $(basename "$0") --clean -y xcode brew docker
EOF
}

main() {
  local selected=()
  while (( $# )); do
    case "$1" in
      --clean)     DRY_RUN=0 ;;
      --yes|-y)    ASSUME_YES=1 ;;
      --list|-l)   list_categories; exit 0 ;;
      --help|-h)   usage; exit 0 ;;
      -*)          error "未知选项: $1"; usage; exit 1 ;;
      *)           selected+=("$1") ;;
    esac
    shift
  done

  require_macos

  if (( DRY_RUN )); then
    printf '%s\n\n' "${YELLOW}${BOLD}[预览模式]${RESET}${YELLOW} 只统计可释放空间,不会删除任何文件。加 --clean 执行清理。${RESET}"
  else
    printf '%s\n\n' "${RED}${BOLD}[清理模式]${RESET} 将真正删除文件,每个类别会先显示大小再确认。"
  fi

  local avail
  avail=$(df -h / | awk 'NR==2{print $4}')
  info "当前系统盘可用空间: ${avail}"
  printf '\n'

  if (( ${#selected[@]} == 0 )); then
    for entry in "${CATEGORIES[@]}"; do
      run_category "${entry%%:*}"
    done
    report_large_files
  else
    for c in "${selected[@]}"; do
      run_category "$c"
    done
  fi

  if (( DRY_RUN )); then
    info "预计可释放: ${GREEN}$(human_kb "$TOTAL_FREED_KB")${RESET}(不含 brew/docker/模拟器等命令型清理)"
  else
    info "本次共释放: ${GREEN}$(human_kb "$TOTAL_FREED_KB")${RESET}"
    avail=$(df -h / | awk 'NR==2{print $4}')
    info "当前系统盘可用空间: ${avail}"
  fi
}

main "$@"
