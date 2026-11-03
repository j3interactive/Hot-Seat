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

// "A1-A13" -> A1..A13; "D7" -> D7
function expandRange(spec) {
  const m = /^([A-Z]+)(\d+)(?:-\1?(\d+))?$/.exec(spec.trim());
  if (!m) throw new Error(`Bad seat range "${spec}" in seatSupervisors`);
  const from = Number(m[2]);
  const to = m[3] ? Number(m[3]) : from;
  const out = [];
  for (let n = from; n <= to; n++) out.push(m[1] + n);
  return out;
}

// seat ID -> supervisor label, from layout.seatSupervisors
function supervisorIndex(layout) {
  const index = new Map();
  for (const [name, specs] of Object.entries(layout.seatSupervisors || {})) {
    for (const spec of specs) {
      for (const id of expandRange(spec)) {
        if (index.has(id)) throw new Error(`Seat ${id} is assigned to both ${index.get(id)} and ${name}`);
        index.set(id, name);
      }
    }
  }
  return index;
}

function loadLayout() {
  const layout = JSON.parse(fs.readFileSync(LAYOUT_PATH, 'utf8'));
  const supOf = supervisorIndex(layout);
  const seats = new Map();
  for (const area of layout.areas) {
    for (const pod of area.pods) {
      pod.seats = cellsOf(pod).map((cell) => {
        const seat = {
          id: cell.id, c: cell.c, r: cell.r,
          podId: pod.id, areaId: area.id,
          type: seatTypeOf(pod, cell.id),
          supervisor: supOf.get(cell.id) || pod.supervisor || null,
          note: (layout.seatNotes || {})[cell.id] || null
        };
        seats.set(cell.id, seat);
        return seat;
      });
    }
  }
  for (const id of supOf.keys()) {
    if (!seats.has(id)) throw new Error(`seatSupervisors names unknown seat ${id}`);
  }
  return { layout, seats };
}

module.exports = { loadLayout, expandRange };
