/// The Web Controller page served at "/": one self-contained HTML file (no external scripts,
/// fonts or images). Redesigned in 0.62.0: a modern, responsive control surface for phones
/// (bottom tabs), tablets (two columns) and desktop browsers (three columns, keyboard
/// shortcuts), dark / light theme.
///
/// It signs in with the PIN, polls /api/state, sends POST /api/... commands with the PIN in the
/// X-LiveCore-PIN header, and receives:
/// - Pictures as ONE long push response (/api/video?stream=1, newest picture only, decoded off
///   the main thread with createImageBitmap), with /api/frame?bus= polling as the fallback.
/// - Sound as one long push response (/api/listen?stream=1) into a jitter buffer that grows after
///   a gap, shrinks when the link is steady and corrects clock drift by resampling slightly
///   (AudioWorklet on https, scheduled buffers with playback-rate correction on plain http).
public enum RemotePage {
    public static let html = #"""
<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#0b0d12">
<title>LiveCore Remote</title>
<style>
:root{
 --bg:#0b0d12;--bg2:#10131a;--card:#151922;--card2:#1b202b;--line:#262c39;--line2:#323a4b;
 --ink:#eef1f6;--dim:#8e97a8;--faint:#5c6577;
 --red:#ff4757;--redD:#a3121f;--green:#2ed47a;--greenD:#0e8a47;--amber:#ffb432;--blue:#4c8dff;--violet:#9b7bff;
 --key:#212734;--keyH:#2a3141;--shadow:0 10px 30px rgba(0,0,0,.35);--r:16px;--rs:11px;
 --nav:64px;
}
:root[data-theme="light"]{
 --bg:#eef1f6;--bg2:#e6eaf1;--card:#ffffff;--card2:#f6f8fb;--line:#dde2ea;--line2:#c9d0dc;
 --ink:#141821;--dim:#5d6676;--faint:#97a0b0;--key:#eef1f6;--keyH:#e3e8f0;--shadow:0 8px 24px rgba(20,30,50,.10);
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}
html,body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",sans-serif;overscroll-behavior:none}
body{min-height:100vh;padding:0}
button,select,input{font:inherit;color:inherit}
button{border:0;background:none;padding:0;cursor:pointer;touch-action:manipulation}
.hidden{display:none!important}
svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}

/* Header */
header{position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:10px;padding:calc(8px + env(safe-area-inset-top)) 14px 8px;
 background:var(--bg);background:color-mix(in srgb,var(--bg) 82%,transparent);-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:9px;min-width:0;flex:1}
