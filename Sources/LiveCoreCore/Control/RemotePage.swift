/// The Web Controller page served at "/": one self-contained HTML file (no external
/// scripts, fonts or images) styled as a hardware switcher panel for phones and tablets.
/// It signs in with the PIN, polls /api/state, shows Program / Preview pictures from
/// /api/frame and sends POST /api/... commands with the PIN in the X-LiveCore-PIN header.
public enum RemotePage {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#0c0d10">
<title>LiveCore Remote</title>
<style>
:root{
 --bg:#0c0d10;--deck:#16181d;--deck2:#1c1f25;--edge:#2a2e36;--ink:#e8ebf0;--dim:#868e9b;--etch:#5d6573;
 --red:#ff3b45;--red2:#c4141f;--green:#22d36f;--green2:#0f9a4a;--amber:#ffb020;--amber2:#d17c00;--blue:#3d8bff;--blue2:#1f5fd1;
 --key:#33373f;--key2:#24272d;--keyEdge:#0b0c0f;
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}
html,body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif;overscroll-behavior:none}
body{padding:calc(8px + env(safe-area-inset-top)) 12px calc(14px + env(safe-area-inset-bottom));
 background:radial-gradient(1200px 600px at 50% -200px,#1d2129 0,transparent 70%),var(--bg)}
button{font:inherit;color:inherit;border:0;background:none;padding:0;cursor:pointer;touch-action:manipulation}
.hidden{display:none!important}

/* Status bar */
.bar{display:flex;align-items:center;flex-wrap:wrap;gap:8px 10px;padding:6px 4px 10px}
.bar .who{display:flex;align-items:center;gap:8px;flex:1 1 160px;min-width:0}
.bar h1{flex:1;min-width:0;margin:0;font-size:15px;font-weight:700;letter-spacing:.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.led{width:9px;height:9px;border-radius:50%;background:#3a3f48;box-shadow:inset 0 1px 1px rgba(0,0,0,.6);flex:none}
.led.ok{background:var(--green);box-shadow:0 0 8px var(--green)}
.led.bad{background:var(--red);box-shadow:0 0 8px var(--red)}
.tally{display:flex;align-items:center;gap:6px;padding:4px 9px 4px 7px;border-radius:7px;background:var(--deck);border:1px solid var(--edge);
 font:700 11px/1 ui-monospace,"SF Mono",Menlo,monospace;letter-spacing:.06em;color:var(--dim)}
.tally.on{color:#fff;border-color:var(--red2);background:linear-gradient(#3a1215,#250a0c)}
.tally.on .led{background:var(--red);box-shadow:0 0 10px var(--red);animation:blink 1.2s steps(1) infinite}
.tally time{font-variant-numeric:tabular-nums;color:inherit}
@keyframes blink{50%{opacity:.35}}

/* Panel modules */
.deck{display:grid;gap:10px}
.mod{position:relative;background:linear-gradient(180deg,var(--deck2),var(--deck));border:1px solid var(--edge);border-radius:14px;padding:12px;
 box-shadow:0 10px 24px rgba(0,0,0,.35),inset 0 1px 0 rgba(255,255,255,.04)}
.mod>h2{margin:0 0 10px;font:700 10px/1 -apple-system,sans-serif;letter-spacing:.18em;text-transform:uppercase;color:var(--etch);display:flex;align-items:center;gap:8px}
.mod>h2::after{content:"";flex:1;height:1px;background:linear-gradient(90deg,var(--edge),transparent)}

/* Monitors */
.monitors{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.mon{position:relative;aspect-ratio:16/9;border-radius:9px;overflow:hidden;background:#050608;border:2px solid #23262d}
.mon img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;opacity:0;transition:opacity .25s}
.mon img.ready{opacity:1}
.mon .lbl{position:absolute;left:0;right:0;bottom:0;display:flex;gap:6px;align-items:center;padding:16px 8px 6px;
 background:linear-gradient(transparent,rgba(0,0,0,.85));font-weight:600;font-size:12px;white-space:nowrap;overflow:hidden}
.mon .lbl b{font:800 10px/1 -apple-system,sans-serif;letter-spacing:.12em;padding:3px 5px;border-radius:4px}
.mon .lbl span{overflow:hidden;text-overflow:ellipsis}
.mon.pvw{border-color:var(--green2);box-shadow:0 0 0 1px rgba(34,211,111,.25),0 0 18px rgba(34,211,111,.15)}
.mon.pvw .lbl b{background:var(--green);color:#03170b}
.mon.pgm{border-color:var(--red2);box-shadow:0 0 0 1px rgba(255,59,69,.3),0 0 22px rgba(255,59,69,.22)}
.mon.pgm .lbl b{background:var(--red);color:#fff}
.mon .nosig{position:absolute;inset:0;display:grid;place-items:center;color:#3b404a;font:700 11px/1 ui-monospace,monospace;letter-spacing:.2em}

/* Keys */
.key{position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;min-height:52px;padding:6px 4px;
 border-radius:9px;background:linear-gradient(180deg,var(--key),var(--key2));color:#cfd4dc;
 box-shadow:0 4px 0 var(--keyEdge),0 5px 8px rgba(0,0,0,.45),inset 0 1px 0 rgba(255,255,255,.10);
 transition:transform .06s ease,box-shadow .06s ease,background .15s,color .15s}
.key.down,.key:active{transform:translateY(3px);box-shadow:0 1px 0 var(--keyEdge),0 2px 4px rgba(0,0,0,.4),inset 0 1px 0 rgba(255,255,255,.06)}
.key:disabled{opacity:.35;cursor:default}
.key .num{font:800 18px/1 -apple-system,sans-serif;font-variant-numeric:tabular-nums}
.key .nm{font-size:10.5px;font-weight:600;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;opacity:.8;padding:0 2px}
.key.on.red{background:linear-gradient(180deg,#ff6a72,var(--red) 45%,var(--red2));color:#fff;
 box-shadow:0 4px 0 #6b0a10,0 0 22px rgba(255,59,69,.55),inset 0 1px 0 rgba(255,255,255,.45)}
.key.on.green{background:linear-gradient(180deg,#6af0a3,var(--green) 45%,var(--green2));color:#032010;
 box-shadow:0 4px 0 #064a22,0 0 22px rgba(34,211,111,.5),inset 0 1px 0 rgba(255,255,255,.5)}
.key.on.amber{background:linear-gradient(180deg,#ffd27a,var(--amber) 45%,var(--amber2));color:#2a1800;
 box-shadow:0 4px 0 #6b3f00,0 0 20px rgba(255,176,32,.5),inset 0 1px 0 rgba(255,255,255,.5)}
.key.on.blue{background:linear-gradient(180deg,#8ab8ff,var(--blue) 45%,var(--blue2));color:#fff;
 box-shadow:0 4px 0 #0d2f6e,0 0 18px rgba(61,139,255,.45),inset 0 1px 0 rgba(255,255,255,.4)}
.key.dimred{box-shadow:0 4px 0 var(--keyEdge),inset 0 0 0 2px rgba(255,59,69,.55),inset 0 1px 0 rgba(255,255,255,.1)}
.key.dimgreen{box-shadow:0 4px 0 var(--keyEdge),inset 0 0 0 2px rgba(34,211,111,.55),inset 0 1px 0 rgba(255,255,255,.1)}
.key.down.on,.key.on:active{transform:translateY(3px)}

/* Buses */
.busrow{display:grid;grid-template-columns:44px 1fr;gap:8px;align-items:stretch}
.busrow+.busrow{margin-top:12px}
.buslbl{display:flex;align-items:center;justify-content:center;writing-mode:vertical-rl;transform:rotate(180deg);
 font:800 10px/1 -apple-system,sans-serif;letter-spacing:.2em;border-radius:7px;background:#101216;border:1px solid var(--edge)}
.buslbl.g{color:var(--green)}.buslbl.r{color:var(--red)}
.keys{display:grid;grid-template-columns:repeat(auto-fill,minmax(70px,1fr));gap:9px 8px}
.empty{color:var(--dim);font-size:13px;padding:10px 0}

/* Transition */
.trans{display:grid;grid-template-columns:1fr;gap:12px}
.chips{display:flex;gap:7px;overflow-x:auto;padding:2px 2px 8px;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
.chips .key{min-height:38px;padding:6px 11px;flex:none;font-size:12px;font-weight:700}
.go{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.go .key{min-height:68px;font:900 20px/1 -apple-system,sans-serif;letter-spacing:.12em}
#auto.run{animation:pulse .5s ease-in-out infinite alternate}
@keyframes pulse{to{filter:brightness(1.35)}}

/* T-bar lever */
.tbar{position:relative;display:flex;align-items:center;gap:12px}
.tbar .pct{width:52px;text-align:right;font:800 18px/1 ui-monospace,"SF Mono",Menlo,monospace;font-variant-numeric:tabular-nums}
.slot{position:relative;flex:1;height:64px;border-radius:12px;background:#08090b;border:1px solid #252931;
 box-shadow:inset 0 3px 10px rgba(0,0,0,.8);touch-action:none;cursor:grab}
.slot::before{content:"";position:absolute;left:26px;right:26px;top:50%;height:6px;margin-top:-3px;border-radius:3px;background:#1d2027;
 box-shadow:inset 0 1px 2px rgba(0,0,0,.9)}
.slot .fill{position:absolute;top:50%;height:6px;margin-top:-3px;border-radius:3px;background:linear-gradient(90deg,var(--blue2),var(--blue));
 box-shadow:0 0 10px rgba(61,139,255,.6)}
.slot .ticks{position:absolute;left:26px;right:26px;bottom:6px;height:6px;
 background:repeating-linear-gradient(90deg,#3a3f48 0 1px,transparent 1px 10%)}
.lever{position:absolute;top:6px;bottom:6px;width:46px;margin-left:-23px;border-radius:8px;
 background:linear-gradient(90deg,#9ba3ad,#eef1f4 35%,#c4cad1 55%,#8a929c);
 box-shadow:0 6px 12px rgba(0,0,0,.6),inset 0 0 0 1px rgba(0,0,0,.35);will-change:left}
.lever::after{content:"";position:absolute;left:12px;right:12px;top:50%;height:16px;margin-top:-8px;
 background:repeating-linear-gradient(90deg,rgba(0,0,0,.35) 0 2px,rgba(255,255,255,.5) 2px 3px,transparent 3px 6px)}
.slot.drag{cursor:grabbing}

/* Small key groups */
.grp{display:grid;grid-template-columns:repeat(4,1fr);gap:9px 8px}
.grp3{display:grid;grid-template-columns:repeat(3,1fr);gap:9px 8px}
.sub{margin:14px 0 8px;font:700 10px/1 -apple-system,sans-serif;letter-spacing:.18em;text-transform:uppercase;color:var(--etch)}
.out .key{min-height:62px}
.out .key time{font:700 12px/1 ui-monospace,"SF Mono",Menlo,monospace;font-variant-numeric:tabular-nums;opacity:.9}
.out .key .cap{font:900 14px/1 -apple-system,sans-serif;letter-spacing:.12em}
.note{color:var(--dim);font-size:12px;margin-top:8px;min-height:1em}

/* Audio */
.strips{display:flex;gap:10px;overflow-x:auto;padding:2px 2px 6px;scrollbar-width:thin}
.strip{flex:none;width:68px;display:flex;flex-direction:column;align-items:center;gap:8px;padding:8px 6px;border-radius:10px;background:#111317;border:1px solid #23262d}
.strip.master{background:linear-gradient(#171a20,#121419);border-color:#343944}
.strip .nm{font-size:10.5px;font-weight:700;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#b9c0ca}
.strip .db{font:700 10px/1 ui-monospace,monospace;color:var(--dim);font-variant-numeric:tabular-nums}
.fz{display:flex;gap:6px;height:190px}
.meter{position:relative;width:5px;border-radius:2px;overflow:hidden;
 background:linear-gradient(0deg,#16c35f 0,#16c35f 66%,#e5c41a 83%,#ff3b45 100%)}
.meter i{position:absolute;left:0;right:0;top:0;background:#0b0c0f;transition:height .08s linear}
.fader{position:relative;width:34px;touch-action:none;cursor:grab}
.fader::before{content:"";position:absolute;left:50%;top:12px;bottom:12px;width:4px;margin-left:-2px;border-radius:2px;background:#050607;
 box-shadow:inset 0 1px 2px #000,0 0 0 1px #262a31}
.fader .cap{position:absolute;left:1px;right:1px;height:24px;margin-top:-12px;border-radius:5px;
 background:linear-gradient(180deg,#474c55,#2b2f36 48%,#d9dde2 50%,#2b2f36 52%,#202328);
 box-shadow:0 4px 8px rgba(0,0,0,.6),inset 0 1px 0 rgba(255,255,255,.2)}
.strip .key{min-height:30px;width:100%;font:800 10px/1 -apple-system,sans-serif;letter-spacing:.08em}

/* Sign in */
#login{max-width:340px;margin:6vh auto 0;text-align:center}
#login h1{font-size:20px;margin:6px 0 4px;letter-spacing:.02em}
#login .note{margin:0 0 18px}
.dots{display:flex;justify-content:center;gap:12px;margin:8px 0 18px}
.dots i{width:13px;height:13px;border-radius:50%;border:2px solid #3a3f48}
.dots i.f{background:var(--ink);border-color:var(--ink)}
.pad{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
.pad .key{min-height:62px;font:700 24px/1 -apple-system,sans-serif}
#err{color:var(--amber);min-height:20px;margin-top:14px;font-size:13px}
.logo{width:54px;height:54px;margin:0 auto;border-radius:14px;background:linear-gradient(135deg,var(--red),#7a0d14);
 display:grid;place-items:center;box-shadow:0 8px 24px rgba(255,59,69,.35)}
.logo::after{content:"";width:16px;height:16px;border-radius:50%;background:#fff;box-shadow:0 0 0 5px rgba(255,255,255,.25)}
.foot{display:flex;justify-content:center;margin-top:12px}
.foot button{color:var(--dim);font-size:12px;padding:10px 14px}

/* Tablet / landscape: a two-column surface */
@media (min-width:900px){
 body{padding-left:18px;padding-right:18px}
 .deck{grid-template-columns:minmax(0,1.35fr) minmax(0,1fr);grid-template-areas:"mon mon" "bus trans" "keys out" "audio audio";gap:12px}
 .a-mon{grid-area:mon}.a-bus{grid-area:bus}.a-trans{grid-area:trans}.a-keys{grid-area:keys}.a-out{grid-area:out}.a-audio{grid-area:audio}
 .monitors{gap:14px}
 .trans{grid-template-columns:1fr 112px;grid-template-areas:"chips lever" "go lever"}
 .trans .chipsbox{grid-area:chips}.trans .go{grid-area:go;align-self:end}.trans .tbar{grid-area:lever}
 .tbar{flex-direction:column-reverse;height:100%;min-height:260px}
 .slot{width:72px;height:auto;flex:1}
 .slot::before{left:50%;right:auto;top:24px;bottom:24px;width:6px;height:auto;margin:0 0 0 -3px}
 .slot .fill{left:50%;width:6px;height:auto;margin:0 0 0 -3px}
 .slot .ticks{left:auto;right:6px;top:24px;bottom:24px;width:6px;height:auto;background:repeating-linear-gradient(180deg,#3a3f48 0 1px,transparent 1px 10%)}
 .lever{left:6px!important;right:6px;top:auto;bottom:auto;width:auto;height:40px;margin:-20px 0 0 0;
  background:linear-gradient(180deg,#9ba3ad,#eef1f4 35%,#c4cad1 55%,#8a929c);will-change:top}
 .lever::after{left:50%;right:auto;top:10px;bottom:10px;width:24px;height:auto;margin:0 0 0 -12px;
  background:repeating-linear-gradient(180deg,rgba(0,0,0,.35) 0 2px,rgba(255,255,255,.5) 2px 3px,transparent 3px 6px)}
 .tbar .pct{width:auto;text-align:center}
 .fz{height:220px}
}
</style>
</head>
<body>
<div id="login">
  <div class="logo"></div>
  <h1>LiveCore Remote</h1>
  <p class="note" data-t="pinHint"></p>
  <div class="dots" id="dots"></div>
  <div class="pad" id="pad"></div>
  <div id="err"></div>
</div>

<div id="app" class="hidden">
  <div class="bar">
    <div class="who"><span id="conn" class="led"></span><h1 id="title">LiveCore Studio</h1></div>
    <span id="recT" class="tally"><span class="led"></span>REC <time>00:00:00</time></span>
    <span id="liveT" class="tally"><span class="led"></span>LIVE <time>00:00:00</time></span>
  </div>
  <div class="deck">
    <div class="mod a-mon">
      <div class="monitors">
        <div class="mon pvw"><div class="nosig">PREVIEW</div><img id="imgPvw" alt=""><div class="lbl"><b>PVW</b><span id="pvwName">—</span></div></div>
        <div class="mon pgm"><div class="nosig">PROGRAM</div><img id="imgPgm" alt=""><div class="lbl"><b>PGM</b><span id="pgmName">—</span></div></div>
      </div>
    </div>
    <div class="mod a-bus">
      <h2 data-t="inputs"></h2>
      <div class="busrow"><div class="buslbl g">PREVIEW</div><div id="pvwBus" class="keys"></div></div>
      <div class="busrow"><div class="buslbl r">PROGRAM</div><div id="pgmBus" class="keys"></div></div>
    </div>
    <div class="mod a-trans">
      <h2 data-t="transition"></h2>
      <div class="trans">
        <div class="chipsbox">
          <div id="kinds" class="chips"></div>
          <div id="durs" class="chips"></div>
        </div>
        <div class="go"><button id="cut" class="key">CUT</button><button id="auto" class="key">AUTO</button></div>
        <div class="tbar"><div id="slot" class="slot"><div class="ticks"></div><div class="fill" id="fill"></div><div class="lever" id="lever"></div></div><span id="tbPct" class="pct">0%</span></div>
      </div>
    </div>
    <div class="mod a-keys">
      <h2>Overlay</h2>
      <div id="overlays" class="grp"></div>
      <div class="sub" data-t="replay"></div>
      <div id="replays" class="grp3"></div>
    </div>
    <div class="mod a-out out">
      <h2 data-t="output"></h2>
      <div class="grp3">
        <button id="rec" class="key"><span class="cap">REC</span><time>00:00:00</time></button>
        <button id="live" class="key"><span class="cap">STREAM</span><time>00:00:00</time></button>
        <button id="snap" class="key"><span class="cap">PHOTO</span><time>&nbsp;</time></button>
      </div>
      <div class="note" id="locks"></div>
    </div>
    <div class="mod a-audio">
      <h2 data-t="audio"></h2>
      <div id="strips" class="strips"></div>
    </div>
  </div>
  <div class="foot"><button id="out" data-t="signOut"></button></div>
</div>

<script>
"use strict";
const T={
 en:{pinHint:"Enter the PIN shown in LiveCore Studio › Settings › Remote.",inputs:"Inputs",transition:"Transition",replay:"Instant replay",output:"Record & stream",audio:"Audio mixer",signOut:"Sign out",wrong:"Wrong PIN.",locked:"Too many wrong PINs. Try again in {s} s.",offline:"Cannot reach LiveCore Studio.",stopRec:"Stop recording?",stopLive:"Stop streaming?",startLive:"Start streaming?",recLocked:"Recording is locked in the app.",liveLocked:"Streaming is locked in the app.",noInputs:"No inputs yet.",noAudio:"No audio channels.",mute:"MUTE"},
 id:{pinHint:"Masukkan PIN yang tampil di LiveCore Studio › Settings › Remote.",inputs:"Input",transition:"Transisi",replay:"Instant replay",output:"Rekam & stream",audio:"Mixer audio",signOut:"Keluar",wrong:"PIN salah.",locked:"Terlalu banyak PIN salah. Coba lagi dalam {s} detik.",offline:"LiveCore Studio tidak terjangkau.",stopRec:"Hentikan rekaman?",stopLive:"Hentikan streaming?",startLive:"Mulai streaming?",recLocked:"Rekaman dikunci di aplikasi.",liveLocked:"Streaming dikunci di aplikasi.",noInputs:"Belum ada input.",noAudio:"Belum ada kanal audio.",mute:"MUTE"}
};
const lang=(navigator.language||"en").slice(0,2), L=T[lang]||T.en;
document.documentElement.lang=T[lang]?lang:"en";
document.querySelectorAll("[data-t]").forEach(e=>{e.textContent=L[e.dataset.t]});
const $=id=>document.getElementById(id);
const el=(tag,cls,txt)=>{const e=document.createElement(tag);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e};
const store={get(){try{return localStorage.getItem("lcPin")||""}catch(e){return ""}},set(v){try{v?localStorage.setItem("lcPin",v):localStorage.removeItem("lcPin")}catch(e){}}};
const buzz=()=>{try{navigator.vibrate&&navigator.vibrate(8)}catch(e){}};
let pin=store.get(), st=null, timer=null, failures=0, typed="";
const m=location.hash.match(/pin=(\d{4,8})/);
if(m){pin=m[1];store.set(pin);history.replaceState(null,"",location.pathname)}

/* Press feel on every key: sink + short vibration, also for keys made later. */
document.addEventListener("pointerdown",e=>{const k=e.target.closest(".key");if(k&&!k.disabled){k.classList.add("down");buzz()}},{passive:true});
const up=()=>document.querySelectorAll(".key.down").forEach(k=>k.classList.remove("down"));
document.addEventListener("pointerup",up);document.addEventListener("pointercancel",up);

async function api(path,method){
  const r=await fetch(path,{method:method||"GET",headers:{"X-LiveCore-PIN":pin},cache:"no-store"});
  if(r.status===401){signedOut(L.wrong);throw new Error("auth")}
  if(r.status===429){signedOut(L.locked.replace("{s}",r.headers.get("Retry-After")||"60"));throw new Error("locked")}
  if(!r.ok)throw new Error("http "+r.status);
  return r;
}
function send(path){api(path,"POST").then(()=>setTimeout(poll,60)).catch(()=>{})}

/* Sign in with an on-screen keypad */
function pad(){
  const p=$("pad");p.textContent="";
  ["1","2","3","4","5","6","7","8","9","⌫","0","OK"].forEach(k=>{const b=el("button","key",k);
    if(k==="OK")b.classList.add("on","blue");
    b.onclick=()=>{if(k==="⌫")typed=typed.slice(0,-1);else if(k==="OK")signIn(typed);else if(typed.length<8)typed+=k;dots()};p.appendChild(b)});
  dots();
}
function dots(){const d=$("dots");d.textContent="";for(let i=0;i<Math.max(6,typed.length);i++)d.appendChild(el("i",i<typed.length?"f":""))}
document.addEventListener("keydown",e=>{if(!$("login").classList.contains("hidden")){
  if(/^\d$/.test(e.key)&&typed.length<8)typed+=e.key;else if(e.key==="Backspace")typed=typed.slice(0,-1);else if(e.key==="Enter")signIn(typed);dots()}});
function signedOut(msg){clearInterval(timer);timer=null;stopFrames();$("app").classList.add("hidden");$("login").classList.remove("hidden");$("err").textContent=msg||"";typed="";dots()}
async function signIn(p){
  if(p)pin=p; if(!pin)return; $("err").textContent="";
  try{await api("/api/ping");store.set(pin);typed="";$("login").classList.add("hidden");$("app").classList.remove("hidden");poll();timer=setInterval(poll,250);startFrames()}
  catch(e){if(e.message!=="auth"&&e.message!=="locked")$("err").textContent=L.offline;typed="";dots()}
}
async function poll(){
  try{st=await (await api("/api/state")).json();failures=0;render()}
  catch(e){if(++failures>3)$("conn").className="led bad"}
}

/* Pictures: alternate Program / Preview, about 3 per second each, only while visible */
let frameTimer=null, frameBus=0;
const urls={};
function startFrames(){stopFrames();frameTimer=setInterval(frame,170)}
function stopFrames(){clearInterval(frameTimer);frameTimer=null}
async function frame(){
  if(!st||!st.frames||document.hidden)return;
  const bus=(frameBus^=1)?"program":"preview", img=$(bus==="program"?"imgPgm":"imgPvw");
  try{const r=await api("/api/frame?bus="+bus);if(r.status!==200)return;
    const u=URL.createObjectURL(await r.blob());img.onload=()=>{img.classList.add("ready");if(urls[bus])URL.revokeObjectURL(urls[bus]);urls[bus]=u};img.src=u}catch(e){}
}

const name=n=>{const i=st.inputs.find(x=>x.n===n);return i?n+"  "+i.name:"—"};
const hms=s=>{s=Math.max(0,Math.floor(s));const h=Math.floor(s/3600),m=Math.floor(s/60)%60,x=s%60;return[h,m,x].map(v=>String(v).padStart(2,"0")).join(":")};
const sig=a=>JSON.stringify(a);
let busSig="", ovSig="", rpSig="", kindSig="", durSig="", stripSig="";

function buildBus(box,isPgm){
  box.textContent="";
  if(!st.inputs.length){box.appendChild(el("div","empty",L.noInputs));return}
  st.inputs.forEach(i=>{const b=el("button","key "+(isPgm?"red":"green"));b.dataset.n=i.n;
    b.append(el("span","num",i.n),el("span","nm",i.name));
    b.onclick=()=>{if(isPgm){st.preview=st.program;st.program=i.n;send("/api/program?input="+i.n)}else{st.preview=i.n;send("/api/preview?input="+i.n)}render()};
    box.appendChild(b)});
}
function render(){
  $("conn").className="led ok";
  $("title").textContent=st.title;
  $("pgmName").textContent=st.program?name(st.program):"—";
  $("pvwName").textContent=st.preview?name(st.preview):"—";
  const s=sig(st.inputs);
  if(s!==busSig){busSig=s;buildBus($("pvwBus"),false);buildBus($("pgmBus"),true)}
  $("pvwBus").querySelectorAll(".key").forEach(b=>{const n=+b.dataset.n;b.classList.toggle("on",n===st.preview);b.classList.toggle("dimred",n===st.program&&n!==st.preview)});
  $("pgmBus").querySelectorAll(".key").forEach(b=>{const n=+b.dataset.n;b.classList.toggle("on",n===st.program);b.classList.toggle("dimgreen",n===st.preview&&n!==st.program)});

  const ks=sig(st.transitions);
  if(ks!==kindSig){kindSig=ks;const k=$("kinds");k.textContent="";st.transitions.forEach(t=>{const b=el("button","key blue",t.name);b.dataset.id=t.id;
    b.onclick=()=>{st.transitionKind=t.id;render();send("/api/transition?kind="+t.id)};k.appendChild(b)})}
  $("kinds").querySelectorAll(".key").forEach(b=>b.classList.toggle("on",+b.dataset.id===st.transitionKind));
  const ds=[0.5,1,1.5,2,3];
  if(!durSig){durSig="1";const d=$("durs");ds.forEach(v=>{const b=el("button","key amber",v+" s");b.dataset.v=v;
    b.onclick=()=>{st.transitionDuration=v;render();send("/api/transition?duration="+v)};d.appendChild(b)})}
  $("durs").querySelectorAll(".key").forEach(b=>b.classList.toggle("on",Math.abs(+b.dataset.v-st.transitionDuration)<0.01));
  $("auto").className="key green "+(st.transitioning?"on run":"dimgreen");
  if(!tb.drag)setLever(st.tbar);

  const os=sig(st.overlays.map(o=>[o.n,o.input]));
  if(os!==ovSig){ovSig=os;const o=$("overlays");o.textContent="";st.overlays.forEach(ov=>{const b=el("button","key");b.dataset.n=ov.n;
    b.append(el("span","num",ov.n),el("span","nm",ov.input?name(ov.input).replace(/^\d+\s+/,""):"—"));b.onclick=()=>send("/api/overlay?n="+ov.n);o.appendChild(b)})}
  st.overlays.forEach((ov,k)=>{const b=$("overlays").children[k];if(!b)return;b.classList.toggle("on",ov.on||ov.preview);
    b.classList.toggle("red",ov.on);b.classList.toggle("amber",ov.preview&&!ov.on);b.disabled=!ov.input});
  const rs=sig(st.replayLengths);
  if(rs!==rpSig){rpSig=rs;const r=$("replays");r.textContent="";st.replayLengths.forEach(s=>{const b=el("button","key amber");b.dataset.s=s;
    b.append(el("span","num",s),el("span","nm","sec"));b.onclick=()=>send("/api/replay?sec="+s);r.appendChild(b)})}
  [...$("replays").children].forEach(b=>{b.disabled=st.replayAvailable<+b.dataset.s});

  $("rec").className="key red"+(st.recording?" on":"");$("live").className="key red"+(st.streaming?" on":"");
  $("rec").querySelector("time").textContent=hms(st.recordTime);$("live").querySelector("time").textContent=hms(st.streamTime);
  $("recT").classList.toggle("on",st.recording);$("liveT").classList.toggle("on",st.streaming);
  $("recT").querySelector("time").textContent=hms(st.recordTime);$("liveT").querySelector("time").textContent=hms(st.streamTime);
  $("locks").textContent=[st.recordLocked?L.recLocked:"",st.streamLocked?L.liveLocked:""].filter(Boolean).join(" ");
  renderAudio();
}

/* T-bar lever: drag anywhere on the slot; horizontal on phones, vertical on tablets */
const tb={drag:false,last:0,timer:null,val:0};
const vertical=()=>matchMedia("(min-width:900px)").matches;
function setLever(v){
  tb.val=v;const lv=$("lever"),f=$("fill"),slot=$("slot");
  const rest=st?st.tbarRest:0, lo=Math.min(v,rest), hi=Math.max(v,rest);
  const P=pad0();
  if(vertical()){const h=slot.clientHeight-2*P;lv.style.left="";lv.style.top=(P+v*h)+"px";f.style.top=(P+lo*h)+"px";f.style.height=((hi-lo)*h)+"px";f.style.left="";f.style.width=""}
  else{const w=slot.clientWidth-2*P;lv.style.top="";lv.style.left=(P+v*w)+"px";f.style.left=(P+lo*w)+"px";f.style.width=((hi-lo)*w)+"px";f.style.top="";f.style.height=""}
  $("tbPct").textContent=Math.round(Math.abs(v-rest)*100)+"%";
}
/* Inset of the lever's travel: half the handle, so it never leaves the slot */
const pad0=()=>vertical()?24:26;
function tbFromEvent(e){const r=$("slot").getBoundingClientRect(),P=pad0();
  const v=vertical()?(e.clientY-r.top-P)/(r.height-2*P):(e.clientX-r.left-P)/(r.width-2*P);return Math.min(1,Math.max(0,v))}
const capture=(n,e)=>{try{n.setPointerCapture(e.pointerId)}catch(x){}};
function tbSend(){tb.last=Date.now();tb.timer=null;api("/api/tbar?value="+tb.val.toFixed(3),"POST").catch(()=>{})}
$("slot").addEventListener("pointerdown",e=>{e.preventDefault();tb.drag=true;$("slot").classList.add("drag");capture($("slot"),e);setLever(tbFromEvent(e));tbSend();buzz()});
$("slot").addEventListener("pointermove",e=>{if(!tb.drag)return;const v=tbFromEvent(e);if(Math.abs(v-tb.val)<0.002)return;setLever(v);
  if((v===0||v===1))buzz();if(Date.now()-tb.last>50)tbSend();else if(!tb.timer)tb.timer=setTimeout(tbSend,50)});
const tbEnd=()=>{if(!tb.drag)return;clearTimeout(tb.timer);tbSend();$("slot").classList.remove("drag");setTimeout(()=>{tb.drag=false},350)};
$("slot").addEventListener("pointerup",tbEnd);$("slot").addEventListener("pointercancel",tbEnd);
addEventListener("resize",()=>{if(st)setLever(tb.drag?tb.val:st.tbar)});

/* Audio mixer strips */
const fz={id:null,val:0,last:0,timer:null};
const dbPct=d=>Math.min(1,Math.max(0,(d+60)/60));
/* Same fader law as the app (FaderLaw): 0.75 = 0 dB, top = +10 dB, 0.25 = -30 dB */
function faderDB(p){if(p<=0.0001)return"-∞";const d=p>=0.75?(p-0.75)/0.25*10:(p>=0.25?(p-0.75)/0.5*30:-30-(0.25-p)/0.25*60);return(d>0?"+":"")+d.toFixed(1)}
function buildStrips(){
  const box=$("strips");box.textContent="";
  const all=[Object.assign({master:true},st.master)].concat(st.channels);
  all.forEach(c=>{const s=el("div","strip"+(c.master?" master":""));s.dataset.id=c.id;
    const nm=el("div","nm",c.master?"MASTER":c.name), db=el("div","db","");
    const fzw=el("div","fz"), ml=el("div","meter"), mr=el("div","meter"), fd=el("div","fader"), cap=el("div","cap");
    ml.appendChild(el("i"));mr.appendChild(el("i"));fd.appendChild(cap);fzw.append(ml,fd,mr);
    const mute=el("button","key red",L.mute);
    if(c.master)mute.style.visibility="hidden";
    mute.onclick=()=>{const on=!mute.classList.contains("on");mute.classList.toggle("on",on);send("/api/audio/mute?id="+encodeURIComponent(c.id)+"&on="+(on?1:0))};
    const pos=e=>{const r=fd.getBoundingClientRect();return Math.min(1,Math.max(0,1-(e.clientY-r.top-12)/(r.height-24)))};
    const put=v=>{fz.val=v;cap.style.top=(12+(1-v)*(fd.clientHeight-24))+"px";db.textContent=faderDB(v)};
    const go=()=>{fz.last=Date.now();fz.timer=null;send(c.master?"/api/audio/master?fader="+fz.val.toFixed(3):"/api/audio/fader?id="+encodeURIComponent(c.id)+"&value="+fz.val.toFixed(3))};
    fd.addEventListener("pointerdown",e=>{e.preventDefault();fz.id=c.id;capture(fd,e);put(pos(e));go();buzz()});
    fd.addEventListener("pointermove",e=>{if(fz.id!==c.id)return;put(pos(e));if(Date.now()-fz.last>60)go();else if(!fz.timer)fz.timer=setTimeout(go,60)});
    const end=()=>{if(fz.id!==c.id)return;clearTimeout(fz.timer);go();setTimeout(()=>{if(fz.id===c.id)fz.id=null},400)};
    fd.addEventListener("pointerup",end);fd.addEventListener("pointercancel",end);
    s._put=put;s._mute=mute;s._ml=ml.firstChild;s._mr=mr.firstChild;
    s.append(nm,fzw,db,mute);box.appendChild(s)});
  if(!st.channels.length)box.appendChild(el("div","empty",L.noAudio));
}
function renderAudio(){
  const ss=sig(st.channels.map(c=>[c.id,c.name]));
  if(ss!==stripSig){stripSig=ss;buildStrips()}
  const all=[st.master].concat(st.channels);
  [...$("strips").querySelectorAll(".strip")].forEach((s,k)=>{const c=all[k];if(!c)return;
    if(fz.id!==c.id)s._put(c.fader);s._mute.classList.toggle("on",!!c.muted);
    s._ml.style.height=(100-dbPct(c.l)*100)+"%";s._mr.style.height=(100-dbPct(c.r)*100)+"%"});
}

/* Buttons */
$("out").onclick=()=>{store.set("");pin="";signedOut("")};
$("cut").onclick=()=>{if(st&&st.preview){const p=st.program;st.program=st.preview;st.preview=p;render()}send("/api/cut")};
$("auto").onclick=()=>send("/api/auto");
$("snap").onclick=()=>send("/api/snapshot");
$("rec").onclick=()=>{if(!st)return;if(st.recordLocked){alert(L.recLocked);return}
  if(st.recording){if(confirm(L.stopRec))send("/api/record/stop")}else send("/api/record/start")};
$("live").onclick=()=>{if(!st)return;if(st.streamLocked){alert(L.liveLocked);return}
  if(st.streaming){if(confirm(L.stopLive))send("/api/stream/stop")}else if(confirm(L.startLive))send("/api/stream/start")};
$("cut").classList.add("dimred");$("auto").classList.add("dimgreen");
pad();
if(pin)signIn();
</script>
</body>
</html>
"""#
}
