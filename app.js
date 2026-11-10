'use strict';
/* Media Tracker — static app, data lives in your browser (localStorage). TMDB supplies metadata. */

const LS_KEY = 'mediatracker.v1';
const IMG = 'https://image.tmdb.org/t/p/w342';
const REC_TTL = 14 * 864e5;
const today = () => new Date().toISOString().slice(0, 10);

let state = load();
let tab = 'library';
let viewer = false;       // true when showing the published read-only snapshot
let sharedUpdated = '';
const OWNER_FLAG = 'mediatracker.owner';
const filters = { q: '', type: 'all', status: 'all', sort: 'title' };

function load() {
  try {
    const s = JSON.parse(localStorage.getItem(LS_KEY));
    if (s) return { apiKey: '', items: [], vinyl: [], dismissed: [], recCache: {}, ...s };
  } catch {}
  return { apiKey: '', items: [], vinyl: [], dismissed: [], recCache: {} };
}
function save() {
  if (viewer) return;
  try { localStorage.setItem(LS_KEY, JSON.stringify(state)); } catch (e) { setStatus('Could not save: ' + e.message); }
}

const $ = (s, r = document) => r.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const keyOf = (type, id) => `${type}:${id}`;
const find = key => state.items.find(i => i.key === key);
const norm = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

function setStatus(msg) {
  const el = $('#status');
  el.hidden = !msg;
  el.textContent = msg || '';
}

/* ---------- TMDB ---------- */
async function tmdb(path, params = {}) {
  const k = state.apiKey.trim();
  if (!k) throw new Error('Add your TMDB API key in Settings first.');
  const url = new URL('https://api.themoviedb.org/3' + path);
  const headers = {};
  if (k.length > 40) headers.Authorization = 'Bearer ' + k; // v4 read access token
  else url.searchParams.set('api_key', k);
  for (const [a, b] of Object.entries(params)) url.searchParams.set(a, b);
  const r = await fetch(url, { headers });
  if (!r.ok) throw new Error(r.status === 401 ? 'TMDB rejected the API key.' : `TMDB error ${r.status}`);
  return r.json();
}

async function pool(tasks, n, onTick) {
  let i = 0, done = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (i < tasks.length) {
      const t = tasks[i++];
      try { await t(); } catch (e) { console.warn(e); }
      onTick?.(++done, tasks.length);
    }
  }));
}

function fromResult(r, type) {
  const date = r.release_date || r.first_air_date || '';
  return {
    key: keyOf(type, r.id), type, tmdbId: r.id, title: r.title || r.name,
    year: date.slice(0, 4), poster: r.poster_path || '', overview: r.overview || '',
    vote: r.vote_average || 0,
  };
}

async function refreshItem(item) {
  if (!item.tmdbId) return;
  if (item.type === 'tv') {
    const d = await tmdb(`/tv/${item.tmdbId}`);
    item.seasons = (d.seasons || []).filter(s => s.season_number > 0)
      .map(s => ({ n: s.season_number, eps: s.episode_count, air: s.air_date || '' }));
    item.tmdbStatus = d.status;
  } else {
    const d = await tmdb(`/movie/${item.tmdbId}`);
    item.collection = d.belongs_to_collection ? { id: d.belongs_to_collection.id, name: d.belongs_to_collection.name } : null;
  }
  item.poster ||= '';
  item.refreshed = Date.now();
}

async function addItem(res, type, status) {
  const key = keyOf(type, res.id);
  let item = find(key);
  if (item) { item.status = status; save(); return item; }
  item = { ...fromResult(res, type), status, ownedSeasons: [], watched: false, addedAt: Date.now() };
  try { await refreshItem(item); } catch (e) { setStatus(e.message); }
  if (type === 'tv' && status === 'owned' && item.seasons) {
    // assume you own what you just added only if it has one season; otherwise let the user pick
    if (item.seasons.length === 1) item.ownedSeasons = [item.seasons[0].n];
  }
  state.items.push(item);
  save();
  return item;
}

/* ---------- Missing-season logic ---------- */
function seasonInfo(item) {
  const seasons = item.seasons || [];
  const owned = new Set(item.ownedSeasons || []);
  const aired = seasons.filter(s => s.air && s.air <= today());
  const missing = aired.filter(s => !owned.has(s.n)).map(s => s.n);
  const upcoming = seasons.filter(s => !s.air || s.air > today()).map(s => s.n);
  return { missing, upcoming, total: aired.length };
}
const missingShows = () => state.items.filter(i => i.type === 'tv' && i.status === 'owned' && seasonInfo(i).missing.length);
const fmtSeasons = a => a.map(n => 'S' + n).join(', ');

