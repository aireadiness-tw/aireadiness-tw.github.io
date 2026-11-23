#!/usr/bin/env bash
# 零九顧問網站：推送前檢查。在 repo 根目錄執行 ./check.sh，全部通過才回傳 0。
# 需要：bash、perl、curl（連結檢查）、node（試算預設值；有 Playwright 時用真瀏覽器）。
# 環境變數：
#   ZERO9_BLOCKLIST  私人禁用字清單路徑（預設 ~/.zero9-blocklist.txt）
#   ZERO9_BASE       正式網址（預設 https://aireadiness-tw.github.io）
#   ZERO9_CHROMIUM   Playwright 要用的瀏覽器執行檔（選填）
set -u
cd "$(dirname "$0")" || exit 2

PAGES="index.html summary/index.html"
BLOCKLIST="${ZERO9_BLOCKLIST:-$HOME/.zero9-blocklist.txt}"
BASE="${ZERO9_BASE:-https://aireadiness-tw.github.io}"
BASE="${BASE%/}"
FAIL=0
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

ok()   { printf '✓ %s\n' "$1"; }
bad()  { printf '✗ %s\n' "$1"; FAIL=1; }
warn() { printf '! %s（略過）\n' "$1"; }

for f in $PAGES; do
  [ -f "$f" ] || { bad "找不到 $f"; exit 1; }
done
command -v perl >/dev/null 2>&1 || { bad "需要 perl"; exit 1; }

# 計算字串出現次數（兩個頁面合計）。$1 是 perl regex。
count() {
  local total=0 n f
  for f in $PAGES; do
    n=$(PAT="$1" perl -CSD -MEncode -0777 -ne '$p=decode_utf8($ENV{PAT}); $n=0; $n++ while /$p/g; print $n' "$f")
    total=$((total + n))
  done
  echo "$total"
}

# ---------- 文字規則 ----------
n=$(count '保證')
[ "$n" -eq 0 ] && ok "沒有「保證」" || bad "出現「保證」$n 次"

# 每個含「8 倍」的句子都要含「目標」（先去掉 HTML 標籤，再以。！？與換行切句）
bad8=$(perl -CSD -Mutf8 -0777 -ne '
  s/<script\b.*?<\/script>//gis; s/<style\b.*?<\/style>//gis;
  s/<[^>]+>//g; s/&nbsp;/ /g;
  for my $s (split /[。！？!?\n]+/) {
    if ($s =~ /(?<![0-9０-９])[8８]\s*倍/) { print "x" unless $s =~ /目標/ }
  }' $PAGES | wc -c | tr -d ' ')
total8=$(count '(?<![0-9０-９])[8８]\s*倍')
if [ "$bad8" -eq 0 ]; then ok "「8 倍」都和「目標」同句（共 $total8 處）"; else bad "有 $bad8 個含「8 倍」的句子沒有「目標」"; fi

n=$(count '工時減少約七成')
[ "$n" -eq 1 ] && ok "「工時減少約七成」剛好 1 次" || bad "「工時減少約七成」出現 $n 次（應為 1）"

# 舊數字（顯示名稱|regex）
D='[–—\-~～至到]'
OLD="21–23|(?<![0-9])21\s*$D\s*23(?![0-9])
19–21|(?<![0-9])19\s*$D\s*21(?![0-9])
27 萬|(?<![0-9])27\s*萬
200 萬|(?<![0-9])200\s*萬
420 萬|(?<![0-9])420\s*萬
半年回本|半年回本
6–7 個月|(?<![0-9])6\s*$D\s*7\s*個月
萬起|萬\s*起
原價|原價"
oldhits=""
while IFS='|' read -r label re; do
  [ -n "$label" ] || continue
  n=$(count "$re")
  [ "$n" -gt 0 ] && oldhits="$oldhits ${label}×$n"
done <<EOF
$OLD
EOF
[ -z "$oldhits" ] && ok "沒有舊數字" || bad "出現舊數字：$oldhits"

# ---------- 試算預設值 ----------
EXPECT_A="2,520,000 元|5.0 位全職人力"
EXPECT_C="894,600 元|529,200 元|1.1 位全職人力"
if ! command -v node >/dev/null 2>&1; then
  warn "沒有 node，無法檢查試算預設值"
else
  JSF=$(mktemp "${TMPDIR:-/tmp}/zero9-check.XXXXXX")
  trap 'rm -f "$JSF"' EXIT
  cat >"$JSF" <<'JS'
const fs = require('fs'), path = require('path');
const want = { A: process.env.EXPECT_A.split('|'), C: process.env.EXPECT_C.split('|') };
function report(mode, got) {
  const bad = [];
  for (const k of ['A', 'C']) want[k].forEach((w, i) => { if (got[k][i] !== w) bad.push(`${k}${i + 1}: ${got[k][i]}≠${w}`); });
  console.log(bad.length ? `FAIL ${mode} ${bad.join('；')}` : `OK ${mode} 全公司 ${got.A.join('／')}；逐項細算 ${got.C.join('／')}`);
}
let pw = null;
for (const p of [process.cwd(), ...(process.env.NODE_PATH || '').split(path.delimiter)].filter(Boolean)) {
  try { pw = require(require.resolve('playwright', { paths: [p] })); break; } catch (e) {}
}
(async () => {
  if (pw) {
    try {
      let b;
      try { b = await pw.chromium.launch(process.env.ZERO9_CHROMIUM ? { executablePath: process.env.ZERO9_CHROMIUM } : {}); }
      catch (e) { b = await pw.chromium.launch({ channel: 'chrome' }); }  // 改用系統的 Chrome
      const pg = await b.newPage();
      await pg.goto('file://' + path.resolve('index.html'));
      const got = await pg.evaluate(() => ({
        A: [...document.querySelectorAll('#roiOutA .v')].map(e => e.textContent.trim()),
        C: [...document.querySelectorAll('#roiOut .v')].map(e => e.textContent.trim()),
      }));
      await b.close();
      report('Playwright', got);
      return;
    } catch (e) { /* 瀏覽器開不起來就改用靜態計算 */ }
  }
  // 靜態計算：從 HTML 讀預設值，用和頁面相同的公式重算
  const h = fs.readFileSync('index.html', 'utf8');
  const v = id => { const m = h.match(new RegExp(`<input[^>]*id="${id}"[^>]*>`)); const n = m && m[0].match(/value="([^"]*)"/); if (!n) throw new Error('找不到 ' + id); return parseFloat(n[1]); };
  const fmt = n => Math.round(n).toLocaleString('en-US');
  const cost = v('roiASalary') * 12 * v('roiALoad'), fte = v('roiAPeople') * Math.min(v('roiARatio'), 100) / 100;
  const m = h.match(/var rows=(\[[\s\S]*?\]);/);
  if (!m) throw new Error('找不到逐項細算的 rows');
  const rows = JSON.parse(m[1]);
  const hourly = v('roiSalary') * 12 * v('roiLoad') / 2080;
  let hours = 0, saved = 0;
  rows.forEach(r => { const x = r[1] * r[2] * 52; hours += x; saved += x * Math.min(r[3], 100) / 100; });
  report('靜態計算', {
    A: [fmt(fte * cost) + ' 元', fte.toFixed(1) + ' 位全職人力'],
    C: [fmt(hours * hourly) + ' 元', fmt(saved * hourly) + ' 元', (saved / 2080).toFixed(1) + ' 位全職人力'],
  });
})().catch(e => console.log('FAIL ' + e.message));
JS
  res=$(EXPECT_A="$EXPECT_A" EXPECT_C="$EXPECT_C" node "$JSF" 2>&1)
  case "$res" in
    OK*)   ok "試算預設值（${res#OK }）" ;;
    *)     bad "試算預設值：${res#FAIL }" ;;
  esac
