'use strict';
// Azure SQL store. Connects with the App Service managed identity
// (DefaultAzureCredential with AZURE_CLIENT_ID); locally it uses your az login.
const fs = require('fs');
const path = require('path');
const sql = require('mssql');
const { sampleOpenFor } = require('./sample');

const SCHEMA_PATH = path.join(__dirname, '..', 'db', 'schema.sql');

function createSqlStore({ server, database, clientId }, layoutData) {
  let pool;

  const config = {
    server,
    database,
    options: { encrypt: true },
    authentication: {
      type: 'azure-active-directory-default',
      options: clientId ? { clientId } : {}
    },
    pool: { max: 10, min: 0, idleTimeoutMillis: 30000 }
  };

  const SELECT_ROW = `d.SeatId AS seatId, d.Status AS status, d.Source AS source,
    d.ClaimedForName AS claimedForName, d.ClaimedByName AS claimedByName, d.ClaimedByUpn AS claimedByUpn,
    CONVERT(varchar(20), d.RowVer, 1) AS rowVer`;

  async function ensureSchema() {
    const exists = await pool.request().query("SELECT OBJECT_ID('dbo.Seat') AS id");
    if (exists.recordset[0].id) return;
    const text = fs.readFileSync(SCHEMA_PATH, 'utf8')
      .split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');
    const statements = text.split(/;\s*\n/).map((s) => s.trim()).filter(Boolean);
    for (const stmt of statements) await pool.request().batch(stmt);
    console.log(`Schema created (${statements.length} statements)`);
  }

  async function ensureSeed() {
    const count = await pool.request().query('SELECT COUNT(*) AS n FROM dbo.Seat');
    if (count.recordset[0].n > 0) return;
    const { layout } = layoutData;
    const tx = new sql.Transaction(pool);
    await tx.begin();
    try {
      for (const area of layout.areas) {
        const g = layout.grids[area.grid];
        await new sql.Request(tx)
          .input('id', area.id).input('name', area.name).input('w', area.width).input('h', area.height)
          .input('sx', g.sx).input('sy', g.sy).input('sw', g.w).input('sh', g.h)
          .input('note', area.note).input('marks', JSON.stringify(area.landmarks || []))
          .query(`INSERT INTO dbo.Area (AreaId, Name, MapWidth, MapHeight, GridSx, GridSy, SeatW, SeatH, Note, LandmarksJson)
                  VALUES (@id, @name, @w, @h, @sx, @sy, @sw, @sh, @note, @marks)`);
        for (const pod of area.pods) {
          await new sql.Request(tx)
            .input('id', pod.id).input('area', area.id).input('label', pod.label)
            .input('sup', pod.supervisor || null).input('x', pod.x).input('y', pod.y)
            .query(`INSERT INTO dbo.Pod (PodId, AreaId, Label, SupervisorLabel, X, Y)
                    VALUES (@id, @area, @label, @sup, @x, @y)`);
          for (const seat of pod.seats) {
            await new sql.Request(tx)
              .input('id', seat.id).input('pod', pod.id).input('c', seat.c).input('r', seat.r)
              .input('type', seat.type).input('note', seat.note)
              .query(`INSERT INTO dbo.Seat (SeatId, PodId, GridCol, GridRow, SeatType, Note)
                      VALUES (@id, @pod, @c, @r, @type, @note)`);
          }
        }
      }
      await tx.commit();
      console.log(`Seeded ${layoutData.seats.size} seats`);
    } catch (e) {
      await tx.rollback();
      throw e;
    }
  }

  async function ensureDay(date) {
    try {
      await pool.request()
        .input('d', sql.Date, date)
        .input('open', sampleOpenFor(date).join(','))
        .query(`INSERT INTO dbo.SeatDay (SeatId, WorkDate, Status, Source)
                SELECT s.SeatId, @d,
                  CASE WHEN s.SeatType = 'Agent' AND s.SeatId IN (SELECT value FROM STRING_SPLIT(@open, ','))
                       THEN 'Open' ELSE 'Assigned' END,
                  'System'
                FROM dbo.Seat s
                WHERE s.IsActive = 1
                  AND NOT EXISTS (SELECT 1 FROM dbo.SeatDay x WHERE x.WorkDate = @d AND x.SeatId = s.SeatId)`);
    } catch (e) {
      if (e.number !== 2627) throw e; // another request created the day first
    }
  }

  async function transition(date, seatId, rowVer, actor, eventType, whereStatus, setSql, extraInputs) {
    const req = pool.request()
      .input('d', sql.Date, date).input('seat', seatId).input('rv', rowVer)
      .input('actor', actor).input('evt', eventType).input('from', whereStatus);
    for (const [k, v] of Object.entries(extraInputs || {})) req.input(k, v);
    const r = await req.query(`
      SET XACT_ABORT ON;
      BEGIN TRAN;
      DECLARE @out TABLE (SeatId varchar(8));
      UPDATE dbo.SeatDay SET ${setSql}, UpdatedAtUtc = SYSUTCDATETIME()
      OUTPUT inserted.SeatId INTO @out
      WHERE WorkDate = @d AND SeatId = @seat AND Status = @from
        AND CONVERT(varchar(20), RowVer, 1) = @rv;
      IF EXISTS (SELECT 1 FROM @out)
        INSERT INTO dbo.SeatEvent (SeatId, WorkDate, EventType, FromStatus, ToStatus, Actor)
        SELECT @seat, @d, @evt, @from, Status, @actor FROM dbo.SeatDay WHERE WorkDate = @d AND SeatId = @seat;
      COMMIT;
      SELECT (SELECT COUNT(*) FROM @out) AS changed, ${SELECT_ROW}
      FROM dbo.SeatDay d WHERE d.WorkDate = @d AND d.SeatId = @seat;`);
    const row = r.recordset[0];
    if (!row) return { ok: false, current: null };
    const changed = row.changed > 0;
    delete row.changed;
    return changed ? { ok: true, row } : { ok: false, current: row };
  }

  return {
    kind: 'sql',
    async init() {
      pool = await new sql.ConnectionPool(config).connect();
      await ensureSchema();
      await ensureSeed();
    },
    async getDay(date) {
      await ensureDay(date);
      const r = await pool.request().input('d', sql.Date, date)
        .query(`SELECT ${SELECT_ROW} FROM dbo.SeatDay d WHERE d.WorkDate = @d`);
      return r.recordset;
    },
    claim(date, seatId, agentName, rowVer, user) {
      return transition(date, seatId, rowVer, user.upn, 'Claimed', 'Open',
        `Status = 'Claimed', Source = 'Manual', ClaimedForName = @agent, ClaimedByName = @byName,
         ClaimedByUpn = @byUpn, ClaimedAtUtc = SYSUTCDATETIME()`,
        { agent: agentName, byName: user.name, byUpn: user.upn });
    },
    release(date, seatId, rowVer, user) {
      return transition(date, seatId, rowVer, user.upn, 'Released', 'Claimed',
        `Status = 'Open', Source = 'Manual', ClaimedForName = NULL, ClaimedByName = NULL,
         ClaimedByUpn = NULL, ClaimedAtUtc = NULL`);
    },
    setStatus(date, seatId, fromStatus, toStatus, rowVer, user) {
      return transition(date, seatId, rowVer, user.upn, toStatus === 'Open' ? 'MarkedOpen' : 'MarkedAssigned',
        fromStatus, `Status = @to, Source = 'Manual'`, { to: toStatus });
    }
  };
}

module.exports = { createSqlStore };