/* ---------- Rendering ---------- */
function poster(path, title) {
  return path ? `<img loading="lazy" src="${IMG}${path}" alt="${esc(title)}">` : `<div class="noposter">${esc(title)}</div>`;
}

function itemCard(i) {
  const badges = [];
  if (i.status === 'wishlist') badges.push('<span class="badge">Wishlist</span>');
  if (i.type === 'tv' && i.status === 'owned') {
    const si = seasonInfo(i);
    if (!i.seasons) badges.push('<span class="badge">No season data</span>');
    else if (si.missing.length) badges.push(`<span class="badge warn">Missing ${esc(fmtSeasons(si.missing))}</span>`);
    else badges.push('<span class="badge ok">Complete</span>');
  }
  if (!i.tmdbId) badges.push('<span class="badge warn">Unmatched</span>');
  if (i.watched) badges.push('<span class="badge ok">Watched</span>');
  return `<div class="card" data-action="open" data-key="${esc(i.key)}">
    ${poster(i.poster, i.title)}
    <div class="meta"><div class="title">${esc(i.title)}</div>
    <div class="sub">${i.type === 'tv' ? 'TV' : 'Movie'}${i.year ? ' · ' + esc(i.year) : ''}</div>
    <div>${badges.join('')}</div></div></div>`;
}

function sugCard(s, reason) {
  return `<div class="card">${poster(s.poster, s.title)}
    <div class="meta"><div class="title">${esc(s.title)}</div>
    <div class="sub">${s.type === 'tv' ? 'TV' : 'Movie'}${s.year ? ' · ' + esc(s.year) : ''}${s.vote ? ' · ★ ' + s.vote.toFixed(1) : ''}</div>
    <div class="sub">${esc(reason)}</div>
    <div class="actions">
      <button data-action="sug-add" data-status="wishlist" data-sug='${esc(JSON.stringify(s))}'>+ Wishlist</button>
      <button data-action="sug-add" data-status="owned" data-sug='${esc(JSON.stringify(s))}'>I own it</button>
      <button data-action="sug-dismiss" data-key="${esc(s.key)}">Hide</button>
    </div></div></div>`;
}

function render() {
  document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  const n = missingShows().length;
  $('#missingCount').textContent = n || '';
  const v = $('#view');
  ({ library: renderLibrary, missing: renderMissing, suggestions: renderSuggestions, vinyl: renderVinyl, settings: renderSettings })[tab](v);
  const note = $('#viewerNote');
  note.hidden = !viewer;
  if (viewer) {
    const when = sharedUpdated ? new Date(sharedUpdated).toLocaleDateString() : '';
    note.innerHTML = `Shared library${when ? ' · updated ' + esc(when) : ''} · <a data-action="own-mode">Manage my own library</a>`;
  }
}

function renderLibrary(v) {
  let items = state.items.filter(i =>
    (filters.type === 'all' || i.type === filters.type) &&
    (filters.status === 'all' || i.status === filters.status) &&
    (!filters.q || norm(i.title).includes(norm(filters.q))));
  const sorters = {
    title: (a, b) => a.title.localeCompare(b.title),
    year: (a, b) => (b.year || '').localeCompare(a.year || ''),
    added: (a, b) => b.addedAt - a.addedAt,
  };
  items.sort(sorters[filters.sort]);
  const opt = (val, cur, label) => `<option value="${val}"${val === cur ? ' selected' : ''}>${label}</option>`;
  v.innerHTML = `<div class="toolbar">
    <input type="search" id="fq" placeholder="Filter library…" value="${esc(filters.q)}">
    <select id="ftype">${opt('all', filters.type, 'Movies & TV')}${opt('movie', filters.type, 'Movies')}${opt('tv', filters.type, 'TV shows')}</select>
    <select id="fstatus">${opt('all', filters.status, 'Owned & wishlist')}${opt('owned', filters.status, 'Owned')}${opt('wishlist', filters.status, 'Wishlist')}</select>
    <select id="fsort">${opt('title', filters.sort, 'Sort: title')}${opt('year', filters.sort, 'Sort: year')}${opt('added', filters.sort, 'Sort: recently added')}</select>
  </div>
  ${items.length ? `<div class="grid">${items.map(itemCard).join('')}</div>`
    : `<div class="empty">${state.items.length ? 'Nothing matches.' : 'Your library is empty. Use “+ Add”, or import a scan in Settings.'}</div>`}`;
  $('#fq').oninput = e => { filters.q = e.target.value; const pos = e.target.selectionStart; renderLibrary(v); const f = $('#fq'); f.focus(); f.setSelectionRange(pos, pos); };
  $('#ftype').onchange = e => { filters.type = e.target.value; render(); };
  $('#fstatus').onchange = e => { filters.status = e.target.value; render(); };
  $('#fsort').onchange = e => { filters.sort = e.target.value; render(); };
}

