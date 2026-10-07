/********* LIGHTDOME – ESP8266 – MONO CANALE *******************************
 * Modalità:
 *  - LIVE: comandi istantanei dall’app (HTTP). Priorità massima.
 *  - PROGRAM: riproduzione da file su LittleFS (persistente, autorun, loop).
 *
 * Hardware:
 *  - NodeMCU V3 ESP-12E.
 *  - Un canale luce (bianco) via MOSFET N-channel in low-side.
 *  - Uscita PWM: D5/GPIO14.
 *
 * WebUI locale:             GET  /
 * Stato tecnico:            GET  /status
 * Set livello LIVE:         GET  /set?y=0..1023
 * Parametri:                GET
 * /params?brightness=0..100&gamma=1.0..3.0&loop=0|1 Pattern RAM (test):  POST
 * /pattern (text/plain: "ms,Y" o "ms,R,G,B") Play/Stop RAM:            POST
 * /play | POST /stop Demo:                     GET  /demo
 *
 * API (Flutter):
 *  - GET  /api/state
 *      -> { on, brightness(0..255), mode:"live"|"program"|"idle",
 *           level(0..1023), programName, positionMs, sampleRateHz, loop }
 *  - POST /api/state (application/json)
 *      -> Accetta: on(bool), brightness(0..255), mode("mono"|"rgb"),
 * color{r,g,b} Se chiamato, entra in LIVE e ferma PROGRAM/RAM.
 *
 * PROGRAM management (persistenti su LittleFS):
 *  - POST   /prog/save?name=<id>&sr=100&autorun=0  (body binario via upload)
 *           Formato file: vedi struct LdyHeader (magic "LDY1")
 *  - POST   /prog/start?name=<id>
 *  - POST   /prog/stop
 *  - GET    /prog/list
 *  - DELETE /prog/delete?name=<id>
 *
 * Autorun:
 *  - Se esistono /autorun.txt (nome) e opzionalmente /autorun_loop ("0"|"1"),
 *    all’avvio parte in PROGRAM con quel file.
 *
 * OTA è temporaneamente disabilitato: non sono configurate credenziali private.
 *****************************************************************************/

#include <Arduino.h>
#include <ArduinoJson.h>
#include <DNSServer.h>
#include <ESP8266WebServer.h>
#include <ESP8266WiFi.h>
#include <ESP8266mDNS.h>
#include <LittleFS.h>
#include <math.h>

// ---- CONFIG RETE ---------------------------------------------------------
// Le credenziali vengono configurate localmente dall'app o dal captive portal
// e salvate in LittleFS. Non sono mai compilate nel firmware né restituite via
// API.
const char *AP_SSID = "LightDome-Setup";
const char *MDNS_NAME = "lightdome";
const char *WIFI_CONFIG_FILE = "/wifi.json";
const char *WIFI_CONFIG_TEMP = "/wifi.json.tmp";
const char *WIFI_CONFIG_BACKUP = "/wifi.json.bak";
const uint32_t WIFI_CONNECT_TIMEOUT_MS = 15000;

// ---- PIN USCITA (MONO CANALE) -------------------------------------------
const int PIN_Y = D5; // D5/GPIO14

// ---- PWM -----------------------------------------------------------------
const uint16_t PWM_RANGE = 1023;
const uint16_t PWM_FREQ = 4000; // 4 kHz

// ---- RUNTIME PARAMS ------------------------------------------------------
float gammaCurve = 2.0f;       // 1.0..3.0
float masterBrightness = 1.0f; // 0..1 (limiter globale)
bool loopEnabled = false;

// ---- STATO LIVE ----------------------------------------------------------
uint16_t levelY = 0; // 0..1023 (pre-gamma/master)
bool isOn = false;   // logico; a HW vale Y=0 se false

// ---- PLAYER RAM (compat) -------------------------------------------------
struct Step {
  uint32_t ms;
  uint16_t r, g, b;
};
const uint16_t MAX_STEPS = 2000;
Step steps[MAX_STEPS];
uint16_t stepCount = 0;
bool ramPlaying = false;
uint32_t stepStartMs = 0;
uint16_t stepIndex = 0;

// ---- PROGRAM (LittleFS) --------------------------------------------------
#include <FS.h>
File progFile;
bool programPlaying = false;
String programName = "";
uint16_t sampleRateHz = 100;
uint32_t frameCount = 0;
uint32_t frameIndex = 0;
uint32_t lastTickUs = 0;

// Header file .ldy
struct __attribute__((packed)) LdyHeader {
  char magic[4];     // "LDY1"
  uint16_t srHz;     // sample rate (LE)
  uint32_t frames;   // frame count (LE)
  uint16_t reserved; // 0
};

// ---- WEB -----------------------------------------------------------------
ESP8266WebServer server(80);
DNSServer dnsServer;
bool littleFsMounted = false;
bool apActive = false;
bool mdnsActive = false;
bool wifiConfigured = false;
String configuredSsid;
uint32_t restartAtMs = 0;

// ---- UTILS ----------------------------------------------------------------
static inline uint16_t clamp16(int v, int lo, int hi) {
  if (v < lo)
    return lo;
  if (v > hi)
    return hi;
  return (uint16_t)v;
}

static inline uint16_t applyGammaBright(uint16_t v) {
  float x = (float)v / 1023.0f;
  float y = powf(x, gammaCurve) * masterBrightness;
  if (y < 0)
    y = 0;
  if (y > 1)
    y = 1;
  return (uint16_t)(y * PWM_RANGE + 0.5f);
}

static inline uint16_t rgbToY_0_1023(uint16_t r, uint16_t g, uint16_t b) {
  float yy = 0.3f * r + 0.59f * g + 0.11f * b;
  if (yy < 0)
    yy = 0;
  if (yy > 1023)
    yy = 1023;
  return (uint16_t)yy;
}

void hwApplyY(uint16_t yRaw) {
  uint16_t y = isOn ? yRaw : 0;
  analogWrite(PIN_Y, applyGammaBright(y));
}

void enterLiveMode() {
  // Ferma qualsiasi player attivo
  if (programPlaying) {
    programPlaying = false;
    if (progFile)
      progFile.close();
  }
  if (ramPlaying)
    ramPlaying = false;
}

// ---- CORS ----------------------------------------------------------------
void sendCORS() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

void handleOptions() {
  sendCORS();
  server.send(204);
}

// ---- HTML (WebUI tecnica completa) ---------------------------------------
const char PAGE[] PROGMEM =
    R"HTML(<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LightDome - Mono</title>
