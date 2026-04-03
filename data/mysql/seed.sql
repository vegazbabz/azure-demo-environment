-- ─────────────────────────────────────────────────────────────────────────────
-- ADE Demo Data — MySQL seed script
-- Targets: ${prefix}db  (deployed by databases.bicep)
-- Run via seed-data.ps1 or: az mysql flexible-server execute ...
-- Script is idempotent — safe to run multiple times.
-- ─────────────────────────────────────────────────────────────────────────────

-- Demo IoT telemetry events table
CREATE TABLE IF NOT EXISTS demo_events (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    event_type  VARCHAR(50)  NOT NULL,
    device_id   VARCHAR(100) NOT NULL,
    payload     JSON         NOT NULL,
    occurred_at DATETIME     NOT NULL DEFAULT NOW(),
    UNIQUE KEY uq_event (device_id, event_type, occurred_at)
);

-- Idempotent inserts using INSERT IGNORE
INSERT IGNORE INTO demo_events (event_type, device_id, payload, occurred_at)
VALUES
    ('temperature', 'dev-001', '{"value": 22.5, "unit": "celsius"}',   '2026-01-01 00:00:00'),
    ('humidity',    'dev-001', '{"value": 61.0, "unit": "percent"}',   '2026-01-01 00:00:00'),
    ('temperature', 'dev-002', '{"value": 19.3, "unit": "celsius"}',   '2026-01-01 00:01:00'),
    ('pressure',    'dev-002', '{"value": 1013.25, "unit": "hPa"}',    '2026-01-01 00:01:00'),
    ('motion',      'dev-003', '{"detected": true, "zone": "entrance"}','2026-01-01 00:02:00'),
    ('temperature', 'dev-001', '{"value": 22.7, "unit": "celsius"}',   '2026-01-01 00:05:00'),
    ('humidity',    'dev-002', '{"value": 58.5, "unit": "percent"}',   '2026-01-01 00:05:00'),
    ('battery',     'dev-003', '{"level": 87, "unit": "percent"}',     '2026-01-01 00:10:00');

-- Demo device registry table
CREATE TABLE IF NOT EXISTS demo_devices (
    device_id   VARCHAR(100) PRIMARY KEY,
    model       VARCHAR(100) NOT NULL,
    location    VARCHAR(100) NOT NULL,
    active      TINYINT(1)   NOT NULL DEFAULT 1,
    registered  DATETIME     NOT NULL DEFAULT NOW()
);

INSERT IGNORE INTO demo_devices (device_id, model, location, active)
VALUES
    ('dev-001', 'SensorX v2',  'Building A - Floor 1', 1),
    ('dev-002', 'SensorX v2',  'Building A - Floor 2', 1),
    ('dev-003', 'MotionPro v1','Building B - Entrance', 1);

-- Summary
SELECT
    device_id,
    COUNT(*)   AS event_count,
    MAX(occurred_at) AS last_seen
FROM demo_events
GROUP BY device_id
ORDER BY last_seen DESC;