function renderMissing(v) {
  const shows = missingShows().sort((a, b) => a.title.localeCompare(b.title));
  const upcoming = state.items.filter(i => i.type === 'tv' && i.status === 'owned' && seasonInfo(i).upcoming.length);
  const noData = state.items.filter(i => i.type === 'tv' && i.status === 'owned' && !i.seasons);
  v.innerHTML = `<section><h2>Shows with missing seasons</h2>
    <div class="sub">Compares the seasons you marked as owned with seasons TMDB lists as already aired.</div>
    ${shows.length ? `<div class="grid">${shows.map(itemCard).join('')}</div>` : '<div class="empty">No missing seasons 🎉</div>'}</section>
    ${upcoming.length ? `<section><h2>Upcoming seasons</h2><div class="sub">Announced or unaired — nothing to find yet.</div>
      <div class="grid">${upcoming.map(i => itemCard(i)).join('')}</div></section>` : ''}
    ${noData.length ? `<section><h2>Need a refresh</h2><div class="sub">No season data yet. Use “Refresh all” in Settings.</div>
      <div class="grid">${noData.map(itemCard).join('')}</div></section>` : ''}`;
}

function renderSuggestions(v) {
  const { recs, parts } = buildSuggestions();
  v.innerHTML = `<div class="toolbar"><button class="primary" data-action="gen-sug">↻ Generate / refresh suggestions</button>
    <span class="sub" style="align-self:center">Uses TMDB recommendations for everything you own or wishlist (cached for 2 weeks).</span></div>
    <section><h2>Complete the collection</h2><div class="sub">Movies from franchises you already own.</div>
      ${parts.length ? `<div class="grid">${parts.map(s => sugCard(s, 'Part of ' + s.collection)).join('')}</div>` : '<div class="empty">None found yet.</div>'}</section>
    <section><h2>You might like</h2><div class="sub">Ranked by how many of your titles TMDB recommends them for.</div>
      ${recs.length ? `<div class="grid">${recs.slice(0, 60).map(s => sugCard(s, `Because of ${s.because.slice(0, 2).join(', ')}${s.because.length > 2 ? ` +${s.because.length - 2}` : ''}`)).join('')}</div>` : '<div class="empty">No suggestions yet — press Generate.</div>'}</section>`;
}

function renderSettings(v) {
  v.innerHTML = `<div class="settings">
    <h2>TMDB API key</h2>
    <div class="sub">Free at <a href="https://www.themoviedb.org/settings/api" target="_blank" rel="noopener">themoviedb.org/settings/api</a>.
      Paste either the “API Key” or the “API Read Access Token”. It is stored only in this browser.</div>
    <input type="password" id="apiKey" value="${esc(state.apiKey)}" placeholder="TMDB key or token">
    <div class="row"><button class="primary" data-action="save-key">Save key</button></div>
    <h2>Library data</h2>
    <div class="sub">${state.items.length} titles. Import a scan from <code>scripts/Scan-Library.ps1</code> or a previous backup.</div>
    <div class="row">
      <button data-action="import">Import scan / backup…</button>
      <button data-action="export">Export backup</button>
      <button data-action="export-shared">Export shared snapshot</button>
      <button data-action="refresh-all">Refresh all from TMDB</button>
      <button data-action="match">Match unmatched titles</button>
      <button class="danger" data-action="wipe">Delete all data</button>
    </div>
    <input type="file" id="file" accept=".json" hidden></div>`;
  $('#file').onchange = e => importFile(e.target.files[0]);
}

/* ---------- Suggestions ---------- */
function buildSuggestions() {
  const have = new Set(state.items.map(i => i.key));
  const hidden = new Set(state.dismissed);
  const scores = new Map();
  for (const item of state.items) {
    const c = state.recCache[item.key];
    if (!c) continue;
    for (const r of c.recs) {
      if (have.has(r.key) || hidden.has(r.key)) continue;
      const e = scores.get(r.key) || { ...r, score: 0, because: [] };
      e.score += 1 + (r.vote || 0) / 20;
      e.because.push(item.title);
      scores.set(r.key, e);
    }
  }
  const recs = [...scores.values()].filter(r => r.vote >= 6).sort((a, b) => b.score - a.score);
  const parts = [];
  const seen = new Set();
  for (const item of state.items) {
    if (item.status !== 'owned' || !item.collection) continue;
    const c = state.recCache['collection:' + item.collection.id];
    if (!c) continue;
    for (const p of c.parts) {
      if (have.has(p.key) || hidden.has(p.key) || seen.has(p.key)) continue;
      seen.add(p.key);
      parts.push({ ...p, collection: item.collection.name });
    }
  }
  return { recs, parts };
}

