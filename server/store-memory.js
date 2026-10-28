'use strict';
// In-memory store for local development and tests. Same contract as store-sql.js.
const { sampleOpenFor } = require('./sample');

function createMemoryStore(seatIndex) {
  const days = new Map(); // date -> Map(seatId -> row)
  const events = [];
  let version = 1;

  function ensureDay(date) {
    if (!days.has(date)) {
      const open = new Set(sampleOpenFor(date));
      const rows = new Map();
      for (const seat of seatIndex.values()) {
        rows.set(seat.id, {
          seatId: seat.id,
          status: open.has(seat.id) && seat.type === 'Agent' ? 'Open' : 'Assigned',
          source: 'System', claimedForName: null, claimedByName: null, claimedByUpn: null,
          rowVer: String(version++)
        });
      }
      days.set(date, rows);
    }
    return days.get(date);
  }

  function result(row) { return { ...row }; }

  return {
    kind: 'memory',
    async init() {},
    async getDay(date) {
      return [...ensureDay(date).values()].map(result);
    },
    async claim(date, seatId, agentName, rowVer, user) {
      const row = ensureDay(date).get(seatId);
      if (!row || row.status !== 'Open' || row.rowVer !== rowVer) return { ok: false, current: row && result(row) };
      Object.assign(row, { status: 'Claimed', source: 'Manual', claimedForName: agentName, claimedByName: user.name, claimedByUpn: user.upn, rowVer: String(version++) });
      events.push({ seatId, date, type: 'Claimed', actor: user.upn });
      return { ok: true, row: result(row) };
    },
    async release(date, seatId, rowVer, user) {
      const row = ensureDay(date).get(seatId);
      if (!row || row.status !== 'Claimed' || row.rowVer !== rowVer) return { ok: false, current: row && result(row) };
      Object.assign(row, { status: 'Open', source: 'Manual', claimedForName: null, claimedByName: null, claimedByUpn: null, rowVer: String(version++) });
      events.push({ seatId, date, type: 'Released', actor: user.upn });
      return { ok: true, row: result(row) };
    },
    async setStatus(date, seatId, fromStatus, toStatus, rowVer, user) {
      const row = ensureDay(date).get(seatId);
      if (!row || row.status !== fromStatus || row.rowVer !== rowVer) return { ok: false, current: row && result(row) };
      Object.assign(row, { status: toStatus, source: 'Manual', rowVer: String(version++) });
      events.push({ seatId, date, type: toStatus === 'Open' ? 'MarkedOpen' : 'MarkedAssigned', actor: user.upn });
      return { ok: true, row: result(row) };
    }
  };
}

module.exports = { createMemoryStore };