<style>
:root{color-scheme:light;--bg:#f3f4f0;--surface:#fff;--surface2:#eef0eb;--text:#181b1a;--muted:#666d69;--line:#dce0d9;--accent:#755700;--accentBg:#fff0bd;--good:#17675f;--shadow:#17201b14}
:root[data-theme=dark]{color-scheme:dark;--bg:#0a0d0d;--surface:#151919;--surface2:#202525;--text:#f2f4ef;--muted:#a7afaa;--line:#2b3230;--accent:#ffd66b;--accentBg:#332a0d;--good:#9bd7ce;--shadow:#0008}
*{box-sizing:border-box}body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;margin:0;background:var(--bg);color:var(--text);min-height:100vh}main{max-width:1120px;margin:auto;padding:24px 18px 50px}
header{display:flex;align-items:center;gap:12px;margin-bottom:22px}.brand{width:46px;height:46px;border-radius:15px;display:grid;place-items:center;background:var(--accentBg);color:var(--accent);font-size:23px}.headcopy{flex:1}h1{font-size:24px;letter-spacing:-.5px;margin:0}.eyebrow{color:var(--good);font-size:12px;font-weight:750;letter-spacing:.8px;text-transform:uppercase}.theme{width:auto;background:var(--surface);color:var(--text);border:1px solid var(--line)}
.row{display:grid;grid-template-columns:repeat(12,1fr);gap:14px}.card{grid-column:span 4;background:var(--surface);border:1px solid var(--line);border-radius:24px;padding:20px;box-shadow:0 14px 40px var(--shadow)}.card:first-child{grid-column:span 7}.card:nth-child(2){grid-column:span 5}.card:nth-child(3){grid-column:span 12}h3{margin:0 0 16px;font-size:17px;letter-spacing:-.2px}
label{display:block;font-size:13px;color:var(--muted);margin:10px 0 7px}input,textarea{width:100%;color:var(--text);background:var(--surface2);border:1px solid var(--line);border-radius:14px;padding:12px;font:inherit}input[type=range]{padding:0;accent-color:var(--accent);border:0}input[type=checkbox]{width:auto;accent-color:var(--accent)}input[type=file]{padding:8px}input[type=file]::file-selector-button{border:0;border-radius:10px;background:var(--surface);color:var(--text);padding:8px 10px;margin-right:9px;font-weight:650}textarea{min-height:150px;font-family:ui-monospace,Consolas,monospace;resize:vertical}
button{padding:10px 14px;border-radius:13px;border:1px solid var(--line);background:var(--surface2);color:var(--text);font:inherit;font-weight:650;cursor:pointer;margin:3px 2px}.on{background:var(--accent);color:var(--bg);border-color:var(--accent)}button:focus-visible,input:focus-visible,textarea:focus-visible{outline:2px solid var(--accent);outline-offset:2px}.mono{font-family:ui-monospace,Consolas,monospace}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.muted{color:var(--muted);font-size:13px;line-height:1.45}pre{background:var(--surface2);border-radius:14px;padding:12px;white-space:pre-wrap}
@media(max-width:760px){main{padding:18px 12px 36px}.card,.card:first-child,.card:nth-child(2),.card:nth-child(3){grid-column:span 12}.grid{grid-template-columns:1fr}header{margin-bottom:16px}.theme{padding:9px 11px}}
</style>
</head>
<body>
<main><header><div class="brand">LD</div><div class="headcopy"><div class="eyebrow">Controllo locale</div><h1>LightDome</h1></div><button class="theme" onclick="toggleTheme()">Cambia tema</button></header>

<div class="row">
  <div class="card">
    <h3>LIVE</h3>
    <label>Livello (0-1023)
      <input id="y" type="range" min="0" max="1023" value="0" oninput="setY()">
    </label>
    <div class="grid">
      <label>Brightness master (%) <input id="br" type="range" min="0" max="100" value="100" oninput="setParams()"></label>
      <label>Gamma (1.0-3.0) <input id="gm" type="range" min="10" max="30" value="20" oninput="setParams()"></label>
    </div>
    <div class="muted">Ogni comando LIVE sospende il PROGRAM in esecuzione.</div>
    <div style="margin-top:8px">
      <button onclick="off()">Off</button>
      <button onclick="pulseDemo()">Pulse demo</button>
    </div>
  </div>

  <div class="card">
    <h3>PROGRAM (file .ldy)</h3>
    <div class="grid">
      <input id="fname" placeholder="Nome programma" />
      <label>Loop <input id="loop" type="checkbox"></label>
    </div>
    <div class="muted">Carica un file .ldy: header LDY1 + campioni uint16 LE</div>
    <input type="file" id="file" />
    <div style="margin-top:8px">
      <button class="on" onclick="saveProg()">Salva</button>
      <button onclick="startProg()">Start</button>
      <button onclick="stopProg()">Stop</button>
      <button onclick="listProg()">Lista</button>
      <button onclick="delProg()">Delete</button>
    </div>
    <pre id="out" class="mono" style="margin-top:8px;max-height:220px;overflow:auto"></pre>
  </div>

  <div class="card">
    <h3>Pattern RAM (test rapido)</h3>
    <textarea id="pat" placeholder="100,0&#10;500,1023&#10;300,400&#10;300,0"></textarea>
    <div style="margin-top:8px">
      <button class="on" onclick="uploadPattern()">Carica</button>
      <button onclick="play()">Play</button>
      <button onclick="stopPlay()">Stop</button>
      <button onclick="clearArea()">Clear</button>
    </div>
    <h3>Stato</h3>
    <div id="st" class="mono">...</div>
  </div>
</div></main>

<script>
const stDiv = document.getElementById('st');
const y  = document.getElementById('y');
const br = document.getElementById('br');
const gm = document.getElementById('gm');
const lp = document.getElementById('loop');
const pat = document.getElementById('pat');
const fname = document.getElementById('fname');
const file = document.getElementById('file');
const out  = document.getElementById('out');
function applyTheme(v){document.documentElement.dataset.theme=v;localStorage.setItem('ld-theme',v)}
function toggleTheme(){applyTheme(document.documentElement.dataset.theme==='dark'?'light':'dark')}
applyTheme(localStorage.getItem('ld-theme')||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'));

function setY(){ fetch(`/set?y=${y.value}`); }
function setParams(){
  const gamma = (gm.value/10).toFixed(1);
  fetch(`/params?brightness=${br.value}&gamma=${gamma}&loop=${lp.checked?1:0}`);
}
function off(){ y.value = 0; fetch('/set?y=0'); }
function pulseDemo(){ fetch('/demo'); }
function uploadPattern(){
  fetch('/pattern',{method:'POST',headers:{'Content-Type':'text/plain'},body:pat.value})
    .then(r=>r.text()).then(t=>{out.textContent=t; updateStatus();});
}
function play(){ fetch('/play',{method:'POST'}).then(updateStatus); }
function stopPlay(){ fetch('/stop',{method:'POST'}).then(updateStatus); }
function clearArea(){ pat.value=''; }
function saveProg(){
  const n = (fname.value||'').trim();
  if (!n || !file.files[0]) { out.textContent='Scegli nome e file'; return; }
  const params = new URLSearchParams({name:n, sr:0, autorun:0});
  fetch('/prog/save?'+params.toString(), {method:'POST', body:file.files[0]})
    .then(r=>r.text()).then(t=>out.textContent=t);
}
function startProg(){
  const n = (fname.value||'').trim(); if (!n){out.textContent='Nome mancante';return;}
  fetch('/prog/start?name='+encodeURIComponent(n), {method:'POST'})
    .then(r=>r.text()).then(t=>{out.textContent=t; updateStatus();});
}
function stopProg(){ fetch('/prog/stop',{method:'POST'}).then(r=>r.text()).then(t=>{out.textContent=t; updateStatus();}); }
function listProg(){ fetch('/prog/list').then(r=>r.text()).then(t=>out.textContent=t); }
function delProg(){
  const n=(fname.value||'').trim(); if(!n){out.textContent='Nome mancante';return;}
  fetch('/prog/delete?name='+encodeURIComponent(n),{method:'DELETE'}).then(r=>r.text()).then(t=>out.textContent=t);
}
function updateStatus(){
  fetch('/status').then(r=>r.json()).then(s=>{
    stDiv.textContent = JSON.stringify(s,null,2);
    br.value = Math.round(s.masterBrightness*100);
    gm.value = Math.round(s.gamma*10);
    lp.checked = s.loop;
    y.value = s.levelY;
  });
}
setInterval(updateStatus, 1000); updateStatus();
</script>
</body></html>)HTML";

const char WIFI_PAGE[] PROGMEM = R"HTML(<!doctype html>
<html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Configura LightDome</title>
<style>
:root{color-scheme:light;--bg:#f3f4f0;--surface:#fff;--surface2:#eef0eb;--text:#181b1a;--muted:#676d69;--line:#dce0d9;--accent:#755700;--accentBg:#fff0bd;--good:#17675f;--danger:#a6372c;--shadow:#17201b18}
:root[data-theme=dark]{color-scheme:dark;--bg:#0a0d0d;--surface:#151919;--surface2:#202525;--text:#f2f4ef;--muted:#a7afaa;--line:#2b3230;--accent:#ffd66b;--accentBg:#332a0d;--good:#9bd7ce;--danger:#ffb4a9;--shadow:#0008}
*{box-sizing:border-box}body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;background:var(--bg);margin:0;color:var(--text);min-height:100vh}main{max-width:560px;margin:auto;padding:24px 14px 40px}
header{display:flex;align-items:center;gap:12px;margin-bottom:18px}.brand{width:46px;height:46px;border-radius:15px;background:var(--accentBg);color:var(--accent);display:grid;place-items:center;font-size:13px;font-weight:800;letter-spacing:.5px}.headcopy{flex:1}.eyebrow{color:var(--good);font-size:11px;font-weight:800;letter-spacing:.9px;text-transform:uppercase}h1{font-size:23px;letter-spacing:-.5px;margin:2px 0 0}.theme{width:auto;padding:9px 11px;background:var(--surface);color:var(--text)}
.card{background:var(--surface);border:1px solid var(--line);border-radius:26px;padding:22px;box-shadow:0 16px 45px var(--shadow)}h2{font-size:21px;letter-spacing:-.4px;margin:0 0 7px}p{line-height:1.5;margin:0}.muted{color:var(--muted);font-size:13px}.steps{display:flex;gap:7px;margin:18px 0 16px}.step{flex:1;background:var(--surface2);border-radius:12px;padding:9px 7px;text-align:center;font-size:11px;color:var(--muted)}.step.active{background:var(--accentBg);color:var(--accent);font-weight:750}
label{display:block;margin:15px 0 7px;font-weight:650;font-size:13px}input,button{width:100%;font:inherit;padding:13px 14px;border-radius:14px;border:1px solid var(--line)}input{background:var(--surface2);color:var(--text)}button{background:var(--accent);color:var(--bg);border-color:var(--accent);font-weight:750;cursor:pointer}button.secondary{background:var(--surface2);color:var(--text);border-color:var(--line)}button:disabled{opacity:.55;cursor:wait}button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
#nets{display:grid;gap:7px;margin-top:10px}.network{display:flex;align-items:center;gap:11px;text-align:left;background:var(--surface2);color:var(--text);border-color:var(--line);padding:12px}.network.selected{background:var(--accentBg);border-color:var(--accent)}.network-copy{flex:1;min-width:0}.network-name{display:block;font-weight:700;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.network-meta{display:block;color:var(--muted);font-size:12px;margin-top:2px}.network-state{color:var(--muted);font-size:12px}
#msg{white-space:pre-wrap;margin-top:14px;padding:12px 13px;border-radius:14px;background:var(--surface2);min-height:20px;color:var(--muted);font-size:13px}.ok{background:#d9efe8!important;color:#105c50!important}.err{background:#fae1de!important;color:#942a22!important}.actions{display:grid;grid-template-columns:1fr 1.4fr;gap:8px;margin-top:16px}.foot{margin-top:14px!important}
@media(max-width:420px){main{padding:14px 10px 28px}.card{padding:18px;border-radius:22px}.actions{grid-template-columns:1fr}.theme{font-size:12px}}
</style></head><body><main>
<header><div class="brand">LD</div><div class="headcopy"><div class="eyebrow">Configurazione locale</div><h1>LightDome</h1></div><button class="theme" onclick="toggleTheme()">Tema</button></header>
<div class="card"><h2>Collega la cupola</h2><p class="muted">Scegli la rete di casa. La password resta soltanto nella memoria della scheda.</p>
<div class="steps"><div class="step active">1 · Rete</div><div class="step">2 · Password</div><div class="step">3 · Pronta</div></div>
<button id="scan" class="secondary" type="button">Aggiorna elenco reti</button><div id="nets"></div>
<label for="ssid">Nome rete Wi-Fi</label><input id="ssid" maxlength="32" autocomplete="off" placeholder="SSID della rete">
<label for="pass">Password</label><input id="pass" type="password" maxlength="63" autocomplete="current-password" placeholder="Vuota soltanto per reti aperte">
<div class="actions"><button id="show" class="secondary" type="button">Mostra password</button><button id="save" type="button">Salva e collega</button></div>
<div id="msg">Pronto per cercare le reti.</div><p class="muted foot">Dopo il riavvio torna sulla rete di casa e apri <b>lightdome.local</b>.</p>
</div></main><script>
const $=id=>document.getElementById(id),msg=$('msg');let selected='';
function applyTheme(v){document.documentElement.dataset.theme=v;localStorage.setItem('ld-theme',v)}
function toggleTheme(){applyTheme(document.documentElement.dataset.theme==='dark'?'light':'dark')}
applyTheme(localStorage.getItem('ld-theme')||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'));
function show(t,c=''){msg.textContent=t;msg.className=c}
function quality(r){return r>=-55?'Segnale ottimo':r>=-68?'Segnale buono':'Segnale debole'}
function choose(n,b){selected=n.ssid;$('ssid').value=n.ssid;document.querySelectorAll('.network').forEach(x=>x.classList.remove('selected'));b.classList.add('selected')}
async function scan(){const b=$('scan');b.disabled=true;show('Ricerca reti in corso…');try{const r=await fetch('/wifi/scan'),j=await r.json();if(!r.ok)throw Error(j.error||'Ricerca non riuscita');const d=$('nets');d.replaceChildren();j.networks.forEach(n=>{const b=document.createElement('button');b.type='button';b.className='network';const c=document.createElement('span');c.className='network-copy';const name=document.createElement('span');name.className='network-name';name.textContent=n.ssid;const meta=document.createElement('span');meta.className='network-meta';meta.textContent=`${quality(n.rssi)} · ${n.rssi} dBm`;const state=document.createElement('span');state.className='network-state';state.textContent=n.secure?'Protetta':'Aperta';c.append(name,meta);b.append(c,state);b.onclick=()=>choose(n,b);d.appendChild(b)});show(`${j.networks.length} reti trovate.`,'ok')}catch(e){show(e.message,'err')}finally{b.disabled=false}}
async function save(){const ssid=$('ssid').value.trim(),password=$('pass').value,b=$('save');if(!ssid){show('Scegli o inserisci una rete.','err');return}b.disabled=true;show('Salvataggio e riavvio…');try{const r=await fetch('/wifi/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid,password})}),j=await r.json();if(!r.ok)throw Error(j.error||'Configurazione non riuscita');$('pass').value='';show('Configurazione salvata. LightDome si sta collegando alla rete.','ok')}catch(e){show(e.message,'err');b.disabled=false}}
$('scan').onclick=scan;$('save').onclick=save;$('show').onclick=()=>{const p=$('pass'),showing=p.type==='text';p.type=showing?'password':'text';$('show').textContent=showing?'Mostra password':'Nascondi password'};scan();
</script></body></html>)HTML";

// -------------------- HANDLERS BASE ---------------------------------------
void handleRoot() {
  sendCORS();
  server.send(200, "text/html", apActive ? FPSTR(WIFI_PAGE) : FPSTR(PAGE));
}

void handleStatus() {
  sendCORS();
  String ip = WiFi.isConnected() ? WiFi.localIP().toString()
                                 : WiFi.softAPIP().toString();
  JsonDocument doc;
  doc["ip"] = ip;
  doc["masterBrightness"] = masterBrightness;
  doc["gamma"] = gammaCurve;
  doc["loop"] = loopEnabled;
  doc["on"] = isOn;
  doc["levelY"] = levelY;
  JsonObject mode = doc["mode"].to<JsonObject>();
  mode["programPlaying"] = programPlaying;
  mode["ramPlaying"] = ramPlaying;
  mode["programName"] = programName;
  mode["sampleRateHz"] = sampleRateHz;
  mode["frameIndex"] = frameIndex;
  mode["frameCount"] = frameCount;
  mode["positionMs"] = (uint32_t)((programPlaying && sampleRateHz > 0)
                                      ? (1000UL * frameIndex) / sampleRateHz
                                      : 0);
  String out;
  serializeJson(doc, out);
  server.send(200, "application/json", out);
}

void handleSet() {
  sendCORS();
  if (!server.hasArg("y")) {
    server.send(400, "text/plain", "Missing y");
    return;
  }
  enterLiveMode();
  levelY = clamp16(server.arg("y").toInt(), 0, 1023);
  isOn = (levelY > 0);
  hwApplyY(levelY);
  server.send(200, "text/plain", "OK");
}

void handleParams() {
  sendCORS();
  if (server.hasArg("brightness")) {
    int p = clamp16(server.arg("brightness").toInt(), 0, 100);
    masterBrightness = p / 100.0f;
  }
  if (server.hasArg("gamma")) {
    float g = server.arg("gamma").toFloat();
    if (g < 1.0f)
      g = 1.0f;
    if (g > 3.0f)
      g = 3.0f;
    gammaCurve = g;
  }
  if (server.hasArg("loop"))
    loopEnabled = (server.arg("loop").toInt() != 0);
  hwApplyY(levelY);
  server.send(200, "text/plain", "OK");
}

// -------------------- PATTERN RAM (compat) -------------------------------
bool parsePattern(const String &body, String &err, uint16_t &loaded) {
  loaded = 0;
  uint16_t count = 0;
  int start = 0;
  while (start < (int)body.length()) {
    int end = body.indexOf('\n', start);
    if (end < 0)
      end = body.length();
    String line = body.substring(start, end);
    start = end + 1;
    line.trim();
    if (line.length() == 0 || line.charAt(0) == '#')
      continue;
    line.replace(';', ',');
    int c1 = line.indexOf(',');
    if (c1 < 0) {
      err = "Formato invalido: " + line;
      return false;
    }
    int c2 = line.indexOf(',', c1 + 1);
    int c3 = (c2 >= 0) ? line.indexOf(',', c2 + 1) : -1;
    long ms = -1, r = 0, g = 0, b = 0;
    if (c2 < 0) {
      String sMs = line.substring(0, c1);
      sMs.trim();
      String sY = line.substring(c1 + 1);
      sY.trim();
      ms = sMs.toInt();
      long y = sY.toInt();
      if (ms <= 0 || y < 0 || y > 1023) {
        err = "Valori fuori range: " + line;
        return false;
      }
      r = g = b = y;
    } else if (c3 >= 0) {
      String sMs = line.substring(0, c1), sR = line.substring(c1 + 1, c2),
             sG = line.substring(c2 + 1, c3), sB = line.substring(c3 + 1);
      sMs.trim();
      sR.trim();
      sG.trim();
      sB.trim();
      ms = sMs.toInt();
      r = sR.toInt();
      g = sG.toInt();
      b = sB.toInt();
      if (ms <= 0 || r < 0 || r > 1023 || g < 0 || g > 1023 || b < 0 ||
          b > 1023) {
        err = "Valori fuori range: " + line;
        return false;
      }
    } else {
      err = "Formato invalido: " + line;
      return false;
    }
    if (count >= MAX_STEPS) {
      err = "Troppi step (limite)";
      return false;
    }
    steps[count].ms = (uint32_t)ms;
    steps[count].r = (uint16_t)r;
    steps[count].g = (uint16_t)g;
    steps[count].b = (uint16_t)b;
    count++;
  }
  stepCount = count;
  loaded = count;
  return true;
}

void handlePattern() {
  sendCORS();
  if (!server.hasArg("plain")) {
    server.send(400, "text/plain", "Body mancante");
    return;
  }
  enterLiveMode();
  String body = server.arg("plain");
  String err;
  uint16_t loaded;
  if (!parsePattern(body, err, loaded)) {
    server.send(400, "text/plain", "Errore: " + err);
    return;
  }
  server.send(200, "text/plain",
              "Pattern caricato: " + String(loaded) + " step");
}
void handlePlay() {
  sendCORS();
  if (stepCount == 0) {
    server.send(400, "text/plain", "Nessun pattern");
    return;
  }
  enterLiveMode();
  ramPlaying = true;
  stepIndex = 0;
  stepStartMs = millis();
  isOn = true;
  server.send(200, "text/plain", "Play RAM");
}
void handleStopRAM() {
  sendCORS();
  ramPlaying = false;
  isOn = false;
  hwApplyY(0);
  server.send(200, "text/plain", "Stop RAM");
}
void handleDemo() {
  sendCORS();
  enterLiveMode();
  for (int i = 0; i <= 1023; i += 16) {
    levelY = i;
    isOn = true;
    hwApplyY(levelY);
    delay(2);
  }
  for (int i = 1023; i >= 0; i -= 16) {
    levelY = i;
    hwApplyY(levelY);
    delay(2);
  }
  server.send(200, "text/plain", "Demo ok");
}

// -------------------- API /api/state --------------------------------------
void handleApiStateGet() {
  sendCORS();
  JsonDocument doc;
  doc["on"] = isOn;
  uint8_t apiBright = (uint8_t)round((levelY / 1023.0f) * 255.0f);
  doc["brightness"] = apiBright;
  // Keep `brightness` as the current 0..255 output level. These explicit
  // fields expose the independent master limiter without changing the
  // existing API meaning expected by older clients.
  doc["brightnessMaster"] = masterBrightness;
  doc["brightnessPct"] = (uint8_t)round(masterBrightness * 100.0f);
  doc["gamma"] = gammaCurve;
  doc["mode"] = programPlaying
                    ? "program"
                    : (ramPlaying ? "program" : (isOn ? "live" : "idle"));
  doc["level"] = levelY;
  doc["loop"] = loopEnabled;
  doc["programName"] = programName;
  doc["sampleRateHz"] = sampleRateHz;
  doc["positionMs"] = (uint32_t)((programPlaying && sampleRateHz > 0)
                                     ? (1000UL * frameIndex) / sampleRateHz
                                     : 0);
  JsonObject color = doc["color"].to<JsonObject>();
  color["r"] = apiBright;
  color["g"] = apiBright;
  color["b"] = apiBright;
  String out;
  serializeJson(doc, out);
  server.send(200, "application/json", out);
}

void handleApiStatePost() {
  sendCORS();
  if (!server.hasArg("plain")) {
    server.send(400, "text/plain", "JSON mancante");
    return;
  }
  JsonDocument doc;
  auto err = deserializeJson(doc, server.arg("plain"));
  if (err) {
    server.send(400, "text/plain", "JSON invalido");
    return;
  }
  enterLiveMode();
  bool reqOn = !doc["on"].isNull() ? doc["on"].as<bool>() : isOn;
  String mode =
      !doc["mode"].isNull() ? String((const char *)doc["mode"]) : "mono";
  int tgtY = levelY;
  if (!doc["brightness"].isNull()) {
    int b255 = doc["brightness"].as<int>();
    b255 = b255 < 0 ? 0 : (b255 > 255 ? 255 : b255);
    tgtY = (int)round((b255 / 255.0f) * 1023.0f);
  }
  if (mode == "rgb" && !doc["color"].isNull()) {
    JsonObject c = doc["color"].as<JsonObject>();
    int r = !c["r"].isNull() ? c["r"].as<int>() : 0;
    int g = !c["g"].isNull() ? c["g"].as<int>() : 0;
    int b = !c["b"].isNull() ? c["b"].as<int>() : 0;
    r = clamp16(r, 0, 255);
    g = clamp16(g, 0, 255);
    b = clamp16(b, 0, 255);
    int y255 = (int)round(0.3f * r + 0.59f * g + 0.11f * b);
    int base255 =
        !doc["brightness"].isNull() ? doc["brightness"].as<int>() : y255;
    int final255 = (base255 < y255) ? base255 : y255;
    tgtY = (int)round((final255 / 255.0f) * 1023.0f);
  }
  isOn = reqOn;
  levelY = clamp16(tgtY, 0, 1023);
  hwApplyY(levelY);
  server.send(204);
}

// -------------------- PROGRAM (.ldy su LittleFS) --------------------------
const char *PROG_DIR = "/prog";
const char *AUTORUN_FILE = "/autorun.txt";
const char *AUTORUN_LOOP = "/autorun_loop";

void sendLittleFsUnavailable() {
  sendCORS();
  server.send(503, "text/plain", "LittleFS non disponibile");
}

bool isValidProgramName(const String &name) {
  if (name.length() == 0 || name.length() > 48)
    return false;
  for (size_t i = 0; i < name.length(); ++i) {
    char c = name.charAt(i);
    bool asciiLetter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    bool digit = c >= '0' && c <= '9';
    if (!asciiLetter && !digit && c != '-' && c != '_')
      return false;
  }
  return true;
}

String programPath(const String &name) {
  return String(PROG_DIR) + "/" + name + ".ldy";
}

String programTempPath(const String &name) {
  return programPath(name) + ".upload";
}

bool validateLdyFile(File &f, LdyHeader &h) {
  if (!f || f.size() < (int)sizeof(LdyHeader))
    return false;
  f.seek(0, SeekSet);
  if (f.readBytes((char *)&h, sizeof(LdyHeader)) != sizeof(LdyHeader))
    return false;
  if (h.magic[0] != 'L' || h.magic[1] != 'D' || h.magic[2] != 'Y' ||
      h.magic[3] != '1')
    return false;
  if (h.srHz == 0 || h.frames == 0)
    return false;

  uint64_t expectedSize = sizeof(LdyHeader) +
                          (uint64_t)h.frames * sizeof(uint16_t);
  if (expectedSize > UINT32_MAX)
    return false;
  return (uint64_t)f.size() == expectedSize;
}

bool readHeader(File &f, LdyHeader &h) {
  return validateLdyFile(f, h);
}

void stopProgram() {
  programPlaying = false;
  if (progFile)
    progFile.close();
  programName = "";
  sampleRateHz = 0;
  frameCount = 0;
  frameIndex = 0;
}

bool startProgramByName(const String &name) {
  if (!littleFsMounted || !isValidProgramName(name))
    return false;

  File candidate = LittleFS.open(programPath(name), "r");
  if (!candidate)
    return false;

  LdyHeader h;
  if (!validateLdyFile(candidate, h)) {
    candidate.close();
    return false;
  }

  candidate.seek(sizeof(LdyHeader), SeekSet);
  stopProgram();
  ramPlaying = false;
  progFile = candidate;
  sampleRateHz = h.srHz;
  frameCount = h.frames;
  frameIndex = 0;
  programName = name;
  programPlaying = true;
  isOn = true;
  lastTickUs = micros();
  progFile.seek(sizeof(LdyHeader), SeekSet);
  return true;
}

File uploadFile;
String uploadName;
String uploadTempPath;
bool uploadCompleted = false;
bool uploadAborted = false;
bool uploadHasError = false;
String uploadErrorMessage;
void handleProgSaveMeta() {
  sendCORS();
  if (!littleFsMounted) {
    server.send(503, "text/plain", "LittleFS non disponibile");
    return;
  }
  if (!uploadName.length() || !isValidProgramName(uploadName)) {
    server.send(400, "text/plain", "Nome programma non valido");
    return;
  }
  if (uploadHasError) {
    server.send(500, "text/plain", uploadErrorMessage);
    return;
  }
  if (uploadAborted || !uploadCompleted) {
    server.send(400, "text/plain", "Upload incompleto");
    return;
  }

  File candidate = LittleFS.open(uploadTempPath, "r");
  LdyHeader header;
  bool valid = validateLdyFile(candidate, header);
  candidate.close();
  if (!valid) {
    LittleFS.remove(uploadTempPath);
    server.send(400, "text/plain", "File LDY1 non valido");
    return;
  }

  String targetPath = programPath(uploadName);
  String backupPath = targetPath + ".backup";
  // Recover a previous interrupted promotion before touching the current
  // program. If both paths exist, the target is already the authoritative
  // copy and the backup is stale.
  if (LittleFS.exists(backupPath)) {
    if (LittleFS.exists(targetPath)) {
      if (!LittleFS.remove(backupPath)) {
        LittleFS.remove(uploadTempPath);
        server.send(500, "text/plain", "Impossibile rimuovere backup obsoleto");
        return;
      }
    } else if (!LittleFS.rename(backupPath, targetPath)) {
      LittleFS.remove(uploadTempPath);
      server.send(500, "text/plain", "Impossibile ripristinare programma precedente");
      return;
    }
  }
  bool hadExisting = LittleFS.exists(targetPath);
  if (hadExisting && !LittleFS.rename(targetPath, backupPath)) {
    LittleFS.remove(uploadTempPath);
    server.send(500, "text/plain", "Impossibile preparare sostituzione");
    return;
  }
  if (!LittleFS.rename(uploadTempPath, targetPath)) {
    bool restored = !hadExisting || LittleFS.rename(backupPath, targetPath);
    LittleFS.remove(uploadTempPath);
    server.send(500, "text/plain",
                restored ? "Impossibile sostituire programma"
                         : "Sostituzione fallita; backup precedente conservato");
    return;
  }
  LittleFS.remove(backupPath);

  bool autorun = server.hasArg("autorun") && server.arg("autorun") != "0";
  if (autorun) {
    File autorunFile = LittleFS.open(AUTORUN_FILE, "w");
    File autorunLoop = LittleFS.open(AUTORUN_LOOP, "w");
    bool autorunOk = autorunFile && autorunLoop;
    if (autorunOk) {
      autorunFile.print(uploadName);
      autorunFile.close();
      autorunLoop.print(loopEnabled ? "1" : "0");
      autorunLoop.close();
    } else {
      if (autorunFile) autorunFile.close();
      if (autorunLoop) autorunLoop.close();
      server.send(500, "text/plain", "Impossibile impostare autorun");
      return;
    }
  }
  server.send(200, "text/plain", "Salvato: " + uploadName);
}

void handleProgSaveUpload() {
  HTTPUpload &up = server.upload();
  if (up.status == UPLOAD_FILE_START) {
    uploadName = server.hasArg("name") ? server.arg("name") : String("unnamed");
    uploadTempPath = "";
    uploadCompleted = false;
    uploadAborted = false;
    uploadHasError = false;
    uploadErrorMessage = "";
    if (!littleFsMounted || !isValidProgramName(uploadName)) {
      uploadHasError = true;
      uploadErrorMessage = "Nome programma non valido";
      return;
    }
    LittleFS.mkdir(PROG_DIR);
    uploadTempPath = programTempPath(uploadName);
    LittleFS.remove(uploadTempPath);
    uploadFile = LittleFS.open(uploadTempPath, "w");
    if (!uploadFile) {
      uploadHasError = true;
      uploadErrorMessage = "Impossibile aprire file temporaneo";
    }
  } else if (up.status == UPLOAD_FILE_WRITE) {
    if (uploadHasError || !uploadFile)
      return;
    size_t written = uploadFile.write(up.buf, up.currentSize);
    if (written != up.currentSize) {
      uploadHasError = true;
      uploadErrorMessage = "Errore scrittura upload";
    }
  } else if (up.status == UPLOAD_FILE_END) {
    if (uploadFile)
      uploadFile.close();
    uploadCompleted = !uploadHasError;
    if (uploadHasError)
      LittleFS.remove(uploadTempPath);
  } else if (up.status == UPLOAD_FILE_ABORTED) {
    if (uploadFile)
      uploadFile.close();
    if (uploadTempPath.length())
      LittleFS.remove(uploadTempPath);
    uploadAborted = true;
  }
}

void handleProgStart() {
  sendCORS();
  if (!littleFsMounted) {
    server.send(503, "text/plain", "LittleFS non disponibile");
    return;
  }
  if (!server.hasArg("name")) {
    server.send(400, "text/plain", "name mancante");
    return;
  }
  String n = server.arg("name");
  if (!isValidProgramName(n)) {
    server.send(400, "text/plain", "Nome programma non valido");
    return;
  }
  if (!startProgramByName(n)) {
    server.send(400, "text/plain", "Impossibile avviare");
    return;
  }
  server.send(200, "text/plain",
              "PROGRAM start: " + n + (loopEnabled ? " (loop)" : ""));
}
void handleProgStop() {
  sendCORS();
  if (!littleFsMounted) {
    server.send(503, "text/plain", "LittleFS non disponibile");
    return;
  }
  stopProgram();
  server.send(200, "text/plain", "PROGRAM stop");
}

void handleProgList() {
  sendCORS();
  if (!littleFsMounted) {
    server.send(503, "text/plain", "LittleFS non disponibile");
    return;
  }
  String out;
  Dir d = LittleFS.openDir(PROG_DIR);
  while (d.next()) {
    out += d.fileName();
    out += " (";
    out += d.fileSize();
    out += ")\n";
  }
  if (out.length() == 0)
    out = "(vuoto)";
  server.send(200, "text/plain", out);
}
void handleProgDelete() {
  sendCORS();
  if (!littleFsMounted) {
    server.send(503, "text/plain", "LittleFS non disponibile");
    return;
  }
  if (!server.hasArg("name")) {
    server.send(400, "text/plain", "name mancante");
    return;
  }
  String n = server.arg("name");
  if (!isValidProgramName(n)) {
    server.send(400, "text/plain", "Nome programma non valido");
    return;
  }
  String path = programPath(n);
  if (LittleFS.exists(path)) {
    if (programPlaying && programName == n)
      stopProgram();
    if (!LittleFS.remove(path)) {
      server.send(500, "text/plain", "Impossibile cancellare");
      return;
    }
    File autorunFile = LittleFS.open(AUTORUN_FILE, "r");
    String autorunName;
    if (autorunFile) {
      autorunName = autorunFile.readStringUntil('\n');
      autorunFile.close();
      autorunName.trim();
    }
    if (autorunName == n) {
      LittleFS.remove(AUTORUN_FILE);
      LittleFS.remove(AUTORUN_LOOP);
    }
    server.send(200, "text/plain", "Cancellato: " + n);
  } else
    server.send(404, "text/plain", "Non trovato");
}

// -------------------- Wi-Fi / captive portal -----------------------------
bool validWifiCredentials(const String &ssid, const String &password) {
  if (ssid.length() == 0 || ssid.length() > 32)
    return false;
  return password.length() == 0 ||
         (password.length() >= 8 && password.length() <= 63);
}

bool loadWifiCredentials(String &ssid, String &password) {
  wifiConfigured = false;
  configuredSsid = "";
  if (!littleFsMounted || !LittleFS.exists(WIFI_CONFIG_FILE))
    return false;
  File f = LittleFS.open(WIFI_CONFIG_FILE, "r");
  if (!f)
    return false;
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, f);
  f.close();
  if (err || !doc["ssid"].is<const char *>() ||
      !doc["password"].is<const char *>())
    return false;
  ssid = String(doc["ssid"].as<const char *>());
  password = String(doc["password"].as<const char *>());
  if (!validWifiCredentials(ssid, password))
    return false;
  wifiConfigured = true;
  configuredSsid = ssid;
  return true;
}

bool saveWifiCredentials(const String &ssid, const String &password) {
  if (!littleFsMounted || !validWifiCredentials(ssid, password))
    return false;
  LittleFS.remove(WIFI_CONFIG_TEMP);
  File f = LittleFS.open(WIFI_CONFIG_TEMP, "w");
  if (!f)
    return false;
  JsonDocument doc;
  doc["ssid"] = ssid;
  doc["password"] = password;
  bool wrote = serializeJson(doc, f) > 0;
  f.close();
  if (!wrote) {
    LittleFS.remove(WIFI_CONFIG_TEMP);
    return false;
  }

  LittleFS.remove(WIFI_CONFIG_BACKUP);
  bool hadExisting = LittleFS.exists(WIFI_CONFIG_FILE);
  if (hadExisting &&
      !LittleFS.rename(WIFI_CONFIG_FILE, WIFI_CONFIG_BACKUP)) {
    LittleFS.remove(WIFI_CONFIG_TEMP);
    return false;
  }
  if (!LittleFS.rename(WIFI_CONFIG_TEMP, WIFI_CONFIG_FILE)) {
    if (hadExisting)
      LittleFS.rename(WIFI_CONFIG_BACKUP, WIFI_CONFIG_FILE);
    LittleFS.remove(WIFI_CONFIG_TEMP);
    return false;
  }
  LittleFS.remove(WIFI_CONFIG_BACKUP);
  wifiConfigured = true;
  configuredSsid = ssid;
  return true;
}

void startSetupPortal() {
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID);
  apActive = true;
  dnsServer.start(53, "*", WiFi.softAPIP());
  Serial.println("Portale Wi-Fi attivo: collegarsi a LightDome-Setup");
  Serial.println("Portale: http://" + WiFi.softAPIP().toString() + "/wifi");
}

bool requestComesFromSetupNetwork() {
  if (!apActive)
    return false;
  IPAddress remote = server.client().remoteIP();
  IPAddress local = WiFi.softAPIP();
  return remote[0] == local[0] && remote[1] == local[1] &&
         remote[2] == local[2];
}

void sendJsonDocument(int status, JsonDocument &doc) {
  sendCORS();
  String out;
  serializeJson(doc, out);
  server.send(status, "application/json", out);
}

void sendWifiError(int status, const String &message) {
  JsonDocument doc;
  doc["error"] = message;
  sendJsonDocument(status, doc);
}

void handleWifiPage() {
  sendCORS();
  server.send(200, "text/html", FPSTR(WIFI_PAGE));
}

void handleWifiStatus() {
  JsonDocument doc;
  doc["configured"] = wifiConfigured;
  doc["connected"] = WiFi.status() == WL_CONNECTED;
  doc["portal"] = apActive;
  doc["mode"] = WiFi.status() == WL_CONNECTED ? "station" : "setup";
  doc["ssid"] = WiFi.status() == WL_CONNECTED ? WiFi.SSID() : configuredSsid;
  doc["ip"] = (WiFi.status() == WL_CONNECTED ? WiFi.localIP()
                                                 : WiFi.softAPIP())
                  .toString();
  doc["hostname"] = String(MDNS_NAME) + ".local";
  sendJsonDocument(200, doc);
}

void handleWifiScan() {
  if (!requestComesFromSetupNetwork()) {
    sendWifiError(403, "Scansione disponibile solo da LightDome-Setup");
    return;
  }
  int count = WiFi.scanNetworks(false, true);
  if (count < 0) {
    sendWifiError(503, "Scansione Wi-Fi non riuscita");
    return;
  }
  JsonDocument doc;
  JsonArray networks = doc["networks"].to<JsonArray>();
  int included = 0;
  for (int i = 0; i < count && included < 20; ++i) {
    String ssid = WiFi.SSID(i);
    if (ssid.length() == 0)
      continue;
    bool duplicate = false;
    for (JsonObject network : networks) {
      if (ssid == String(network["ssid"].as<const char *>())) {
        duplicate = true;
        break;
      }
    }
    if (duplicate)
      continue;
    JsonObject network = networks.add<JsonObject>();
    network["ssid"] = ssid;
    network["rssi"] = WiFi.RSSI(i);
    network["secure"] = WiFi.encryptionType(i) != ENC_TYPE_NONE;
    included++;
  }
  WiFi.scanDelete();
  sendJsonDocument(200, doc);
}

void handleWifiConfig() {
  if (!requestComesFromSetupNetwork()) {
    sendWifiError(403, "Configurazione disponibile solo da LightDome-Setup");
    return;
  }
  if (!littleFsMounted) {
    sendWifiError(503, "Memoria locale non disponibile");
    return;
  }

  String ssid;
  String password;
  if (server.hasArg("plain") && server.arg("plain").length() > 0) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, server.arg("plain"));
    if (err || !doc["ssid"].is<const char *>() ||
        !doc["password"].is<const char *>()) {
      sendWifiError(400, "Dati Wi-Fi non validi");
      return;
    }
    ssid = String(doc["ssid"].as<const char *>());
    password = String(doc["password"].as<const char *>());
  } else {
    ssid = server.arg("ssid");
    password = server.arg("password");
  }
  ssid.trim();
  if (!validWifiCredentials(ssid, password)) {
    sendWifiError(400,
                  "SSID richiesto; password vuota oppure da 8 a 63 caratteri");
    return;
  }
  if (!saveWifiCredentials(ssid, password)) {
    sendWifiError(500, "Impossibile salvare la configurazione");
    return;
  }

  JsonDocument response;
  response["accepted"] = true;
  response["restarting"] = true;
  sendJsonDocument(202, response);
  restartAtMs = millis() + 1500;
}

void redirectToWifiPortal() {
  String location = "http://" + WiFi.softAPIP().toString() + "/wifi";
  server.sendHeader("Location", location, true);
  server.send(302, "text/plain", "Configura LightDome su " + location);
}

void setupWiFi() {
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  String ssid;
  String password;
  if (loadWifiCredentials(ssid, password)) {
    Serial.println("Tentativo di connessione al Wi-Fi configurato...");
    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid.c_str(), password.c_str());
    uint32_t startedAt = millis();
    while (WiFi.status() != WL_CONNECTED &&
           millis() - startedAt < WIFI_CONNECT_TIMEOUT_MS) {
      delay(250);
      yield();
    }
  }
  password = "";
  if (WiFi.status() != WL_CONNECTED)
    startSetupPortal();
  else
    Serial.println("Wi-Fi collegato. IP: " + WiFi.localIP().toString());
}