async function generateSuggestions() {
  const stale = c => !c || Date.now() - c.t > REC_TTL;
  const tasks = [];
  for (const item of state.items) {
    if (!item.tmdbId) continue;
    if (stale(state.recCache[item.key])) tasks.push(async () => {
      const d = await tmdb(`/${item.type}/${item.tmdbId}/recommendations`);
      state.recCache[item.key] = { t: Date.now(), recs: (d.results || []).slice(0, 15).map(r => fromResult(r, item.type)) };
    });
    if (item.type === 'movie' && item.collection && stale(state.recCache['collection:' + item.collection.id])) {
      const cid = item.collection.id;
      tasks.push(async () => {
        const d = await tmdb(`/collection/${cid}`);
        const released = (d.parts || []).filter(p => p.release_date && p.release_date <= today());
        state.recCache['collection:' + cid] = { t: Date.now(), parts: released.map(p => fromResult(p, 'movie')) };
      });
    }
  }
  if (!tasks.length) { setStatus('Suggestions are up to date.'); setTimeout(() => setStatus(''), 2000); return render(); }
  await pool(tasks, 5, (d, t) => setStatus(`Fetching suggestions… ${d}/${t}`));
  save(); setStatus(''); render();
}

/* ---------- Import / export ---------- */
async function matchOne(entry, type) {
  const params = { query: entry.title };
  if (entry.year) params[type === 'tv' ? 'first_air_date_year' : 'year'] = entry.year;
  let r = (await tmdb(`/search/${type}`, params)).results || [];
  if (!r.length && entry.year) r = (await tmdb(`/search/${type}`, { query: entry.title })).results || [];
  return r[0] || null;
}

async function importFile(file) {
  if (!file) return;
  let data;
  try { data = JSON.parse(await file.text()); } catch { return setStatus('That file is not valid JSON.'); }
  if (data.items) { // backup restore
    const have = new Set(state.items.map(i => i.key));
    for (const i of data.items) if (!have.has(i.key)) state.items.push(i);
    const haveV = new Set(state.vinyl.map(v => v.key));
    for (const v of data.vinyl || []) if (!haveV.has(v.key)) state.vinyl.push(v);
    state.dismissed = [...new Set([...state.dismissed, ...(data.dismissed || [])])];
    save(); setStatus(''); return render();
  }
  const entries = [...(data.movies || []).map(e => ({ ...e, type: 'movie' })), ...(data.tv || []).map(e => ({ ...e, type: 'tv' }))];
  // Titles already in the library only get their owned seasons updated (no TMDB calls); the rest are new.
  const srcOf = e => `${e.type}|${norm(e.title)}|${e.year || ''}`;
  const bySrc = new Map(state.items.filter(i => i.src).map(i => [i.src, i]));
  const todo = [];
  let updated = 0;
  for (const e of entries) {
    const have = bySrc.get(srcOf(e)) || state.items.find(i => i.type === e.type && norm(i.title) === norm(e.title) && (!e.year || String(i.year) === String(e.year)));
    if (!have) { todo.push(e); continue; }
    have.src ||= srcOf(e);
    let changed = have.status !== 'owned';
    have.status = 'owned';
    if (e.type === 'tv') {
      const merged = [...new Set([...(have.ownedSeasons || []), ...(e.seasons || [])])].sort((a, b) => a - b);
      changed ||= merged.length !== (have.ownedSeasons || []).length;
      have.ownedSeasons = merged;
    }
    if (changed) updated++;
  }
  save();
  if (todo.length) {
    try { await tmdb('/configuration'); } catch (e) { return setStatus('Import stopped: ' + e.message + ' Save a valid key in Settings, then import again.'); }
  }
  let matched = 0, unmatched = 0;
  const tasks = todo.map(e => async () => {
    let item;
    const res = await matchOne(e, e.type).catch(() => null);
    if (res) {
      matched++;
      item = find(keyOf(e.type, res.id));
      if (!item) { item = { ...fromResult(res, e.type), status: 'owned', ownedSeasons: [], watched: false, addedAt: Date.now() }; state.items.push(item); await refreshItem(item).catch(() => {}); }
    } else {
      unmatched++;
      item = { key: `local:${e.type}:${norm(e.title)}:${e.year || ''}`, type: e.type, tmdbId: null, title: e.title, year: String(e.year || ''), poster: '', status: 'owned', ownedSeasons: [], watched: false, addedAt: Date.now() };
      if (!find(item.key)) state.items.push(item);
    }
    item.status = 'owned';
    item.src = srcOf(e);
    if (e.type === 'tv') item.ownedSeasons = [...new Set([...(item.ownedSeasons || []), ...(e.seasons || [])])].sort((a, b) => a - b);
  });
  await pool(tasks, 4, (d, t) => setStatus(`Importing… ${d}/${t}`));
  save(); const f = $('#file'); if (f) f.value = '';
  setStatus(`${todo.length} new titles (${matched} matched, ${unmatched} unmatched), ${updated} existing titles updated.`);
  setTimeout(() => setStatus(''), 8000); render();
}

