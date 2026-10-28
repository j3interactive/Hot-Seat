'use strict';
// PILOT ONLY: sample "who's off" by weekday, taken from the Metro chart.
// Replaced by the Genesys WFM sync in roadmap phase 4.
const SAMPLE_OPEN = {
  1: ['F5', 'I3', 'I4', 'I5', 'I7', 'N3', 'N4'],
  2: ['C4', 'A14', 'G7', 'D20', 'G28', 'T27', 'T28', 'T29'],
  3: ['D20', 'F14', 'A9', 'C18', 'G22', 'N7', 'I3', 'I4'],
  4: ['C4', 'C14', 'C5', 'A32', 'A29', 'D4', 'D8', 'E3'],
  5: ['C9', 'C5', 'A23', 'A27', 'B10', 'F11'],
  6: ['A15', 'A17', 'A19', 'A26', 'G4'],
  0: []
};

function sampleOpenFor(isoDate) {
  const day = new Date(isoDate + 'T12:00:00Z').getUTCDay();
  return SAMPLE_OPEN[day] || [];
}

module.exports = { sampleOpenFor };
