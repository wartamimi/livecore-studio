/// LCS Live pages (0.52.0). Plain HTML + JavaScript, no external files or libraries.
enum LiveCallPages {
    static let closed = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>LCS Live</title><style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0e1116;color:#cfd6e2;font:16px -apple-system,Segoe UI,Roboto,sans-serif;text-align:center;padding:24px;box-sizing:border-box}</style></head>
    <body><div><h2>LCS Live</h2><p>This call link is not open (any more).<br>Link panggilan ini tidak aktif.</p></div></body></html>
    """

    /// Loaded by the app's own web view from http://127.0.0.1 (a secure context). The app drives it
    /// through `lcs.*` calls and receives answers, state and the guest's sound through
    /// window.webkit.messageHandlers.lcs.
    static let host = #"""
    <!doctype html><html><head><meta charset="utf-8"><title>LCS Live host</title>
    <style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
    video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}
    #idle{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;color:#d8dee9;font:600 5vh -apple-system,Helvetica,sans-serif;text-align:center;background:radial-gradient(circle at 50% 40%,#1b2433,#05070a)}
    #idle small{display:block;font-weight:400;font-size:2.8vh;color:#8d97a8;margin-top:1.4vh}</style></head>
    <body><video id="v" autoplay playsinline muted></video><div id="idle"><div id="it">LCS Live</div><small id="is">Waiting for guest…</small></div>
    <script>
    (()=>{
    const post=m=>{try{window.webkit.messageHandlers.lcs.postMessage(m)}catch(e){}};
    const v=document.getElementById('v'),idle=document.getElementById('idle'),is=document.getElementById('is');
    let pc=null,ac=null,dest=null,atrack=null,canvas=null,cctx=null,vtrack=null,tap=null,src=null,t0=0,rate=48000;
    const log=s=>post({t:'log',s:String(s)});
    function b64(buf){const u=new Uint8Array(buf);let s='';for(let i=0;i<u.length;i+=32768)s+=String.fromCharCode.apply(null,u.subarray(i,i+32768));return btoa(s)}
    function audio(){
      if(ac)return;
      try{ac=new AudioContext({sampleRate:rate})}catch(e){ac=new AudioContext()}
      dest=ac.createMediaStreamDestination();atrack=dest.stream.getAudioTracks()[0];
      ac.resume().catch(()=>{});
    }
    function pic(){
      if(canvas)return;
      canvas=document.createElement('canvas');canvas.width=640;canvas.height=360;cctx=canvas.getContext('2d');
      cctx.fillStyle='#000';cctx.fillRect(0,0,640,360);
      vtrack=canvas.captureStream(15).getVideoTracks()[0];
    }
    function sendPCM(l,r){
      const n=l.length,b=new Int16Array(n*2);
      for(let i=0;i<n;i++){let a=l[i],c=r[i];a=a<-1?-1:a>1?1:a;c=c<-1?-1:c>1?1:c;b[2*i]=a*32767;b[2*i+1]=c*32767}
      post({t:'pcm',rate:ac.sampleRate,d:b64(b.buffer)});
    }
    async function makeTap(){
      if(tap)return;
      try{
        const code="class T extends AudioWorkletProcessor{constructor(){super();this.n=0;this.l=new Float32Array(960);this.r=new Float32Array(960)}process(i){const x=i[0];if(x&&x.length){const L=x[0],R=x[1]||x[0];for(let k=0;k<L.length;k++){this.l[this.n]=L[k];this.r[this.n]=R[k];if(++this.n===960){this.port.postMessage([this.l.slice(),this.r.slice()]);this.n=0}}}return true}}registerProcessor('lcs-tap',T)";
        await ac.audioWorklet.addModule(URL.createObjectURL(new Blob([code],{type:'application/javascript'})));
        tap=new AudioWorkletNode(ac,'lcs-tap',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[2]});
        tap.port.onmessage=e=>sendPCM(e.data[0],e.data[1]);
      }catch(e){
        log('worklet unavailable, using ScriptProcessor: '+e);
        tap=ac.createScriptProcessor(1024,2,2);
        tap.onaudioprocess=e=>{const ib=e.inputBuffer;sendPCM(ib.getChannelData(0).slice(),(ib.numberOfChannels>1?ib.getChannelData(1):ib.getChannelData(0)).slice())};
      }
      const g=ac.createGain();g.gain.value=0;tap.connect(g);g.connect(ac.destination);
    }
    async function listen(track){
      audio();await makeTap();
      if(src){try{src.disconnect()}catch(e){}}
      src=ac.createMediaStreamSource(new MediaStream([track]));src.connect(tap);
      ac.resume().catch(()=>{});
    }
    function gathered(p,ms){return new Promise(res=>{if(p.iceGatheringState==='complete')return res();const t=setTimeout(res,ms);p.addEventListener('icegatheringstatechange',()=>{if(p.iceGatheringState==='complete'){clearTimeout(t);res()}})})}
    function show(s){const live=s==='connected';idle.style.display=live?'none':'flex';if(!live)is.textContent=s==='idle'?'Waiting for guest…':s==='connecting'?'Connecting…':'Guest disconnected · waiting…'}
    window.lcs={
      setup(r,title){rate=r||48000;document.getElementById('it').textContent=title||'LCS Live'},
      async offer(seq,sdp,ice){
        try{
          if(pc){try{pc.close()}catch(e){}}
          audio();pic();
          const p=new RTCPeerConnection({iceServers:ice});pc=p;show('connecting');
          p.ontrack=e=>{if(p!==pc)return;
            if(e.track.kind==='video'){v.srcObject=new MediaStream([e.track]);v.play().catch(()=>{})}
            else listen(e.track).catch(x=>log('audio: '+x));};
          const st=()=>{if(p!==pc)return;const s=p.connectionState||p.iceConnectionState;post({t:'state',seq,s});show(s==='completed'?'connected':s)};
          p.onconnectionstatechange=st;p.oniceconnectionstatechange=st;
          await p.setRemoteDescription({type:'offer',sdp});
          for(const t of p.getTransceivers()){
            const k=t.receiver&&t.receiver.track&&t.receiver.track.kind;
            if(k==='video'&&vtrack){await t.sender.replaceTrack(vtrack);t.direction='sendrecv'}
            if(k==='audio'&&atrack){await t.sender.replaceTrack(atrack);t.direction='sendrecv'}
          }
          await p.setLocalDescription(await p.createAnswer());
          await gathered(p,4000);
          if(p!==pc)return;
          post({t:'answer',seq,sdp:p.localDescription.sdp});
        }catch(e){post({t:'error',seq,s:String(e)})}
      },
      hangup(){if(pc){try{pc.close()}catch(e){}pc=null}v.srcObject=null;show('idle')},
      frame(b){if(!cctx)return;const i=new Image();i.onload=()=>{cctx.drawImage(i,0,0,640,360)};i.src='data:image/jpeg;base64,'+b},
      blank(){if(cctx){cctx.fillStyle='#000';cctx.fillRect(0,0,640,360)}},
      audio(b){
        if(!ac||!dest)return;
        const s=atob(b),u=new Uint8Array(s.length);for(let i=0;i<s.length;i++)u[i]=s.charCodeAt(i);
        const p=new Int16Array(u.buffer),n=p.length>>1;if(!n)return;
        const buf=ac.createBuffer(2,n,ac.sampleRate),L=buf.getChannelData(0),R=buf.getChannelData(1);
        for(let i=0;i<n;i++){L[i]=p[2*i]/32768;R[i]=p[2*i+1]/32768}
        const x=ac.createBufferSource();x.buffer=buf;x.connect(dest);
        const now=ac.currentTime;if(t0<now+0.02||t0>now+0.4)t0=now+0.08;
        x.start(t0);t0+=n/ac.sampleRate;
      }
    };
    show('idle');post({t:'ready'});
    })();
    </script></body></html>
    """#

    /// The guest's page (opened from the link, ideally over https).
    static let guest = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <title>LCS Live</title>
    <style>
    *{box-sizing:border-box}body{margin:0;min-height:100vh;background:#0e1116;color:#e6eaf2;font:15px -apple-system,Segoe UI,Roboto,sans-serif}
    header{display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid #222a36}
    header b{background:#d92d3a;color:#fff;border-radius:5px;padding:2px 7px;font-size:12px;letter-spacing:.5px}
    header span{font-weight:600}
    main{max-width:980px;margin:0 auto;padding:16px}
    .stage{position:relative;background:#000;border-radius:10px;overflow:hidden;aspect-ratio:16/9}
    .stage video{width:100%;height:100%;object-fit:contain;background:#000}
    #me{position:absolute;right:10px;bottom:10px;width:28%;max-width:240px;aspect-ratio:16/9;border-radius:8px;border:2px solid #fff3;background:#111;object-fit:cover;transform:scaleX(-1)}
    #msg{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;text-align:center;padding:20px;color:#aab3c3;pointer-events:none}
    .row{display:flex;flex-wrap:wrap;gap:10px;margin:14px 0;align-items:center}
    input,select{background:#161b23;color:inherit;border:1px solid #2c3442;border-radius:8px;padding:10px;font:inherit;min-width:0}
    input{flex:1 1 200px}select{flex:1 1 180px}
    button{border:0;border-radius:8px;padding:11px 16px;font:600 15px inherit;font-family:inherit;color:#fff;background:#2a3140;cursor:pointer}
    button.go{background:#1f8f4e}button.end{background:#c62f3b}button.off{background:#6b2a2a}
    #status{color:#9aa4b5;font-size:13px}.note{color:#7f899b;font-size:12px;line-height:1.5}
    .hide{display:none!important}
    </style></head><body>
    <header><b>LIVE</b><span id="title">LCS Live</span></header>
    <main>
      <div class="stage"><video id="ret" autoplay playsinline></video><video id="me" autoplay playsinline muted></video><div id="msg"></div></div>
      <div id="join">
        <div class="row"><input id="name" maxlength="40" autocomplete="name"><button id="go" class="go"></button></div>
        <div class="row"><select id="cam"></select><select id="mic"></select></div>
        <p class="note" id="tip"></p>
      </div>
      <div id="incall" class="hide">
        <div class="row"><button id="bmic"></button><button id="bcam"></button><button id="bend" class="end"></button></div>
      </div>
      <div id="status"></div>
    </main>
    <script>
    (()=>{
    const id=/^id\b/i.test(navigator.language||'');
    const T=id?{name:'Nama Anda',join:'Gabung',tip:'Gunakan headphone agar suara acara tidak masuk kembali ke mikrofon. Izinkan akses kamera dan mikrofon saat diminta.',mute:'Matikan mic',unmute:'Nyalakan mic',camOff:'Matikan kamera',camOn:'Nyalakan kamera',end:'Tutup',wait:'Menunggu studio menerima…',connecting:'Menyambung…',live:'Terhubung ke studio',lost:'Koneksi terputus, menyambung ulang…',ended:'Panggilan selesai.',replaced:'Link ini dibuka di perangkat lain.',closed:'Link panggilan tidak aktif.',nomedia:'Kamera/mikrofon tidak bisa dibuka: ',insecure:'Kamera butuh koneksi https. Buka link online (https) dari studio.',noanswer:'Studio belum menjawab. Coba lagi.',preview:'Pratinjau kamera Anda',ret:'Gambar program dari studio akan tampil di sini.'}
             :{name:'Your name',join:'Join',tip:'Use headphones so the show sound does not go back into your microphone. Allow camera and microphone access when asked.',mute:'Mute mic',unmute:'Unmute mic',camOff:'Camera off',camOn:'Camera on',end:'Hang up',wait:'Waiting for the studio to accept…',connecting:'Connecting…',live:'Connected to the studio',lost:'Connection lost, reconnecting…',ended:'Call ended.',replaced:'This link was opened on another device.',closed:'This call link is not open.',nomedia:'Cannot open camera/microphone: ',insecure:'The camera needs an https connection. Open the online (https) link from the studio.',noanswer:'The studio did not answer. Try again.',preview:'Your camera preview',ret:'The program picture from the studio appears here.'};
    const $=x=>document.getElementById(x);
    const key=location.pathname.split('/').filter(Boolean)[1]||'';
    const api='/live/api/'+encodeURIComponent(key)+'/';
    let info=null,local=null,pc=null,seq=0,live=false,ended=false,retry=null,pinger=null,lostAt=0;
    $('name').placeholder=T.name;$('go').textContent=T.join;$('tip').textContent=T.tip;$('bend').textContent=T.end;
    $('bmic').textContent=T.mute;$('bcam').textContent=T.camOff;$('msg').textContent=T.ret;
    try{$('name').value=localStorage.getItem('lcs-name')||''}catch(e){}
    const status=s=>{$('status').textContent=s};
    const sleep=ms=>new Promise(r=>setTimeout(r,ms));
    fetch(api+'info',{cache:'no-store'}).then(r=>r.ok?r.json():Promise.reject()).then(j=>{info=j;$('title').textContent=j.title||'LCS Live';document.title=(j.title||'LCS Live')+' · LCS Live'}).catch(()=>status(T.closed));
    if(!window.isSecureContext||!navigator.mediaDevices){status(T.insecure)}
    async function devices(){
      try{const d=await navigator.mediaDevices.enumerateDevices();
        const fill=(sel,kind)=>{const cur=sel.value;sel.innerHTML='';d.filter(x=>x.kind===kind).forEach((x,i)=>{const o=document.createElement('option');o.value=x.deviceId;o.textContent=x.label||(kind==='videoinput'?'Camera ':'Microphone ')+(i+1);sel.appendChild(o)});if(cur)sel.value=cur};
        fill($('cam'),'videoinput');fill($('mic'),'audioinput');}catch(e){}
    }
    async function openMedia(){
      const cam=$('cam').value,mic=$('mic').value;
      const a={echoCancellation:true,noiseSuppression:true,autoGainControl:true};if(mic)a.deviceId={exact:mic};
      const v={width:{ideal:1280},height:{ideal:720},frameRate:{ideal:30}};if(cam)v.deviceId={exact:cam};
      try{return await navigator.mediaDevices.getUserMedia({audio:a,video:v})}
      catch(e){try{return await navigator.mediaDevices.getUserMedia({audio:a})}catch(e2){throw e}}
    }
    devices();
    function gathered(p,ms){return new Promise(res=>{if(p.iceGatheringState==='complete')return res();const t=setTimeout(res,ms);p.addEventListener('icegatheringstatechange',()=>{if(p.iceGatheringState==='complete'){clearTimeout(t);res()}})})}
    async function connect(){
      clearTimeout(retry);if(ended)return;
      if(pc){try{pc.close()}catch(e){}}
      live=false;status(T.connecting);
      const p=new RTCPeerConnection({iceServers:(info&&info.ice)||[{urls:'stun:stun.l.google.com:19302'}]});pc=p;
      local.getTracks().forEach(t=>p.addTrack(t,local));
      if(!local.getVideoTracks().length)p.addTransceiver('video',{direction:'recvonly'});
      p.ontrack=e=>{const r=$('ret');if(!r.srcObject)r.srcObject=new MediaStream();r.srcObject.getTracks().filter(t=>t.kind===e.track.kind).forEach(t=>r.srcObject.removeTrack(t));r.srcObject.addTrack(e.track);r.play().catch(()=>{});$('msg').textContent=''};
      p.onconnectionstatechange=p.oniceconnectionstatechange=()=>{
        if(p!==pc)return;const s=p.connectionState||p.iceConnectionState;
        if(s==='connected'||s==='completed'){live=true;lostAt=0;status(T.live);tune(p)}
        else if(s==='failed'){live=false;status(T.lost);retry=setTimeout(connect,2000)}
        else if(s==='disconnected'){status(T.lost);lostAt=Date.now();setTimeout(()=>{if(p===pc&&lostAt&&Date.now()-lostAt>=6000)connect()},6500)}
      };
      try{
        await p.setLocalDescription(await p.createOffer());
        await gathered(p,4000);
        const r=await fetch(api+'offer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sdp:p.localDescription.sdp,name:$('name').value})});
        if(r.status===404){status(T.closed);return hang(false)}
        seq=(await r.json()).seq;status(T.wait);
        for(let i=0;i<150&&p===pc&&!ended;i++){
          const a=await fetch(api+'answer?seq='+seq,{cache:'no-store'});
          if(a.status===200){const j=await a.json();await p.setRemoteDescription({type:'answer',sdp:j.sdp});return}
          if(a.status===409){status(T.replaced);return hang(false)}
          if(a.status===404){status(T.closed);return hang(false)}
          await sleep(800);
        }
        if(p===pc&&!ended){status(T.noanswer);retry=setTimeout(connect,4000)}
      }catch(e){if(p===pc&&!ended){status(T.lost);retry=setTimeout(connect,3000)}}
    }
    function tune(p){p.getSenders().forEach(s=>{if(!s.track||s.track.kind!=='video'||!s.getParameters)return;const q=s.getParameters();if(!q.encodings||!q.encodings.length)q.encodings=[{}];q.encodings[0].maxBitrate=2500000;s.setParameters(q).catch(()=>{})})}
    async function ping(){
      if(ended||!seq)return;
      try{const r=await fetch(api+'ping?seq='+seq,{cache:'no-store'});if(r.status===409){status(T.replaced);hang(false)}else if(r.status===404){status(T.closed);hang(false)}}catch(e){}
    }
    function hang(tell){
      ended=true;clearTimeout(retry);clearInterval(pinger);
      if(tell&&seq)fetch(api+'leave?seq='+seq,{method:'POST',keepalive:true}).catch(()=>{});
      if(pc){try{pc.close()}catch(e){}pc=null}
      if(local)local.getTracks().forEach(t=>t.stop());
      $('me').srcObject=null;$('ret').srcObject=null;
      $('incall').classList.add('hide');$('join').classList.remove('hide');
      if(tell)status(T.ended);
    }
    $('go').onclick=async()=>{
      if(!window.isSecureContext||!navigator.mediaDevices){status(T.insecure);return}
      try{localStorage.setItem('lcs-name',$('name').value)}catch(e){}
      try{local=await openMedia()}catch(e){status(T.nomedia+(e&&e.name||e));return}
      devices();
      $('me').srcObject=local;$('me').classList.toggle('hide',!local.getVideoTracks().length);
      $('join').classList.add('hide');$('incall').classList.remove('hide');
      ended=false;seq=0;clearInterval(pinger);pinger=setInterval(ping,4000);
      if(!info){try{info=await (await fetch(api+'info',{cache:'no-store'})).json()}catch(e){}}
      connect();
    };
    $('bmic').onclick=()=>{const t=local&&local.getAudioTracks()[0];if(!t)return;t.enabled=!t.enabled;$('bmic').textContent=t.enabled?T.mute:T.unmute;$('bmic').classList.toggle('off',!t.enabled)};
    $('bcam').onclick=()=>{const t=local&&local.getVideoTracks()[0];if(!t)return;t.enabled=!t.enabled;$('bcam').textContent=t.enabled?T.camOff:T.camOn;$('bcam').classList.toggle('off',!t.enabled)};
    $('bend').onclick=()=>hang(true);
    window.addEventListener('pagehide',()=>{if(!ended&&seq)navigator.sendBeacon&&navigator.sendBeacon(api+'leave?seq='+seq)});
    })();
    </script></body></html>
    """#
}