function download(name, text) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
  a.download = name;
  a.click();
  URL.revokeObjectURL(a.href);
}

function exportBackup() {
  download(`media-tracker-backup-${today()}.json`, JSON.stringify({ items: state.items, vinyl: state.vinyl, dismissed: state.dismissed }, null, 2));
}

// Public, read-only snapshot for family/friends. Leaves out the API key, hidden suggestions and vinyl notes.
function exportShared() {
  const data = {
    version: 1, updated: new Date().toISOString(),
    items: state.items.map(({ src, ...i }) => i),
    vinyl: state.vinyl.map(({ notes, ...v }) => v),
  };
  download('media-tracker-shared.json', JSON.stringify(data));
  setStatus('Saved media-tracker-shared.json — run scripts\\Publish-Snapshot.ps1 to put it in the repo.');
  setTimeout(() => setStatus(''), 8000);
}

async function refreshAll(onlyUnmatched) {
  const tasks = state.items.map(item => async () => {
    if (!item.tmdbId) {
      const res = await matchOne(item, item.type);
      if (!res) return;
      const m = fromResult(res, item.type);
      Object.assign(item, { key: m.key, tmdbId: m.tmdbId, poster: m.poster, overview: m.overview, year: item.year || m.year });
      if (state.items.some(o => o !== item && o.key === item.key)) item._dup = true;
    } else if (onlyUnmatched) return;
    await refreshItem(item);
  });
  await pool(tasks, 4, (d, t) => setStatus(`Refreshing… ${d}/${t}`));
  state.items = state.items.filter(i => !i._dup);
  save(); setStatus('Done.'); setTimeout(() => setStatus(''), 2000); render();
}

/* ---------- Vinyl (MusicBrainz + Cover Art Archive, no key needed) ---------- */
const vinylFilters = { q: '', status: 'all', sort: 'artist' };
const cover = v => v.mbid
  ? `<img loading="lazy" src="https://coverartarchive.org/release-group/${esc(v.mbid)}/front-250" alt="${esc(v.title)}" data-fallback="${esc(v.title)}">`
  : `<div class="noposter">${esc(v.title)}</div>`;
const findVinyl = key => state.vinyl.find(v => v.key === key);

// Cover Art Archive returns 404 for releases without art: swap in a text placeholder.
document.addEventListener('error', e => {
  const img = e.target;
  if (img.tagName !== 'IMG' || img.dataset.fallback === undefined) return;
  const d = document.createElement('div');
  d.className = 'noposter';
  d.textContent = img.dataset.fallback;
  img.replaceWith(d);
}, true);

function vinylCard(v) {
  return `<div class="card" data-action="open-vinyl" data-key="${esc(v.key)}">${cover(v)}
    <div class="meta"><div class="title">${esc(v.title)}</div>
    <div class="sub">${esc(v.artist)}${v.year ? ' · ' + esc(v.year) : ''}</div>
    <div>${v.status === 'wishlist' ? '<span class="badge">Wishlist</span>' : ''}</div></div></div>`;
}

function renderVinyl(v) {
  const f = vinylFilters;
  const items = state.vinyl.filter(r => (f.status === 'all' || r.status === f.status) &&
    (!f.q || norm(r.artist + ' ' + r.title).includes(norm(f.q))));
  const sorters = {
    artist: (a, b) => a.artist.localeCompare(b.artist) || (a.year || '').localeCompare(b.year || ''),
    title: (a, b) => a.title.localeCompare(b.title),
    year: (a, b) => (b.year || '').localeCompare(a.year || ''),
    added: (a, b) => b.addedAt - a.addedAt,
  };
  items.sort(sorters[f.sort]);
  const opt = (val, cur, label) => `<option value="${val}"${val === cur ? ' selected' : ''}>${label}</option>`;
  const owned = state.vinyl.filter(r => r.status === 'owned').length;
  v.innerHTML = `<div class="toolbar">
    <input type="search" id="vq" placeholder="Filter records…" value="${esc(f.q)}">
    <select id="vstatus">${opt('all', f.status, 'Owned & wishlist')}${opt('owned', f.status, 'Owned')}${opt('wishlist', f.status, 'Wishlist')}</select>
    <select id="vsort">${opt('artist', f.sort, 'Sort: artist')}${opt('title', f.sort, 'Sort: title')}${opt('year', f.sort, 'Sort: year')}${opt('added', f.sort, 'Sort: recently added')}</select>
  </div>
  <div class="sub" style="margin-bottom:12px">${owned} records owned · ${state.vinyl.length - owned} on wishlist. Use “+ Add” to search MusicBrainz.</div>
  ${items.length ? `<div class="grid">${items.map(vinylCard).join('')}</div>`
    : `<div class="empty">${state.vinyl.length ? 'Nothing matches.' : 'No records yet. Use “+ Add” to search for an album.'}</div>`}`;
  $('#vq').oninput = e => { f.q = e.target.value; const pos = e.target.selectionStart; renderVinyl(v); const q = $('#vq'); q.focus(); q.setSelectionRange(pos, pos); };
  $('#vstatus').onchange = e => { f.status = e.target.value; render(); };
  $('#vsort').onchange = e => { f.sort = e.target.value; render(); };
}

