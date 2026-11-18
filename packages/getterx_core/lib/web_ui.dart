/// "GetterX Lite": the full GetterX feature set as a local web page, served by
/// the CLI. Used on systems the desktop app cannot run on (32-bit Windows /
/// Linux, 32-bit ARM, RISC-V, old OS versions, headless servers).
///
/// Security: binds to 127.0.0.1 only; every API call needs a random per-run
/// token in a custom header (blocks CSRF from other sites); the Host header
/// must be the loopback address (blocks DNS rebinding).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'engine.dart';
import 'models.dart';
import 'selector.dart';
import 'store.dart';

class WebUi {
  final Engine engine;
  final ConfigStore store;
  final String token;
  final _progress = <String, Progress>{};
  HttpServer? _server;
  Timer? _timer;

  WebUi(this.engine, this.store) : token = _randomToken() {
    engine.progress.listen((p) => _progress[p.sourceId] = p);
  }

  static String _randomToken() {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(24, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  static const editableSourceKeys = {
    'name', 'enabled', 'mode', 'downloadDir', 'channels', 'preferStable', 'includeFilesRegex', //
    'excludeFilesRegex', 'fileTypes', 'versionRegex', 'linkRegex', 'versionExtractRegex', 'onlyPlatformFiles',
    'includeSourceArchives', 'tagsFallback', 'keepOld', 'keepCount', 'loaders', 'gameVersions', 'gameVersionLimit',
    'includeSnapshots', 'groupMinorVersions', 'primaryFileOnly',
  };

  Future<Uri> start({int port = 8765}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    _schedule();
    return Uri.parse('http://127.0.0.1:${_server!.port}/#$token');
  }

  void _schedule() {
    _timer?.cancel();
    final m = store.config.settings.checkIntervalMinutes;
    if (m > 0) _timer = Timer.periodic(Duration(minutes: m), (_) => engine.checkAll());
  }

  Future<void> close() async {
    _timer?.cancel();
    await _server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('X-Frame-Options', 'DENY')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Cache-Control', 'no-store');
    try {
      final host = (req.headers.host ?? '').toLowerCase();
      if (host != '127.0.0.1' && host != 'localhost') {
        return await _send(res, 403, {'error': 'forbidden host'});
      }
      final path = req.uri.path;
      if (path == '/' && req.method == 'GET') {
        res.headers
          ..contentType = ContentType.html
          ..set(
            'Content-Security-Policy',
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:",
          );
        res.write(_page);
        await res.close();
        return;
      }
      if (!path.startsWith('/api/')) return await _send(res, 404, {'error': 'not found'});
      if (req.headers.value('x-getterx-token') != token) return await _send(res, 401, {'error': 'bad token'});
      final body = req.method == 'POST' ? await _readJson(req) : const <String, dynamic>{};
      await store.reload();
      switch ('${req.method} $path') {
        case 'GET /api/state':
          return await _send(res, 200, _state());
        case 'GET /api/log':
          return await _send(res, 200, {
            'log': [for (final e in store.readLog(max: 300)) e.toJson()],
          });
        case 'POST /api/add':
          final s = await engine.createFromLink('${body['link'] ?? ''}');
          await store.saveSource(s);
          unawaited(engine.check(s.id));
          return await _send(res, 200, {'id': s.id});
        case 'POST /api/source':
          final cur = store.config.sources.firstWhere((s) => s.id == body['id']);
          final j = cur.toJson();
          for (final k in editableSourceKeys) {
            if (body.containsKey(k)) j[k] = body[k];
          }
          final updated = TrackedSource.fromJson(j);
          for (final re in [
            updated.includeFilesRegex,
            updated.excludeFilesRegex,
            updated.versionRegex,
            updated.linkRegex,
            updated.versionExtractRegex,
          ]) {
            if (re.isNotEmpty) RegExp(re); // throws FormatException on invalid input
          }
          await store.saveSource(updated);
          return await _send(res, 200, {'ok': true});
        case 'POST /api/check':
          final id = body['id'] as String?;
          unawaited(id == null ? engine.checkAll() : engine.check(id));
          return await _send(res, 200, {'ok': true});
        case 'POST /api/preview':
          final s = store.config.sources.firstWhere((s) => s.id == body['id']);
          final plan = await engine.preview(s);
          return await _send(res, 200, {
            'downloads': [
              for (final d in plan.downloads)
                {'version': d.release.version, 'folder': d.folder, 'files': d.files.map((f) => f.name).toList()},
            ],
            'delete': [for (final d in plan.delete) d.version],
            'archive': [for (final d in plan.archive) d.version],
          });
        case 'POST /api/remove':
          final s = store.config.sources.firstWhere((s) => s.id == body['id']);
          if (body['deleteFiles'] == true) await engine.deleteAllFiles(s);
          await store.removeSource(s.id);
          return await _send(res, 200, {'ok': true});
        case 'POST /api/settings':
          final st = store.config.settings;
          if (body['downloadDir'] is String) st.downloadDir = (body['downloadDir'] as String).trim();
          if (body['checkIntervalMinutes'] is int) st.checkIntervalMinutes = body['checkIntervalMinutes'] as int;
          if (body['curseforgeBaseUrl'] is String) {
            final b = (body['curseforgeBaseUrl'] as String).trim();
            if (b.isNotEmpty && !b.startsWith('https://')) throw const FormatException('must start with https://');
            st.curseforgeBaseUrl = b;
          }
          if (const {'system', 'light', 'dark', 'oled'}.contains(body['themeMode'])) {
            st.themeMode = body['themeMode'] as String;
          }
          await store.saveSettings();
          _schedule();
          return await _send(res, 200, {'ok': true});
      }
      return await _send(res, 404, {'error': 'not found'});
    } catch (e) {
      return await _send(res, 400, {'error': '$e'});
    }
  }

  Map<String, dynamic> _state() => {
    'settings': {
      ...store.config.settings.toJson(),
      'defaultDownloadRoot': engine.defaultDownloadRoot,
      'downloadRoot': engine.downloadRoot,
      'dataDir': store.dataDir.path,
      'platform': '${engine.platform.os} ${engine.platform.arch}',
      'credentials': {
        'github': engine.credentials.githubToken.isNotEmpty,
        'curseforge': engine.credentials.curseforgeApiKey.isNotEmpty,
        'itchio': engine.credentials.itchApiKey.isNotEmpty,
        'modrinth': engine.credentials.modrinthToken.isNotEmpty,
      },
    },
    'sources': [
      for (final s in store.config.sources)
        {
          ...s.toJson()..remove('downloads'),
          'kindLabel': sourceKindLabel(s.kind),
          'modeLabel': trackModeLabel(s.mode),
          'isMod': s.isMod,
          'folder': engine.folderFor(s),
          'running': engine.isRunning(s.id),
          'progress': _progress[s.id]?.message,
          'fraction': _progress[s.id]?.fraction,
          'records': [
            for (final d in s.downloads) {...d.toJson(), 'old': isArchivedSlot(d.slot), 'label': baseSlot(d.slot)},
          ],
        },
    ],
  };

  static Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.length > 1 << 20) throw const FormatException('too large');
    return text.isEmpty ? {} : (jsonDecode(text) as Map).cast<String, dynamic>();
  }

