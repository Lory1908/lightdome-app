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
// 14 bit keeps the lower fifth of the slider smooth after the gamma curve.
// With the old 10-bit range, gamma 2.0 left only ~10 physical steps at 10%.
const uint16_t PWM_RANGE = 16383;
const uint16_t PWM_FREQ = 4000; // 4 kHz

// ---- RUNTIME PARAMS ------------------------------------------------------
float gammaCurve = 2.0f;       // 1.0..3.0
float masterBrightness = 1.0f; // 0..1 (limiter globale)
bool loopEnabled = false;

// ---- STATO LIVE ----------------------------------------------------------
uint16_t levelY = 0; // 0..1023 (pre-gamma/master)
bool isOn = false;   // logico; a HW vale Y=0 se false
float renderedLevelY = 0.0f;
float transitionStartY = 0.0f;
uint16_t targetLevelY = 0;
uint16_t liveTransitionMs = 90;
uint16_t activeTransitionMs = 0;
uint32_t transitionStartedMs = 0;
uint32_t lastRenderUs = 0;
// Audio stream watchdog is opt-in: legacy /set remains unchanged.
const uint32_t AUDIO_TIMEOUT_MS = 1200;
bool audioStreamArmed = false;
uint32_t lastAudioPacketMs = 0;
String audioFallbackName;

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
  uint16_t reserved; // optional recipe JSON bytes after the samples
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

static inline float smoothStep01(float x) {
  if (x <= 0.0f)
    return 0.0f;
  if (x >= 1.0f)
    return 1.0f;
  return x * x * (3.0f - 2.0f * x);
}

void setOutputTarget(uint16_t y, uint16_t transitionMs) {
  targetLevelY = y;
  levelY = y;
  transitionStartY = renderedLevelY;
  activeTransitionMs = transitionMs;
  transitionStartedMs = millis();
  isOn = y > 0 || renderedLevelY > 0.5f;
  if (transitionMs == 0) {
    renderedLevelY = y;
    isOn = y > 0;
    hwApplyY(y);
  }
}

void updateSmoothOutput() {
  const uint32_t nowUs = micros();
  if ((uint32_t)(nowUs - lastRenderUs) < 4000)
    return;
  lastRenderUs = nowUs;
  if (activeTransitionMs == 0 || fabsf(renderedLevelY - targetLevelY) < 0.5f) {
    renderedLevelY = targetLevelY;
  } else {
    const uint32_t elapsed = millis() - transitionStartedMs;
    const float p = smoothStep01((float)elapsed / activeTransitionMs);
    renderedLevelY = transitionStartY + (targetLevelY - transitionStartY) * p;
    if (elapsed >= activeTransitionMs)
      renderedLevelY = targetLevelY;
  }
  isOn = targetLevelY > 0 || renderedLevelY > 0.5f;
  hwApplyY((uint16_t)(renderedLevelY + 0.5f));
}