function openVinyl(key) {
  const r = findVinyl(key);
  if (!r) return;
  const d = $('#itemDialog');
  d.innerHTML = `<form method="dialog" class="dlg-head"><h2>${esc(r.title)}</h2><button aria-label="Close">✕</button></form>
    <div class="detail">${cover(r)}<div>
      <p><strong>${esc(r.artist)}</strong>${r.year ? ` <span class="sub">(${esc(r.year)})</span>` : ''}</p>
      <p class="sub">${r.status === 'owned' ? 'In your collection' : 'On your wishlist'}</p>
      ${viewer ? '' : `<label class="sub" for="vnotes">Notes (pressing, condition, where you bought it…)</label>
      <textarea id="vnotes" rows="4" style="width:100%" data-key="${esc(key)}">${esc(r.notes || '')}</textarea>`}</div></div>
    <div class="actions" style="margin-top:14px">
      <button data-action="v-status" data-key="${esc(key)}">Move to ${r.status === 'owned' ? 'wishlist' : 'owned'}</button>
      ${r.mbid ? `<a href="https://musicbrainz.org/release-group/${esc(r.mbid)}" target="_blank" rel="noopener"><button type="button">MusicBrainz ↗</button></a>` : ''}
      <button class="danger" data-action="v-remove" data-key="${esc(key)}">Remove</button></div>`;
  if (!d.open) d.showModal();
}

