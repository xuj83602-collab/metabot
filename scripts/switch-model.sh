#!/usr/bin/env bash
# switch-model.sh — 切换 Claude Code 模型/API Key，并自动重启 MetaBot
#
# 用法:
#   ./scripts/switch-model.sh --model claude-sonnet-4-6
#   ./scripts/switch-model.sh --model deepseek-v3 --base-url https://api.deepseek.com
#   ./scripts/switch-model.sh --status
#
# API Key 优先从环境变量 ANTHROPIC_API_KEY 读取；如需交互式输入使用 --api-key

set -euo pipefail

usage() {
  cat <<EOF
用法: $0 [选项]

选项:
  --model <名称>      模型名称（必填，除非使用 --status）
  --api-key <密钥>    API 密钥（可选，不填则保留现有密钥）
  --base-url <地址>   API 地址（可选，不填则保留现有地址）
  --no-restart        更新设置后不重启 MetaBot
  --status            显示当前配置，不做任何修改
  -h, --help          显示此帮助

示例:
  $0 --model claude-sonnet-4-6
  $0 --model deepseek-v3 --base-url https://api.deepseek.com
  $0 --status

环境变量:
  ANTHROPIC_API_KEY  API 密钥（优先于 --api-key 参数）
EOF
  exit 1
}

# 解析参数
MODEL=""
API_KEY=""
BASE_URL=""
NO_RESTART=false
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --model)    MODEL="${2:?错误: --model 需要一个参数}"; shift 2 ;;
    --api-key)  API_KEY="${2:?错误: --api-key 需要一个参数}"; shift 2 ;;
    --base-url) BASE_URL="${2:?错误: --base-url 需要一个参数}"; shift 2 ;;
    --no-restart) NO_RESTART=true; shift ;;
    --status)   STATUS_ONLY=true; shift ;;
    -h|--help)  usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

# ---------- 读/写 settings.json ----------

NODE_SCRIPT=$(cat <<'NODESCRIPT'
const fs = require('fs');
const path = require('path');
const home = process.env.USERPROFILE || process.env.HOME;
if (!home) { console.error('错误: 无法确定用户主目录'); process.exit(1); }
const f = path.join(home, '.claude', 'settings.json');
if (!fs.existsSync(f)) { console.error('错误: 找不到 ' + f); process.exit(1); }

let s;
try { s = JSON.parse(fs.readFileSync(f, 'utf8')); }
catch(e) { console.error('错误: JSON 解析失败: ' + e.message); process.exit(1); }

const mode = process.env.SW_MODE; // "read" 或 "write"
const settingsEnv = s.env || (s.env = {});

if (mode === 'read') {
  const token = settingsEnv.ANTHROPIC_AUTH_TOKEN || '';
  const masked = token.length > 0
    ? (token.length > 12 ? token.slice(0,8)+'...'+token.slice(-4) : token.slice(0,4)+'****')
    : '(未设置)';
  console.log('  模型:   ', settingsEnv.ANTHROPIC_MODEL || '(未设置)');
  console.log('  地址:   ', settingsEnv.ANTHROPIC_BASE_URL || '(未设置)');
  console.log('  API Key:', masked);
  process.exit(0);
}

// write 模式：备份 + 更新
const backupDir = path.join(path.dirname(f), 'backup');
if (!fs.existsSync(backupDir)) fs.mkdirSync(backupDir, { recursive: true });
fs.copyFileSync(f, path.join(backupDir, 'settings.json.' + Date.now() + '.bak'));
// 清理旧备份（保留最近 10 个）
try {
  const backups = fs.readdirSync(backupDir)
    .filter(f => f.startsWith('settings.json.') && f.endsWith('.bak'))
    .sort().reverse();
  if (backups.length > 10) backups.slice(10).forEach(f => fs.unlinkSync(path.join(backupDir, f)));
} catch(e) { /* 忽略清理失败 */ }

const newModel   = process.env.SW_MODEL;
const newApiKey  = process.env.SW_API_KEY;
const newBaseUrl = process.env.SW_BASE_URL;

['ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL',
 'ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL',
 'ANTHROPIC_REASONING_MODEL'].forEach(k => settingsEnv[k] = newModel);

if (newApiKey)  settingsEnv.ANTHROPIC_AUTH_TOKEN = newApiKey;
if (newBaseUrl) settingsEnv.ANTHROPIC_BASE_URL   = newBaseUrl;

// 原子写入
const tmp = f + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(s, null, 2), 'utf8');
fs.renameSync(tmp, f);

const masked = newApiKey
  ? (newApiKey.length > 12 ? newApiKey.slice(0,8)+'...'+newApiKey.slice(-4) : newApiKey.slice(0,4)+'****')
  : '(保留原有)';
console.log('  模型:   ', newModel);
console.log('  地址:   ', newBaseUrl || '(保留原有)');
console.log('  API Key:', masked);
NODESCRIPT
)

run_node() { SW_MODE="$1" SW_MODEL="$MODEL" SW_API_KEY="$API_KEY" SW_BASE_URL="$BASE_URL" node -e "$NODE_SCRIPT" || exit 1; }

# ---------- 主逻辑 ----------

if $STATUS_ONLY; then
  echo "当前 Claude Code 配置:"
  run_node "read"
  exit 0
fi

[[ -z "$MODEL" ]] && { echo "错误: --model 是必填参数"; echo; usage; }

# 模型名基本校验
if [[ ! "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "警告: 模型名称包含非常规字符: $MODEL"
  echo "常见格式: claude-sonnet-4-6, deepseek-v3, gpt-4o"
  read -p "是否继续？(y/N) " -n 1 -r; echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo "正在更新 Claude Code 设置..."
run_node "write"
echo "设置已更新"
echo

if $NO_RESTART; then
  echo "跳过重启（--no-restart），请手动执行: pm2 restart metabot --update-env"
  exit 0
fi

if command -v pm2 &>/dev/null && pm2 list 2>/dev/null | grep -q "metabot.*online"; then
  echo "正在重启 MetaBot..."
  pm2 restart metabot --update-env
  echo "MetaBot 已重启，模型切换完成: $MODEL"
else
  echo "MetaBot 未通过 PM2 运行，跳过重启"
fi
