'use strict';
// Loads data/floor-layout.json and flattens it into a seat index.
const fs = require('fs');
const path = require('path');

const LAYOUT_PATH = path.join(__dirname, '..', 'data', 'floor-layout.json');

function cellsOf(pod) {
  if (pod.cells) return pod.cells.map(([id, c, r]) => ({ id, c, r }));
  const out = [];
  pod.rows.forEach((row, r) => row.forEach((id, c) => { if (id) out.push({ id, c, r }); }));
  return out;
}

function seatTypeOf(pod, id) {
  if ((pod.desks || []).includes(id)) return 'SupervisorDesk';
  if ((pod.trainerDesks || []).includes(id)) return 'TrainerDesk';
  return pod.seatType || 'Agent';
}

function loadLayout() {
  const layout = JSON.parse(fs.readFileSync(LAYOUT_PATH, 'utf8'));
  const seats = new Map();
  for (const area of layout.areas) {
    for (const pod of area.pods) {
      pod.seats = cellsOf(pod).map((cell) => {
        const seat = {
          id: cell.id, c: cell.c, r: cell.r,
          podId: pod.id, areaId: area.id,
          type: seatTypeOf(pod, cell.id),
          note: (layout.seatNotes || {})[cell.id] || null
        };
        seats.set(cell.id, seat);
        return seat;
      });
    }
  }
  return { layout, seats };
}

module.exports = { loadLayout };
