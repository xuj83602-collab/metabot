#!/usr/bin/env bash
# switch-model.sh — 切换 Claude Code 模型/API Key，并自动重启 MetaBot
#
# 用法:
#   ./scripts/switch-model.sh --model claude-sonnet-4-6
#   ./scripts/switch-model.sh --model deepseek-v3 --base-url https://api.deepseek.com
#   ./scripts/switch-model.sh --status
#   ./scripts/switch-model.sh --list
#
# 安全说明:
#   API Key 优先从环境变量 ANTHROPIC_API_KEY 读取
#   如需交互式输入，使用 --api-key 选项（密钥不会回显）

set -euo pipefail

# 常见模型列表（用于验证和自动补全）
declare -A KNOWN_MODELS=(
  ["claude-opus-4-7"]="Claude Opus 4.7"
  ["claude-sonnet-4-6"]="Claude Sonnet 4.6"
  ["claude-haiku-4-5"]="Claude Haiku 4.5"
  ["deepseek-v3"]="DeepSeek V3"
  ["deepseek-r1"]="DeepSeek R1"
  ["deepseek-r1-0528"]="DeepSeek R1 0528"
  ["gpt-4o"]="GPT-4o"
  ["gpt-4o-mini"]="GPT-4o Mini"
  ["qwen-plus"]="Qwen Plus"
  ["qwen-max"]="Qwen Max"
  ["qwen-turbo"]="Qwen Turbo"
  ["qwen-long"]="Qwen Long"
  ["glm-4"]="GLM-4"
  ["glm-4-flash"]="GLM-4 Flash"
  ["ernie-4.0"]="ERNIE 4.0"
  ["ernie-3.5"]="ERNIE 3.5"
)

usage() {
  cat <<EOF
用法: $0 [选项]

选项:
  --model <名称>      模型名称（必填，除非使用 --status 或 --list）
  --api-key <密钥>    API 密钥（可选，不填则保留现有密钥）
                      安全建议：优先使用环境变量 ANTHROPIC_API_KEY
  --base-url <地址>   API 地址（可选，不填则保留现有地址）
  --no-restart        更新设置后不重启 MetaBot
  --status            显示当前配置，不做任何修改
  --list              列出常见模型名称
  -h, --help          显示此帮助

示例:
  $0 --model claude-sonnet-4-6
  $0 --model deepseek-v3 --base-url https://api.deepseek.com
  $0 --model claude-opus-4-7 --base-url https://api.anthropic.com
  $0 --status
  $0 --list

环境变量:
  ANTHROPIC_API_KEY   API 密钥（优先于 --api-key 参数）
EOF
  exit 1
}

MODEL=""
API_KEY=""
BASE_URL=""
NO_RESTART=false
STATUS_ONLY=false
LIST_MODELS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --model)
      [[ -z "${2:-}" || "$2" == --* ]] && { echo "错误: --model 需要一个参数"; exit 1; }
      MODEL="$2"; shift 2 ;;
    --api-key)
      [[ -z "${2:-}" || "$2" == --* ]] && { echo "错误: --api-key 需要一个参数"; exit 1; }
      API_KEY="$2"; shift 2 ;;
    --base-url)
      [[ -z "${2:-}" || "$2" == --* ]] && { echo "错误: --base-url 需要一个参数"; exit 1; }
      BASE_URL="$2"; shift 2 ;;
    --no-restart) NO_RESTART=true; shift ;;
    --status)     STATUS_ONLY=true; shift ;;
    --list)       LIST_MODELS=true; shift ;;
    -h|--help)    usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

# ---------- 读/写 settings.json 用 Node.js ----------

node_read_status() {
  node -e "
const fs = require('fs');
const path = require('path');
// 兼容 Windows 和 Linux/macOS
const up = process.env.USERPROFILE || process.env.HOME;
if (!up) { console.error('错误: 无法确定用户主目录'); process.exit(1); }
const f = path.join(up, '.claude', 'settings.json');
if (!fs.existsSync(f)) { console.error('错误: 找不到 ' + f); process.exit(1); }
let s;
try { s = JSON.parse(fs.readFileSync(f, 'utf8')); }
catch(e) { console.error('错误: JSON 解析失败 — ' + e.message); process.exit(1); }
const settingsEnv = s.env || {};
// ANTHROPIC_AUTH_TOKEN 是项目约定的环境变量名（Claude Code 使用此名称）
const token = settingsEnv.ANTHROPIC_AUTH_TOKEN || '';
const masked = token.length > 0
  ? (token.length > 12 ? token.slice(0,8)+'...'+token.slice(-4) : token.slice(0,4)+'****')
  : '(未设置)';
console.log('  模型:   ', settingsEnv.ANTHROPIC_MODEL    || '(未设置)');
console.log('  地址:   ', settingsEnv.ANTHROPIC_BASE_URL  || '(未设置)');
console.log('  API Key:', masked);
" || exit 1
}

