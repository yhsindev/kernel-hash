<template>
  <footer
    v-if="$slidev.nav.currentPage !== 1"
    class="absolute bottom-4 right-6 text-sm"
    style="color:#6f7d8e"
  >
    {{ $slidev.nav.currentPage }} / {{ $slidev.nav.total }}
  </footer>
</template>

<style>
/* 全域樣式：Slidev 會把 markdown 內的 <style> 限定在單一頁，故改由每頁都載入的 global-bottom 注入 */
:root {
  --slidev-theme-primary: #74d7ff;
}

.slidev-layout {
  background: #070b10;
  color: #e8eef5;
  font-family: "Inter", "Noto Sans TC", "Microsoft JhengHei", sans-serif;
  padding: 26px 50px 20px;
}

.slidev-layout h1 {
  color: #ffffff;
  font-size: 1.8rem;
  font-weight: 760;
  letter-spacing: -0.03em;
  line-height: 1.12;
  margin-bottom: 0.6rem;
}

.slidev-layout h2 {
  color: #f5f7fa;
  font-size: 1.3rem;
  font-weight: 680;
  margin-top: 0.5rem;
  margin-bottom: 0.5rem;
}

.slidev-layout h3 {
  color: #d9e2ec;
  font-size: 1.0rem;
  font-weight: 620;
  margin-top: 0.3rem;
}

.slidev-layout p,
.slidev-layout li {
  color: #d7dee8;
  font-size: 0.9rem;
  line-height: 1.48;
  margin-top: 0.28rem;
  margin-bottom: 0.28rem;
}

.slidev-layout ul { margin-top: 0.35rem; }
.slidev-layout li { margin-bottom: 0.18rem; }

.slidev-layout strong,
.key { color: #ffffff; font-weight: 760; }

.small { color: #aeb8c5; font-size: 0.76rem; line-height: 1.42; }
.muted { color: #8f9aa8; }
.accent { color: #74d7ff; }
.warn { color: #f2a3a8; }

.box {
  border: 1px solid #253142;
  background: #0d131d;
  border-radius: 14px;
  padding: 14px 20px;
  margin-top: 0.5rem;
}

.insight {
  border-left: 3px solid #74d7ff;
  background: #0d1826;
  border-radius: 0 12px 12px 0;
  padding: 12px 18px;
  margin-top: 0.55rem;
}
.insight strong { color: #74d7ff; }

.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }

.slidev-layout table {
  width: 100%;
  font-size: 0.72rem;
  border-collapse: collapse;
  margin-top: 0.55rem;
}
.slidev-layout th { color: #ffffff; background: #121a25; font-weight: 700; }
.slidev-layout td, .slidev-layout th { border: 1px solid #263244; padding: 0.4rem 0.54rem; }
.slidev-layout tr:nth-child(even) td { background: #0c121b; }

.slidev-layout :not(pre) > code { color: #cfe0f0 !important; background: #182231 !important; border-radius: 4px; padding: 0.05rem 0.28rem; }
.slidev-layout pre {
  background: #0b111a !important;
  border: 1px solid #253142;
  border-radius: 14px;
  padding: 12px 16px;
  margin-top: 0.6rem;
}
.slidev-layout pre code { font-size: 0.72rem; line-height: 1.4; }

.cover-title { margin-top: 96px; }
.cover-subtitle { color: #aeb8c5; font-size: 1.02rem; line-height: 1.55; }

.tag {
  display: inline-block;
  border: 1px solid #2c3a4e;
  border-radius: 999px;
  padding: 0.22rem 0.65rem;
  color: #b9c7d8;
  background: #0e1520;
  font-size: 0.72rem;
  margin-right: 0.35rem;
}

.foot {
  position: absolute;
  bottom: 22px;
  left: 54px;
  color: #6f7d8e;
  font-size: 0.62rem;
}

/* 圖片頁：純 HTML flex 兩欄，白底卡片承載 matplotlib 圖，圖高明確設限避免溢出 */
.figrow { display: flex; gap: 1.7rem; align-items: center; margin-top: 0.3rem; }
.figcol { flex: 0 0 55%; background: #ffffff; border-radius: 12px; padding: 8px; border: 1px solid #253142; }
.figimg { display: block; width: 100%; max-height: 300px; object-fit: contain; border-radius: 6px; }
.figcap { color: #8f9aa8; font-size: 0.66rem; margin-top: 0.3rem; line-height: 1.3; }
.figtxt { flex: 1 1 0; min-width: 0; }
.figtxt p { font-size: 0.82rem; line-height: 1.5; color: #d7dee8; margin: 0.3rem 0; }
.figtxt .insight { margin-top: 0.55rem; }
.figtxt .insight, .figtxt .insight strong { font-size: 0.82rem; line-height: 1.5; }

/* OVS 查找路徑流程圖（緊湊，避免垂直溢出） */
.pathflow { display: flex; flex-direction: column; align-items: stretch; gap: 0.04rem; margin-top: 0.15rem; flex: 0 0 41%; }
.pbox {
  border: 1px solid #2c3a4e; background: #0e1520; border-radius: 9px;
  padding: 0.26rem 0.7rem; font-size: 0.75rem; color: #e8eef5; text-align: center;
}
.pbox code { font-size: 0.72rem; }
.pbox.danger { border-color: #e0555f; background: #1e1113; color: #ffd7da; font-weight: 700; }
.parrow { text-align: center; }
.parrow .lbl { font-size: 0.6rem; color: #9fb0c3; line-height: 1.18; display: block; padding: 0.02rem 0; }
.parrow .tri { display: block; color: #3a4a5e; font-size: 0.68rem; line-height: 1; }
.parrow.attack .lbl { color: #f2a3a8; }
.parrow.attack .lbl b { color: #ff7a82; }

/* section divider */
.sec { margin-top: 140px; }
.secnum { color: #74d7ff; font-size: 1.05rem; letter-spacing: 0.32em; }
.sectitle { color: #ffffff; font-size: 2.15rem; font-weight: 760; margin-top: 0.5rem; letter-spacing: -0.02em; }
.secsub { color: #aeb8c5; font-size: 0.95rem; margin-top: 0.7rem; }
</style>