async function searchVinyl(q) {
  const out = $('#searchResults');
  const clean = q.replace(/[+\-&|!(){}\[\]^"~*?:\\\/]/g, ' ').trim();
  if (!clean) { out.innerHTML = ''; return; }
  try {
    const url = `https://musicbrainz.org/ws/2/release-group?fmt=json&limit=12&query=${encodeURIComponent(`releasegroup:(${clean}) OR artist:(${clean})`)}`;
    const r = await fetch(url);
    if (!r.ok) throw new Error(r.status === 503 ? 'MusicBrainz is busy, try again in a moment.' : `MusicBrainz error ${r.status}`);
    const rs = ((await r.json())['release-groups'] || []).map(g => ({
      mbid: g.id, title: g.title, year: (g['first-release-date'] || '').slice(0, 4),
      artist: (g['artist-credit'] || []).map(a => a.name + (a.joinphrase || '')).join('') || 'Unknown artist',
      kind: [g['primary-type'], ...(g['secondary-types'] || [])].filter(Boolean).join(' + '),
    }));
    out._vinyl = rs;
    out.innerHTML = rs.map((x, n) => {
      const have = findVinyl('vinyl:' + x.mbid);
      return `<div class="result">${cover(x)}
        <div class="info"><div class="title">${esc(x.title)}</div>
        <div class="sub">${esc(x.artist)}${x.year ? ' · ' + esc(x.year) : ''}${x.kind ? ' · ' + esc(x.kind) : ''}${have ? ' · in collection (' + have.status + ')' : ''}</div></div>
        <div class="actions"><button data-action="v-add" data-status="owned" data-n="${n}">I own it</button>
        <button data-action="v-add" data-status="wishlist" data-n="${n}">Wishlist</button></div></div>`;
    }).join('') + '<div class="actions"><button data-action="v-manual">Can’t find it? Add manually</button></div>';
  } catch (e) { out.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

function addVinylManual() {
  const artist = prompt('Artist:'); if (!artist) return;
  const title = prompt('Album title:'); if (!title) return;
  const year = prompt('Year (optional):') || '';
  state.vinyl.push({ key: `vinyl:local:${Date.now()}`, mbid: '', artist: artist.trim(), title: title.trim(), year: year.trim(), status: 'owned', notes: '', addedAt: Date.now() });
  save(); render();
}

/* ---------- Dialogs ---------- */
function openItem(key) {
  const i = find(key);
  if (!i) return;
  const d = $('#itemDialog');
  const si = seasonInfo(i);
  const chips = i.type === 'tv' && i.seasons ? `<div class="sub">Tap the seasons you own:</div><div class="chips">${
    i.seasons.map(s => {
      const future = !s.air || s.air > today();
      return `<button class="chip${i.ownedSeasons.includes(s.n) ? ' on' : ''}${future ? ' future' : ''}" data-action="toggle-season" data-key="${esc(key)}" data-n="${s.n}" title="${s.eps || '?'} episodes${future ? ' · not aired yet' : ''}">S${s.n}</button>`;
    }).join('')}</div>${si.missing.length ? `<div class="badge warn">Missing ${esc(fmtSeasons(si.missing))}</div>` : ''}` : '';
  d.innerHTML = `<form method="dialog" class="dlg-head"><h2>${esc(i.title)} ${i.year ? `<span class="sub">(${esc(i.year)})</span>` : ''}</h2><button aria-label="Close">✕</button></form>
    <div class="detail">${poster(i.poster, i.title)}<div>
      <p class="sub">${esc(i.overview || 'No description.')}</p>
      ${i.collection ? `<p class="sub">Collection: ${esc(i.collection.name)}</p>` : ''}
      ${i.tmdbStatus ? `<p class="sub">Show status: ${esc(i.tmdbStatus)}</p>` : ''}
      ${chips}</div></div>
    <div class="actions" style="margin-top:14px">
      <button data-action="set-status" data-key="${esc(key)}" data-status="${i.status === 'owned' ? 'wishlist' : 'owned'}">Move to ${i.status === 'owned' ? 'wishlist' : 'owned'}</button>
      <button data-action="toggle-watched" data-key="${esc(key)}">${i.watched ? 'Mark unwatched' : 'Mark watched'}</button>
      ${i.tmdbId ? `<button data-action="refresh-one" data-key="${esc(key)}">Refresh</button>
        <a href="https://www.themoviedb.org/${i.type}/${i.tmdbId}" target="_blank" rel="noopener"><button type="button">TMDB ↗</button></a>` : ''}
      <button class="danger" data-action="remove" data-key="${esc(key)}">Remove</button></div>`;
  if (!d.open) d.showModal();
}

let searchTimer;
async function doSearch(q) {
  const out = $('#searchResults');
  if (!q.trim()) { out.innerHTML = ''; return; }
  try {
    const d = await tmdb('/search/multi', { query: q });
    const rs = (d.results || []).filter(r => r.media_type === 'movie' || r.media_type === 'tv').slice(0, 10);
    out.innerHTML = rs.length ? rs.map(r => {
      const it = fromResult(r, r.media_type);
      const have = find(it.key);
      return `<div class="result">${poster(it.poster, it.title)}
        <div class="info"><div class="title">${esc(it.title)}</div>
        <div class="sub">${it.type === 'tv' ? 'TV' : 'Movie'}${it.year ? ' · ' + esc(it.year) : ''}${have ? ' · in library (' + have.status + ')' : ''}</div></div>
        <div class="actions"><button data-action="add" data-status="owned" data-id="${it.tmdbId}" data-type="${it.type}">I own it</button>
        <button data-action="add" data-status="wishlist" data-id="${it.tmdbId}" data-type="${it.type}">Wishlist</button></div></div>`;
    }).join('') : '<div class="empty">No results.</div>';
    out._results = rs;
  } catch (e) { out.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

/* ---------- Events ---------- */
document.addEventListener('click', async e => {
  const t = e.target.closest('[data-action]');
  if (!t) return;
  const { action, key } = t.dataset;
  if (viewer && !['open', 'open-vinyl', 'own-mode'].includes(action)) return;
  const item = key && find(key);
  switch (action) {
    case 'open': openItem(key); break;
    case 'toggle-season': {
      const n = +t.dataset.n, s = new Set(item.ownedSeasons);
      s.has(n) ? s.delete(n) : s.add(n);
      item.ownedSeasons = [...s].sort((a, b) => a - b);
      save(); openItem(key); render(); break;
    }
    case 'set-status': item.status = t.dataset.status; save(); openItem(key); render(); break;
    case 'toggle-watched': item.watched = !item.watched; save(); openItem(key); render(); break;
    case 'refresh-one': setStatus('Refreshing…'); await refreshItem(item).catch(err => setStatus(err.message)); save(); setStatus(''); openItem(key); render(); break;
    case 'remove':
      if (confirm(`Remove “${item.title}” from your library?`)) { state.items = state.items.filter(i => i !== item); save(); $('#itemDialog').close(); render(); }
      break;
    case 'add': {
      const res = $('#searchResults')._results.find(r => r.id === +t.dataset.id && r.media_type === t.dataset.type);
      t.disabled = true;
      await addItem(res, t.dataset.type, t.dataset.status);
      t.textContent = '✓ Added'; render(); break;
    }
    case 'sug-add': {
      const s = JSON.parse(t.dataset.sug);
      await addItem({ id: s.tmdbId, title: s.title, name: s.title, release_date: s.year ? s.year + '-01-01' : '', poster_path: s.poster, overview: s.overview, vote_average: s.vote }, s.type, t.dataset.status);
      render(); break;
    }
    case 'open-vinyl': openVinyl(key); break;
    case 'own-mode':
      try { localStorage.setItem(OWNER_FLAG, '1'); } catch {}
      location.reload(); break;
    case 'export-shared': exportShared(); break;
    case 'v-status': { const r = findVinyl(key); r.status = r.status === 'owned' ? 'wishlist' : 'owned'; save(); openVinyl(key); render(); break; }
    case 'v-remove': {
      const r = findVinyl(key);
      if (confirm(`Remove “${r.title}” by ${r.artist}?`)) { state.vinyl = state.vinyl.filter(x => x !== r); save(); $('#itemDialog').close(); render(); }
      break;
    }
    case 'v-add': {
      const x = $('#searchResults')._vinyl[+t.dataset.n];
      if (!findVinyl('vinyl:' + x.mbid)) state.vinyl.push({ key: 'vinyl:' + x.mbid, mbid: x.mbid, artist: x.artist, title: x.title, year: x.year, status: t.dataset.status, notes: '', addedAt: Date.now() });
      save(); t.textContent = '✓ Added'; t.disabled = true; break;
    }
    case 'v-manual': addVinylManual(); break;
    case 'sug-dismiss': state.dismissed.push(key); save(); render(); break;
    case 'gen-sug': generateSuggestions().catch(err => setStatus(err.message)); break;
    case 'save-key': state.apiKey = $('#apiKey').value.trim(); save(); setStatus('Key saved.'); setTimeout(() => setStatus(''), 1500); break;
    case 'import': $('#file').click(); break;
    case 'export': exportBackup(); break;
    case 'refresh-all': refreshAll(false).catch(err => setStatus(err.message)); break;
    case 'match': refreshAll(true).catch(err => setStatus(err.message)); break;
    case 'wipe': if (confirm('Delete ALL library data from this browser?')) { state = { apiKey: state.apiKey, items: [], vinyl: [], dismissed: [], recCache: {} }; save(); render(); } break;
  }
});

$('#tabs').addEventListener('click', e => { const b = e.target.closest('button'); if (b) { tab = b.dataset.tab; render(); } });
let addMode = 'media';
$('#addBtn').onclick = () => {
  addMode = tab === 'vinyl' ? 'vinyl' : 'media';
  $('#addTitle').textContent = addMode === 'vinyl' ? 'Add a vinyl record' : 'Add a movie or show';
  $('#searchInput').placeholder = addMode === 'vinyl' ? 'Search by artist or album (MusicBrainz)…' : 'Search TMDB…';
  $('#searchInput').value = '';
  $('#searchResults').innerHTML = '';
  $('#addDialog').showModal();
  $('#searchInput').focus();
};
$('#searchInput').oninput = e => {
  clearTimeout(searchTimer);
  const vinyl = addMode === 'vinyl'; // MusicBrainz asks for ~1 request/second
  searchTimer = setTimeout(() => (vinyl ? searchVinyl : doSearch)(e.target.value), vinyl ? 700 : 300);
};
document.addEventListener('change', e => {
  if (e.target.id !== 'vnotes') return;
  const r = findVinyl(e.target.dataset.key);
  if (r) { r.notes = e.target.value; save(); }
});
$('#addDialog').addEventListener('close', () => render());
$('#itemDialog').addEventListener('click', e => { if (e.target === e.currentTarget) e.currentTarget.close(); });

// A visitor with no library of their own sees the published snapshot, read-only.
async function boot() {
  let owner = false;
  try { owner = localStorage.getItem(OWNER_FLAG) === '1'; } catch {}
  const hasLocal = state.items.length || state.vinyl.length || state.apiKey;
  if (!hasLocal && !owner) {
    try {
      const r = await fetch('shared/library.json', { cache: 'no-cache' });
      if (r.ok) {
        const d = await r.json();
        state = { apiKey: '', items: d.items || [], vinyl: d.vinyl || [], dismissed: [], recCache: {} };
        sharedUpdated = d.updated || '';
        viewer = true;
        document.body.classList.add('viewer');
      }
    } catch {}
  }
  if (!viewer && !state.apiKey) tab = 'settings';
  render();
}
boot();

if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}
