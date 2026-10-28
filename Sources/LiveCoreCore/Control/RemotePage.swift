/// The Web Controller page served at "/": one self-contained HTML file (no external
/// scripts, fonts or images) for phones and tablets. It signs in with the PIN, polls
/// /api/state and sends POST /api/... commands with the PIN in the X-LiveCore-PIN header.
public enum RemotePage {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#111317">
<title>LiveCore Remote</title>
<style>
:root{--bg:#111317;--panel:#1b1e24;--line:#2b3038;--text:#e9ecf1;--dim:#8d95a3;--pgm:#e5484d;--pvw:#30a46c;--acc:#3b82f6;--warn:#f5a524}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--text);font:15px/1.35 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
body{padding:12px 16px calc(16px + env(safe-area-inset-bottom))}
header{display:flex;align-items:center;gap:8px;margin-bottom:12px}
header h1{font-size:16px;margin:0;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pill{font-size:11px;font-weight:700;letter-spacing:.04em;padding:3px 8px;border-radius:999px;background:var(--panel);color:var(--dim);border:1px solid var(--line)}
.pill.live{background:var(--pgm);color:#fff;border-color:var(--pgm)}
.pill.rec{background:#b42318;color:#fff;border-color:#b42318}
.dot{width:9px;height:9px;border-radius:50%;background:var(--dim)}
.dot.ok{background:var(--pvw)}.dot.bad{background:var(--pgm)}
section{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px;margin-bottom:12px}
h2{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:0 0 8px}
.buses{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.bus{border-radius:8px;padding:8px 10px;border:2px solid var(--line);min-height:52px}
.bus small{display:block;font-size:11px;font-weight:700;letter-spacing:.06em}
.bus.p{border-color:var(--pgm)}.bus.p small{color:var(--pgm)}
.bus.v{border-color:var(--pvw)}.bus.v small{color:var(--pvw)}
.bus b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(96px,1fr));gap:8px}
button{font:inherit;color:var(--text);background:#262a32;border:2px solid var(--line);border-radius:10px;padding:10px;min-height:48px;cursor:pointer;touch-action:manipulation}
button:active{filter:brightness(1.3)}
button:disabled{opacity:.4}
.in{text-align:left;min-height:64px;display:flex;flex-direction:column;justify-content:space-between}
.in .n{font-size:12px;color:var(--dim);font-weight:700}
.in .t{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;width:100%}
.in.p{border-color:var(--pgm);background:#3a1d20}.in.p .n{color:var(--pgm)}
.in.v{border-color:var(--pvw);background:#17311f}.in.v .n{color:var(--pvw)}
.seg{display:flex;background:#262a32;border-radius:9px;padding:3px;margin-bottom:8px}
.seg button{flex:1;min-height:34px;padding:4px;border:0;background:transparent;font-size:13px}
.seg button.on{background:var(--acc);color:#fff}
.row{display:flex;gap:8px}.row>*{flex:1}
.big{font-size:18px;font-weight:800;letter-spacing:.06em;min-height:64px}
#cut{background:#3a1d20;border-color:var(--pgm)}
#auto{background:#17311f;border-color:var(--pvw)}
.tb{display:flex;align-items:center;gap:12px;margin-top:12px}
.tb input{flex:1;height:40px;accent-color:var(--acc)}
.tb span{width:44px;text-align:right;font-variant-numeric:tabular-nums;font-weight:700}
.toggle.on{background:var(--acc);border-color:var(--acc);color:#fff}
.toggle.red.on{background:var(--pgm);border-color:var(--pgm)}
.note{font-size:12px;color:var(--dim);margin-top:8px}
#login{max-width:360px;margin:12vh auto 0;text-align:center}
#login input{width:100%;font:inherit;font-size:28px;letter-spacing:.3em;text-align:center;padding:12px;border-radius:10px;border:2px solid var(--line);background:var(--panel);color:var(--text);margin:12px 0}
#login button{width:100%;background:var(--acc);border-color:var(--acc);color:#fff;font-weight:700}
#err{color:var(--warn);min-height:20px;margin-top:10px}
.hidden{display:none!important}
</style>
</head>
<body>
<div id="login">
  <h1>LiveCore Remote</h1>
  <p class="note" data-t="pinHint"></p>
  <input id="pin" type="password" inputmode="numeric" autocomplete="off" maxlength="8" pattern="[0-9]*">
  <button id="go" data-t="signIn"></button>
  <div id="err"></div>
</div>
<div id="app" class="hidden">
  <header>
    <span id="conn" class="dot"></span>
    <h1 id="title">LiveCore Studio</h1>
    <span id="recPill" class="pill">REC</span>
    <span id="livePill" class="pill">LIVE</span>
  </header>
  <section>
    <div class="buses">
      <div class="bus p"><small>PROGRAM</small><b id="pgmName">—</b></div>
      <div class="bus v"><small>PREVIEW</small><b id="pvwName">—</b></div>
    </div>
  </section>
  <section>
    <h2 data-t="inputs"></h2>
    <div class="seg"><button id="modePvw" class="on" data-t="tapPreview"></button><button id="modePgm" data-t="tapProgram"></button></div>
    <div id="inputs" class="grid"></div>
  </section>
  <section>
    <div class="row"><button id="cut" class="big">CUT</button><button id="auto" class="big">AUTO</button></div>
    <div class="tb"><input id="tbar" type="range" min="0" max="1000" value="0"><span id="tbPct">0%</span></div>
    <div class="note" id="trName"></div>
  </section>
  <section>
    <h2>Overlay</h2>
    <div id="overlays" class="row"></div>
  </section>
  <section>
    <h2 data-t="replay"></h2>
    <div id="replays" class="row"></div>
  </section>
  <section>
    <h2 data-t="output"></h2>
    <div class="row">
      <button id="rec" class="toggle red" data-t="record"></button>
      <button id="live" class="toggle red" data-t="stream"></button>
      <button id="snap" data-t="snapshot"></button>
    </div>
    <div class="note" id="locks"></div>
  </section>
  <div class="row"><button id="out" data-t="signOut"></button></div>
</div>
<script>
"use strict";
const T={
 en:{pinHint:"Enter the PIN shown in LiveCore Studio › Settings › Remote.",signIn:"Sign in",inputs:"Inputs",tapPreview:"Tap = Preview",tapProgram:"Tap = Program",replay:"Instant replay",output:"Record & stream",record:"Record",stream:"Stream",recStop:"Stop rec",liveStop:"Stop stream",snapshot:"Snapshot",signOut:"Sign out",wrong:"Wrong PIN.",locked:"Too many wrong PINs. Try again in {s} s.",offline:"Cannot reach LiveCore Studio.",stopRec:"Stop recording?",stopLive:"Stop streaming?",startLive:"Start streaming?",recLocked:"Recording is locked in the app.",liveLocked:"Streaming is locked in the app.",noInputs:"No inputs yet."},
 id:{pinHint:"Masukkan PIN yang tampil di LiveCore Studio › Settings › Remote.",signIn:"Masuk",inputs:"Input",tapPreview:"Ketuk = Preview",tapProgram:"Ketuk = Program",replay:"Instant replay",output:"Rekam & stream",record:"Rekam",stream:"Stream",recStop:"Stop rekam",liveStop:"Stop stream",snapshot:"Snapshot",signOut:"Keluar",wrong:"PIN salah.",locked:"Terlalu banyak PIN salah. Coba lagi dalam {s} detik.",offline:"LiveCore Studio tidak terjangkau.",stopRec:"Hentikan rekaman?",stopLive:"Hentikan streaming?",startLive:"Mulai streaming?",recLocked:"Rekaman dikunci di aplikasi.",liveLocked:"Streaming dikunci di aplikasi.",noInputs:"Belum ada input."}
};
const L=T[(navigator.language||"en").slice(0,2)]||T.en;
document.documentElement.lang=T[(navigator.language||"en").slice(0,2)]?(navigator.language||"en").slice(0,2):"en";
document.querySelectorAll("[data-t]").forEach(e=>{e.textContent=L[e.dataset.t]});
const $=id=>document.getElementById(id);
const store={get(){try{return localStorage.getItem("lcPin")||""}catch(e){return ""}},set(v){try{v?localStorage.setItem("lcPin",v):localStorage.removeItem("lcPin")}catch(e){}}};
let pin=store.get(), st=null, mode="preview", dragging=false, timer=null, failures=0;
const m=location.hash.match(/pin=(\d{4,8})/);
if(m){pin=m[1];store.set(pin);history.replaceState(null,"",location.pathname)}

async function api(path,method){
  const r=await fetch(path,{method:method||"GET",headers:{"X-LiveCore-PIN":pin},cache:"no-store"});
  if(r.status===401){signedOut(L.wrong);throw new Error("auth")}
  if(r.status===429){const s=r.headers.get("Retry-After")||"60";signedOut(L.locked.replace("{s}",s));throw new Error("locked")}
  if(!r.ok)throw new Error("http "+r.status);
  return r.json();
}
function send(path){api(path,"POST").then(poll).catch(()=>{})}
function signedOut(msg){clearInterval(timer);timer=null;$("app").classList.add("hidden");$("login").classList.remove("hidden");$("err").textContent=msg||""}
async function signIn(){
  pin=$("pin").value.trim()||pin; $("err").textContent="";
  try{await api("/api/ping");store.set(pin);$("login").classList.add("hidden");$("app").classList.remove("hidden");poll();timer=setInterval(poll,500)}
  catch(e){if(e.message!=="auth"&&e.message!=="locked")$("err").textContent=L.offline}
}
async function poll(){
  try{st=await api("/api/state");failures=0;render()}
  catch(e){if(++failures>2)$("conn").className="dot bad"}
}
function name(n){const i=st.inputs.find(x=>x.n===n);return i?n+"  "+i.name:"—"}
function render(){
  $("conn").className="dot ok";
  $("title").textContent=st.title;
  $("pgmName").textContent=st.program?name(st.program):"—";
  $("pvwName").textContent=st.preview?name(st.preview):"—";
  const g=$("inputs");
  if(g.childElementCount!==st.inputs.length||[...g.children].some((b,k)=>b.dataset.key!==st.inputs[k].n+"|"+st.inputs[k].name)){
    g.textContent="";
    if(!st.inputs.length){const d=document.createElement("div");d.className="note";d.textContent=L.noInputs;g.appendChild(d)}
    st.inputs.forEach(i=>{const b=document.createElement("button");b.className="in";b.dataset.key=i.n+"|"+i.name;b.dataset.n=i.n;
      const n=document.createElement("span");n.className="n";n.textContent=i.n;const t=document.createElement("span");t.className="t";t.textContent=i.name;
      b.append(n,t);b.onclick=()=>send((mode==="preview"?"/api/preview":"/api/program")+"?input="+i.n);g.appendChild(b)});
  }
  [...g.querySelectorAll(".in")].forEach(b=>{const n=+b.dataset.n;b.classList.toggle("p",n===st.program);b.classList.toggle("v",n===st.preview&&n!==st.program)});
  if(!dragging)$("tbar").value=Math.round(st.tbar*1000);
  $("tbPct").textContent=Math.round(Math.abs((dragging?$("tbar").value/1000:st.tbar)-st.tbarRest)*100)+"%";
  $("trName").textContent=st.transition;
  const o=$("overlays");
  if(o.childElementCount!==st.overlays.length){o.textContent="";st.overlays.forEach(ov=>{const b=document.createElement("button");b.className="toggle";b.textContent=ov.n;b.onclick=()=>send("/api/overlay?n="+ov.n);o.appendChild(b)})}
  st.overlays.forEach((ov,k)=>{const b=o.children[k];b.classList.toggle("on",ov.on);b.style.borderColor=ov.preview&&!ov.on?"var(--pvw)":"";b.disabled=!ov.input})
  const r=$("replays");
  if(r.childElementCount!==st.replayLengths.length){r.textContent="";st.replayLengths.forEach(s=>{const b=document.createElement("button");b.textContent=s+" s";b.dataset.s=s;b.onclick=()=>send("/api/replay?sec="+s);r.appendChild(b)})}
  [...r.children].forEach(b=>{b.disabled=st.replayAvailable<+b.dataset.s});
  $("rec").classList.toggle("on",st.recording);$("live").classList.toggle("on",st.streaming);
  $("rec").textContent=st.recording?L.recStop:L.record;$("live").textContent=st.streaming?L.liveStop:L.stream;
  $("recPill").classList.toggle("rec",st.recording);$("livePill").classList.toggle("live",st.streaming);
  $("locks").textContent=[st.recordLocked?L.recLocked:"",st.streamLocked?L.liveLocked:""].filter(Boolean).join(" ");
}
$("go").onclick=signIn;
$("pin").onkeydown=e=>{if(e.key==="Enter")signIn()};
$("out").onclick=()=>{store.set("");pin="";signedOut("")};
$("modePvw").onclick=()=>{mode="preview";$("modePvw").classList.add("on");$("modePgm").classList.remove("on")};
$("modePgm").onclick=()=>{mode="program";$("modePgm").classList.add("on");$("modePvw").classList.remove("on")};
$("cut").onclick=()=>send("/api/cut");
$("auto").onclick=()=>send("/api/auto");
$("snap").onclick=()=>send("/api/snapshot");
$("rec").onclick=()=>{if(!st)return;if(st.recordLocked){alert(L.recLocked);return}
  if(st.recording){if(confirm(L.stopRec))send("/api/record/stop")}else send("/api/record/start")};
$("live").onclick=()=>{if(!st)return;if(st.streamLocked){alert(L.liveLocked);return}
  if(st.streaming){if(confirm(L.stopLive))send("/api/stream/stop")}else if(confirm(L.startLive))send("/api/stream/start")};
let lastSent=0,pending=null;
function sendTbar(){const v=($("tbar").value/1000).toFixed(3);lastSent=Date.now();pending=null;api("/api/tbar?value="+v,"POST").catch(()=>{})}
$("tbar").addEventListener("input",()=>{dragging=true;if(st)$("tbPct").textContent=Math.round(Math.abs($("tbar").value/1000-st.tbarRest)*100)+"%";
  if(Date.now()-lastSent>60)sendTbar();else if(!pending)pending=setTimeout(sendTbar,60)});
$("tbar").addEventListener("change",()=>{clearTimeout(pending);sendTbar();setTimeout(()=>{dragging=false},300)});
if(pin){$("pin").value="";signIn()}
</script>
</body>
</html>
"""#
}
