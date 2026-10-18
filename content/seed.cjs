// 首次安装时给 junyao-ktv 灌一份「可用的初始状态」。
//
// 上游镜像的空白状态是：曲库 0 首、演唱账号 0 个。曲库靠预置文件解决（见
// setup-junyaoktv.sh 把示例 MV 放进 /mv），演唱账号则没有别的办法——
// /tv 页面强制要求一个「用户管理」里创建的账号才能进入，空白安装下点
// 「大屏演唱」只会看到「还没有可用的登录账号，请让管理员先创建」。
// 对小白来说这一步是死路，所以这里直接建一个默认账号。
//
// 另一件事是曲库来源的默认值：默认只保留内置示例曲库 /mv，不把整个懒猫
// 网盘拉进来扫描（原因见下面第 2 段的长注释）。
//
// 关键点：直接用应用自己的 db.js 来建表，而不是自己写 CREATE TABLE。
// db.js 在 require 时就会建表并跑完它全部幂等迁移，所以这里只要在它之后
// 写数据，schema 一定和这个版本的镜像一致（上游加列也不会漏）。
// 脚本是幂等的：任何一步发现数据已存在就跳过，升级/重启都不会覆盖用户数据。
//
// 注意 require 的路径是镜像内的 /app（不是本文件所在位置）——setup_script
// 是以 root 在容器内执行的，/app 就是 WORKDIR 里的应用代码。
//
// 后缀必须是 .cjs 而不是 .mjs：这个文件被 `node <file>` 直接执行，若以 .mjs
// 结尾 node 会按 ES module 解析，require 直接是 undefined，实测报
// `ReferenceError: require is not defined in ES module scope`。
const crypto = require('crypto');

function sha256Hex(text) {
  return crypto.createHash('sha256').update(String(text)).digest('hex');
}

let db;
try {
  db = require('/app/server/db.js');
} catch (e) {
  console.error('[junyaoktv-setup] 无法加载应用数据库模块，跳过初始化: ' + e.message);
  process.exit(0);
}

// 1) 默认演唱账号：电视端 /tv 要用它登录。
try {
  const count = db.prepare('SELECT COUNT(*) AS c FROM tv_users').get().c;
  if (count === 0) {
    db.prepare('INSERT INTO tv_users (username, password_hash) VALUES (?, ?)')
      .run('admin', sha256Hex('admin123'));
    console.log('[junyaoktv-setup] 已创建默认演唱账号 admin');
  } else {
    console.log('[junyaoktv-setup] 已有演唱账号 ' + count + ' 个，保持不变');
  }
} catch (e) {
  console.error('[junyaoktv-setup] 创建演唱账号失败: ' + e.message);
}

// 2) 曲库来源。scanner.js 在 settings 表里没有 library_roots 这个 key 时
//    会自己迁移出一份默认值，那份默认值只看 MV_DIR / MV_DIR_NET 环境变量，
//    我们只设了 MV_DIR=/mv。
//
//    这里显式写成「只有 /mv 一条」，是有意为之，不是漏了 /mv-net：
//    /mv-net 是指向整个懒猫网盘的软链。若默认就当曲库根目录，全新安装的
//    第一次扫描会把用户网盘里所有视频收进曲库——家庭录像、电影、动画片
//    全都进来（实测这台机器上一次扫出 4397 条，绝大多数是电影而非 MV）。
//    对「K 歌」场景这既慢又吵，也超出用户预期。
//
//    正确流程是上游设计的那样：默认只扫内置示例曲库；用户想用自己的 MV
//    时，到后台「曲库管理 → 曲库来源」里手动添加 /mv-net 下的具体文件夹
//    （可以在里面选子目录，不必整个网盘）。
//
//    /mv-net 软链本身仍然保留（见 setup-junyaoktv.sh），因为后台的文件夹
//    浏览器只允许在 BASE_MOUNTS（/mv、/mv-net）范围内挑路径，没有这条软链
//    就根本浏览不到网盘。软链只是「可浏览」，不等于「默认扫描」。
//
//    只有在这个 key 完全不存在时才写，避免覆盖管理员在后台改过的配置。
//    字段与 scanner.js migrateLegacyEnvRoots() 生成的结构一致：
//    dir / label / isNetwork / enabled。
try {
  const key = 'library_roots';
  const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
  if (!row) {
    const roots = [
      { dir: '/mv', label: '示例曲库 (内置 4 首)', isNetwork: false, enabled: true },
    ];
    db.prepare('INSERT INTO settings (key, value) VALUES (?, ?)')
      .run(key, JSON.stringify(roots));
    console.log('[junyaoktv-setup] 已预置曲库来源: /mv（网盘曲库请到后台自行添加）');
  } else {
    console.log('[junyaoktv-setup] 已有曲库来源配置，保持不变');
  }
} catch (e) {
  console.error('[junyaoktv-setup] 预置曲库来源失败: ' + e.message);
}

console.log('[junyaoktv-setup] 完成');