void enterLiveMode() {
  // Any explicit non-audio action takes ownership away from the watchdog.
  // handleSet() can arm it again immediately when audio=1 is present.
  audioStreamArmed = false;
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
const char PAGE[] PROGMEM = R"HTML(<!doctype html>
<html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0b0e0e"><title>LightDome</title>
<style>
:root{color-scheme:light;--bg:#f3f4ef;--panel:#fff;--soft:#eef0eb;--soft2:#e5e8e1;--text:#171a19;--muted:#68706c;--line:#dce0d9;--accent:#765900;--accent2:#fff0b8;--good:#17675f;--danger:#a63a31;--shadow:#19231d12}
:root[data-theme=dark]{color-scheme:dark;--bg:#090c0c;--panel:#151919;--soft:#202525;--soft2:#292f2e;--text:#f3f5f1;--muted:#a5ada9;--line:#2b3230;--accent:#ffd66b;--accent2:#342b0e;--good:#99d8ce;--danger:#ffb4a9;--shadow:#0007}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--text);font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;min-height:100vh}button,input,select{font:inherit}button{cursor:pointer}.shell{max-width:1100px;margin:auto;padding:18px 18px 104px}
.top{display:flex;align-items:center;gap:13px;min-height:52px;margin-bottom:20px}.mark{width:46px;height:46px;border-radius:16px;background:var(--accent2);color:var(--accent);display:grid;place-items:center;font-size:13px;font-weight:850;letter-spacing:.08em}.identity{flex:1}.identity h1{font-size:22px;letter-spacing:-.04em;margin:0}.connection{display:flex;align-items:center;gap:7px;color:var(--good);font-size:12px;font-weight:750;margin-top:3px}.dot{width:7px;height:7px;border-radius:50%;background:currentColor}.iconbtn{border:1px solid var(--line);background:var(--panel);color:var(--text);border-radius:14px;padding:10px 13px;font-weight:700}
.view{display:none}.view.active{display:block}.intro{margin-bottom:16px}.intro h2{margin:0;font-size:29px;letter-spacing:-.05em}.intro p{margin:7px 0 0;color:var(--muted);line-height:1.5}.grid{display:grid;grid-template-columns:1.25fr .75fr;gap:14px}.card{background:var(--panel);border:1px solid var(--line);border-radius:26px;padding:20px;box-shadow:0 16px 40px var(--shadow)}.card h3{font-size:17px;margin:0;letter-spacing:-.02em}.sub{color:var(--muted);font-size:13px;line-height:1.45;margin:5px 0 0}
.hero{min-height:410px;display:flex;flex-direction:column}.lampwrap{display:grid;place-items:center;flex:1;padding:18px}.lamp{width:216px;height:216px;border-radius:50%;background:var(--soft2);border:2px solid var(--line);box-shadow:0 0 0 14px var(--soft);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:3px;color:var(--muted);transition:background .18s ease,box-shadow .18s ease,transform .18s ease,opacity .18s ease}.lamp strong{font-size:46px;line-height:1;letter-spacing:-.06em;font-weight:420;color:var(--text)}.lamp span{font-size:12px;font-weight:750;letter-spacing:.08em;text-transform:uppercase}.lamp.on{background:var(--accent2);border-color:var(--accent);box-shadow:0 0 0 14px var(--soft),0 0 78px color-mix(in srgb,var(--accent) 56%,transparent);transform:scale(1.025);color:var(--accent)}.lamp.on strong{color:var(--accent)}
.levelrow{display:flex;align-items:end;justify-content:space-between;margin-bottom:12px}.range{width:100%;accent-color:var(--accent);height:28px}.quick{display:grid;grid-template-columns:repeat(5,1fr);gap:7px;margin-top:12px}.quick button,.preset,.action,.ghost{border-radius:14px;padding:11px;border:1px solid var(--line);font-weight:720}.quick button,.ghost{background:var(--soft);color:var(--text)}.action{background:var(--accent);color:var(--bg);border-color:var(--accent)}.action:disabled,.ghost:disabled{opacity:.45;cursor:default}.statusline{display:flex;align-items:center;gap:10px;padding:13px 0;border-bottom:1px solid var(--line)}.statusline:last-child{border-bottom:0}.statuscopy{flex:1}.statuscopy b{display:block;font-size:14px}.statuscopy span{font-size:12px;color:var(--muted)}.value{font-size:13px;font-weight:750}
.presetrow{display:grid;grid-template-columns:repeat(4,1fr);gap:9px;margin:16px 0}.preset{background:var(--soft);color:var(--text);text-align:left;min-height:76px}.preset.active{background:var(--accent2);border-color:var(--accent);color:var(--accent)}.preset b{display:block;margin-bottom:5px}.preset span{font-size:11px;color:var(--muted)}.formgrid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.field{display:block}.field>span{display:flex;justify-content:space-between;color:var(--muted);font-size:12px;font-weight:650;margin:0 2px 7px}.field input:not([type=range]),.field select{width:100%;border:1px solid var(--line);background:var(--soft);color:var(--text);padding:12px 13px;border-radius:14px}.preview{height:132px;background:var(--soft);border-radius:18px;margin:16px 0;padding:10px}.preview canvas{width:100%;height:100%}.switchrow{display:flex;align-items:center;gap:10px;margin:11px 0}.switchrow input{width:19px;height:19px;accent-color:var(--accent)}.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:16px}.notice{margin-top:12px;padding:12px 14px;border-radius:14px;background:var(--soft);color:var(--muted);font-size:13px}.notice.good{background:#ddefe8;color:#115d51}.notice.bad{background:#f8dfdc;color:#912e27}
.programs{display:grid;gap:9px;margin-top:15px}.program{display:flex;align-items:center;gap:9px;background:var(--soft);border:1px solid var(--line);border-radius:17px;padding:13px}.programmain{flex:1;min-width:0}.programmain b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.programmain span{font-size:12px;color:var(--muted)}.program button{padding:9px 11px}.empty{padding:26px;text-align:center;color:var(--muted)}[hidden]{display:none!important}.quality{margin:14px 0 2px;padding:12px 14px;border-radius:14px;background:var(--soft);font-size:13px;color:var(--muted)}.quality b{color:var(--text)}
details{border-top:1px solid var(--line);margin-top:16px;padding-top:12px}summary{font-weight:750;cursor:pointer}.advanced{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:14px}.technical{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12px;white-space:pre-wrap;background:var(--soft);border-radius:16px;padding:14px;min-height:120px}
.guide{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:16px}.guide div{background:var(--soft);border-radius:18px;padding:16px}.guide b{display:block;margin-bottom:7px}.guide span{font-size:13px;color:var(--muted);line-height:1.45}
.nav{position:fixed;z-index:4;left:50%;bottom:max(12px,env(safe-area-inset-bottom));transform:translateX(-50%);display:grid;grid-template-columns:repeat(4,1fr);width:min(620px,calc(100% - 24px));padding:7px;background:color-mix(in srgb,var(--panel) 94%,transparent);border:1px solid var(--line);border-radius:23px;box-shadow:0 18px 50px #0004;backdrop-filter:blur(16px)}.nav button{border:0;background:transparent;color:var(--muted);padding:11px 8px;border-radius:16px;font-size:12px;font-weight:750}.nav button.active{background:var(--accent2);color:var(--accent)}
button:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:2px}@media(max-width:720px){.shell{padding:14px 12px 100px}.grid,.formgrid,.advanced{grid-template-columns:1fr}.hero{min-height:380px}.presetrow{grid-template-columns:1fr 1fr}.guide{grid-template-columns:1fr}.intro h2{font-size:25px}.lamp{width:178px;height:178px}.lamp strong{font-size:38px}.quick{grid-template-columns:repeat(5,1fr)}.quick button{padding:10px 4px;font-size:12px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
</style></head><body><main class="shell">
<header class="top"><div class="mark">LD</div><div class="identity"><h1>LightDome</h1><div class="connection"><span class="dot"></span><span id="connectionText">Cupola pronta</span></div></div><button class="iconbtn" id="themeBtn" type="button">Tema</button></header>

<section class="view active" data-view="home"><div class="intro"><h2>La tua luce, subito.</h2><p>Regola l’atmosfera. I pattern salvati continuano anche quando chiudi questa pagina.</p></div>
<div class="grid"><article class="card hero"><div class="levelrow"><div><h3>Intensità</h3><p class="sub" id="modeText">Controllo manuale</p></div></div><div class="lampwrap"><div id="lamp" class="lamp"><strong id="lampLevel">0%</strong><span id="lampState">Spenta</span></div></div><input aria-label="Intensità luce" class="range" id="level" type="range" min="0" max="1023" value="0"><div class="quick"><button data-level="0">Off</button><button data-level="256">25%</button><button data-level="512">50%</button><button data-level="767">75%</button><button data-level="1023">100%</button></div></article>
<aside class="card"><h3>Adesso</h3><p class="sub">Le informazioni utili, senza dettagli tecnici.</p><div class="statusline"><div class="statuscopy"><b>Stato</b><span id="humanState">In attesa</span></div><span class="value" id="stateBadge">—</span></div><div class="statusline"><div class="statuscopy"><b>Pattern</b><span id="programState">Nessuno in esecuzione</span></div><button class="ghost" id="stopBtn">Ferma</button></div><div class="statusline"><div class="statuscopy"><b>Continuità</b><span>La cupola lavora senza telefono</span></div><span class="value">Locale</span></div><div class="actions"><button class="action" data-go="create">Crea un pattern</button><button class="ghost" data-go="library">I miei pattern</button></div></aside></div></section>

<section class="view" data-view="create"><div class="intro"><h2>Crea un’atmosfera</h2><p>Scegli uno stile, personalizzalo e salvalo direttamente nella cupola.</p></div><article class="card"><h3>Parti da qui</h3><div class="presetrow"><button class="preset active" data-preset="breath"><b>Respiro</b><span>Morbido e continuo</span></button><button class="preset" data-preset="pulse"><b>Battito</b><span>Ritmico e definito</span></button><button class="preset" data-preset="sunrise"><b>Alba</b><span>Crescita lenta</span></button><button class="preset" data-preset="random"><b>Organico</b><span>Variazioni naturali</span></button></div>
<div class="formgrid"><label class="field"><span><b>Nome</b><em>solo lettere e numeri</em></span><input id="patternName" maxlength="32" value="respiro"></label><label class="field"><span><b>Durata ciclo</b><output id="durationOut">4,0 s</output></span><input class="range" id="duration" type="range" min="1" max="20" step=".5" value="4"></label><label class="field"><span><b>Minimo</b><output id="minOut">8%</output></span><input class="range" id="minimum" type="range" min="0" max="90" value="8"></label><label class="field"><span><b>Massimo</b><output id="maxOut">100%</output></span><input class="range" id="maximum" type="range" min="10" max="100" value="100"></label><label class="field" id="dutyField" hidden><span><b>Tempo acceso</b><output id="dutyOut">50%</output></span><input class="range" id="duty" type="range" min="5" max="95" value="50"><small class="sub">Per quanto tempo resta alla luce massima in ogni battito.</small></label><label class="field" id="randomField" hidden><span><b>Irregolarità</b><output id="randomOut">20%</output></span><input class="range" id="randomness" type="range" min="0" max="100" value="20"><small class="sub">Quanto il movimento varia invece di ripetersi sempre uguale.</small></label><label class="field"><span><b>Movimento</b><em>come accelera e rallenta</em></span><select id="easing"><option value="smooth">Morbido</option><option value="sine">Naturale</option><option value="linear">Lineare</option><option value="sharp">Netto</option></select></label></div>
<div class="preview"><canvas id="patternCanvas" width="900" height="220"></canvas></div><label class="switchrow"><input id="loop" type="checkbox" checked><span><b>Continua finché non la fermo</b><br><small class="sub">Funziona anche con app e pagina chiuse.</small></span></label><label class="switchrow"><input id="autorun" type="checkbox"><span><b>Riparti dopo uno spegnimento</b><br><small class="sub">Imposta questo pattern come avvio automatico.</small></span></label>
<div class="quality"><b>Qualità alta</b> · 250 aggiornamenti al secondo, scelta automaticamente.</div>
<div class="actions"><button class="ghost" id="tryPattern">Prova sulla cupola</button><button class="ghost" id="stopPreview" disabled>Ferma prova</button><button class="action" id="savePattern">Salva e avvia</button></div><div class="notice" id="createNotice">Pronto per creare il pattern.</div></article></section>

<section class="view" data-view="library"><div class="intro"><h2>I tuoi pattern</h2><p>Sono conservati nella cupola e non dipendono dall’app.</p></div><article class="card"><div class="levelrow"><div><h3>Libreria locale</h3><p class="sub">Avvia, sostituisci o rimuovi un pattern.</p></div><button class="ghost" id="refreshPrograms">Aggiorna</button></div><div class="programs" id="programs"><div class="empty">Caricamento…</div></div><details><summary>Importa un file .ldy</summary><div class="formgrid" style="margin-top:14px"><label class="field"><span><b>Nome</b></span><input id="importName" placeholder="nome_pattern"></label><label class="field"><span><b>File</b></span><input id="importFile" type="file" accept=".ldy"></label></div><div class="actions"><button class="action" id="importBtn">Importa</button></div></details><div class="notice" id="libraryNotice">I pattern avviati continuano anche senza questa pagina.</div></article></section>

<section class="view" data-view="more"><div class="intro"><h2>Aiuto e impostazioni</h2><p>Le azioni quotidiane restano semplici; i dettagli tecnici sono qui quando servono.</p></div><article class="card"><h3>Primi passi</h3><div class="guide"><div><b>1. Regola</b><span>Usa Home per cambiare la luce in tempo reale.</span></div><div><b>2. Crea</b><span>Personalizza un preset e controlla l’anteprima.</span></div><div><b>3. Lascia fare</b><span>Salva: la cupola continuerà da sola.</span></div></div><details><summary>Controlli avanzati</summary><div class="advanced"><label class="field"><span><b>Limite luminosità</b><output id="masterOut">100%</output></span><input class="range" id="master" type="range" min="0" max="100" value="100"></label><label class="field"><span><b>Gamma</b><output id="gammaOut">2,0</output></span><input class="range" id="gamma" type="range" min="10" max="30" value="20"></label></div><div class="actions"><a class="ghost" href="/wifi" style="text-decoration:none">Configura Wi-Fi</a></div></details><details><summary>Diagnostica</summary><pre class="technical" id="technical">Caricamento…</pre></details></article></section>
</main><nav class="nav" aria-label="Navigazione principale"><button class="active" data-nav="home">Home</button><button data-nav="create">Crea</button><button data-nav="library">Pattern</button><button data-nav="more">Altro</button></nav>
<script>
const $=id=>document.getElementById(id),state={drag:false,last:null,preset:'breath',programs:[]};let sendTimer=0,paramTimer=0;
function applyTheme(v){document.documentElement.dataset.theme=v;localStorage.setItem('ld-theme',v)}applyTheme(localStorage.getItem('ld-theme')||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'));$('themeBtn').onclick=()=>applyTheme(document.documentElement.dataset.theme==='dark'?'light':'dark');
function go(name){document.querySelectorAll('.view').forEach(v=>v.classList.toggle('active',v.dataset.view===name));document.querySelectorAll('[data-nav]').forEach(b=>b.classList.toggle('active',b.dataset.nav===name));if(location.hash!=='#'+name)history.replaceState(null,'','#'+name);scrollTo({top:0,behavior:'smooth'});if(name==='library')loadPrograms()}document.querySelectorAll('[data-nav]').forEach(b=>b.onclick=()=>go(b.dataset.nav));document.querySelectorAll('[data-go]').forEach(b=>b.onclick=()=>go(b.dataset.go));
function renderLevel(v){const p=Math.round(v/10.23),on=v>0;$('lampLevel').textContent=p+'%';$('lampState').textContent=on?'Anteprima luce':'Spenta';$('lamp').classList.toggle('on',on);$('lamp').style.opacity=(on?(.72+.28*p/100):1).toFixed(2)}
function queueLevel(v,final=false){renderLevel(v);clearTimeout(sendTimer);sendTimer=setTimeout(()=>fetch('/set?y='+Math.round(v)+'&smooth='+(final?70:110)).catch(()=>{}),final?0:45)}
$('level').onpointerdown=()=>state.drag=true;$('level').oninput=e=>queueLevel(+e.target.value);$('level').onchange=e=>{state.drag=false;queueLevel(+e.target.value,true)};document.querySelectorAll('[data-level]').forEach(b=>b.onclick=()=>{$('level').value=b.dataset.level;queueLevel(+b.dataset.level,true)});$('stopBtn').onclick=async()=>{await fetch('/prog/stop',{method:'POST'});await fetch('/set?y=0&smooth=120');refreshState()};
async function refreshState(){try{const r=await fetch('/status'),s=await r.json();state.last=s;$('connectionText').textContent='Cupola pronta';if(!state.drag){$('level').value=s.levelY;renderLevel(s.levelY)}$('master').value=Math.round(s.masterBrightness*100);$('gamma').value=Math.round(s.gamma*10);$('masterOut').textContent=Math.round(s.masterBrightness*100)+'%';$('gammaOut').textContent=s.gamma.toFixed(1).replace('.',',');const playing=s.mode.programPlaying;$('modeText').textContent=playing?'Pattern autonomo':'Controllo manuale';$('humanState').textContent=playing?'Sta riproducendo un pattern':s.on?'Luce accesa e pronta':'Luce spenta e pronta';$('stateBadge').textContent=s.on?'Accesa':'Spenta';$('programState').textContent=playing?(s.mode.programName||'Pattern in esecuzione'):'Nessuno in esecuzione';$('technical').textContent=JSON.stringify(s,null,2)}catch(e){$('connectionText').textContent='Connessione interrotta';$('humanState').textContent='Non riesco a raggiungere la cupola';$('stateBadge').textContent='Offline'}}
function queueParams(){clearTimeout(paramTimer);paramTimer=setTimeout(()=>fetch('/params?brightness='+$('master').value+'&gamma='+($('gamma').value/10).toFixed(1)+'&loop='+($('loop').checked?1:0)),100)}$('master').oninput=()=>{$('masterOut').textContent=$('master').value+'%';queueParams()};$('gamma').oninput=()=>{$('gammaOut').textContent=($('gamma').value/10).toFixed(1).replace('.',',');queueParams()};
const inputs=['duration','minimum','maximum','duty','randomness','easing'];inputs.forEach(id=>$(id).oninput=updateBuilder);
function setPreset(type,rename=true){state.preset=type;document.querySelectorAll('[data-preset]').forEach(x=>x.classList.toggle('active',x.dataset.preset===type));const p={breath:[4,8,100,50,'smooth',20],pulse:[1.4,5,100,35,'sharp',20],sunrise:[12,2,100,80,'sine',20],random:[6,18,82,50,'smooth',55]}[type];$('duration').value=p[0];$('minimum').value=p[1];$('maximum').value=p[2];$('duty').value=p[3];$('easing').value=p[4];$('randomness').value=p[5];if(rename)$('patternName').value=type==='breath'?'respiro':type==='pulse'?'battito':type==='sunrise'?'alba':'organico';updateBuilder()}
document.querySelectorAll('[data-preset]').forEach(b=>b.onclick=()=>setPreset(b.dataset.preset));
function ease(t,type){if(type==='linear')return t;if(type==='sharp')return t<.5?2*t*t:1-Math.pow(-2*t+2,2)/2;if(type==='sine')return-(Math.cos(Math.PI*t)-1)/2;return t*t*(3-2*t)}
function valueAt(t){const min=+$('minimum').value/100,max=+$('maximum').value/100,duty=+$('duty').value/100,e=$('easing').value;if(state.preset==='sunrise')return min+(max-min)*ease(t,e);if(state.preset==='pulse'){const edge=.12;if(t<duty){const q=t/duty;return q<edge?min+(max-min)*ease(q/edge,e):q>1-edge?max-(max-min)*ease((q-1+edge)/edge,e):max}return min}if(state.preset==='random'){const wobble=(Math.sin(t*19.7)+Math.sin(t*43.1)*.45+Math.sin(t*7.3)*.7)/2.15*.5+.5;const mix=+$('randomness').value/100;const base=(1-Math.cos(t*Math.PI*2))/2;return min+(max-min)*(base*(1-mix)+wobble*mix)}const wave=(1-Math.cos(t*Math.PI*2))/2;return min+(max-min)*ease(wave,e)}
function updateBuilder(){$('durationOut').textContent=(+$('duration').value).toFixed(1).replace('.',',')+' s';$('minOut').textContent=$('minimum').value+'%';$('maxOut').textContent=$('maximum').value+'%';$('dutyOut').textContent=$('duty').value+'%';$('randomOut').textContent=$('randomness').value+'%';$('dutyField').hidden=state.preset!=='pulse';$('randomField').hidden=state.preset!=='random';if(+$('minimum').value>+$('maximum').value)$('minimum').value=$('maximum').value;drawPreview()}
function drawPreview(){const c=$('patternCanvas'),x=c.getContext('2d'),w=c.width,h=c.height;x.clearRect(0,0,w,h);x.strokeStyle=getComputedStyle(document.documentElement).getPropertyValue('--line');x.lineWidth=2;for(let i=1;i<4;i++){x.beginPath();x.moveTo(0,h*i/4);x.lineTo(w,h*i/4);x.stroke()}x.strokeStyle=getComputedStyle(document.documentElement).getPropertyValue('--accent');x.lineWidth=7;x.lineCap='round';x.beginPath();for(let i=0;i<=w;i++){const y=h-12-valueAt(i/w)*(h-24);i?x.lineTo(i,y):x.moveTo(i,y)}x.stroke()}
function recipeData(){return{preset:state.preset,duration:+$('duration').value,minimum:+$('minimum').value,maximum:+$('maximum').value,duty:+$('duty').value,easing:$('easing').value,randomness:+$('randomness').value,loop:$('loop').checked,autorun:$('autorun').checked}}
function makeLdy(){const sr=250,duration=+$('duration').value,frames=Math.max(2,Math.round(sr*duration)),meta=new TextEncoder().encode(JSON.stringify(recipeData())),buf=new ArrayBuffer(12+frames*2+meta.length),v=new DataView(buf);v.setUint8(0,76);v.setUint8(1,68);v.setUint8(2,89);v.setUint8(3,49);v.setUint16(4,sr,true);v.setUint32(6,frames,true);v.setUint16(10,meta.length,true);for(let i=0;i<frames;i++)v.setUint16(12+i*2,Math.round(valueAt(i/(frames-1))*1023),true);new Uint8Array(buf,12+frames*2).set(meta);return buf}
function validName(n){return /^[A-Za-z0-9_-]{1,48}$/.test(n)}
async function uploadGenerated(preview=false){const requested=$('patternName').value.trim();if(!validName(requested)){showNotice('createNotice','Usa un nome breve con lettere, numeri, trattino o underscore.','bad');return}const n=preview?'_anteprima':requested;showNotice('createNotice',preview?'Preparo la prova sulla cupola…':'Sto salvando il pattern nella cupola…');try{await fetch('/params?loop='+(preview?0:($('loop').checked?1:0)));const form=new FormData();form.append('file',new Blob([makeLdy()],{type:'application/octet-stream'}),n+'.ldy');const r=await fetch('/prog/save?name='+encodeURIComponent(n)+'&autorun='+(preview?0:($('autorun').checked?1:0)),{method:'POST',body:form});const t=await r.text();if(!r.ok)throw Error(t);await fetch('/prog/start?name='+encodeURIComponent(n),{method:'POST'});$('stopPreview').disabled=!preview;showNotice('createNotice',preview?'Prova avviata: esegue un ciclo e poi spegne la luce.':'Pattern salvato e avviato. Puoi chiudere la pagina.','good');refreshState()}catch(e){showNotice('createNotice','Non sono riuscito a salvare: '+e.message,'bad')}}
async function stopPreview(){await fetch('/prog/stop',{method:'POST'});await fetch('/set?y=0&smooth=120');await fetch('/prog/delete?name=_anteprima',{method:'DELETE'}).catch(()=>{});$('stopPreview').disabled=true;showNotice('createNotice','Prova fermata.','good');refreshState()}
function showNotice(id,text,type=''){$(id).textContent=text;$(id).className='notice '+type}$('tryPattern').onclick=()=>uploadGenerated(true);$('stopPreview').onclick=stopPreview;$('savePattern').onclick=()=>uploadGenerated(false);
function applyRecipe(m,n){state.preset=m.preset||'breath';document.querySelectorAll('[data-preset]').forEach(x=>x.classList.toggle('active',x.dataset.preset===state.preset));$('patternName').value=n;$('duration').value=m.duration??4;$('minimum').value=m.minimum??8;$('maximum').value=m.maximum??100;$('duty').value=m.duty??50;$('easing').value=m.easing||'smooth';$('randomness').value=m.randomness??20;$('loop').checked=m.loop!==false;$('autorun').checked=m.autorun===true;updateBuilder();go('create')}
async function editProgram(n){try{const r=await fetch('/prog/meta?name='+encodeURIComponent(n));if(!r.ok)throw Error();applyRecipe(await r.json(),n);showNotice('createNotice','Pattern caricato. Modificalo e premi Salva e avvia.','good')}catch(e){const lower=n.toLowerCase(),guess=lower.includes('batt')?'pulse':lower.includes('alb')?'sunrise':lower.includes('organ')?'random':'breath';setPreset(guess,false);$('patternName').value=n;go('create');showNotice('createNotice','Questo pattern è precedente all’editor: ho ricostruito una base modificabile.','good')}}
async function loadPrograms(){const box=$('programs');box.innerHTML='<div class="empty">Caricamento…</div>';try{const t=await fetch('/prog/list').then(r=>r.text()),items=t.split('\n').map(x=>x.trim()).filter(x=>x&&x!=='(vuoto)').map(x=>x.replace(/^\/prog\//,'').replace(/\.ldy.*$/,'')).filter(x=>x!=='_anteprima');state.programs=items;box.replaceChildren();if(!items.length){box.innerHTML='<div class="empty">Non hai ancora salvato pattern.</div>';return}items.forEach(n=>{const row=document.createElement('div');row.className='program';const main=document.createElement('div');main.className='programmain';const b=document.createElement('b');b.textContent=n;const s=document.createElement('span');s.textContent=state.last?.mode?.programName===n?'In esecuzione':'Salvato nella cupola';main.append(b,s);const edit=document.createElement('button');edit.className='ghost';edit.textContent='Modifica';edit.onclick=()=>editProgram(n);const play=document.createElement('button');play.className='action';play.textContent='Avvia';play.onclick=async()=>{await fetch('/prog/start?name='+encodeURIComponent(n),{method:'POST'});showNotice('libraryNotice','Pattern avviato. Continuerà anche chiudendo la pagina.','good');loadPrograms();refreshState()};const del=document.createElement('button');del.className='ghost';del.textContent='Elimina';del.onclick=async()=>{if(!confirm('Eliminare '+n+'?'))return;await fetch('/prog/delete?name='+encodeURIComponent(n),{method:'DELETE'});loadPrograms()};row.append(main,edit,play,del);box.append(row)})}catch(e){box.innerHTML='<div class="empty">Impossibile leggere la libreria.</div>'}}
$('refreshPrograms').onclick=loadPrograms;$('importBtn').onclick=async()=>{const n=$('importName').value.trim(),f=$('importFile').files[0];if(!validName(n)||!f){showNotice('libraryNotice','Scegli un file e inserisci un nome valido.','bad');return}const form=new FormData();form.append('file',f,f.name);const r=await fetch('/prog/save?name='+encodeURIComponent(n)+'&autorun=0',{method:'POST',body:form}),t=await r.text();showNotice('libraryNotice',t,r.ok?'good':'bad');loadPrograms()};
updateBuilder();go(['home','create','library','more'].includes(location.hash.slice(1))?location.hash.slice(1):'home');refreshState();setInterval(refreshState,1200);
</script></body></html>)HTML";

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
  if (apActive)
    server.send_P(200, "text/html", WIFI_PAGE);
  else
    server.send_P(200, "text/html", PAGE);
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
  doc["outputLevelY"] = (uint16_t)(renderedLevelY + 0.5f);
  doc["targetLevelY"] = targetLevelY;
  doc["smoothMs"] = liveTransitionMs;
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
  audioStreamArmed = server.hasArg("audio") && server.arg("audio") == "1";
  if (audioStreamArmed)
    lastAudioPacketMs = millis();
  levelY = clamp16(server.arg("y").toInt(), 0, 1023);
  uint16_t transitionMs = liveTransitionMs;
  if (server.hasArg("smooth"))
    transitionMs = clamp16(server.arg("smooth").toInt(), 0, 1000);
  setOutputTarget(levelY, transitionMs);
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
  hwApplyY((uint16_t)(renderedLevelY + 0.5f));
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
  setOutputTarget(0, liveTransitionMs);
  server.send(200, "text/plain", "Stop RAM");
}
void handleDemo() {
  sendCORS();
  enterLiveMode();
  for (int i = 0; i <= 1023; i += 16) {
    setOutputTarget(i, 0);
    delay(2);
  }
  for (int i = 1023; i >= 0; i -= 16) {
    setOutputTarget(i, 0);
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
  doc["outputLevel"] = (uint16_t)(renderedLevelY + 0.5f);
  doc["targetLevel"] = targetLevelY;
  doc["smoothMs"] = liveTransitionMs;
  doc["audioStreamActive"] = audioStreamArmed;
  doc["audioFallback"] = audioFallbackName;
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
  audioStreamArmed = false;
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
  uint16_t smoothMs = liveTransitionMs;
  if (!doc["smoothMs"].isNull())
    smoothMs = clamp16(doc["smoothMs"].as<int>(), 0, 1000);
  setOutputTarget(reqOn ? clamp16(tgtY, 0, 1023) : 0, smoothMs);
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

  if (h.reserved > 2048)
    return false;
  uint64_t expectedSize = sizeof(LdyHeader) +
                          (uint64_t)h.frames * sizeof(uint16_t) + h.reserved;
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
  audioStreamArmed = false;
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
  String requestedName = server.hasArg("name") ? server.arg("name") : String();
  if (!requestedName.length() || !isValidProgramName(requestedName)) {
    if (uploadTempPath.length())
      LittleFS.remove(uploadTempPath);
    server.send(400, "text/plain", "Nome programma non valido");
    return;
  }
  uploadName = requestedName;
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
  } else if (LittleFS.exists(AUTORUN_FILE)) {
    // Turning autorun off while replacing its current pattern must also clear
    // the persisted boot selection. Leave a different autorun pattern alone.
    File autorunFile = LittleFS.open(AUTORUN_FILE, "r");
    String autorunName;
    if (autorunFile) {
      autorunName = autorunFile.readStringUntil('\n');
      autorunFile.close();
      autorunName.trim();
    }
    if (autorunName == uploadName) {
      LittleFS.remove(AUTORUN_FILE);
      LittleFS.remove(AUTORUN_LOOP);
    }
  }
  server.send(200, "text/plain", "Salvato: " + uploadName);
}

void handleProgSaveUpload() {
  HTTPUpload &up = server.upload();
  if (up.status == UPLOAD_FILE_START) {
    uploadName = "";
    uploadTempPath = "";
    uploadCompleted = false;
    uploadAborted = false;
    uploadHasError = false;
    uploadErrorMessage = "";
    if (!littleFsMounted) {
      uploadHasError = true;
      uploadErrorMessage = "LittleFS non disponibile";
      return;
    }
    LittleFS.mkdir(PROG_DIR);
    uploadTempPath = String(PROG_DIR) + "/.incoming.upload";
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

void handleProgMeta() {
  sendCORS();
  if (!littleFsMounted || !server.hasArg("name")) {
    server.send(400, "text/plain", "name mancante");
    return;
  }
  String n = server.arg("name");
  if (!isValidProgramName(n)) {
    server.send(400, "text/plain", "Nome programma non valido");
    return;
  }
  File f = LittleFS.open(programPath(n), "r");
  LdyHeader h;
  if (!f || !validateLdyFile(f, h)) {
    if (f) f.close();
    server.send(404, "text/plain", "Pattern non trovato");
    return;
  }
  if (h.reserved == 0) {
    f.close();
    server.send(404, "text/plain", "Parametri editor non disponibili");
    return;
  }
  f.seek(sizeof(LdyHeader) + h.frames * sizeof(uint16_t), SeekSet);
  String metadata;
  metadata.reserve(h.reserved);
  for (uint16_t i = 0; i < h.reserved && f.available(); ++i)
    metadata += (char)f.read();
  f.close();
  JsonDocument doc;
  if (deserializeJson(doc, metadata)) {
    server.send(400, "text/plain", "Parametri editor non validi");
    return;
  }
  server.send(200, "application/json", metadata);
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

// -------------------- Audio watchdog configuration --------------------------
// Optional and volatile: no flash writes for frequently changing audio modes.
void handleAudioConfig() {
  sendCORS();
  if (!server.hasArg("plain")) {
    server.send(400, "text/plain", "JSON mancante");
    return;
  }
  JsonDocument doc;
  if (deserializeJson(doc, server.arg("plain"))) {
    server.send(400, "text/plain", "JSON non valido");
    return;
  }
  if (!doc["fallback"].isNull() && !doc["fallback"].is<const char *>()) {
    server.send(400, "text/plain", "Fallback non valido");
    return;
  }
  const String name = doc["fallback"].isNull()
                          ? String()
                          : String(doc["fallback"].as<const char *>());
  if (name.length() && (!isValidProgramName(name) || !littleFsMounted ||
                        !LittleFS.exists(programPath(name)))) {
    server.send(400, "text/plain", "Pattern di riserva non disponibile");
    return;
  }
  audioFallbackName = name;
  server.send(204);
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
  server.send_P(200, "text/html", WIFI_PAGE);
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
  server.on("/prog/meta", HTTP_GET, handleProgMeta);
  server.on("/audio/config", HTTP_POST, handleAudioConfig);
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
  server.on("/prog/meta", HTTP_OPTIONS, handleOptions);
  server.on("/audio/config", HTTP_OPTIONS, handleOptions);
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
  if (audioStreamArmed && (uint32_t)(millis() - lastAudioPacketMs) > AUDIO_TIMEOUT_MS) {
    audioStreamArmed = false;
    // A disconnected phone/computer must not leave the last light value on.
    if (audioFallbackName.isEmpty() || !startProgramByName(audioFallbackName))
      setOutputTarget(0, 350);
  }
  if (programPlaying) {
    if (sampleRateHz == 0)
      sampleRateHz = 100;
    uint32_t usPer = 1000000UL / sampleRateHz;
    if ((int32_t)(micros() - lastTickUs) >= (int32_t)usPer) {
      lastTickUs += usPer;
      if (frameIndex >= frameCount) {
        if (loopEnabled) {
          progFile.seek(sizeof(LdyHeader), SeekSet);
          frameIndex = 0;
        } else {
          bool wasPreview = programName == "_anteprima";
          stopProgram();
          if (wasPreview)
            setOutputTarget(0, 120);
        }
      }
      if (programPlaying) {
        uint8_t buf[2];
        if (progFile.read(buf, 2) == 2) {
          uint16_t y = (uint16_t)(buf[0] | (buf[1] << 8));
          if (y > 1023)
            y = 1023;
          setOutputTarget(y, 0);
          frameIndex++;
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
      setOutputTarget(y, 0);
    }
  }
  if (!programPlaying && !ramPlaying)
    updateSmoothOutput();
}
