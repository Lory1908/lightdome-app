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
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LightDome - Mono</title>
<style>
 body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;margin:16px;max-width:980px}
 h1{margin:0 0 12px}
 .row{display:flex;gap:12px;flex-wrap:wrap}
 .card{border:1px solid #ddd;border-radius:10px;padding:12px;flex:1;min-width:280px}
 label{display:block;font-size:14px;margin:6px 0}
 input[type=range]{width:100%}
 textarea{width:100%;min-height:180px;font-family:ui-monospace,Consolas,monospace}
 button{padding:8px 14px;border-radius:8px;border:1px solid #444;background:#fff;cursor:pointer}
 .on{background:#1a73e8;color:#fff;border-color:#1a73e8}
 .mono{font-family:ui-monospace,Consolas,monospace}
 .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 .muted{color:#666}
</style>
</head>
<body>
<h1>LightDome - Mono</h1>

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
      <input id="fname" placeholder="nome programma (es. song1)" />
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
    <textarea id="pat" placeholder="Esempio:\n100,0\n500,1023\n300,400\n300,0"></textarea>
    <div style="margin-top:8px">
      <button class="on" onclick="uploadPattern()">Carica</button>
      <button onclick="play()">Play</button>
      <button onclick="stopPlay()">Stop</button>
      <button onclick="clearArea()">Clear</button>
    </div>
    <h3>Stato</h3>
    <div id="st" class="mono">...</div>
  </div>
</div>

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
<html lang="it"><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Configura LightDome</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;background:#f4f5f7;margin:0;color:#202124}
main{max-width:520px;margin:32px auto;padding:16px}.card{background:#fff;border-radius:16px;padding:22px;box-shadow:0 6px 24px #0002}
h1{margin:0 0 8px;font-size:26px}p{line-height:1.45}.muted{color:#5f6368;font-size:14px}
label{display:block;margin:16px 0 6px;font-weight:600}input,select,button{box-sizing:border-box;width:100%;font:inherit;padding:12px;border-radius:10px;border:1px solid #b8bdc5}
button{margin-top:14px;background:#3157d5;color:#fff;border:0;font-weight:700;cursor:pointer}button.secondary{background:#eef1fb;color:#2443a4}
button:disabled{opacity:.55;cursor:wait}#msg{white-space:pre-wrap;margin-top:14px;padding:10px;border-radius:9px;background:#f1f3f4;min-height:20px}.ok{background:#e6f4ea!important;color:#137333}.err{background:#fce8e6!important;color:#b3261e}
</style></head><body><main><div class="card">
<h1>Configura LightDome</h1>
<p>Collega la cupola al Wi-Fi di casa. La password resta memorizzata solo nella scheda.</p>
<button id="scan" class="secondary" type="button">Cerca reti Wi-Fi</button>
<label for="ssid">Rete Wi-Fi</label><input id="ssid" list="nets" maxlength="32" autocomplete="off" placeholder="Nome della rete"><datalist id="nets"></datalist>
<label for="pass">Password</label><input id="pass" type="password" maxlength="63" autocomplete="current-password" placeholder="Lascia vuoto solo per reti aperte">
<button id="save" type="button">Salva e collega</button>
<div id="msg">Pronto.</div>
<p class="muted">Dopo il salvataggio la scheda si riavvia. Ricollega questo dispositivo al Wi-Fi di casa e apri <b>http://lightdome.local</b>.</p>
</div></main><script>
const $=id=>document.getElementById(id),msg=$('msg');
function show(t,c=''){msg.textContent=t;msg.className=c}
async function scan(){const b=$('scan');b.disabled=true;show('Ricerca reti in corso…');try{const r=await fetch('/wifi/scan');const j=await r.json();if(!r.ok)throw Error(j.error||'Ricerca non riuscita');const d=$('nets');d.replaceChildren();j.networks.forEach(n=>{const o=document.createElement('option');o.value=n.ssid;o.label=`${n.ssid} (${n.rssi} dBm${n.secure?', protetta':''})`;d.appendChild(o)});show(`${j.networks.length} reti trovate.`,'ok')}catch(e){show(e.message,'err')}finally{b.disabled=false}}
async function save(){const ssid=$('ssid').value.trim(),password=$('pass').value,b=$('save');if(!ssid){show('Scegli o inserisci una rete.','err');return}b.disabled=true;show('Salvataggio…');try{const r=await fetch('/wifi/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid,password})});const j=await r.json();if(!r.ok)throw Error(j.error||'Configurazione non riuscita');$('pass').value='';show('Configurazione salvata. LightDome si riavvia e prova a collegarsi al Wi-Fi.','ok')}catch(e){show(e.message,'err');b.disabled=false}}
$('scan').onclick=scan;$('save').onclick=save;scan();
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
