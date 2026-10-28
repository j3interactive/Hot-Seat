'use strict';
const path = require('path');
const express = require('express');
const { loadLayout } = require('./layout');
const { requireUser, atLeast } = require('./auth');
const { createMemoryStore } = require('./store-memory');
const { createSqlStore } = require('./store-sql');
const { createRealtime } = require('./realtime');

const PORT = process.env.PORT || 8080;
const TZ = 'America/New_York';
const layoutData = loadLayout();
const realtime = createRealtime();

const store = (process.env.STORE || (process.env.SQL_SERVER ? 'sql' : 'memory')) === 'sql'
  ? createSqlStore({ server: process.env.SQL_SERVER, database: process.env.SQL_DATABASE, clientId: process.env.AZURE_CLIENT_ID }, layoutData)
  : createMemoryStore(layoutData.seats);

function todayIso() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}

function validDate(date) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return false;
  const d = Date.parse(date + 'T12:00:00Z');
  if (Number.isNaN(d)) return false;
  const diffDays = (d - Date.parse(todayIso() + 'T12:00:00Z')) / 86400000;
  return diffDays >= -14 && diffDays <= 21;
}

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '10kb' }));
app.use((req, res, next) => {
  res.set('X-Content-Type-Options', 'nosniff');
  res.set('Referrer-Policy', 'same-origin');
  next();
});

app.get('/healthz', (req, res) => res.json({ ok: true, store: store.kind, realtime: realtime.enabled }));

const api = express.Router();
api.use(requireUser);

api.get('/me', (req, res) => {
  res.json({ ...req.user, canClaim: atLeast(req.user, 'supervisor'), isAdmin: atLeast(req.user, 'admin'), today: todayIso(), realtime: realtime.enabled });
});

api.get('/layout', (req, res) => res.json(layoutData.layout));

api.get('/negotiate', async (req, res, next) => {
  try { res.json({ url: await realtime.negotiate(req.user) }); } catch (e) { next(e); }
});

api.get('/days/:date', async (req, res, next) => {
  try {
    const { date } = req.params;
    if (!validDate(date)) return res.status(400).json({ error: 'Date out of range' });
    res.json({ date, seats: await store.getDay(date) });
  } catch (e) { next(e); }
});

function seatAction(handler, minRole) {
  return async (req, res, next) => {
    try {
      const { date, seatId } = req.params;
      if (!validDate(date)) return res.status(400).json({ error: 'Date out of range' });
      const seat = layoutData.seats.get(seatId);
      if (!seat) return res.status(404).json({ error: 'Unknown seat' });
      if (!atLeast(req.user, minRole)) return res.status(403).json({ error: 'Not allowed for your role' });
      const rowVer = String((req.body && req.body.rowVer) || '');
      const result = await handler(req, res, { date, seat, rowVer });
      if (!result) return; // handler already responded
      if (!result.ok) {
        return res.status(409).json({ error: 'Seat changed before your update', current: result.current });
      }
      await realtime.publish({ type: 'seat.changed', date, seat: result.row, by: req.user.name });
      res.json(result.row);
    } catch (e) { next(e); }
  };
}

api.post('/days/:date/seats/:seatId/claim', seatAction(async (req, res, { date, seat, rowVer }) => {
  if (seat.type !== 'Agent') { res.status(400).json({ error: 'Only agent seats can be claimed' }); return null; }
  const agent = String((req.body && req.body.agent) || '').trim().slice(0, 128);
  if (!agent) { res.status(400).json({ error: 'Enter the agent name' }); return null; }
  return store.claim(date, seat.id, agent, rowVer, req.user);
}, 'supervisor'));

api.post('/days/:date/seats/:seatId/release', seatAction(async (req, res, { date, seat, rowVer }) => {
  const day = await store.getDay(date);
  const row = day.find((r) => r.seatId === seat.id);
  if (row && row.status === 'Claimed' && row.claimedByUpn !== req.user.upn && !atLeast(req.user, 'admin')) {
    res.status(403).json({ error: 'Only the supervisor who claimed it, or an admin, can release it' });
    return null;
  }
  return store.release(date, seat.id, rowVer, req.user);
}, 'supervisor'));

// PILOT: lets a supervisor mark a seat open or assigned by hand, standing in
// for the Genesys WFM sync (roadmap phase 4).
api.post('/days/:date/seats/:seatId/status', seatAction(async (req, res, { date, seat, rowVer }) => {
  const to = req.body && req.body.status;
  if (seat.type !== 'Agent') { res.status(400).json({ error: 'Only agent seats change status' }); return null; }
  if (to !== 'Open' && to !== 'Assigned') { res.status(400).json({ error: 'Status must be Open or Assigned' }); return null; }
  return store.setStatus(date, seat.id, to === 'Open' ? 'Assigned' : 'Open', to, rowVer, req.user);
}, 'supervisor'));

app.use('/api', api);
app.use(express.static(path.join(__dirname, '..', 'public'), { maxAge: '5m' }));

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'Something went wrong. Try again.' });
});

store.init()
  .then(() => app.listen(PORT, () => console.log(`Metro Hot Seating on :${PORT} (store=${store.kind}, realtime=${realtime.enabled})`)))
  .catch((e) => { console.error('Startup failed:', e); process.exit(1); });

module.exports = { app };
