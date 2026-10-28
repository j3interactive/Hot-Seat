-- Metro Hot Seating — Azure SQL schema (current full picture).
-- Once a database exists, make changes as numbered migrations in db/migrations/
-- and keep this file in sync.

CREATE TABLE dbo.Area (
    AreaId        varchar(16)   NOT NULL PRIMARY KEY,       -- main, esc, nest, acad
    Name          nvarchar(64)  NOT NULL,
    MapWidth      int           NOT NULL,
    MapHeight     int           NOT NULL,
    GridSx        int           NOT NULL,
    GridSy        int           NOT NULL,
    SeatW         int           NOT NULL,
    SeatH         int           NOT NULL,
    Note          nvarchar(400) NULL,
    LandmarksJson nvarchar(max) NULL                         -- windows, doors, etc. for drawing
);

CREATE TABLE dbo.Pod (
    PodId                 varchar(16)      NOT NULL PRIMARY KEY,   -- A1, A15, G16 ...
    AreaId                varchar(16)      NOT NULL REFERENCES dbo.Area(AreaId),
    Label                 nvarchar(64)     NOT NULL,
    SupervisorLabel       nvarchar(64)     NULL,                   -- floor label from the layout file
    SupervisorObjectId    uniqueidentifier NULL,                   -- Entra object ID, loaded at runtime
    X                     int              NOT NULL,
    Y                     int              NOT NULL
);

CREATE TABLE dbo.Seat (
    SeatId                  varchar(8)       NOT NULL PRIMARY KEY, -- A14, I3, T27 (floor labels, never renumber)
    PodId                   varchar(16)      NOT NULL REFERENCES dbo.Pod(PodId),
    GridCol                 int              NOT NULL,
    GridRow                 int              NOT NULL,
    SeatType                varchar(16)      NOT NULL
        CONSTRAINT CK_Seat_Type CHECK (SeatType IN ('Agent','SupervisorDesk','TrainerDesk','Ops')),
    Note                    nvarchar(400)    NULL,
    IsActive                bit              NOT NULL CONSTRAINT DF_Seat_IsActive DEFAULT (1),
    -- runtime mappings; never seeded from the repo
    HomeAgentGenesysUserId  uniqueidentifier NULL,
    HomeAgentUpn            nvarchar(256)    NULL,
    DeviceId                nvarchar(64)     NULL
);
CREATE INDEX IX_Seat_HomeAgent ON dbo.Seat (HomeAgentGenesysUserId);

CREATE TABLE dbo.SeatDay (
    SeatId          varchar(8)     NOT NULL REFERENCES dbo.Seat(SeatId),
    WorkDate        date           NOT NULL,                  -- America/New_York business date
    Status          varchar(20)    NOT NULL
        CONSTRAINT CK_SeatDay_Status CHECK (Status IN
            ('Assigned','Open','LikelyOpen','Claimed','Blocked','OccupiedUnclaimed')),
    Source          varchar(12)    NOT NULL
        CONSTRAINT CK_SeatDay_Source CHECK (Source IN
            ('WFM','Presence','Badge','Device','Manual','Block','System')),
    OpenFromUtc     datetime2(0)   NULL,                      -- for early leaves / split shifts
    ClaimedForName  nvarchar(128)  NULL,
    ClaimedForUpn   nvarchar(256)  NULL,
    ClaimedByUpn    nvarchar(256)  NULL,
    ClaimedAtUtc    datetime2(0)   NULL,
    UpdatedAtUtc    datetime2(0)   NOT NULL CONSTRAINT DF_SeatDay_Updated DEFAULT (SYSUTCDATETIME()),
    RowVer          rowversion     NOT NULL,
    CONSTRAINT PK_SeatDay PRIMARY KEY (WorkDate, SeatId)
);

CREATE TABLE dbo.Block (
    BlockId       int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    AreaId        varchar(16)   NULL REFERENCES dbo.Area(AreaId),
    PodId         varchar(16)   NULL REFERENCES dbo.Pod(PodId),
    SeatId        varchar(8)    NULL REFERENCES dbo.Seat(SeatId),
    StartsAtUtc   datetime2(0)  NOT NULL,
    EndsAtUtc     datetime2(0)  NOT NULL,
    Reason        nvarchar(400) NOT NULL,
    CreatedByUpn  nvarchar(256) NOT NULL,
    CreatedAtUtc  datetime2(0)  NOT NULL CONSTRAINT DF_Block_Created DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Block_Target CHECK (
        (CASE WHEN AreaId IS NULL THEN 0 ELSE 1 END +
         CASE WHEN PodId  IS NULL THEN 0 ELSE 1 END +
         CASE WHEN SeatId IS NULL THEN 0 ELSE 1 END) = 1),
    CONSTRAINT CK_Block_Range CHECK (EndsAtUtc > StartsAtUtc)
);

CREATE TABLE dbo.SeatEvent (
    EventId      bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SeatId       varchar(8)    NOT NULL,
    WorkDate     date          NOT NULL,
    EventType    varchar(32)   NOT NULL,   -- Claimed, Released, Opened, NoShowFlagged, NoShowConfirmed, Blocked ...
    FromStatus   varchar(20)   NULL,
    ToStatus     varchar(20)   NULL,
    Actor        nvarchar(256) NOT NULL,   -- UPN, or 'system:wfm' / 'system:presence'
    Detail       nvarchar(400) NULL,
    AtUtc        datetime2(0)  NOT NULL CONSTRAINT DF_SeatEvent_At DEFAULT (SYSUTCDATETIME())
);
CREATE INDEX IX_SeatEvent_Day ON dbo.SeatEvent (WorkDate, SeatId);