void setup() {
  analogWriteRange(PWM_RANGE);
  analogWriteFreq(PWM_FREQ);
  pinMode(PIN_Y, OUTPUT);
  isOn = false;
  levelY = 0;
  hwApplyY(0);
  Serial.begin(115200);
  littleFsMounted = LittleFS.begin();
  setupWiFi();
  if (WiFi.status() == WL_CONNECTED && MDNS.begin(MDNS_NAME)) {
    MDNS.addService("http", "tcp", 80);
    mdnsActive = true;
  }
  server.onNotFound([]() {
    if (apActive)
      redirectToWifiPortal();
    else {
      sendCORS();
      server.send(404, "text/plain", "Not found");
    }
  });
  server.on("/", HTTP_GET, handleRoot);
  server.on("/wifi", HTTP_GET, handleWifiPage);
  server.on("/wifi/status", HTTP_GET, handleWifiStatus);
  server.on("/wifi/scan", HTTP_GET, handleWifiScan);
  server.on("/wifi/config", HTTP_POST, handleWifiConfig);
  server.on("/generate_204", HTTP_GET, redirectToWifiPortal);
  server.on("/hotspot-detect.html", HTTP_GET, redirectToWifiPortal);
  server.on("/ncsi.txt", HTTP_GET, redirectToWifiPortal);
  server.on("/connecttest.txt", HTTP_GET, redirectToWifiPortal);
  server.on("/status", HTTP_GET, handleStatus);
  server.on("/set", HTTP_GET, handleSet);
  server.on("/params", HTTP_GET, handleParams);
  server.on("/pattern", HTTP_POST, handlePattern);
  server.on("/play", HTTP_POST, handlePlay);
  server.on("/stop", HTTP_POST, handleStopRAM);
  server.on("/demo", HTTP_GET, handleDemo);
  server.on("/api/state", HTTP_GET, handleApiStateGet);
  server.on("/api/state", HTTP_POST, handleApiStatePost);
  server.on("/prog/save", HTTP_POST, handleProgSaveMeta, handleProgSaveUpload);
  server.on("/prog/start", HTTP_POST, handleProgStart);
  server.on("/prog/stop", HTTP_POST, handleProgStop);
  server.on("/prog/list", HTTP_GET, handleProgList);
  server.on("/prog/delete", HTTP_DELETE, handleProgDelete);
  server.on("/", HTTP_OPTIONS, handleOptions);
  server.on("/wifi", HTTP_OPTIONS, handleOptions);
  server.on("/wifi/status", HTTP_OPTIONS, handleOptions);
  server.on("/wifi/scan", HTTP_OPTIONS, handleOptions);
  server.on("/wifi/config", HTTP_OPTIONS, handleOptions);
  server.on("/status", HTTP_OPTIONS, handleOptions);
  server.on("/set", HTTP_OPTIONS, handleOptions);
  server.on("/params", HTTP_OPTIONS, handleOptions);
  server.on("/pattern", HTTP_OPTIONS, handleOptions);
  server.on("/play", HTTP_OPTIONS, handleOptions);
  server.on("/stop", HTTP_OPTIONS, handleOptions);
  server.on("/demo", HTTP_OPTIONS, handleOptions);
  server.on("/api/state", HTTP_OPTIONS, handleOptions);
  server.on("/prog/save", HTTP_OPTIONS, handleOptions);
  server.on("/prog/start", HTTP_OPTIONS, handleOptions);
  server.on("/prog/stop", HTTP_OPTIONS, handleOptions);
  server.on("/prog/list", HTTP_OPTIONS, handleOptions);
  server.on("/prog/delete", HTTP_OPTIONS, handleOptions);
  // ArduinoOTA e HTTP OTA disabilitati: non inizializzare servizi senza
  // password privata.
  server.begin();
  if (littleFsMounted && LittleFS.exists(AUTORUN_FILE)) {
    File f = LittleFS.open(AUTORUN_FILE, "r");
    String name = f.readStringUntil('\n');
    f.close();
    name.trim();
    if (LittleFS.exists(AUTORUN_LOOP)) {
      File lf = LittleFS.open(AUTORUN_LOOP, "r");
      String v = lf.readString();
      lf.close();
      loopEnabled = (v.indexOf('1') != -1);
    }
    if (name.length() && startProgramByName(name))
      Serial.println("Autorun PROGRAM: " + name +
                     (loopEnabled ? " (loop)" : ""));
  }
  Serial.println(
      "LightDome pronto. IP: " +
      (WiFi.isConnected() ? WiFi.localIP() : WiFi.softAPIP()).toString());
}