.mark{width:28px;height:28px;border-radius:9px;flex:none;background:linear-gradient(135deg,var(--red),#7d1fd1);display:grid;place-items:center;box-shadow:0 4px 14px rgba(255,71,87,.35)}
.mark::after{content:"";width:9px;height:9px;border-radius:50%;background:#fff}
.brand h1{margin:0;font-size:15px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.brand small{display:block;font-size:11px;color:var(--dim);font-weight:500}
.pill{display:inline-flex;align-items:center;gap:6px;height:28px;padding:0 10px;border-radius:99px;background:var(--card);border:1px solid var(--line);
 font:700 11px/1 ui-monospace,"SF Mono",Menlo,monospace;letter-spacing:.04em;color:var(--dim);white-space:nowrap}
.pill i{width:8px;height:8px;border-radius:50%;background:var(--faint)}
.pill.ok i{background:var(--green);box-shadow:0 0 8px var(--green)}
.pill.weak i{background:var(--amber);box-shadow:0 0 8px var(--amber)}
.pill.bad i{background:var(--red);box-shadow:0 0 8px var(--red)}
.pill.on{color:#fff;background:linear-gradient(135deg,var(--red),var(--redD));border-color:transparent}
.pill.on i{background:#fff;animation:blink 1.2s steps(1) infinite}
.iconbtn{width:36px;height:36px;border-radius:11px;display:grid;place-items:center;background:var(--card);border:1px solid var(--line);color:var(--dim)}
.iconbtn:active{transform:scale(.96)}
@keyframes blink{50%{opacity:.3}}

/* Grid of cards */
main{display:grid;gap:12px;padding:12px;max-width:1800px;margin:0 auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:14px;box-shadow:var(--shadow);min-width:0}
.card h2{display:flex;align-items:center;gap:8px;margin:0 0 12px;font-size:12px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--dim)}
.card h2 .sp{flex:1}
.card h2 .tag{font:600 11px/1 -apple-system,sans-serif;letter-spacing:0;text-transform:none;color:var(--faint)}

/* Monitors */
.mons{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.mons.pgmonly{grid-template-columns:1fr}
.mons.pgmonly .mon.pvw{display:none}
.mon{position:relative;aspect-ratio:16/9;border-radius:12px;overflow:hidden;background:#05070a;border:2px solid var(--line2)}
.mon canvas,.mon img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain}
.mon.pgm{border-color:var(--red);box-shadow:0 0 0 3px rgba(255,71,87,.15)}
.mon.pvw{border-color:var(--green);box-shadow:0 0 0 3px rgba(46,212,122,.12)}
.mon .ns{position:absolute;inset:0;display:grid;place-items:center;color:#3a4252;font:700 11px/1 ui-monospace,monospace;letter-spacing:.25em}
.mon .cap{position:absolute;left:8px;right:8px;bottom:8px;display:flex;align-items:center;gap:6px;pointer-events:none}
.mon .cap b{font:800 10px/1 -apple-system,sans-serif;letter-spacing:.1em;padding:4px 6px;border-radius:6px;color:#fff}
.mon.pgm .cap b{background:var(--red)}.mon.pvw .cap b{background:var(--greenD)}
.mon .cap span{font-size:12px;font-weight:600;color:#fff;text-shadow:0 1px 3px #000;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mon .fps{position:absolute;right:8px;top:8px;font:700 10px/1 ui-monospace,monospace;color:#cfd6e2;background:rgba(0,0,0,.45);padding:3px 5px;border-radius:5px}
.mon .exp{position:absolute;left:8px;top:8px;width:30px;height:30px;border-radius:8px;display:grid;place-items:center;background:rgba(0,0,0,.45);color:#fff;opacity:.8}
.mon:fullscreen{border:0;border-radius:0}

/* Keys */
.key{position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:3px;min-height:54px;padding:6px 6px;border-radius:var(--rs);
 background:var(--key);border:1px solid var(--line);color:var(--ink);transition:transform .07s,background .15s,box-shadow .15s,border-color .15s}
.key.down,.key:active{transform:scale(.965)}
.key:disabled{opacity:.35;cursor:default}
.key .n{font:800 17px/1 -apple-system,sans-serif;font-variant-numeric:tabular-nums}
.key .t{font-size:11px;font-weight:600;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--dim)}
.key .k{position:absolute;left:6px;top:5px;font-size:10px;opacity:.6}
.key.on{color:#fff;border-color:transparent}
.key.on .t{color:rgba(255,255,255,.85)}
.key.on.red{background:linear-gradient(160deg,#ff6b78,var(--red) 55%,var(--redD));box-shadow:0 6px 18px rgba(255,71,87,.35)}
.key.on.green{background:linear-gradient(160deg,#5fe8a0,var(--green) 55%,var(--greenD));box-shadow:0 6px 18px rgba(46,212,122,.3)}
.key.on.amber{background:linear-gradient(160deg,#ffd27a,var(--amber) 60%,#c77d00);color:#2a1800;box-shadow:0 6px 18px rgba(255,180,50,.3)}
.key.on.amber .t{color:#4a3000}
.key.on.blue{background:linear-gradient(160deg,#82b0ff,var(--blue) 60%,#2559c9);box-shadow:0 6px 18px rgba(76,141,255,.3)}
.key.on.violet{background:linear-gradient(160deg,#c2adff,var(--violet) 60%,#5b39c9);box-shadow:0 6px 18px rgba(155,123,255,.3)}
.key.ringR{border-color:var(--red)}.key.ringG{border-color:var(--green)}
.key.big{min-height:68px;font:900 18px/1 -apple-system,sans-serif;letter-spacing:.12em}
.key.wide{flex-direction:row;gap:8px;font-weight:700}

/* Buses */
.bus{display:grid;grid-template-columns:30px 1fr;gap:8px}
.bus+.bus{margin-top:10px}
.bus .lab{writing-mode:vertical-rl;transform:rotate(180deg);display:flex;align-items:center;justify-content:center;border-radius:9px;
 font:800 10px/1 -apple-system,sans-serif;letter-spacing:.2em;background:var(--bg2);border:1px solid var(--line)}
.bus .lab.g{color:var(--green)}.bus .lab.r{color:var(--red)}
.keys{display:grid;grid-template-columns:repeat(auto-fill,minmax(76px,1fr));gap:8px}
.search{display:flex;gap:8px;margin:-2px 0 10px}
.search input{flex:1;min-width:0;height:34px;border-radius:10px;border:1px solid var(--line);background:var(--bg2);padding:0 10px;-webkit-user-select:text;user-select:text}
.empty{color:var(--dim);font-size:13px;padding:8px 0}

/* Transition */
.chips{display:flex;gap:7px;overflow-x:auto;padding:2px 2px 8px;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
.chip{flex:none;height:34px;padding:0 13px;border-radius:99px;background:var(--key);border:1px solid var(--line);font-size:12px;font-weight:700;color:var(--dim)}
.chip.on{background:var(--blue);border-color:transparent;color:#fff}
.chip.amber.on{background:var(--amber);color:#2a1800}
.go{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:4px}
#auto.run{animation:pulse .5s ease-in-out infinite alternate}
@keyframes pulse{to{filter:brightness(1.3)}}
.tbar{display:flex;align-items:center;gap:12px;margin-top:12px}
.tbar .pct{width:48px;text-align:right;font:800 16px/1 ui-monospace,"SF Mono",Menlo,monospace;font-variant-numeric:tabular-nums}
.slot{position:relative;flex:1;height:58px;border-radius:14px;background:var(--bg2);border:1px solid var(--line);touch-action:none;cursor:grab}
.slot::before{content:"";position:absolute;left:24px;right:24px;top:50%;height:6px;margin-top:-3px;border-radius:3px;background:var(--line)}
.slot .fill{position:absolute;top:50%;height:6px;margin-top:-3px;border-radius:3px;background:linear-gradient(90deg,var(--blue),var(--violet))}
.lever{position:absolute;top:6px;bottom:6px;width:44px;margin-left:-22px;border-radius:10px;background:linear-gradient(180deg,#f7f9fc,#c9d1dc);
 box-shadow:0 6px 14px rgba(0,0,0,.35),inset 0 0 0 1px rgba(0,0,0,.15)}
.lever::after{content:"";position:absolute;left:50%;top:12px;bottom:12px;width:3px;margin-left:-1.5px;border-radius:2px;background:var(--blue)}

/* Small groups */
.grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.grid2{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}
.sub{margin:14px 0 8px;font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--faint)}
.note{color:var(--dim);font-size:12px;margin-top:8px;min-height:1em}
.out .key time{font:700 12px/1 ui-monospace,"SF Mono",Menlo,monospace;font-variant-numeric:tabular-nums;opacity:.9}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-top:12px}
.stat{background:var(--bg2);border:1px solid var(--line);border-radius:10px;padding:8px 6px;text-align:center}
.stat b{display:block;font:800 15px/1.1 ui-monospace,"SF Mono",Menlo,monospace;font-variant-numeric:tabular-nums}
.stat span{font-size:10px;color:var(--dim);font-weight:600;letter-spacing:.05em;text-transform:uppercase}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.row+.row{margin-top:8px}
.ptzsel,.sel{height:36px;border-radius:10px;border:1px solid var(--line);background:var(--bg2);padding:0 8px;min-width:0}

/* Audio */
.listen{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:10px;border-radius:12px;background:var(--bg2);border:1px solid var(--line);margin-bottom:12px}
.listen .key{min-height:38px;padding:0 14px;flex-direction:row;gap:7px;font-weight:700}
.listen input[type=range]{flex:1;min-width:90px;accent-color:var(--blue)}
.buf{flex-basis:100%;display:flex;align-items:center;gap:8px;font-size:11px;color:var(--dim)}
.buf .bar{flex:1;height:5px;border-radius:3px;background:var(--line);overflow:hidden}
.buf .bar i{display:block;height:100%;width:0;background:var(--green);transition:width .3s}
.strips{display:flex;gap:10px;overflow-x:auto;padding:2px 2px 6px;scrollbar-width:thin}
.strip{flex:none;width:72px;display:flex;flex-direction:column;align-items:center;gap:8px;padding:10px 6px;border-radius:12px;background:var(--bg2);border:1px solid var(--line)}
.strip.master{border-color:var(--line2)}
.strip .nm{font-size:11px;font-weight:700;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.strip .db{font:700 10px/1 ui-monospace,monospace;color:var(--dim);font-variant-numeric:tabular-nums}
.fz{display:flex;gap:6px;height:190px}
.meter{position:relative;width:6px;border-radius:3px;overflow:hidden;background:linear-gradient(0deg,#1fc66a 0,#1fc66a 66%,#f0c419 83%,#ff4757 100%)}
.meter i{position:absolute;left:0;right:0;top:0;height:100%;background:var(--bg2);transform-origin:top;will-change:transform;opacity:.92}
.fader{position:relative;width:36px;touch-action:none;cursor:grab}
.fader::before{content:"";position:absolute;left:50%;top:12px;bottom:12px;width:4px;margin-left:-2px;border-radius:2px;background:var(--line)}
.fader .cap{position:absolute;left:1px;right:1px;top:0;height:24px;border-radius:7px;will-change:transform;background:linear-gradient(180deg,#f7f9fc,#c3cbd7);
 box-shadow:0 4px 10px rgba(0,0,0,.35)}
.fader .cap::after{content:"";position:absolute;left:6px;right:6px;top:50%;height:2px;margin-top:-1px;background:var(--ink);opacity:.7}
.strip .key{min-height:30px;width:100%;font:800 10px/1 -apple-system,sans-serif;letter-spacing:.06em}

/* Bottom navigation (phones) */
nav{position:fixed;left:0;right:0;bottom:0;z-index:30;display:none;grid-template-columns:repeat(4,1fr);height:calc(var(--nav) + env(safe-area-inset-bottom));
 padding-bottom:env(safe-area-inset-bottom);background:var(--card);background:color-mix(in srgb,var(--card) 88%,transparent);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);border-top:1px solid var(--line)}
nav button{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;font-size:11px;font-weight:600;color:var(--faint)}
nav button.on{color:var(--blue)}
nav svg{width:22px;height:22px}
/* Phones held upright: one section group at a time, chosen in the bottom bar */
@media (max-width:759px) and (min-height:521px){
 body{padding-bottom:calc(var(--nav) + env(safe-area-inset-bottom))}
 nav{display:grid}
 .toast{bottom:calc(var(--nav) + 16px + env(safe-area-inset-bottom))}
 body[data-tab="switch"] [data-tab]:not([data-tab~="switch"]),
 body[data-tab="tools"] [data-tab]:not([data-tab~="tools"]),
 body[data-tab="audio"] [data-tab]:not([data-tab~="audio"]),
 body[data-tab="more"] [data-tab]:not([data-tab~="more"]){display:none}
}

/* Sheet */
.sheet{position:fixed;inset:0;z-index:50;display:flex;align-items:flex-end;justify-content:center;background:rgba(0,0,0,.45)}
.sheet .box{width:100%;max-width:520px;max-height:88vh;overflow:auto;background:var(--card);border-radius:22px 22px 0 0;padding:18px 18px calc(18px + env(safe-area-inset-bottom));border:1px solid var(--line)}
.sheet h3{margin:0 0 14px;font-size:17px}
.opt{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:10px 0;border-bottom:1px solid var(--line)}
.opt:last-of-type{border-bottom:0}
.opt label{font-weight:600}.opt small{display:block;color:var(--dim);font-size:12px;font-weight:400}
.seg{display:inline-flex;background:var(--bg2);border:1px solid var(--line);border-radius:10px;padding:3px;gap:2px}
.seg button{padding:6px 10px;border-radius:8px;font-size:12px;font-weight:700;color:var(--dim)}
.seg button.on{background:var(--blue);color:#fff}
.sw{position:relative;width:46px;height:28px;border-radius:99px;background:var(--line2);transition:background .2s;flex:none}
.sw::after{content:"";position:absolute;left:3px;top:3px;width:22px;height:22px;border-radius:50%;background:#fff;transition:transform .2s}
.sw.on{background:var(--green)}.sw.on::after{transform:translateX(18px)}
.kbd{font:600 12px/1.8 ui-monospace,monospace;color:var(--dim)}
.kbd b{display:inline-block;min-width:22px;padding:0 6px;margin-right:6px;border-radius:6px;background:var(--bg2);border:1px solid var(--line);text-align:center;color:var(--ink)}

/* Sign in */
#login{max-width:360px;margin:0 auto;padding:calc(8vh + env(safe-area-inset-top)) 18px 24px;text-align:center}
#login .mark{width:64px;height:64px;border-radius:20px;margin:0 auto 14px}
#login .mark::after{width:18px;height:18px}
#login h1{font-size:22px;margin:0 0 6px}
#login p{color:var(--dim);margin:0 0 20px}
.dots{display:flex;justify-content:center;gap:12px;margin:0 0 22px}
.dots i{width:13px;height:13px;border-radius:50%;border:2px solid var(--line2)}
.dots i.f{background:var(--ink);border-color:var(--ink)}
.pad{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
.pad .key{min-height:62px;font:600 24px/1 -apple-system,sans-serif}
#err{color:var(--amber);min-height:20px;margin-top:16px;font-size:13px}
.toast{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);z-index:60;background:var(--ink);color:var(--bg);
 padding:9px 14px;border-radius:12px;font-size:13px;font-weight:600;box-shadow:var(--shadow);max-width:90vw}

/* Layouts */
.a-mon,.a-bus,.a-trans,.a-ov,.a-out,.a-audio,.a-tools{min-width:0}
@media (min-width:760px){
 main{grid-template-columns:minmax(0,1.25fr) minmax(0,1fr);grid-template-areas:"mon mon" "bus trans" "ov out" "tools tools" "audio audio"}
 .a-mon{grid-area:mon}.a-bus{grid-area:bus}.a-trans{grid-area:trans}.a-ov{grid-area:ov}.a-out{grid-area:out}.a-audio{grid-area:audio}.a-tools{grid-area:tools}
}
@media (min-width:1200px){
 main{grid-template-columns:minmax(0,1.3fr) minmax(320px,.8fr) minmax(320px,.8fr);
  grid-template-areas:"mon mon trans" "bus bus ov" "audio audio out" "audio audio tools"}
 .fz{height:230px}
}
@media (max-width:420px){
 main{padding:10px;gap:10px}
 .card{padding:12px;border-radius:14px}
 .keys{grid-template-columns:repeat(auto-fill,minmax(64px,1fr));gap:7px}
 .key{min-height:50px}
 .bus{grid-template-columns:24px 1fr}
 .grid4{grid-template-columns:repeat(2,1fr)}
 .strip{width:64px}.fz{height:170px}
 .pill.lv:not(.on){display:none}
}
@media (orientation:landscape) and (max-height:520px){
 main{grid-template-columns:minmax(0,1.1fr) minmax(0,1fr);grid-template-areas:"mon trans" "bus bus" "ov out" "tools tools" "audio audio"}
 .a-mon{grid-area:mon}.a-bus{grid-area:bus}.a-trans{grid-area:trans}.a-ov{grid-area:ov}.a-out{grid-area:out}.a-audio{grid-area:audio}.a-tools{grid-area:tools}
 .fz{height:150px}
}
@media (hover:hover){.key:hover:not(:disabled):not(.on){background:var(--keyH)}.chip:hover:not(.on){color:var(--ink)}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
#prompt{position:fixed;inset:0;background:#000;z-index:50;overflow:hidden}
#prompt .pt{position:absolute;left:6%;right:6%;top:33%;color:#fff;font-weight:600;line-height:1.25;white-space:pre-wrap;transition:transform .3s linear}
#prompt .pl{position:absolute;left:0;right:0;top:33%;height:2px;background:rgba(255,220,0,.4)}
#prompt .pc{position:absolute;left:0;right:0;bottom:10px;display:flex;gap:6px;justify-content:center;flex-wrap:wrap}
#prompt .pc button{min-width:52px}
</style>
</head>
<body data-tab="switch">
<svg style="display:none"><symbol id="i-sw" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/></symbol>
<symbol id="i-tools" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h10"/></symbol>
<symbol id="i-audio" viewBox="0 0 24 24"><path d="M6 4v16M12 8v12M18 4v16M4 14h4M10 10h4M16 16h4"/></symbol>
<symbol id="i-more" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/></symbol>
<symbol id="i-gear" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></symbol>
<symbol id="i-exp" viewBox="0 0 24 24"><path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/></symbol>
<symbol id="i-head" viewBox="0 0 24 24"><path d="M3 18v-6a9 9 0 0 1 18 0v6"/><path d="M21 19a2 2 0 0 1-2 2h-1v-6h3zM3 19a2 2 0 0 0 2 2h1v-6H3z"/></symbol>
</svg>

<div id="login">
  <div class="mark"></div>
  <h1>LiveCore Remote</h1>
  <p data-t="pinHint"></p>
  <div class="dots" id="dots"></div>
  <div class="pad" id="pad"></div>
  <div id="err"></div>
</div>

<div id="app" class="hidden">
  <header>
    <div class="brand"><div class="mark"></div><div style="min-width:0"><h1 id="title">LiveCore Studio</h1><small id="netTxt">—</small></div></div>
    <span id="conn" class="pill"><i></i><span id="connTxt">…</span></span>
    <span id="recT" class="pill lv"><i></i>REC <time>00:00:00</time></span>
    <span id="liveT" class="pill lv"><i></i>LIVE <time>00:00:00</time></span>
    <button class="iconbtn" id="gear" aria-label="settings"><svg><use href="#i-gear"/></svg></button>
  </header>
  <main>
    <section class="card a-mon" data-tab="switch">
      <div class="mons" id="mons">
        <div class="mon pvw" id="monPvw"><div class="ns">PREVIEW</div><canvas id="cvPvw"></canvas><img id="imgPvw" alt="" class="hidden">
          <button class="exp" data-exp="monPvw" aria-label="full screen"><svg><use href="#i-exp"/></svg></button><span class="fps" id="fpsPvw"></span>
          <div class="cap"><b>PVW</b><span id="pvwName">—</span></div></div>
        <div class="mon pgm" id="monPgm"><div class="ns">PROGRAM</div><canvas id="cvPgm"></canvas><img id="imgPgm" alt="" class="hidden">
          <button class="exp" data-exp="monPgm" aria-label="full screen"><svg><use href="#i-exp"/></svg></button><span class="fps" id="fpsPgm"></span>
          <div class="cap"><b>PGM</b><span id="pgmName">—</span></div></div>
      </div>
    </section>
    <section class="card a-bus" data-tab="switch">
      <h2><span data-t="inputs"></span><span class="sp"></span><span class="tag" id="inCount"></span></h2>
      <div class="search hidden" id="searchBox"><input id="search" type="search" autocomplete="off" data-ph="search"></div>
      <div class="bus"><div class="lab g">PREVIEW</div><div id="pvwBus" class="keys"></div></div>
      <div class="bus"><div class="lab r">PROGRAM</div><div id="pgmBus" class="keys"></div></div>
    </section>
    <section class="card a-trans" data-tab="switch">
      <h2><span data-t="transition"></span><span class="sp"></span><span class="tag" id="transName"></span></h2>
      <div id="kinds" class="chips"></div>
      <div id="durs" class="chips"></div>
      <div class="go"><button id="cut" class="key big ringR">CUT</button><button id="auto" class="key big ringG">AUTO</button></div>
      <div class="tbar"><div id="slot" class="slot"><div class="fill" id="fill"></div><div class="lever" id="lever"></div></div><span id="tbPct" class="pct">0%</span></div>
    </section>
    <section class="card a-ov" data-tab="tools">
      <h2><span>Overlay</span><span class="sp"></span><span class="tag" data-t="ovHint"></span></h2>
      <div id="overlays" class="grid4"></div>
      <div class="sub" data-t="replay"></div>
      <div id="replays" class="grid4"></div>
      <div class="sub hidden" id="qrHead" data-t="qr"></div>
      <div id="qrs"></div>
      <div class="sub hidden" id="macHead">Macro</div>
      <div id="macros" class="grid4"></div>
      <div class="sub">Teleprompter</div>
      <div class="grid4" id="prKeys"></div>
      <div id="scBox" class="hidden"><div class="sub" id="scHead">Score</div><div class="grid4" id="scKeys"></div></div>
    </section>
    <section class="card a-tools" data-tab="tools">
      <h2 data-t="tools"></h2>
      <div id="noTools" class="empty" data-t="noTools"></div>
      <div id="ptzBox" class="hidden">
        <div class="row"><span class="sub" style="margin:0">PTZ</span><select id="ptzSel" class="ptzsel"></select></div>
        <div class="grid4" id="ptzKeys" style="margin-top:8px"></div>
      </div>
      <div id="dataBox" class="hidden">
        <div class="sub" data-t="dataRows"></div>
        <div id="dataRows"></div>
      </div>
    </section>
    <section class="card a-out out" data-tab="switch more">
      <h2 data-t="output"></h2>
      <div class="grid3">
        <button id="rec" class="key red"><span class="n">REC</span><time>00:00:00</time></button>
        <button id="live" class="key red"><span class="n">LIVE</span><time>00:00:00</time></button>
        <button id="snap" class="key"><span class="n">PHOTO</span><span class="t">&nbsp;</span></button>
      </div>
      <div class="grid3" style="margin-top:8px">
        <button id="mark" class="key amber"><span class="n">★</span><span class="t">MARK <span id="markN">0</span></span></button>
        <button id="fs" class="key violet"><span class="n">⛶</span><span class="t">FULLSCREEN</span></button>
        <button id="lsn2" class="key blue"><span class="n">🎧</span><span class="t" data-t="listenShort"></span></button>
      </div>
      <div class="stats">
        <div class="stat"><b id="sCpu">–</b><span>CPU</span></div>
        <div class="stat"><b id="sFps">–</b><span>FPS</span></div>
        <div class="stat"><b id="sDrop">–</b><span>Drop</span></div>
        <div class="stat"><b id="sLat">–</b><span>Ping</span></div>
      </div>
      <div class="note" id="locks"></div>
    </section>
    <section class="card a-audio" data-tab="audio">
      <h2 data-t="audio"></h2>
      <div class="listen">
        <button id="lsn" class="key"><svg><use href="#i-head"/></svg><span id="lsnTxt"></span></button>
        <select id="lbus" class="sel"><option value="master">Master</option><option value="busA">Bus A</option><option value="busB">Bus B</option><option value="busC">Bus C</option><option value="busD">Bus D</option></select>
        <input id="lvol" type="range" min="0" max="1" step="0.01" value="0.8" aria-label="volume">
        <div class="buf"><span id="lst" data-t="notListening"></span><span class="bar"><i id="bufBar"></i></span><span id="bufMs"></span></div>
      </div>
      <div id="strips" class="strips"></div>
    </section>
  </main>
  <nav>
    <button data-go="switch" class="on"><svg><use href="#i-sw"/></svg><span data-t="tSwitch"></span></button>
    <button data-go="tools"><svg><use href="#i-tools"/></svg><span data-t="tTools"></span></button>
    <button data-go="audio"><svg><use href="#i-audio"/></svg><span data-t="tAudio"></span></button>
    <button data-go="more"><svg><use href="#i-more"/></svg><span data-t="tMore"></span></button>
  </nav>
</div>

<div id="sheet" class="sheet hidden"><div class="box">
  <h3 data-t="settings"></h3>
  <div class="opt"><div><label data-t="theme"></label></div><div class="seg" id="optTheme"><button data-v="auto">Auto</button><button data-v="dark" data-t="dark"></button><button data-v="light" data-t="light"></button></div></div>
  <div class="opt"><div><label data-t="quality"></label><small data-t="qualityHint"></small></div><div class="seg" id="optQ"><button data-v="auto">Auto</button><button data-v="low">Low</button><button data-v="normal">SD</button><button data-v="high">HD</button></div></div>
  <div class="opt"><div><label data-t="fpsOpt"></label></div><div class="seg" id="optFps"><button data-v="15">15</button><button data-v="10">10</button><button data-v="5">5</button></div></div>
  <div class="opt"><div><label data-t="pgmOnly"></label><small data-t="pgmOnlyHint"></small></div><button class="sw" id="optPgm"></button></div>
  <div class="opt"><div><label data-t="audioFirst"></label><small data-t="audioFirstHint"></small></div><button class="sw" id="optAF"></button></div>
  <div class="opt"><div><label data-t="haptics"></label></div><button class="sw" id="optHap"></button></div>
  <div class="opt"><div><label data-t="awake"></label><small data-t="awakeHint"></small></div><button class="sw" id="optWake"></button></div>
  <div class="opt"><div><label data-t="confirmLive"></label></div><button class="sw" id="optConf"></button></div>
  <div class="sub" data-t="keys"></div>
  <div class="kbd"><b>1–9</b>Preview · <b>⇧1–9</b>Program · <b>Space</b>CUT · <b>Enter</b>AUTO · <b>Q W E R</b>Overlay 1–4 · <b>M</b>★ · <b>L</b>Listen · <b>P</b>Photo</div>
  <div class="row" style="margin-top:16px;justify-content:space-between"><button class="key wide" id="out" style="min-height:42px;padding:0 16px" data-t="signOut"></button><button class="key wide on blue" id="closeSheet" style="min-height:42px;padding:0 22px">OK</button></div>
</div></div>
<div id="toast" class="toast hidden"></div>

<script>
"use strict";
const T={
 en:{pinHint:"Enter the PIN shown in LiveCore Studio › Settings › Remote.",inputs:"Inputs",transition:"Transition",replay:"Instant replay",output:"Record & stream",audio:"Audio",signOut:"Sign out",wrong:"Wrong PIN.",locked:"Too many wrong PINs. Try again in {s} s.",offline:"Cannot reach LiveCore Studio.",stopRec:"Stop recording?",stopLive:"Stop streaming?",startLive:"Start streaming?",recLocked:"Recording is locked in the app.",liveLocked:"Streaming is locked in the app.",noInputs:"No inputs yet.",noAudio:"No audio channels.",listen:"Listen",listenStop:"Stop",listenShort:"LISTEN",listening:"Listening",notListening:"Not listening",weak:"weak link",mute:"MUTE",ovHint:"Tap = Preview · hold = Program",qr:"QR code",tools:"Camera & titles",noTools:"No PTZ cameras or data titles in this project.",dataRows:"Title data",search:"Search inputs",tSwitch:"Switch",tTools:"Tools",tAudio:"Audio",tMore:"Output",settings:"Remote settings",theme:"Theme",dark:"Dark",light:"Light",quality:"Picture quality",qualityHint:"Auto lowers it on a weak link",fpsOpt:"Pictures per second",pgmOnly:"Program only",pgmOnlyHint:"Hide Preview: half the data",audioFirst:"Sound first",audioFirstHint:"While listening, pictures slow down so sound never breaks",haptics:"Vibration",awake:"Keep screen on",awakeHint:"Needs https (Tailscale / Cloudflare link)",confirmLive:"Ask before going live",keys:"Keyboard",reconnect:"Reconnecting…",gap:"Gap in sound: buffer raised"},
 id:{pinHint:"Masukkan PIN yang tampil di LiveCore Studio › Settings › Remote.",inputs:"Input",transition:"Transisi",replay:"Instant replay",output:"Rekam & stream",audio:"Audio",signOut:"Keluar",wrong:"PIN salah.",locked:"Terlalu banyak PIN salah. Coba lagi dalam {s} detik.",offline:"LiveCore Studio tidak terjangkau.",stopRec:"Hentikan rekaman?",stopLive:"Hentikan streaming?",startLive:"Mulai streaming?",recLocked:"Rekaman dikunci di aplikasi.",liveLocked:"Streaming dikunci di aplikasi.",noInputs:"Belum ada input.",noAudio:"Belum ada kanal audio.",listen:"Dengar",listenStop:"Berhenti",listenShort:"DENGAR",listening:"Mendengarkan",notListening:"Tidak mendengarkan",weak:"koneksi lemah",mute:"MUTE",ovHint:"Ketuk = Preview · tahan = Program",qr:"Kode QR",tools:"Kamera & title",noTools:"Belum ada kamera PTZ atau title dengan data di proyek ini.",dataRows:"Data title",search:"Cari input",tSwitch:"Switch",tTools:"Alat",tAudio:"Audio",tMore:"Output",settings:"Pengaturan remote",theme:"Tema",dark:"Gelap",light:"Terang",quality:"Kualitas gambar",qualityHint:"Auto menurunkannya saat koneksi lemah",fpsOpt:"Gambar per detik",pgmOnly:"Program saja",pgmOnlyHint:"Sembunyikan Preview: data jadi separuh",audioFirst:"Utamakan suara",audioFirstHint:"Saat mendengarkan, gambar diperlambat agar suara tidak putus",haptics:"Getar",awake:"Layar tetap menyala",awakeHint:"Perlu https (link Tailscale / Cloudflare)",confirmLive:"Tanya sebelum live",keys:"Keyboard",reconnect:"Menyambung ulang…",gap:"Suara sempat putus: buffer dinaikkan"}
};
const lang=(navigator.language||"en").slice(0,2), L=T[lang]||T.en;
document.documentElement.lang=T[lang]?lang:"en";
document.querySelectorAll("[data-t]").forEach(e=>{e.textContent=L[e.dataset.t]});
document.querySelectorAll("[data-ph]").forEach(e=>{e.placeholder=L[e.dataset.ph]});
const $=id=>document.getElementById(id);
const el=(tag,cls,txt)=>{const e=document.createElement(tag);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e};
const ls={get(k,d){try{const v=localStorage.getItem(k);return v==null?d:v}catch(e){return d}},set(k,v){try{v==null||v===""?localStorage.removeItem(k):localStorage.setItem(k,v)}catch(e){}}};
/* Viewer preferences (this browser only) */
const pref={theme:ls.get("lcTheme","auto"),q:ls.get("lcQ","auto"),fps:+ls.get("lcFps","15"),pgm:ls.get("lcPgm","0")==="1",af:ls.get("lcAF","1")==="1",
  hap:ls.get("lcHap","1")==="1",wake:ls.get("lcWake","0")==="1",conf:ls.get("lcConf","1")==="1",tab:ls.get("lcTab","switch")};
const buzz=(ms)=>{if(!pref.hap)return;try{navigator.vibrate&&navigator.vibrate(ms||8)}catch(e){}};
let pin=ls.get("lcPin",""), st=null, failures=0, typed="";
const m=location.hash.match(/pin=(\d{4,8})/);
if(m){pin=m[1];ls.set("lcPin",pin);history.replaceState(null,"",location.pathname)}

function applyTheme(){const t=pref.theme==="auto"?(matchMedia("(prefers-color-scheme: light)").matches?"light":"dark"):pref.theme;
  document.documentElement.dataset.theme=t;document.querySelector('meta[name="theme-color"]').content=t==="light"?"#eef1f6":"#0b0d12"}
applyTheme();matchMedia("(prefers-color-scheme: light)").addEventListener("change",applyTheme);
let toastT=null;function toast(s){const t=$("toast");t.textContent=s;t.classList.remove("hidden");clearTimeout(toastT);toastT=setTimeout(()=>t.classList.add("hidden"),2200)}

/* Press feel on every key */
document.addEventListener("pointerdown",e=>{const k=e.target.closest(".key,.chip");if(k&&!k.disabled){k.classList.add("down");buzz()}},{passive:true});
const up=()=>document.querySelectorAll(".down").forEach(k=>k.classList.remove("down"));
document.addEventListener("pointerup",up);document.addEventListener("pointercancel",up);

/* Connection quality: round-trip times and failures decide "weak" mode (Auto quality = Low).
   It turns on quickly and off only after 15 s of good replies. */
const net={rtt:150,fails:[],weak:false,since:0,bytes:0,t0:performance.now(),kbps:0,
  ok(ms){this.rtt=this.rtt*0.8+Math.min(ms,5000)*0.2;this.eval()},
  fail(){this.fails.push(Date.now());this.eval()},
  eval(){const now=Date.now();this.fails=this.fails.filter(t=>now-t<10000);
    const bad=this.rtt>450||this.fails.length>=2,good=this.rtt<220&&!this.fails.length;
    if(bad)this.since=now;
    if(!this.weak&&bad){this.weak=true;netChanged()}
    else if(this.weak&&good&&now-this.since>15000){this.weak=false;netChanged()}}};
function netChanged(){
  connPill();
  if(aud.gen&&aud.abort&&aud.low!==net.weak){aud.restart=true;aud.abort.abort()}
  video.retune();
}
function connPill(){const c=$("conn");if(!c)return;const off=failures>3;
  c.className="pill "+(off?"bad":net.weak?"weak":"ok");$("connTxt").textContent=off?L.reconnect:Math.round(net.rtt)+" ms";$("sLat").textContent=Math.round(net.rtt)}
setInterval(()=>{const now=performance.now(),dt=(now-net.t0)/1000;if(dt>=1){net.kbps=net.bytes*8/1000/dt;net.bytes=0;net.t0=now;
  $("netTxt").textContent=(net.kbps>=1000?(net.kbps/1000).toFixed(1)+" Mbit/s":Math.round(net.kbps)+" kbit/s")+(net.weak?" · "+L.weak:"")}},1000);

// Every request has a time limit (no hanging forever on a dead link); opt.timeout 0 = none.
async function api(path,method,opt){
  opt=opt||{};const ac=new AbortController(),lim=opt.timeout!=null?opt.timeout:(net.weak?8000:5000);
  const to=lim?setTimeout(()=>ac.abort(),lim):null;
  if(opt.signal)opt.signal.addEventListener("abort",()=>ac.abort());
  const h={"X-LiveCore-PIN":pin};if(opt.rid)h["X-LCS-Req"]=opt.rid;
  const t0=performance.now();let r;
  try{r=await fetch(path,{method:method||"GET",headers:h,cache:"no-store",signal:ac.signal})}
  catch(e){if(to)clearTimeout(to);if(!opt.signal||!opt.signal.aborted)net.fail();throw e}
  if(to)clearTimeout(to);
  if(!opt.noRtt)net.ok(performance.now()-t0);
  if(r.status===401){signedOut(L.wrong);throw new Error("auth")}
  if(r.status===429){signedOut(L.locked.replace("{s}",r.headers.get("Retry-After")||"60"));throw new Error("locked")}
  if(!r.ok)throw new Error("http "+r.status);
  return r;
}
// Tap = first action, hold 0.5 s = second (overlay: tap to Preview, hold to Program).
function holdTap(b,tap,hold){let t=null,held=false;
  b.addEventListener("pointerdown",()=>{held=false;t=setTimeout(()=>{held=true;t=null;buzz(30);hold()},500)});
  const end=()=>{if(t){clearTimeout(t);t=null;if(!held)tap()}};
  b.addEventListener("pointerup",end);b.addEventListener("pointerleave",()=>{if(t){clearTimeout(t);t=null}});
  b.addEventListener("contextmenu",e=>e.preventDefault())}
// Commands carry an id and are re-sent up to 3 times when the reply is lost; the app runs each id once.
let ridN=0;
function send(path){
  const rid=Date.now().toString(36)+"-"+(++ridN)+"-"+Math.random().toString(36).slice(2,6);
  const go=n=>api(path,"POST",{rid}).then(()=>setTimeout(poll,60)).catch(e=>{
    if(e.message==="auth"||e.message==="locked"||/^http 4/.test(e.message))return;
    if(n<3)setTimeout(()=>go(n+1),500*(n+1))});
  go(0);
}
let pollGen=null;
function startPoll(){const g=pollGen={};(async function loop(){if(pollGen!==g)return;const t0=performance.now();await poll();
  setTimeout(loop,Math.max(0,(net.weak?1000:250)-(performance.now()-t0)))})()}

/* Sign in with an on-screen keypad */
function pad(){
  const p=$("pad");p.textContent="";
  ["1","2","3","4","5","6","7","8","9","⌫","0","OK"].forEach(k=>{const b=el("button","key",k);
    if(k==="OK")b.classList.add("on","blue");
    b.onclick=()=>{if(k==="⌫")typed=typed.slice(0,-1);else if(k==="OK")signIn(typed);else if(typed.length<8)typed+=k;dots()};p.appendChild(b)});
  dots();
}
function dots(){const d=$("dots");d.textContent="";for(let i=0;i<Math.max(6,typed.length);i++)d.appendChild(el("i",i<typed.length?"f":""))}
function signedOut(msg){stopListen();pollGen=null;video.stop();$("app").classList.add("hidden");$("sheet").classList.add("hidden");$("login").classList.remove("hidden");$("err").textContent=msg||"";typed="";dots()}
async function signIn(p){
  if(p)pin=p; if(!pin)return; $("err").textContent="";
  try{await api("/api/ping");ls.set("lcPin",pin);typed="";$("login").classList.add("hidden");$("app").classList.remove("hidden");startPoll();video.start();wake()}
  catch(e){if(e.message!=="auth"&&e.message!=="locked")$("err").textContent=L.offline;typed="";dots()}
}
async function poll(){
  try{const r=await api("/api/state");const txt=await r.text();net.bytes+=txt.length;st=JSON.parse(txt);failures=0;render()}
  catch(e){if(++failures>3)connPill()}
}

/* ---------- Pictures ----------
   Push stream (/api/video?stream=1): records of [len u32][bus u8][seq u32][jpeg]. The newest
   picture per monitor is decoded with createImageBitmap (off the main thread) and drawn on a
   canvas; a picture that arrives while the last one is still decoding replaces it, so nothing
   piles up. Falls back to polling /api/frame?bus= when streaming does not work. */
class ByteQueue{constructor(){this.c=[];this.n=0}
  push(u){this.c.push(u);this.n+=u.length}
  peek4(){if(this.n<4)return -1;const b=this.read(4,true);return b[0]|b[1]<<8|b[2]<<16|(b[3]<<24>>>0)}
  read(k,peek){const out=new Uint8Array(k);let o=0,i=0,off=0;
    while(o<k){const c=this.c[i];const take=Math.min(c.length-off,k-o);out.set(c.subarray(off,off+take),o);o+=take;off+=take;if(off===c.length){i++;off=0}}
    if(!peek){this.c=this.c.slice(i);if(off&&this.c.length)this.c[0]=this.c[0].subarray(off);this.n-=k}
    return out}}
const video={gen:null,abort:null,mode:"stream",fails:0,q:"",fpsSpec:"",got:{0:0,1:0},cnt:{0:0,1:0},busy:{0:false,1:false},next:{0:null,1:null},seq:{},urls:{},
  quality(){if(pref.q!=="auto")return pref.q;return net.weak?"low":"normal"},
  rates(){let p=pref.fps,v=pref.fps;if(net.weak){p=Math.min(p,6);v=1}
    if(pref.af&&aud.gen){p=Math.min(p,10);v=Math.min(v,3)}
    if(document.hidden){p=1;v=1}return p+","+v},
  buses(){return pref.pgm?"program":"program,preview"},
  start(){this.stop();const g=this.gen={};this.q=this.quality();this.fpsSpec=this.rates();
    if(this.mode==="stream"&&window.ReadableStream)this.stream(g);else{this.poll("program",g);if(!pref.pgm)this.poll("preview",g)}},
  stop(){this.gen=null;if(this.abort){try{this.abort.abort()}catch(e){}this.abort=null}},
  retune(){if(!this.gen)return;if(this.q!==this.quality()||this.fpsSpec!==this.rates()||this.busSpec!==this.buses())this.start()},
  async stream(g){
    const ac=new AbortController();this.abort=ac;this.busSpec=this.buses();let any=false,last=Date.now();
    const wd=setInterval(()=>{if(Date.now()-last>4000)ac.abort()},1000);
    try{
      const r=await api("/api/video?stream=1&bus="+this.busSpec+"&q="+this.q+"&fps="+this.fpsSpec,"GET",{timeout:0,signal:ac.signal,noRtt:true});
      if(!r.body||!r.body.getReader)throw new Error("no stream");
      const rd=r.body.getReader(),bq=new ByteQueue();
      while(this.gen===g){
        const x=await rd.read();if(x.done)break;last=Date.now();net.bytes+=x.value.length;bq.push(x.value);
        for(;;){const len=bq.peek4();if(len<0||bq.n<4+len)break;bq.read(4);const rec=bq.read(len);
          if(rec[0]===255||len<6)continue;any=true;this.fails=0;
          this.show(rec[0],new Blob([rec.subarray(5)],{type:"image/jpeg"}))}
      }
      try{rd.cancel()}catch(e){}
    }catch(e){}
    clearInterval(wd);if(this.abort===ac)this.abort=null;
    if(this.gen!==g)return;
    if(!any&&++this.fails>=2){this.mode="poll";this.start();return}
    setTimeout(()=>{if(this.gen===g)this.stream(g)},any?200:1000);
  },
  show(bus,blob){
    if(this.busy[bus]){this.next[bus]=blob;return}
    this.busy[bus]=true;
    const done=()=>{this.busy[bus]=false;this.cnt[bus]++;const n=this.next[bus];this.next[bus]=null;if(n)this.show(bus,n)};
    const cv=$(bus===0?"cvPgm":"cvPvw");
    if(window.createImageBitmap){
      createImageBitmap(blob).then(bm=>{if(cv.width!==bm.width||cv.height!==bm.height){cv.width=bm.width;cv.height=bm.height}
        cv.getContext("2d").drawImage(bm,0,0);bm.close&&bm.close();done()}).catch(done);
    }else{
      const img=$(bus===0?"imgPgm":"imgPvw"),u=URL.createObjectURL(blob);img.classList.remove("hidden");cv.classList.add("hidden");
      img.onload=img.onerror=()=>{if(this.urls[bus])URL.revokeObjectURL(this.urls[bus]);this.urls[bus]=u;done()};img.src=u;
    }
  },
  // Fallback: one request per picture, the next only after the last one is shown.
  async poll(bus,g){
    if(this.gen!==g)return;
    const t0=performance.now(),b=bus==="program"?0:1;
    if(st&&st.frames&&!document.hidden){
      const lo=this.q==="low"?"&q=low":"",k=bus+lo;
      try{const r=await api("/api/frame?bus="+bus+lo+(this.seq[k]!=null?"&since="+this.seq[k]:""),"GET",{noRtt:true});
        const q=r.headers.get("X-Frame-Seq");net.ok(performance.now()-t0);
        if(r.status===200){if(q!=null)this.seq[k]=q;const bl=await r.blob();net.bytes+=bl.size;this.show(b,bl)}}catch(e){}
    }
    const every=net.weak?(bus==="program"?200:1000):66;
    setTimeout(()=>this.poll(bus,g),Math.max(document.hidden||!st||!st.frames?300:0,every-(performance.now()-t0)));
  }};
setInterval(()=>{["Pgm","Pvw"].forEach((k,i)=>{const n=video.cnt[i];video.cnt[i]=0;$("fps"+k).textContent=n?n+" fps":""})},1000);
document.addEventListener("visibilitychange",()=>{video.retune();if(!document.hidden)wake()});
document.querySelectorAll("[data-exp]").forEach(b=>b.onclick=e=>{e.stopPropagation();const m=$(b.dataset.exp);
  if(document.fullscreenElement)document.exitFullscreen();else if(m.requestFullscreen)m.requestFullscreen().catch(()=>{});else if(m.webkitRequestFullscreen)m.webkitRequestFullscreen()});

/* ---------- Rendering ---------- */
const name=n=>{const i=st.inputs.find(x=>x.n===n);return i?n+"  "+i.name:"—"};
const hms=s=>{s=Math.max(0,Math.floor(s));const h=Math.floor(s/3600),m=Math.floor(s/60)%60,x=s%60;return[h,m,x].map(v=>String(v).padStart(2,"0")).join(":")};
const sig=a=>JSON.stringify(a);
const kindIcon=k=>({camera:"🎥",videoFile:"🎞",image:"🖼",color:"🎨",text:"T",browser:"🌐",timer:"⏱",screen:"🖥",replay:"⏪",colorBars:"▦",scene:"◫",ticker:"≡",slideshow:"🖼",ndi:"📡",presentation:"📊",frame:"▢",subtitles:"💬",liveCall:"📞",srt:"📡",decklink:"🎥",qrCode:"▣",virtualSet:"🎬"})[k]||"•";
let macSig="",qrSig="",busSig="",ovSig="",rpSig="",kindSig="",stripSig="",ptzSig="",dataSig="",filter="";

function buildBus(box,isPgm){
  box.textContent="";
  const list=st.inputs.filter(i=>!filter||(i.n+" "+i.name).toLowerCase().includes(filter));
  if(!list.length){box.appendChild(el("div","empty",L.noInputs));return}
  list.forEach(i=>{const b=el("button","key "+(isPgm?"red":"green"));b.dataset.n=i.n;
    b.append(el("span","k",kindIcon(i.kind)),el("span","n",i.n),el("span","t",i.name));b.title=i.name;
    b.onclick=()=>{if(isPgm){st.preview=st.program;st.program=i.n;send("/api/program?input="+i.n)}else{st.preview=i.n;send("/api/preview?input="+i.n)}render()};
    box.appendChild(b)});
}
function render(){
  connPill();
  $("title").textContent=st.title;
  $("pgmName").textContent=st.program?name(st.program):"—";
  $("pvwName").textContent=st.preview?name(st.preview):"—";
  $("inCount").textContent=st.inputs.length||"";
  $("searchBox").classList.toggle("hidden",st.inputs.length<13);
  const s=sig(st.inputs.map(i=>[i.n,i.name,i.kind]))+filter;
  if(s!==busSig){busSig=s;buildBus($("pvwBus"),false);buildBus($("pgmBus"),true)}
  $("pvwBus").querySelectorAll(".key").forEach(b=>{const n=+b.dataset.n;b.classList.toggle("on",n===st.preview);b.classList.toggle("ringR",n===st.program&&n!==st.preview)});
  $("pgmBus").querySelectorAll(".key").forEach(b=>{const n=+b.dataset.n;b.classList.toggle("on",n===st.program);b.classList.toggle("ringG",n===st.preview&&n!==st.program)});

  const ks=sig(st.transitions);
  if(ks!==kindSig){kindSig=ks;const k=$("kinds");k.textContent="";st.transitions.forEach(t=>{const b=el("button","chip",t.name);b.dataset.id=t.id;
    b.onclick=()=>{st.transitionKind=t.id;render();send("/api/transition?kind="+t.id)};k.appendChild(b)})}
  $("kinds").querySelectorAll(".chip").forEach(b=>b.classList.toggle("on",+b.dataset.id===st.transitionKind));
  if(!$("durs").children.length){[0.5,1,1.5,2,3].forEach(v=>{const b=el("button","chip amber",v+" s");b.dataset.v=v;
    b.onclick=()=>{st.transitionDuration=v;render();send("/api/transition?duration="+v)};$("durs").appendChild(b)})}
  $("durs").querySelectorAll(".chip").forEach(b=>b.classList.toggle("on",Math.abs(+b.dataset.v-st.transitionDuration)<0.01));
  $("transName").textContent=st.transition||"";
  $("auto").className="key big green "+(st.transitioning?"on run":"ringG");
  if(!tb.drag)setLever(st.tbar);

  const os=sig(st.overlays.map(o=>[o.n,o.input]))+busSig;
  if(os!==ovSig){ovSig=os;const o=$("overlays");o.textContent="";st.overlays.forEach(ov=>{const b=el("button","key");b.dataset.n=ov.n;
    b.append(el("span","n",ov.n),el("span","t",ov.input?name(ov.input).replace(/^\d+\s+/,""):"—"));holdTap(b,()=>send("/api/overlay?n="+ov.n),()=>send("/api/overlay?to=program&n="+ov.n));o.appendChild(b)})}
  st.overlays.forEach((ov,k)=>{const b=$("overlays").children[k];if(!b)return;b.classList.toggle("on",ov.on||ov.preview);
    b.classList.toggle("red",ov.on);b.classList.toggle("amber",ov.preview&&!ov.on);b.disabled=!ov.input});
  const rs=sig(st.replayLengths);
  if(rs!==rpSig){rpSig=rs;const r=$("replays");r.textContent="";st.replayLengths.forEach(s=>{const b=el("button","key amber");b.dataset.s=s;
    b.append(el("span","n",s),el("span","t","sec"));b.onclick=()=>send("/api/replay?sec="+s);r.appendChild(b)});
    const mk=el("button","key amber");mk.append(el("span","n","★"),el("span","t","MARK"));mk.onclick=()=>$("mark").click();r.appendChild(mk)}
  [...$("replays").children].forEach(b=>{if(b.dataset.s)b.disabled=st.replayAvailable<+b.dataset.s});
  const qrs=st.qrs||[];const qs=sig(qrs.map(q=>[q.n,q.items.length]));
  if(qs!==qrSig){qrSig=qs;const q=$("qrs");q.textContent="";qrs.forEach(x=>{const row=el("div","grid3");row.style.marginBottom="8px";
    const b=el("button","key");b.append(el("span","n","QR "+x.n),el("span","t",x.name));b.onclick=()=>send("/api/qr/show?input="+x.n);
    const pv=el("button","key blue","◀");pv.onclick=()=>send("/api/qr/previous?input="+x.n);
    const nx=el("button","key blue","▶");nx.onclick=()=>send("/api/qr/next?input="+x.n);
    row.append(b,pv,nx);q.appendChild(row)})}
  qrs.forEach((x,k)=>{const row=$("qrs").children[k];if(!row)return;const b=row.children[0];b.classList.toggle("on",x.on);b.classList.toggle("red",x.on);
    b.querySelector(".t").textContent=(x.items[x.item-1]||x.name)+(x.items.length>1?" ("+x.item+"/"+x.items.length+")":"");
    row.children[1].disabled=row.children[2].disabled=x.items.length<2});
  $("qrHead").classList.toggle("hidden",!qrs.length);
  const ms=st.macros||[];const mg=sig(ms.map(m=>[m.n,m.name]));
  if(mg!==macSig){macSig=mg;const m=$("macros");m.textContent="";ms.forEach(x=>{const b=el("button","key blue");
    b.append(el("span","n","M"+x.n),el("span","t",x.name));b.onclick=()=>send("/api/macro?n="+x.n);m.appendChild(b)})}
  ms.forEach((x,k)=>{const b=$("macros").children[k];if(b)b.classList.toggle("on",!!x.running)});
  $("macHead").classList.toggle("hidden",!ms.length);
  renderTools();
  $("markN").textContent=st.highlights||0;

  $("rec").className="key red"+(st.recording?" on":"");$("live").className="key red"+(st.streaming?" on":"");
  $("rec").querySelector("time").textContent=hms(st.recordTime);$("live").querySelector("time").textContent=hms(st.streamTime);
  $("recT").classList.toggle("on",st.recording);$("liveT").classList.toggle("on",st.streaming);
  $("recT").querySelector("time").textContent=hms(st.recordTime);$("liveT").querySelector("time").textContent=hms(st.streamTime);
  $("fs").classList.toggle("on",!!st.fullscreen);
  $("sCpu").textContent=st.cpu!=null?Math.round(st.cpu)+"%":"–";$("sFps").textContent=st.fps!=null?Math.round(st.fps):"–";$("sDrop").textContent=st.dropped!=null?st.dropped:"–";
  $("sCpu").style.color=st.cpu>70?"var(--amber)":"";
  $("locks").textContent=[st.recordLocked?L.recLocked:"",st.streamLocked?L.liveLocked:""].filter(Boolean).join(" ");
  renderAudio();
}
function renderTools(){
  const ptz=st.inputs.filter(i=>i.ptz),data=st.inputs.filter(i=>i.data);
  $("noTools").classList.toggle("hidden",ptz.length+data.length>0);
  $("ptzBox").classList.toggle("hidden",!ptz.length);$("dataBox").classList.toggle("hidden",!data.length);
  const ps=sig(ptz.map(i=>[i.n,i.name]));
  if(ps!==ptzSig){ptzSig=ps;const s=$("ptzSel"),cur=s.value;s.textContent="";ptz.forEach(i=>{const o=el("option",null,i.n+"  "+i.name);o.value=i.n;s.appendChild(o)});
    if(cur&&ptz.some(i=>String(i.n)===cur))s.value=cur;
    const k=$("ptzKeys");if(!k.children.length){for(let p=1;p<=8;p++){const b=el("button","key blue");b.append(el("span","n",p),el("span","t","preset"));
      b.onclick=()=>send("/api/ptz/preset?input="+$("ptzSel").value+"&preset="+p);k.appendChild(b)}
      const h=el("button","key");h.append(el("span","n","⌂"),el("span","t","home"));h.onclick=()=>send("/api/ptz/home?input="+$("ptzSel").value);k.appendChild(h)}}
  const ds=sig(data.map(i=>[i.n,i.name]));
  if(ds!==dataSig){dataSig=ds;const box=$("dataRows");box.textContent="";data.forEach(i=>{const row=el("div","grid3");row.style.marginBottom="8px";
    const t=el("button","key");t.append(el("span","n",i.n),el("span","t",i.name));t.onclick=()=>send("/api/preview?input="+i.n);
    const pv=el("button","key blue","◀");pv.onclick=()=>send("/api/data/previous?input="+i.n);
    const nx=el("button","key blue","▶");nx.onclick=()=>send("/api/data/next?input="+i.n);
    row.append(t,pv,nx);box.appendChild(row)})}
}

/* T-bar: drag anywhere on the slot */
const tb={drag:false,last:0,timer:null,val:0};
const P0=24;
function setLever(v){
  tb.val=v;const lv=$("lever"),f=$("fill"),slot=$("slot");
  const rest=st?st.tbarRest:0,lo=Math.min(v,rest),hi=Math.max(v,rest),w=slot.clientWidth-2*P0;
  lv.style.left=(P0+v*w)+"px";f.style.left=(P0+lo*w)+"px";f.style.width=((hi-lo)*w)+"px";
  $("tbPct").textContent=Math.round(Math.abs(v-rest)*100)+"%";
}
function tbFromEvent(e){const r=$("slot").getBoundingClientRect();return Math.min(1,Math.max(0,(e.clientX-r.left-P0)/(r.width-2*P0)))}
const capture=(n,e)=>{try{n.setPointerCapture(e.pointerId)}catch(x){}};
function tbSend(){tb.last=Date.now();tb.timer=null;api("/api/tbar?value="+tb.val.toFixed(3),"POST").catch(()=>{})}
$("slot").addEventListener("pointerdown",e=>{e.preventDefault();tb.drag=true;capture($("slot"),e);setLever(tbFromEvent(e));tbSend();buzz()});
$("slot").addEventListener("pointermove",e=>{if(!tb.drag)return;const v=tbFromEvent(e);if(Math.abs(v-tb.val)<0.002)return;setLever(v);
  if(v===0||v===1)buzz();if(Date.now()-tb.last>50)tbSend();else if(!tb.timer)tb.timer=setTimeout(tbSend,50)});
const tbEnd=()=>{if(!tb.drag)return;clearTimeout(tb.timer);tbSend();setTimeout(()=>{tb.drag=false},350)};
$("slot").addEventListener("pointerup",tbEnd);$("slot").addEventListener("pointercancel",tbEnd);
addEventListener("resize",()=>{if(st)setLever(tb.drag?tb.val:st.tbar)});

/* Mixer strips */
const fz={id:null,val:0,last:0,timer:null,y0:0,v0:0};
const held={};
const dbPct=d=>Math.min(1,Math.max(0,(d+60)/60));
/* Same fader law as the app (FaderLaw): 0.75 = 0 dB, top = +10 dB, 0.25 = -30 dB */
function faderDB(p){if(p<=0.0001)return"-∞";const d=p>=0.75?(p-0.75)/0.25*10:(p>=0.25?(p-0.75)/0.5*30:-30-(0.25-p)/0.25*60);return(d>0?"+":"")+d.toFixed(1)}
function buildStrips(){
  const box=$("strips");box.textContent="";
  const all=[Object.assign({master:true},st.master)].concat(st.channels);
  all.forEach(c=>{const s=el("div","strip"+(c.master?" master":""));s.dataset.id=c.id;
    const nm=el("div","nm",c.master?"MASTER":c.name),db=el("div","db","");
    const fzw=el("div","fz"),ml=el("div","meter"),mr=el("div","meter"),fd=el("div","fader"),cap=el("div","cap");
    ml.appendChild(el("i"));mr.appendChild(el("i"));fd.appendChild(cap);fzw.append(ml,fd,mr);
    const mute=el("button","key red",L.mute);
    if(c.master)mute.style.visibility="hidden";
    mute.onclick=()=>{const on=!mute.classList.contains("on");mute.classList.toggle("on",on);send("/api/audio/mute?id="+encodeURIComponent(c.id)+"&on="+(on?1:0))};
    const pos=e=>{const r=fd.getBoundingClientRect();return Math.min(1,Math.max(0,1-(e.clientY-r.top-12)/(r.height-24)))};
    let shown=-1;
    const put=v=>{if(Math.abs(v-shown)<0.0005)return;shown=v;cap.style.transform="translateY("+((1-v)*(fd.clientHeight-24))+"px)";db.textContent=faderDB(v)};
    const go=()=>{fz.last=Date.now();fz.timer=null;held[c.id]={v:fz.val,t:Date.now()};
      api(c.master?"/api/audio/master?fader="+fz.val.toFixed(3):"/api/audio/fader?id="+encodeURIComponent(c.id)+"&value="+fz.val.toFixed(3),"POST").catch(()=>{})};
    fd.addEventListener("pointerdown",e=>{e.preventDefault();fz.id=c.id;capture(fd,e);
      const capY=fd.getBoundingClientRect().top+12+(1-shown)*(fd.clientHeight-24);
      fz.y0=e.clientY;fz.v0=Math.abs(e.clientY-capY)<=16?shown:pos(e);fz.val=fz.v0;put(fz.val);go();buzz()});
    fd.addEventListener("pointermove",e=>{if(fz.id!==c.id)return;
      fz.val=Math.min(1,Math.max(0,fz.v0-(e.clientY-fz.y0)/Math.max(1,fd.clientHeight-24)));put(fz.val);
      if(Date.now()-fz.last>50)go();else if(!fz.timer)fz.timer=setTimeout(go,50)});
    const end=()=>{if(fz.id!==c.id)return;clearTimeout(fz.timer);go();fz.id=null};
    fd.addEventListener("pointerup",end);fd.addEventListener("pointercancel",end);
    // Double-tap the fader: back to 0 dB.
    let lastTap=0;fd.addEventListener("pointerup",()=>{const n=Date.now();if(n-lastTap<300){fz.val=0.75;put(0.75);go()}lastTap=n});
    s._put=put;s._mute=mute;s._ml=ml.firstChild;s._mr=mr.firstChild;
    s.append(nm,fzw,db,mute);box.appendChild(s)});
  if(!st.channels.length)box.appendChild(el("div","empty",L.noAudio));
}
function renderAudio(){
  const ss=sig(st.channels.map(c=>[c.id,c.name]));
  if(ss!==stripSig){stripSig=ss;buildStrips()}
  const all=[st.master].concat(st.channels);
  [...$("strips").querySelectorAll(".strip")].forEach((s,k)=>{const c=all[k];if(!c)return;
    const h=held[c.id];
    if(h&&(Math.abs(h.v-c.fader)<0.01||Date.now()-h.t>1500))delete held[c.id];
    if(fz.id!==c.id&&!held[c.id])s._put(c.fader);s._mute.classList.toggle("on",!!c.muted);
    s._ml.style.transform="scaleY("+(1-dbPct(c.l))+")";s._mr.style.transform="scaleY("+(1-dbPct(c.r))+")"});
}

/* ---------- Sound (Audio Monitor) ----------
   PCM blocks [next u32][rate u32][channels u32][int16...] arrive over one push response.
   They go into a jitter buffer: playback waits for `target` seconds of sound, the target grows
   by 0.1 s after a gap (up to 1.2 s) and shrinks again after 20 s without one, and the speed is
   nudged by up to ±1.5 % so the buffer stays at the target (the Mac's and the phone's clocks
   never run at exactly the same speed: without this the buffer slowly runs dry or overflows).
   https: an AudioWorklet does this on the audio thread. http (LAN): blocks are scheduled ahead
   on the audio clock with a playback-rate correction. */
const WORKLET=`class P extends AudioWorkletProcessor{constructor(){super();this.cap=1<<18;this.L=new Float32Array(this.cap);this.R=new Float32Array(this.cap);
this.w=0;this.r=0;this.rate=24000;this.target=.25;this.started=false;this.t=0;this.lastGap=0;this.rep=0;
this.port.onmessage=e=>{const d=e.data;if(d.target){this.target=d.target;return}const p=d.pcm,ch=d.ch,n=(p.length/ch)|0;this.rate=d.rate;
for(let i=0;i<n;i++){const k=this.w%this.cap;this.L[k]=p[i*ch]/32768;this.R[k]=ch>1?p[i*ch+1]/32768:this.L[k];this.w++}
if(this.w-this.r>Math.min(this.cap-2048,(this.target+1.2)*this.rate))this.r=this.w-this.target*this.rate}}
process(i,o){const out=o[0],l=out[0],r=out[1]||out[0],n=l.length,sr=sampleRate;this.t+=n/sr;
const fill=(this.w-this.r)/this.rate;
if(!this.started){if(fill>=this.target)this.started=true;else{l.fill(0);if(r!==l)r.fill(0);this.report(fill);return true}}
const k=Math.max(-.015,Math.min(.015,(fill-this.target)/Math.max(this.target,.05)*.015));const step=this.rate/sr*(1+k);
for(let j=0;j<n;j++){if(this.w-this.r<2){for(;j<n;j++){l[j]=0;if(r!==l)r[j]=0}this.started=false;this.target=Math.min(1.2,this.target+.1);this.lastGap=this.t;this.port.postMessage({gap:1,target:this.target});break}
const i0=Math.floor(this.r),f=this.r-i0,a=i0%this.cap,b=(i0+1)%this.cap;l[j]=this.L[a]+(this.L[b]-this.L[a])*f;if(r!==l)r[j]=this.R[a]+(this.R[b]-this.R[a])*f;this.r+=step}
if(this.t-this.lastGap>20&&this.target>.15){this.target=Math.max(.15,this.target-.05);this.lastGap=this.t}
this.report(fill);return true}
report(fill){if(this.t-this.rep>.5){this.rep=this.t;this.port.postMessage({fill:fill,target:this.target})}}}
registerProcessor("lc-player",P)`;
const aud={ctx:null,gain:null,node:null,gen:null,abort:null,low:false,restart:false,nextSeq:0,
  // http fallback scheduler
  playT:0,lead:0.3,lastGap:0,pend:[],pendN:0,rate:24000,ch:2,fill:0,target:0.25};
function lsnUI(){const on=!!aud.gen;$("lsn").classList.toggle("on",on);$("lsn").classList.toggle("blue",on);$("lsnTxt").textContent=on?L.listenStop:L.listen;
  $("lsn2").classList.toggle("on",on);if(!on){$("lst").textContent=L.notListening;$("bufBar").style.width="0";$("bufMs").textContent=""}}
function bufUI(){const f=aud.fill,t=aud.target;$("lst").textContent=L.listening+(aud.low?" · mono":"");
  $("bufBar").style.width=Math.min(100,f/Math.max(t*2,0.1)*100)+"%";$("bufBar").style.background=f<t*0.5?"var(--amber)":"var(--green)";
  $("bufMs").textContent=Math.round(t*1000)+" ms"}
function stopListen(){aud.gen=null;aud.nextSeq=0;if(aud.abort){try{aud.abort.abort()}catch(e){}}if(aud.ctx){aud.ctx.close();aud.ctx=null}aud.node=null;lsnUI();video.retune()}
async function startListen(){
  stopListen();
  const C=window.AudioContext||window.webkitAudioContext;if(!C)return;
  const ctx=aud.ctx=new C({latencyHint:"playback"});aud.gain=ctx.createGain();aud.gain.gain.value=+$("lvol").value;aud.gain.connect(ctx.destination);
  const gen=aud.gen={};aud.playT=0;aud.lead=net.weak?0.6:0.3;aud.lastGap=Date.now();aud.pend=[];aud.pendN=0;aud.target=net.weak?0.5:0.25;
  try{ctx.resume&&ctx.resume()}catch(e){}
  if(window.isSecureContext&&ctx.audioWorklet&&window.AudioWorkletNode){
    try{const u=URL.createObjectURL(new Blob([WORKLET],{type:"text/javascript"}));await ctx.audioWorklet.addModule(u);URL.revokeObjectURL(u);
      if(aud.gen!==gen)return;
      const n=aud.node=new AudioWorkletNode(ctx,"lc-player",{numberOfInputs:0,outputChannelCount:[2]});n.connect(aud.gain);
      n.port.postMessage({target:aud.target});
      n.port.onmessage=e=>{const d=e.data;if(d.gap){toast(L.gap)}if(d.fill!=null){aud.fill=d.fill;aud.target=d.target;bufUI()}};
    }catch(e){aud.node=null}
  }
  lsnUI();bufUI();video.retune();
  listenStream(gen);
}
function playBlock(buf){
  const dv=new DataView(buf);
  aud.nextSeq=dv.getUint32(0,true);const rate=dv.getUint32(4,true),ch=dv.getUint32(8,true);
  const n=Math.floor((buf.byteLength-12)/2/ch);if(n<=0||!aud.ctx)return;
  const pcm=new Int16Array(buf.slice(12,12+n*ch*2));
  if(aud.node){aud.node.port.postMessage({pcm,ch,rate},[pcm.buffer]);return}
  // http fallback: gather ~80 ms, then schedule it ahead on the audio clock.
  if(rate!==aud.rate||ch!==aud.ch){aud.pend=[];aud.pendN=0;aud.rate=rate;aud.ch=ch}
  aud.pend.push(pcm);aud.pendN+=n;
  if(aud.pendN<rate*0.08)return;
  const ctx=aud.ctx,ab=ctx.createBuffer(2,aud.pendN,rate),Lc=ab.getChannelData(0),Rc=ab.getChannelData(1);let o=0;
  for(const p of aud.pend){const m=p.length/ch;for(let i=0;i<m;i++){Lc[o]=p[i*ch]/32768;Rc[o]=ch>1?p[i*ch+1]/32768:Lc[o];o++}}
  aud.pend=[];aud.pendN=0;
  const now=ctx.currentTime;let ahead=aud.playT-now;
  if(ahead<0.01){ if(aud.playT>0){aud.lead=Math.min(1.2,aud.lead+0.1);aud.lastGap=Date.now();toast(L.gap)} aud.playT=now+aud.lead;ahead=aud.lead }
  else if(ahead>aud.lead+0.8){ return }   // far too much queued (burst after a stall): drop this chunk to catch up
  if(Date.now()-aud.lastGap>20000&&aud.lead>0.2){aud.lead=Math.max(0.2,aud.lead-0.05);aud.lastGap=Date.now()}
  const k=1+Math.max(-0.015,Math.min(0.015,(ahead-aud.lead)/aud.lead*0.015));
  const src=ctx.createBufferSource();src.buffer=ab;src.playbackRate.value=k;src.connect(aud.gain);src.start(aud.playT);aud.playT+=ab.duration/k;
  aud.fill=ahead;aud.target=aud.lead;bufUI();
}
async function listenStream(gen){
  let got=false,last=Date.now();
  const ac=new AbortController();aud.abort=ac;aud.low=net.weak;aud.restart=false;
  const wd=setInterval(()=>{if(Date.now()-last>4000)ac.abort()},1000);
  try{
    const r=await api("/api/listen?stream=1&bus="+$("lbus").value+(aud.low?"&q=low":""),"GET",{timeout:0,signal:ac.signal,noRtt:true});
    if(!r.body||!r.body.getReader)throw new Error("no stream");
    const rd=r.body.getReader(),bq=new ByteQueue();
    while(aud.gen===gen){
      const x=await rd.read();if(x.done)break;last=Date.now();net.bytes+=x.value.length;bq.push(x.value);
      for(;;){const len=bq.peek4();if(len<0||bq.n<4+len)break;bq.read(4);got=true;playBlock(bq.read(len).buffer)}
    }
    try{rd.cancel()}catch(e){}
  }catch(e){}
  clearInterval(wd);if(aud.abort===ac)aud.abort=null;
  if(aud.gen!==gen)return;
  if(aud.restart)listenStream(gen);
  else if(got)setTimeout(()=>listenStream(gen),net.weak?800:200);else listenLoop(gen);
}
async function listenLoop(gen){
  if(aud.gen!==gen)return;
  const t0=performance.now();
  try{const r=await api("/api/listen?bus="+$("lbus").value+"&since="+aud.nextSeq);
    if(aud.gen!==gen)return;
    if(r.status===200){const b=await r.arrayBuffer();net.bytes+=b.byteLength;playBlock(b)}}catch(e){if(aud.gen!==gen)return}
  setTimeout(()=>listenLoop(gen),Math.max(0,(net.weak?250:120)-(performance.now()-t0)));
}
const toggleListen=()=>{if(aud.gen)stopListen();else startListen()};
$("lsn").onclick=toggleListen;$("lsn2").onclick=toggleListen;
$("lvol").oninput=()=>{if(aud.gain)aud.gain.gain.value=+$("lvol").value};
$("lbus").onchange=()=>{if(aud.gen)startListen()};
lsnUI();

/* ---------- Buttons, tabs, settings ---------- */
$("cut").onclick=()=>{if(st&&st.preview){const p=st.program;st.program=st.preview;st.preview=p;render()}send("/api/cut")};
$("auto").onclick=()=>send("/api/auto");
$("snap").onclick=()=>{send("/api/snapshot");toast("📷")};
$("fs").onclick=()=>send("/api/fullscreen");
$("mark").onclick=()=>{if(st){st.highlights=(st.highlights||0)+1;render()}send("/api/highlight")};
$("rec").onclick=()=>{if(!st)return;if(st.recordLocked){alert(L.recLocked);return}
  if(st.recording){if(confirm(L.stopRec))send("/api/record/stop")}else send("/api/record/start")};
$("live").onclick=()=>{if(!st)return;if(st.streamLocked){alert(L.liveLocked);return}
  if(st.streaming){if(confirm(L.stopLive))send("/api/stream/stop")}else if(!pref.conf||confirm(L.startLive))send("/api/stream/start")};
$("search").oninput=e=>{filter=e.target.value.trim().toLowerCase();if(st)render()};
function goTab(t){pref.tab=t;ls.set("lcTab",t);document.body.dataset.tab=t;document.querySelectorAll("nav button").forEach(b=>b.classList.toggle("on",b.dataset.go===t));if(st)setTimeout(()=>{setLever(st.tbar);stripSig="";renderAudio()},0)}
document.querySelectorAll("nav button").forEach(b=>b.onclick=()=>goTab(b.dataset.go));
goTab(pref.tab);
function seg(id,key,val,apply){const s=$(id);const draw=()=>s.querySelectorAll("button").forEach(b=>b.classList.toggle("on",b.dataset.v===String(pref[key])));
  s.querySelectorAll("button").forEach(b=>b.onclick=()=>{pref[key]=key==="fps"?+b.dataset.v:b.dataset.v;ls.set(val,String(pref[key]));draw();apply&&apply()});draw()}
function sw(id,key,val,apply){const b=$(id);const draw=()=>b.classList.toggle("on",!!pref[key]);b.onclick=()=>{pref[key]=!pref[key];ls.set(val,pref[key]?"1":"0");draw();apply&&apply()};draw()}
seg("optTheme","theme","lcTheme",applyTheme);seg("optQ","q","lcQ",()=>video.retune());seg("optFps","fps","lcFps",()=>video.retune());
sw("optPgm","pgm","lcPgm",()=>{$("mons").classList.toggle("pgmonly",pref.pgm);video.retune()});sw("optAF","af","lcAF",()=>video.retune());
sw("optHap","hap","lcHap");sw("optWake","wake","lcWake",()=>wake());sw("optConf","conf","lcConf");
$("mons").classList.toggle("pgmonly",pref.pgm);
$("gear").onclick=()=>$("sheet").classList.remove("hidden");
$("closeSheet").onclick=()=>$("sheet").classList.add("hidden");
$("sheet").onclick=e=>{if(e.target===$("sheet"))$("sheet").classList.add("hidden")};
$("out").onclick=()=>{ls.set("lcPin","");pin="";signedOut("")};
// Keep the screen on while the remote is open (Wake Lock: https only).
let wl=null;async function wake(){try{if(pref.wake&&navigator.wakeLock&&!wl){wl=await navigator.wakeLock.request("screen");wl.addEventListener("release",()=>{wl=null})}
  else if(!pref.wake&&wl){wl.release();wl=null}}catch(e){wl=null}}

/* Keyboard (desktop browsers and tablets with a keyboard) */
document.addEventListener("keydown",e=>{
  if(!$("login").classList.contains("hidden")){
    if(/^\d$/.test(e.key)&&typed.length<8)typed+=e.key;else if(e.key==="Backspace")typed=typed.slice(0,-1);else if(e.key==="Enter")signIn(typed);dots();return}
  if(!st||e.metaKey||e.ctrlKey||e.altKey||/INPUT|SELECT|TEXTAREA/.test((e.target.tagName||"")))return;
  const d=e.code&&e.code.startsWith("Digit")?+e.code.slice(5):(/^\d$/.test(e.key)?+e.key:NaN);
  if(d>=1&&d<=9){e.preventDefault();if(e.shiftKey)send("/api/program?input="+d);else{st.preview=d;render();send("/api/preview?input="+d)}return}
  const k=e.key.toLowerCase();
  if(e.key===" "){e.preventDefault();$("cut").click()}
  else if(e.key==="Enter"){e.preventDefault();$("auto").click()}
  else if("qwer".includes(k)&&k.length===1){const n="qwer".indexOf(k)+1;send(e.shiftKey?"/api/overlay?to=program&n="+n:"/api/overlay?n="+n)}
  else if(k==="m")$("mark").click();
  else if(k==="l")toggleListen();
  else if(k==="p")$("snap").click();
});

pad();
if(pin)signIn();
</script>
<div id="prompt" class="hidden"><div class="pl"></div><div class="pt" id="prText"></div><div class="pc" id="prCtl"></div></div>
<script>
// Teleprompter (0.71.0): the Mac keeps the position; the phone shows it and can control it.
let prRev=-1,prBusy=false;
function prCmd(c){send("/api/prompter/cmd?do="+c)}
(function(){const keys=[["⛶","open"],["⏮","restart"],["⏯","toggle"],["−5s","back"],["+5s","forward"],["🐢","slower"],["🐇","faster"],["⇋","mirror"]];
  const box=document.getElementById("prKeys"),ctl=document.getElementById("prCtl");
  keys.forEach(([t,c])=>{const b=document.createElement("button");b.className="key blue";b.textContent=t;
    b.onclick=()=>{if(c==="open"){document.getElementById("prompt").classList.remove("hidden");prRender()}else prCmd(c)};box.appendChild(b)});
  keys.slice(1).concat([["✕","close"]]).forEach(([t,c])=>{const b=document.createElement("button");b.className="key";b.textContent=t;
    b.onclick=(e)=>{e.stopPropagation();if(c==="close")document.getElementById("prompt").classList.add("hidden");else prCmd(c)};ctl.appendChild(b)});
})();
async function prFetch(){if(prBusy)return;prBusy=true;
  try{const r=await api("/api/prompter");const j=await r.json();prRev=j.rev;document.getElementById("prText").textContent=j.text||""}catch(e){}
  prBusy=false}
function prRender(){const p=(typeof st!=="undefined"&&st&&st.prompter)||null;if(!p)return;
  if(p.rev!==prRev)prFetch();
  const box=document.getElementById("prompt");if(box.classList.contains("hidden"))return;
  const t=document.getElementById("prText");
  t.style.fontSize=Math.max(16,Math.round(p.size*Math.min(1,window.innerWidth/1100)))+"px";
  t.style.transform=(p.mirror?"scaleX(-1) ":"")+"translateY("+(-p.pos*t.scrollHeight)+"px)"}
setInterval(prRender,250);
// Scoreboard (0.74.0): +/- for each side, period, reset.
(function(){[["+1","homePlus"],["−1","homeMinus"],["+1","awayPlus"],["−1","awayMinus"],["◀","periodBack"],["▶","periodNext"],["0:0","reset"]].forEach(([t,c])=>{
  const b=document.createElement("button");b.className="key"+(c.startsWith("period")?" blue":"");b.textContent=t;b.dataset.c=c;
  b.onclick=()=>send("/api/score?do="+c);document.getElementById("scKeys").appendChild(b)})})();
setInterval(()=>{const s=(typeof st!=="undefined"&&st&&st.score)||null;document.getElementById("scBox").classList.toggle("hidden",!s);if(!s)return;
  document.getElementById("scHead").textContent=s.home+"  "+s.h+" - "+s.a+"  "+s.away+(s.p?"  ·  "+s.p:"");
  document.querySelectorAll("#scKeys button").forEach(b=>{if(b.dataset.c.startsWith("home"))b.textContent=s.home.slice(0,4)+" "+(b.dataset.c==="homePlus"?"+1":"−1");
    if(b.dataset.c.startsWith("away"))b.textContent=s.away.slice(0,4)+" "+(b.dataset.c==="awayPlus"?"+1":"−1")})},500);
</script>
</body>
</html>
"""#
}
