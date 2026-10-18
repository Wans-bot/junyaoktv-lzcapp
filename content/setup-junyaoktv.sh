#!/bin/sh
# 骏耀K歌 首次安装准备。
#
# 三件事：
#   1) 把内置的 4 首示例 MV 拷进 /mv（曲库目录），让用户第一次打开就有
#      完整可用的曲库，点歌 / 播放 / 队列 全流程都能走通；
#   2) 把 TV 端写死的外网 CDN 依赖（hls.js / qrcodejs）换成本地文件；
#   3) 调用 seed.cjs 建好默认演唱账号与曲库来源配置。
#
# 全部步骤幂等：MV 只在目标文件不存在时拷，数据库那步自己判断有没有数据。
# 用户后来放进来的曲子不会被覆盖，重启 / 升级都不会动它们。
set -e

MV_DIR=/mv
SRC=/lzcapp/pkg/content/sample-mv

echo "[junyaoktv-setup] 准备曲库目录 $MV_DIR"
mkdir -p "$MV_DIR"

if [ -d "$SRC" ]; then
  copied=0
  for f in "$SRC"/*.mp4; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    if [ ! -f "$MV_DIR/$base" ]; then
      cp "$f" "$MV_DIR/$base"
      copied=$((copied + 1))
    fi
  done
  echo "[junyaoktv-setup] 示例曲目新增 $copied 首（已存在的不动）"
else
  echo "[junyaoktv-setup] 未找到示例曲目目录，跳过"
fi

# 曲库目录要允许应用进程读写（转码缓存可能落在同目录）。
chmod -R 777 "$MV_DIR" 2>/dev/null || true

# 让「我的曲库」指向懒猫网盘。
#
# 上游的 /mv-net 是写死在 scanner.js BASE_MOUNTS 里的第二个曲库根目录
# （`{ key: 'mv-net', dir: '/mv-net' }`），但 binds 不接受
# /lzcapp/media/RemoteFS 作为源（实测报
# `invalid bind source: /lzcapp/media/RemoteFS`）；而平台在声明
# media.read + ext_config.enable_media_access 后会自动把网盘挂到
# /lzcapp/media/RemoteFS。所以这里用一条软链把两者接起来：
# /mv-net -> /lzcapp/media/RemoteFS。scanner 的 listFilesRecursive 用的是
# readdirSync + statSync（statSync 跟随软链），能正常走进去列文件。
if [ -d /lzcapp/media/RemoteFS ]; then
  if [ -L /mv-net ]; then
    rm -f /mv-net
  fi
  if [ ! -e /mv-net ]; then
    ln -s /lzcapp/media/RemoteFS /mv-net
    echo "[junyaoktv-setup] 已把 /mv-net 链到懒猫网盘 /lzcapp/media/RemoteFS"
  else
    echo "[junyaoktv-setup] /mv-net 已存在（真实目录），保持不变"
  fi
else
  echo "[junyaoktv-setup] 未挂载懒猫网盘，跳过 /mv-net 软链"
fi

# 把 TV 端的外网 CDN 依赖换成本地文件。
#
# 上游 /tv/index.html 与 /tv/clean.html 直接从 cdnjs.cloudflare.com 加载
# qrcodejs（扫码点歌的二维码）和 hls.js（HLS 播放，演唱页面靠它放片子）。
# 家里断网 / 评审机器出不了外网时，这两条脚本拉不到 → 二维码不显示、MV 放不出来。
# 这里把两个库（版本与上游引用的一致）随包带上，落到 express.static 的
# /tv 目录下，再把 HTML 里的外链改成本地路径 /tv/vendor/*.js。
# express 的静态映射见 /app/server/index.js:303
#   app.use('/tv', express.static(path.join(__dirname, '../web/tv')));
# 所以 /app/web/tv/vendor/x.js 可通过 /tv/vendor/x.js 访问。
#
# 幂等：文件覆盖写、HTML 里换掉就不再有 cdnjs 字样，重复启动无副作用。
WEB_TV=/app/web/tv
VENDOR_SRC=/lzcapp/pkg/content/vendor
if [ -d "$WEB_TV" ] && [ -d "$VENDOR_SRC" ]; then
  mkdir -p "$WEB_TV/vendor"
  for f in qrcode.min.js hls.min.js; do
    [ -f "$VENDOR_SRC/$f" ] && cp -f "$VENDOR_SRC/$f" "$WEB_TV/vendor/$f"
  done
  for h in index.html clean.html; do
    [ -f "$WEB_TV/$h" ] || continue
    sed -i \
      -e 's#https://cdnjs\.cloudflare\.com/ajax/libs/qrcodejs/1\.0\.0/qrcode\.min\.js#/tv/vendor/qrcode.min.js#g' \
      -e 's#https://cdnjs\.cloudflare\.com/ajax/libs/hls\.js/1\.5\.13/hls\.min\.js#/tv/vendor/hls.min.js#g' \
      "$WEB_TV/$h"
  done
  left=$(grep -c 'cdnjs\.cloudflare\.com' "$WEB_TV"/index.html "$WEB_TV"/clean.html 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
  echo "[junyaoktv-setup] TV 端 CDN 已本地化（残留外链 $left 处）"
else
  echo "[junyaoktv-setup] 未找到 $WEB_TV 或 $VENDOR_SRC，跳过 CDN 本地化"
fi

# 建默认演唱账号 + 曲库来源。node 在镜像里一定有；失败也不阻断应用启动，
# 只是少一个默认账号，用户仍可在后台自己创建。
if [ -f /lzcapp/pkg/content/seed.cjs ]; then
  node /lzcapp/pkg/content/seed.cjs || echo "[junyaoktv-setup] seed.cjs 执行失败，忽略"
fi

echo "[junyaoktv-setup] 完成"
