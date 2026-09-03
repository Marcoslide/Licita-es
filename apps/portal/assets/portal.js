/* BOLSA DE LICITAÇÕES — núcleo do portal (Supabase Auth + helpers) */
"use strict";

// cliente supabase (UMD carregado antes deste arquivo)
const CFG = window.PORTAL_CONFIG;
const sb = window.supabase ? window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY) : null;

const $ = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => [...(r || document).querySelectorAll(s)];
const fmtBRL = (v, dec = 0) => Number(v || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL', minimumFractionDigits: dec, maximumFractionDigits: dec });
const fmtMi = (v) => v >= 1e9 ? 'R$ ' + (v / 1e9).toLocaleString('pt-BR', { maximumFractionDigits: 2 }) + ' bi'
  : v >= 1e6 ? 'R$ ' + (v / 1e6).toLocaleString('pt-BR', { maximumFractionDigits: 1 }) + ' mi'
  : fmtBRL(v);
const fmtN = (v) => Number(v || 0).toLocaleString('pt-BR');

function toast(msg) {
  let box = $('.toasts');
  if (!box) { box = document.createElement('div'); box.className = 'toasts'; document.body.appendChild(box); }
  const t = document.createElement('div'); t.className = 'toast'; t.innerHTML = msg;
  box.appendChild(t); setTimeout(() => t.remove(), 6000);
}
function formMsg(el, tipo, texto) {
  el.className = 'form-msg on ' + tipo; el.textContent = texto;
}

// ---------- UTM / atribuição (§56) ----------
function captureUTM() {
  try {
    const p = new URLSearchParams(location.search);
    const keys = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];
    if (keys.some(k => p.get(k))) {
      const utm = {};
      keys.forEach(k => { if (p.get(k)) utm[k] = p.get(k); });
      utm.referrer = document.referrer || null;
      utm.landing_page = location.pathname;
      localStorage.setItem('bolsa_utm', JSON.stringify(utm));
    }
  } catch { /* storage indisponível */ }
}
function getUTM() {
  try { return JSON.parse(localStorage.getItem('bolsa_utm') || 'null'); } catch { return null; }
}

// ---------- tracking de eventos (§101) — nunca bloqueia a UI ----------
async function track(tipo, dados) {
  try { if (sb) await sb.rpc('saas_registrar_evento', { p_tipo: tipo, p_dados: dados || {}, p_utm: getUTM() }); }
  catch { /* telemetria é best-effort */ }
}

// ---------- sessão / guardas ----------
async function getUser() {
  if (!sb) return null;
  try { const { data } = await sb.auth.getUser(); return data.user || null; } catch { return null; }
}
async function guardAuth() {
  const u = await getUser();
  if (!u) {
    // funciona tanto na raiz do portal quanto em subpastas (ex.: admin/)
    const emAdmin = location.pathname.replace(/\\/g, '/').includes('/admin/');
    const destino = (emAdmin ? 'admin/' : '') + location.pathname.split('/').pop();
    location.href = (emAdmin ? '../' : '') + 'login.html?next=' + encodeURIComponent(destino);
    return null;
  }
  return u;
}
async function getAcesso() {
  try { const { data, error } = await sb.rpc('saas_meu_acesso'); if (error) throw error; return data || {}; }
  catch { return {}; }
}
async function isAdmin() {
  try { const { data } = await sb.rpc('saas_is_admin'); return data === true; } catch { return false; }
}
async function sair() { try { await sb.auth.signOut(); } finally { location.href = 'login.html'; } }

// ---------- gate de recurso por plano (§44): modal elegante, nunca "403" ----------
function gateUpgrade(recurso, planoNecessario, beneficios) {
  let bk = $('#gate-modal');
  if (!bk) {
    bk = document.createElement('div'); bk.id = 'gate-modal'; bk.className = 'modal-bk';
    bk.innerHTML = `<div class="modal">
      <div class="stage beta" style="margin-bottom:10px">RECURSO DO PLANO <b id="gm-plano"></b></div>
      <h3 id="gm-titulo"></h3><p id="gm-desc"></p>
      <div style="display:flex;gap:10px;margin-top:18px">
        <a class="btn primary" href="precos.html">Fazer upgrade</a>
        <button class="btn ghost" onclick="document.getElementById('gate-modal').classList.remove('on')">Agora não</button>
      </div></div>`;
    document.body.appendChild(bk);
    bk.addEventListener('click', e => { if (e.target === bk) bk.classList.remove('on'); });
  }
  $('#gm-plano', bk).textContent = planoNecessario.toUpperCase();
  $('#gm-titulo', bk).textContent = recurso;
  $('#gm-desc', bk).textContent = beneficios;
  bk.classList.add('on');
  track('upgrade_gate_shown', { recurso, plano: planoNecessario });
}

// ---------- REST simples às views públicas da base bolsa (só leitura) ----------
async function bolsaView(view, params) {
  const url = `${CFG.SUPABASE_URL}/rest/v1/${view}?${params || 'select=*'}`;
  const r = await fetch(url, { headers: { apikey: CFG.SUPABASE_ANON_KEY, authorization: 'Bearer ' + CFG.SUPABASE_ANON_KEY } });
  if (!r.ok) throw new Error('REST ' + r.status);
  return r.json();
}

captureUTM();
