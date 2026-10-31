'use strict';
(function () {
  const S = {
    me: null, layout: null, date: null, area: 'main', sup: 'All', openOnly: false,
    seats: new Map(), sel: null, ws: null, wsTries: 0, pollTimer: null, busy: false
  };
  const $ = (id) => document.getElementById(id);
  
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'style') el.style.cssText = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat()) {
      if (kid === null || kid === undefined || kid === false) continue;
      el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }

  async function api(path, opts) {
    const res = await fetch('/api' + path, {
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      ...opts
    });
    if (res.status === 401) { location.href = '/.auth/login/aad?post_login_redirect_uri=' + encodeURIComponent(location.pathname); throw new Error('Signing in'); }
    const body = await res.json().catch(() => ({}));
    if (!res.ok) { const err = new Error(body.error || 'Request failed'); err.status = res.status; err.body = body; throw err; }
    return body;
  }

  function toast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => t.classList.remove('show'), 3500);
  }

  // ---------- dates ----------
  // The board is today only; it resets every night.
  function todayLabel(iso) {
    return 'Today · ' + new Date(iso + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric', timeZone: 'UTC' });
  }

  // ---------- layout helpers ----------
  function allPods() { return S.layout.areas.flatMap((a) => a.pods.map((p) => ({ pod: p, area: a }))); }
  function seatInfo(id) {
    for (const { pod, area } of allPods()) {
      const s = pod.seats.find((x) => x.id === id);
      if (s) return { seat: s, pod, area };
    }
    return null;
  }
  function statusOf(seat) {
    if (seat.type === 'SupervisorDesk' || seat.type === 'TrainerDesk') return 'Desk';
    const row = S.seats.get(seat.id);
    return row ? row.status : 'Assigned';
  }

  // ---------- render ----------
  function render() {
    renderTotals(); renderAreas(); renderSups(); renderMap(); renderDetail(); renderLists();
  }

  function counts() {
    const c = { Open: 0, Claimed: 0, Assigned: 0 };
    const perArea = {};
    for (const { pod, area } of allPods()) {
      for (const seat of pod.seats) {
        const st = statusOf(seat);
        if (c[st] !== undefined) c[st]++;
        if (st === 'Open') perArea[area.id] = (perArea[area.id] || 0) + 1;
      }
    }
    return { c, perArea };
  }

  function renderTotals() {
    const { c } = counts();
    const stat = (label, n, color) => h('div', { class: 'stat' }, h('div', null, label), h('div', { style: 'color:' + color }, n));
    $('totals').replaceChildren(
      stat('Open', c.Open, '#11532F'), stat('Claimed', c.Claimed, '#6B4500'), stat('Assigned', c.Assigned, '#33475B'));
  }

  function renderAreas() {
    const { perArea } = counts();
    $('areas').replaceChildren(...S.layout.areas.map((a) => h('button', {
      class: 'tab', role: 'tab', 'aria-selected': a.id === S.area ? 'true' : 'false',
      onclick: () => { S.area = a.id; S.sel = null; render(); }
    }, a.name + ' ', h('span', { style: 'font-weight:500;opacity:.85' }, '(' + (perArea[a.id] || 0) + ' open)'))));
  }

  function renderSups() {
    const box = $('sups');
    if (S.area !== 'main') { box.replaceChildren(); return; }
    const area = S.layout.areas.find((a) => a.id === 'main');
    const names = ['All', ...new Set(area.pods.flatMap((p) => p.seats.map((x) => x.supervisor)).filter((n) => n && n !== 'Ops / QA'))];
    box.replaceChildren(...names.map((n) => h('button', {
      class: 'chip', 'aria-pressed': S.sup === n ? 'true' : 'false',
      onclick: () => { S.sup = n; renderMap(); renderSups(); }
    }, n === 'All' ? 'All supervisors' : n)));
  }

  function renderMap(flashId) {
    const area = S.layout.areas.find((a) => a.id === S.area);
    const g = S.layout.grids[area.grid];
    const map = $('map');
    map.style.width = area.width + 'px';
    map.style.height = area.height + 'px';
    map.setAttribute('aria-label', area.name + ' map');
    const nodes = [];
    for (const m of area.landmarks || []) {
      nodes.push(h('div', { class: 'mark mark-' + m.kind, style: `left:${m.x}px;top:${m.y}px;width:${m.w}px;height:${m.h}px` }, m.text));
    }
    for (const pod of area.pods) {
      const maxC = Math.max(...pod.seats.map((s) => s.c));
      const maxR = Math.max(...pod.seats.map((s) => s.r));
      const w = 16 + (maxC + 1) * g.sx - (g.sx - g.w);
      const hgt = 34 + (maxR + 1) * g.sy - (g.sy - g.h) + 8;
      const filtering = S.area === 'main' && S.sup !== 'All';
      const podSups = [...new Set(pod.seats.map((x) => x.supervisor).filter(Boolean))];
      const dim = filtering && !podSups.includes(S.sup);
      nodes.push(h('div', { class: 'pod' + (dim ? ' dim' : ''), style: `left:${pod.x}px;top:${pod.y}px;width:${w}px;height:${hgt}px`, title: podSups.join(', ') },
        h('b', null, pod.label), h('span', null, podSups.length > 1 ? podSups.join(' · ') : (podSups[0] || pod.supervisor || ''))));
      for (const seat of pod.seats) {
        const st = statusOf(seat);
        const selected = S.sel === seat.id;
        const faded = !selected && ((filtering && seat.supervisor !== S.sup) || (S.openOnly && st !== 'Open'));
        nodes.push(h('button', {
          class: `seat s-${st}${seat.note ? ' has-note' : ''}${faded ? ' dim' : ''}${flashId === seat.id ? ' flash' : ''}`,
          style: `left:${pod.x + 8 + seat.c * g.sx}px;top:${pod.y + 34 + seat.r * g.sy}px;width:${g.w}px;height:${g.h}px`,
          'aria-pressed': selected ? 'true' : 'false',
          title: seat.supervisor ? `${seat.id} · ${seat.supervisor}` : seat.id,
          'aria-label': `${seat.id}, ${st === 'Desk' ? 'supervisor desk' : st}${seat.supervisor ? ', ' + seat.supervisor : ''}${seat.note ? ', has note' : ''}`,
          onclick: () => { S.sel = seat.id; renderMap(); renderDetail(); }
        }, seat.id));
      }
    }
    map.replaceChildren(...nodes);
    const note = $('areaNote');
    note.replaceChildren(area.note ? h('div', { class: 'note' }, h('span', null, area.note)) : '');
  }

  function renderDetail() {
    const box = $('detail');
    if (!S.sel) {
      box.className = 'card empty';
      box.replaceChildren(S.me.canClaim
        ? 'Select a seat on the floor to see its pod and any notes, and to claim it for an agent.'
        : 'Select a seat to see its status. You have view-only access.');
      return;
    }
    const info = seatInfo(S.sel);
    const { seat, pod } = info;
    const st = statusOf(seat);
    const row = S.seats.get(seat.id) || {};
    const kids = [
      h('div', { class: 'row' }, h('span', { class: 'big' }, seat.id), h('span', { class: 'badge b-' + st }, st === 'Desk' ? 'Sup desk' : st)),
      h('div', { class: 'muted' }, `${seat.supervisor ? 'Supervisor: ' + seat.supervisor + ' · ' : ''}Pod ${pod.label} · Today`)
    ];
    let desc = '';
    if (st === 'Open') desc = 'Free to use today.';
    else if (st === 'Assigned') desc = 'Home agent is expected today. Not available.';
    else if (st === 'Claimed') desc = `Claimed by ${row.claimedByName} for ${row.claimedForName}.`;
    else desc = 'Supervisor or trainer desk — not for agent seating.';
    kids.push(h('p', { style: 'margin:0;font-size:14px;line-height:1.5' }, desc));
    if (seat.note) kids.push(h('div', { class: 'note' }, h('span', null, h('strong', null, 'Seat note: '), seat.note)));

    if (S.me.canClaim && st === 'Open') {
      const input = h('input', { id: 'agent', type: 'text', placeholder: 'Agent name', maxlength: '128', autocomplete: 'off' });
      const go = h('button', { class: 'btn btn-go', onclick: () => act('claim', { agent: input.value }) }, `Claim ${seat.id} for today`);
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') go.click(); });
      kids.push(h('div', { class: 'field' }, h('label', { for: 'agent' }, 'Seat which agent?'), input, go));
      kids.push(h('button', { class: 'btn', onclick: () => act('status', { status: 'Assigned' }) }, 'Mark as assigned (home agent is in)'));
    }
    if (S.me.canClaim && st === 'Assigned') {
      kids.push(h('button', { class: 'btn', onclick: () => act('status', { status: 'Open' }) }, 'Mark open (home agent is out)'));
    }
    if (st === 'Claimed' && (row.claimedByUpn === S.me.upn || S.me.isAdmin)) {
      kids.push(h('button', { class: 'btn', onclick: () => act('release', {}) }, 'Release seat'));
    }
    kids.push(h('button', { class: 'btn btn-link', onclick: () => { S.sel = null; renderMap(); renderDetail(); } }, 'Close'));
    box.className = 'card';
    box.replaceChildren(...kids);
  }

  function renderLists() {
    $('openTitle').textContent = 'Open today';
    $('claimsTitle').textContent = "Today's claims";
    const open = [];
    const claimed = [];
    for (const { pod, area } of allPods()) {
      for (const seat of pod.seats) {
        const st = statusOf(seat);
        if (st === 'Open') open.push({ seat, pod, area });
        if (st === 'Claimed') claimed.push({ seat, row: S.seats.get(seat.id) });
      }
    }
    $('openCount').textContent = open.length + ' seats';
    $('openList').replaceChildren(...(open.length ? open.map(({ seat, pod, area }) => h('button', {
      class: 'item', onclick: () => { S.area = area.id; S.sel = seat.id; render(); }
    }, h('code', null, seat.id), h('span', { class: 'muted' }, seat.supervisor || area.name))) : [h('div', { class: 'muted' }, 'No open seats.')]));
    $('claimList').replaceChildren(...(claimed.length ? claimed.map(({ seat, row }) => h('div', { class: 'claim' },
      h('code', null, seat.id), h('span', null, row.claimedForName, ' ', h('span', { class: 'muted' }, '· by ' + row.claimedByName)))) : [h('div', { class: 'muted' }, 'No seats claimed yet.')]));
  }

  // ---------- actions ----------
  async function act(kind, body) {
    if (S.busy) return;
    const id = S.sel;
    const row = S.seats.get(id) || {};
    if (kind === 'claim' && !String(body.agent || '').trim()) { toast('Enter the agent name first.'); return; }
    S.busy = true;
    document.querySelectorAll('#detail .btn').forEach((b) => { b.disabled = true; });
    try {
      const updated = await api(`/days/${S.date}/seats/${encodeURIComponent(id)}/${kind}`, {
        method: 'POST', body: JSON.stringify({ ...body, rowVer: row.rowVer })
      });
      S.seats.set(updated.seatId, updated);
      toast(kind === 'claim' ? `${id} claimed for ${updated.claimedForName}.` : kind === 'release' ? `${id} released.` : `${id} marked ${updated.status.toLowerCase()}.`);
    } catch (e) {
      if (e.status === 409 && e.body && e.body.current) {
        S.seats.set(e.body.current.seatId, e.body.current);
        const cur = e.body.current;
        toast(cur.status === 'Claimed' ? `Too late — ${cur.claimedByName} just claimed ${id} for ${cur.claimedForName}.` : `${id} changed before your update. Showing the latest.`);
      } else {
        toast(e.message);
      }
    } finally {
      S.busy = false;
      render();
    }
  }

  // ---------- data + live updates ----------
  async function loadDay() {
    await rollDay();
    const data = await api('/days/' + S.date);
    S.seats = new Map(data.seats.map((r) => [r.seatId, r]));
    render();
  }

  // A board left open overnight moves to the new day on its next refresh.
  async function rollDay() {
    if (Date.now() - (rollDay.at || 0) < 60000) return;
    rollDay.at = Date.now();
    const me = await api('/me');
    if (me.today !== S.date) { S.me = me; S.date = me.today; S.sel = null; setSub(); }
  }
  function setSub() {
    $('sub').textContent = todayLabel(S.date) + ' · Pilot: availability is sample data until the Genesys sync is connected';
  }

  function setLive(state) {
    const pill = $('live');
    pill.className = 'pill ' + (state === 'live' ? 'pill-live' : state === 'off' ? 'pill-off' : 'pill-wait');
    $('live-text').textContent = state === 'live' ? 'Live' : state === 'off' ? 'Refreshing every 30s' : 'Reconnecting';
  }

  async function connect() {
    if (!S.me.realtime) { setLive('off'); startPolling(); return; }
    try {
      const { url } = await api('/negotiate');
      const ws = new WebSocket(url);
      S.ws = ws;
      ws.onopen = () => { S.wsTries = 0; stopPolling(); setLive('live'); loadDay().catch(() => {}); };
      ws.onmessage = (ev) => {
        let msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
        if (msg.type === 'seat.changed' && msg.date === S.date && msg.seat) {
          S.seats.set(msg.seat.seatId, msg.seat);
          renderTotals(); renderAreas(); renderMap(msg.seat.seatId); renderLists();
          if (S.sel === msg.seat.seatId && !S.busy) renderDetail();
        }
      };
      ws.onclose = () => {
        setLive('wait');
        startPolling();
        const delay = Math.min(30000, 1000 * Math.pow(2, S.wsTries++));
        setTimeout(connect, delay);
      };
    } catch (e) {
      setLive('wait');
      startPolling();
      setTimeout(connect, Math.min(30000, 1000 * Math.pow(2, S.wsTries++)));
    }
  }
  function startPolling() {
    if (S.pollTimer) return;
    S.pollTimer = setInterval(() => { if (!S.busy) loadDay().catch(() => {}); }, 30000);
  }
  function stopPolling() { clearInterval(S.pollTimer); S.pollTimer = null; }

  async function start() {
    try {
      S.me = await api('/me');
      S.layout = await api('/layout');
      S.date = S.me.today;
      const roleText = { admin: 'Admin', supervisor: 'Supervisor', viewer: 'View only' }[S.me.role];
      $('me').replaceChildren('Signed in as ', h('strong', null, S.me.name), h('br'), roleText);
      rollDay.at = Date.now();
      setSub();
      $('openOnly').addEventListener('change', (e) => { S.openOnly = e.target.checked; renderMap(); });
      await loadDay();
      connect();
      document.addEventListener('visibilitychange', () => { if (!document.hidden) loadDay().catch(() => {}); });
    } catch (e) {
      $('sub').textContent = 'Could not load: ' + e.message;
    }
  }
  start();
})();