  static Future<void> _send(HttpResponse res, int code, Object body) async {
    res
      ..statusCode = code
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }
}

const _page = r'''<!doctype html>
<html lang="en" data-theme="system"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>GetterX Lite</title>
<style>
:root{--bg:#f6f9f5;--card:#fff;--fg:#17201a;--mut:#5b6b60;--acc:#1a7f45;--err:#b3261e;--line:#dfe7e0}
:root[data-theme=dark]{--bg:#101512;--card:#18201b;--fg:#e3ebe5;--mut:#9fb0a5;--acc:#4fd88a;--err:#ffb4ab;--line:#2a352e}
:root[data-theme=oled]{--bg:#000;--card:#0a0a0a;--fg:#e8ece9;--mut:#9aa39d;--acc:#4fd88a;--err:#ffb4ab;--line:#1c1f1d}
@media (prefers-color-scheme:dark){:root[data-theme=system]{--bg:#101512;--card:#18201b;--fg:#e3ebe5;--mut:#9fb0a5;--acc:#4fd88a;--err:#ffb4ab;--line:#2a352e}}
*{box-sizing:border-box}body{margin:0;font:15px/1.45 system-ui,sans-serif;background:var(--bg);color:var(--fg)}
header{display:flex;gap:8px;align-items:center;padding:12px 16px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg)}
header h1{font-size:20px;margin:0 auto 0 0}main{max-width:900px;margin:0 auto;padding:16px}
button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:20px;padding:6px 14px;cursor:pointer}
button.p{background:var(--acc);border-color:var(--acc);color:#fff}button:disabled{opacity:.5}
input,select,textarea{font:inherit;width:100%;padding:7px 9px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:10px 0}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.mut{color:var(--mut);font-size:13px}.err{color:var(--err)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}@media(max-width:640px){.grid{grid-template-columns:1fr}}
label{display:block;font-size:13px;color:var(--mut)}label.c{display:flex;gap:6px;align-items:center;color:var(--fg);font-size:14px}label.c input{width:auto}
progress{width:100%}details summary{cursor:pointer}h2{font-size:16px;margin:18px 0 6px}code{font-size:12px}
</style></head><body>
<header><h1>GetterX <span class="mut">Lite</span></h1><button onclick="checkAll()">Check all</button><button onclick="view('log')">Activity</button><button onclick="view('settings')">Settings</button></header>
<main id="m">Loading…</main>
<script>
const T=location.hash.slice(1);let S=null,V='list',editing=null;
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(p,b){const r=await fetch('/api/'+p,{method:b?'POST':'GET',headers:{'X-GetterX-Token':T,'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined});const j=await r.json();if(!r.ok)throw new Error(j.error||r.status);return j}
function ago(t){if(!t)return'never';const d=(Date.now()-new Date(t))/6e4;return d<1?'just now':d<60?Math.round(d)+' min ago':d<1440?Math.round(d/60)+' h ago':Math.round(d/1440)+' d ago'}
async function load(){try{S=await api('state');document.documentElement.dataset.theme=S.settings.themeMode||'system';if(!editing)render()}catch(e){document.getElementById('m').innerHTML='<p class="err">'+esc(e.message)+'</p><p>Open the exact link printed by <code>getterx-cli serve</code>.</p>'}}
function view(v){V=v;editing=null;render()}
async function checkAll(){await api('check',{});load()}
function render(){const m=document.getElementById('m');if(V==='settings')return m.innerHTML=settingsHtml();if(V==='log'){api('log').then(j=>{m.innerHTML='<h2>Activity</h2>'+j.log.map(e=>'<div class="card"><b>'+esc(e.l)+'</b> '+esc(e.m)+'<div class="mut">'+ago(e.t)+'</div></div>').join('')+'<button onclick="view(\'list\')">Back</button>'});return}
m.innerHTML='<div class="card row"><input id="link" placeholder="Paste a GitHub / GitLab / Codeberg / Modrinth / CurseForge / itch.io / F-Droid link or any download page" style="flex:1"><button class="p" onclick="add()">Add</button></div><p id="addErr" class="err"></p>'+(S.sources.length?S.sources.map(cardHtml).join(''):'<p class="mut">Nothing tracked yet.</p>')}
function cardHtml(s){const act=s.records.filter(r=>!r.old),old=s.records.filter(r=>r.old);return '<div class="card"><div class="row"><b style="flex:1">'+esc(s.name)+(s.enabled?'':' (paused)')+'</b><button onclick="checkOne(\''+esc(s.id)+'\')" '+(s.running?'disabled':'')+'>Check</button><button onclick="edit(\''+esc(s.id)+'\')">Edit</button></div><div class="mut">'+esc(s.kindLabel)+' · '+esc(s.ref)+' · '+esc(s.modeLabel)+'<br>Latest: '+esc(s.latestVersionSeen||'?')+' · checked '+ago(s.lastChecked)+'<br>Folder: <code>'+esc(s.folder)+'</code></div>'+(s.running?'<div>'+esc(s.progress||'Working…')+'</div><progress '+(s.fraction!=null?'value="'+s.fraction+'"':'')+'></progress>':'')+(s.lastError?'<div class="err">'+esc(s.lastError)+'</div>':'')+'<details><summary>'+act.length+' downloaded'+(old.length?', '+old.length+' old kept':'')+'</summary>'+s.records.map(r=>'<div class="mut">'+(r.old?'[old] ':'')+esc(r.label.replace(/^slot:/,''))+' — '+esc(r.version)+'<br>'+r.files.map(f=>'<code>'+esc(f)+'</code>').join('<br>')+'</div>').join('')+'</details></div>'}
async function add(){const l=document.getElementById('link').value;document.getElementById('addErr').textContent='';try{const r=await api('add',{link:l});await load();edit(r.id)}catch(e){document.getElementById('addErr').textContent=e.message}}
async function checkOne(id){await api('check',{id});load()}
const MODES=[['latest','Latest only (auto-update)'],['newReleases','Every new release from now on'],['allReleases','Every release ever (full archive)'],['latestPerLoaderAndGameVersion','Latest per mod loader & game version']];
function edit(id){editing=id;const s=S.sources.find(x=>x.id===id);const ch=c=>s.channels.includes(c)?'checked':'';const b=(k,t)=>'<label class="c"><input type="checkbox" id="f_'+k+'" '+(s[k]?'checked':'')+'> '+t+'</label>';const t=(k,l,ph)=>'<label>'+l+'<input id="f_'+k+'" value="'+esc(Array.isArray(s[k])?s[k].join(', '):s[k])+'" placeholder="'+esc(ph||'')+'"></label>';
document.getElementById('m').innerHTML='<h2>'+esc(s.name)+'</h2><div class="card grid">'+t('name','Name')+t('downloadDir','Download folder (empty = '+S.settings.downloadRoot+')')+'<label>What to download<select id="f_mode">'+MODES.filter(m=>m[0]!=='latestPerLoaderAndGameVersion'||s.isMod).map(m=>'<option value="'+m[0]+'" '+(s.mode===m[0]?'selected':'')+'>'+m[1]+'</option>').join('')+'</select></label><div><label>Channels</label><div class="row"><label class="c"><input type="checkbox" id="c_release" '+ch('release')+'>release</label><label class="c"><input type="checkbox" id="c_beta" '+ch('beta')+'>beta / pre-release</label><label class="c"><input type="checkbox" id="c_alpha" '+ch('alpha')+'>alpha</label></div></div>'+b('preferStable','Prefer stable builds')+b('keepOld','Keep old versions')+t('keepCount','Keep at most N old versions (0 = all)')+t('fileTypes','Only file types (comma, e.g. exe, jar)')+t('includeFilesRegex','Only file names matching (regex)')+t('excludeFilesRegex','Skip file names matching (regex)')+t('versionRegex','Only versions/tags matching (regex)')+(s.isMod?t('loaders','Mod loaders (comma, empty = all)','fabric, neoforge')+t('gameVersions','Game versions (comma, empty = all)','26.3, 26.2')+t('gameVersionLimit','Only newest N game versions (0 = all)')+b('groupMinorVersions','Group minor versions (1.21.x)')+b('includeSnapshots','Include snapshots')+b('primaryFileOnly','Only the main file'):b('onlyPlatformFiles','Only files for this device ('+esc(S.settings.platform)+')')+b('includeSourceArchives','Also source code zip'))+(s.kind==='web'?t('linkRegex','Website: only links matching (regex)')+t('versionExtractRegex','Website: version from link (regex with a group)'):'')+b('enabled','Include in automatic checks')+'</div><p id="err" class="err"></p><div class="row"><button class="p" onclick="save(\''+esc(id)+'\')">Save</button><button onclick="preview(\''+esc(id)+'\')">Preview</button><button onclick="view(\'list\')">Cancel</button><span style="flex:1"></span><button onclick="removeSrc(\''+esc(id)+'\',false)">Remove</button><button onclick="removeSrc(\''+esc(id)+'\',true)">Remove + delete files</button></div><div id="pv"></div>'}
function form(id){const s=S.sources.find(x=>x.id===id),g=k=>document.getElementById('f_'+k),list=k=>g(k).value.split(',').map(x=>x.trim()).filter(Boolean),o={id};
['name','downloadDir','includeFilesRegex','excludeFilesRegex','versionRegex','linkRegex','versionExtractRegex'].forEach(k=>{if(g(k))o[k]=g(k).value.trim()});
['preferStable','keepOld','groupMinorVersions','includeSnapshots','primaryFileOnly','onlyPlatformFiles','includeSourceArchives','enabled'].forEach(k=>{if(g(k))o[k]=g(k).checked});
['keepCount','gameVersionLimit'].forEach(k=>{if(g(k))o[k]=parseInt(g(k).value)||0});['fileTypes','loaders','gameVersions'].forEach(k=>{if(g(k))o[k]=list(k).map(x=>k==='gameVersions'?x:x.toLowerCase().replace(/^\./,''))});
o.mode=g('mode').value;o.channels=['release','beta','alpha'].filter(c=>document.getElementById('c_'+c).checked);return o}
async function save(id){try{await api('source',form(id));editing=null;await load();V='list';render()}catch(e){document.getElementById('err').textContent=e.message}}
async function preview(id){const pv=document.getElementById('pv');pv.innerHTML='<p class="mut">Checking…</p>';try{await api('source',form(id));const p=await api('preview',{id});pv.innerHTML='<h2>Preview</h2>'+(p.downloads.length+p.delete.length+p.archive.length===0?'<p>Up to date.</p>':'')+p.downloads.map(d=>'<div class="card">⬇ '+esc(d.version)+(d.folder?' → '+esc(d.folder):'')+'<div class="mut">'+d.files.map(esc).join('<br>')+'</div></div>').join('')+p.delete.map(v=>'<div class="card">🗑 remove '+esc(v)+'</div>').join('')+p.archive.map(v=>'<div class="card">📦 keep '+esc(v)+' as old</div>').join('')}catch(e){pv.innerHTML='<p class="err">'+esc(e.message)+'</p>'}}
async function removeSrc(id,del){if(!confirm(del?'Stop tracking and DELETE downloaded files?':'Stop tracking (files stay)?'))return;await api('remove',{id,deleteFiles:del});editing=null;V='list';load()}
function settingsHtml(){const st=S.settings,c=st.credentials;return '<h2>Settings</h2><div class="card grid"><label>Default download folder<input id="s_dir" value="'+esc(st.downloadDir)+'" placeholder="'+esc(st.defaultDownloadRoot)+'"></label><label>Check every … minutes while running (0 = only manually)<input id="s_int" type="number" value="'+st.checkIntervalMinutes+'"></label><label>CurseForge API address (optional)<input id="s_cf" value="'+esc(st.curseforgeBaseUrl)+'"></label><label>Theme<select id="s_theme">'+[['system','Auto'],['light','Light'],['dark','Dark'],['oled','OLED black']].map(t=>'<option value="'+t[0]+'" '+(st.themeMode===t[0]?'selected':'')+'>'+t[1]+'</option>').join('')+'</select></label></div><p id="err" class="err"></p><div class="row"><button class="p" onclick="saveSettings()">Save</button><button onclick="view(\'list\')">Back</button></div><h2>Accounts</h2><div class="card mut">Lite reads logins only from environment variables (never stored):<br><code>GETTERX_GITHUB_TOKEN</code> '+(c.github?'✔':'—')+' · <code>GETTERX_ITCH_KEY</code> '+(c.itchio?'✔':'—')+' · <code>GETTERX_MODRINTH_TOKEN</code> '+(c.modrinth?'✔':'—')+' · <code>GETTERX_CURSEFORGE_KEY</code> '+(c.curseforge?'✔':'—')+'</div><p class="mut">Data: <code>'+esc(st.dataDir)+'</code> · '+esc(st.platform)+'</p>'}
async function saveSettings(){try{await api('settings',{downloadDir:document.getElementById('s_dir').value,checkIntervalMinutes:parseInt(document.getElementById('s_int').value)||0,curseforgeBaseUrl:document.getElementById('s_cf').value,themeMode:document.getElementById('s_theme').value});await load();view('list')}catch(e){document.getElementById('err').textContent=e.message}}
load();setInterval(()=>{if(V==='list'&&!editing)load()},2500);
</script></body></html>''';