// -------------------- LOOP ------------------------------------------------
void loop() {
  server.handleClient();
  if (apActive)
    dnsServer.processNextRequest();
  if (mdnsActive)
    MDNS.update();
  if (restartAtMs != 0 && (int32_t)(millis() - restartAtMs) >= 0) {
    delay(50);
    ESP.restart();
  }
  if (programPlaying) {
    if (sampleRateHz == 0)
      sampleRateHz = 100;
    uint32_t usPer = 1000000UL / sampleRateHz;
    if ((int32_t)(micros() - lastTickUs) >= (int32_t)usPer) {
      lastTickUs += usPer;
      uint8_t buf[2];
      if (progFile.read(buf, 2) == 2) {
        uint16_t y = (uint16_t)(buf[0] | (buf[1] << 8));
        if (y > 1023)
          y = 1023;
        levelY = y;
        isOn = (y > 0);
        hwApplyY(levelY);
        frameIndex++;
      } else {
        if (loopEnabled) {
          progFile.seek(sizeof(LdyHeader), SeekSet);
          frameIndex = 0;
        } else
          stopProgram();
      }
    }
  }
  if (ramPlaying && stepCount > 0) {
    uint32_t now = millis();
    uint32_t elapsed = now - stepStartMs;
    if (elapsed >= steps[stepIndex].ms) {
      stepIndex++;
      stepStartMs = now;
      if (stepIndex >= stepCount) {
        if (loopEnabled)
          stepIndex = 0;
        else
          ramPlaying = false;
      }
    }
    if (ramPlaying) {
      uint16_t y = rgbToY_0_1023(steps[stepIndex].r, steps[stepIndex].g,
                                 steps[stepIndex].b);
      isOn = (y > 0);
      levelY = y;
      hwApplyY(levelY);
    }
  }
}