node_update_settings() {
  local new_model="$1" new_api_key="$2" new_base_url="$3"
  SW_MODEL="$new_model" SW_API_KEY="$new_api_key" SW_BASE_URL="$new_base_url" \
  node -e "
const fs = require('fs');
const path = require('path');
// 兼容 Windows 和 Linux/macOS
const up = process.env.USERPROFILE || process.env.HOME;
if (!up) { console.error('错误: 无法确定用户主目录'); process.exit(1); }
const f = path.join(up, '.claude', 'settings.json');
if (!fs.existsSync(f)) { console.error('错误: 找不到 ' + f); process.exit(1); }

// 备份原配置
const backupDir = path.join(path.dirname(f), 'backup');
const backupFile = path.join(backupDir, 'settings.json.' + Date.now() + '.bak');
if (!fs.existsSync(backupDir)) {
  fs.mkdirSync(backupDir, { recursive: true });
}
fs.copyFileSync(f, backupFile);
console.log('  备份:   ', backupFile);

// 清理旧备份（保留最近 10 个）
try {
  const backups = fs.readdirSync(backupDir)
    .filter(f => f.startsWith('settings.json.') && f.endsWith('.bak'))
    .sort()
    .reverse();
  if (backups.length > 10) {
    backups.slice(10).forEach(f => fs.unlinkSync(path.join(backupDir, f)));
  }
} catch(e) { /* 忽略清理失败 */ }

let s;
try { s = JSON.parse(fs.readFileSync(f, 'utf8')); }
catch(e) { console.error('错误: JSON 解析失败 — ' + e.message); process.exit(1); }

// 在函数顶部声明变量，避免 TDZ 问题
const newModel   = process.env.SW_MODEL;
const newApiKey  = process.env.SW_API_KEY;
const newBaseUrl = process.env.SW_BASE_URL;

const settingsEnv = s.env || (s.env = {});

['ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL',
 'ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL',
 'ANTHROPIC_REASONING_MODEL'].forEach(k => settingsEnv[k] = newModel);

// ANTHROPIC_AUTH_TOKEN 是项目约定的环境变量名（Claude Code 使用此名称）
if (newApiKey)  settingsEnv.ANTHROPIC_AUTH_TOKEN = newApiKey;
if (newBaseUrl) settingsEnv.ANTHROPIC_BASE_URL   = newBaseUrl;

// 原子写入：先写临时文件再重命名，防止中断导致配置损坏
const tmp = f + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(s, null, 2), 'utf8');
fs.renameSync(tmp, f);

const masked = newApiKey && newApiKey.length > 0
  ? (newApiKey.length > 12 ? newApiKey.slice(0,8)+'...'+newApiKey.slice(-4) : newApiKey.slice(0,4)+'****')
  : '(保留原有)';
console.log('  模型:   ', newModel);
console.log('  地址:   ', newBaseUrl || '(保留原有)');
console.log('  API Key:', masked);
" || exit 1
}

# ---------- 主逻辑 ----------

if $LIST_MODELS; then
  echo "常见模型列表:"
  echo "-------------"
  for model in "${!KNOWN_MODELS[@]}"; do
    printf "  %-25s %s\n" "$model" "${KNOWN_MODELS[$model]}"
  done | sort
  echo
  echo "提示: 也可以使用任意模型名称，不限于上述列表"
  exit 0
fi

if $STATUS_ONLY; then
  echo "当前 Claude Code 配置:"
  node_read_status
  exit 0
fi

[[ -z "$MODEL" ]] && { echo "错误: --model 是必填参数"; echo; usage; }

# 验证模型名称格式（基本检查）
if [[ ! "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "警告: 模型名称包含非常规字符: $MODEL"
  echo "常见模型名称格式: claude-sonnet-4-6, deepseek-v3, gpt-4o"
  echo
  read -p "是否继续？(y/N) " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo "正在更新 Claude Code 设置..."
node_update_settings "$MODEL" "$API_KEY" "$BASE_URL"
echo "设置已更新"
echo

if $NO_RESTART; then
  echo "跳过重启（--no-restart）"
  echo "如需生效，请手动执行: pm2 restart metabot --update-env"
  exit 0
fi

if command -v pm2 &>/dev/null && pm2 list 2>/dev/null | grep -q "metabot.*online"; then
  echo "正在重启 MetaBot..."
  pm2 restart metabot --update-env
  echo "MetaBot 已重启，模型切换完成: $MODEL"
else
  echo "MetaBot 未通过 PM2 运行，跳过重启"
  echo "启动命令: pm2 start npm --name metabot -- start"
fi