fi

# ---------- 連結 ----------
if ! command -v curl >/dev/null 2>&1; then
  warn "沒有 curl，無法檢查連結"
elif ! curl -s -o /dev/null -m 10 "$BASE/"; then
  warn "連不上 ${BASE}，無法檢查連結"
else
  urls=$( { printf '%s\n' "$BASE/" "$BASE/summary/" "$BASE/check/"
            BASE="$BASE" perl -ne 'while (/(?:href|src)="(https?:\/\/[^"]+)"/g) { print "$1\n" }
                      while (/"(https:\/\/(?:docs\.google\.com\/forms|forms\.gle)\/[^"]+)"/g) { print "$1\n" }
                      while (/href="(\/[^"#]*)/g) { print "$ENV{BASE}$1\n" }' $PAGES
          } | sed 's/&amp;/\&/g' | sort -u)
  nbad=0; nall=0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    nall=$((nall + 1))
    code=$(curl -s -o /dev/null -L -m 20 -A 'Mozilla/5.0 (zero9 check.sh)' -w '%{http_code}' "$u")
    if [ "$code" != "200" ]; then nbad=$((nbad + 1)); printf '    %s %s\n' "$code" "$u"; fi
  done <<EOF
$urls
EOF
  [ "$nbad" -eq 0 ] && ok "連結都回 200（$nall 個）" || bad "$nbad 個連結沒有回 200"
fi

# ---------- 私人禁用字 ----------
if [ ! -f "$BLOCKLIST" ]; then
  warn "沒有私人禁用字清單 $BLOCKLIST"
else
  hits=$(BL="$BLOCKLIST" perl -CSD -e '
    open my $fh, "<:encoding(UTF-8)", $ENV{BL} or die;
    my (@w, @x);
    while (<$fh>) { s/\r?\n$//; s/^\s+|\s+$//g; next if $_ eq "" || /^#/;
      if (s/^!//) { push @x, lc $_ if $_ ne "" } else { push @w, lc $_ } }
    for my $f (@ARGV) {
      open my $in, "<:encoding(UTF-8)", $f or next;
      while (my $l = <$in>) { $l = lc $l;
        for my $e (@x) { $l =~ s/\Q$e\E/\x{0}/g }
        for my $w (@w) { if (index($l, $w) >= 0) { print "$f:$.\n"; last } } } }' $PAGES AGENTS.md CLAUDE.md 2>/dev/null | sort -u | tr '\n' ' ')
  [ -z "$hits" ] && ok "沒有私人禁用字" || bad "命中私人禁用字，位置：$hits"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "全部通過"; else echo "有項目沒通過，請修正後再推送"; fi
exit "$FAIL"
