-- ZenSched Claims-Inspection Local Database Schema
-- SQLite database for clients (carriers, TPAs, IA firms, attorneys, direct),
-- a cache of loss-site addresses, the inspector roster, one-off claim
-- assignments, the inspection visits on each assignment, client invoices /
-- receivables, and subcontractor payouts.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my claims-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 claims-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT AN ESTIMATING TOOL AND NOT XACTANALYSIS. Nothing here writes a
-- scope, a line item, a replacement-cost figure, or a liability opinion. The
-- Claim Photo Report is access + weather + photos of what was seen. You (or
-- the desk adjuster) estimate elsewhere.
--
-- NO BAA. ZenShows / ZenSched is not a HIPAA business associate. Do not use
-- this kit for medical / workers-comp health claims that would require a BAA.
-- Auto, property, liability-scene, and CAT photo inspections only.
--
-- PHI / PII BOUNDARY: claimant name, claim number, policy number, and date of
-- birth live ONLY in this file on your computer: assignments.claim_no,
-- assignments.policy_no, assignments.claimant_name, assignments.claimant_dob.
-- ZenSched receives, per inspection, a place label ("Inspect - Willow Ln"),
-- the street address for the GPS pin, an event title
-- ("Inspect A-2026-0001 - Willow Ln"), and the Claim Photo Report (loss type
-- seen, access, overview/detail photos, weather, denied reason, notes).
-- SKILL.md forbids the agent from putting any local-only column into a
-- ZenSched field.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Claims Inspection');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('state', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_inspector_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_inspection_minutes', '60');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_travel_buffer_minutes', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('report_form_id', NULL);

-- Clients: who hires you and who pays you. A carrier, a TPA, a larger IA firm
-- passing overflow, an attorney (liability scene), or a direct insured.
-- payment_terms_days drives invoice due dates; default_fee / default_trip_fee
-- are copied onto the assignment when the order does not state a fee.
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'tpa'
    CHECK (client_type IN ('carrier', 'tpa', 'ia_firm', 'attorney', 'direct', 'other')),
  contact_name TEXT,                                -- LOCAL ONLY: desk adjuster / AP
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 30,   -- net 30 / net 45; direct = 0
  default_fee REAL,                                 -- $ per completed inspection assignment
  default_trip_fee REAL,                            -- $ when access is denied / no one home
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Places: a cache of loss-site addresses -> ZenSched location ids.
-- Body shops, apartments, and CAT staging lots repeat; most dwellings do not.
-- normalized_address is the de-dup key: the agent builds it as
-- lowercase(address + city + state + zip) with commas, periods, and '#' removed
-- and whitespace collapsed to single spaces (SQLite cannot collapse whitespace,
-- so the agent does it). The agent looks here FIRST and only calls
-- location_create (geocode, $0.03) on a miss. Hand-tuned pins (location_update)
-- therefore survive for repeat sites. place_label is the ONLY name sent to
-- ZenSched for this address; street_name (no house number) feeds event titles
-- ("Inspect A-2026-0001 - Willow Ln"). access_notes is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS places (
  place_id INTEGER PRIMARY KEY AUTOINCREMENT,
  normalized_address TEXT NOT NULL UNIQUE,
  address TEXT NOT NULL,
  city TEXT,
  state TEXT,
  zip TEXT,
  street_name TEXT,                                 -- 'Willow Ln' (no number); used in event titles
  place_label TEXT,                                 -- sent to ZenSched: 'Inspect - Willow Ln'
  zensched_location_id INTEGER,                     -- from location_create (permanent), integer id
  access_notes TEXT,                                -- LOCAL ONLY: gate code, 'unit in rear', 'dog'
  is_repeat_site INTEGER DEFAULT 0,                 -- 1 = shop / complex / facility you expect to return to
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Inspectors: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. In agency mode add a row per
-- subcontracted 1099 inspector with payout_type/payout_value
-- ('flat' = $ per assignment, 'percent' = % of the billable total).
-- license_no (adjuster / appraiser license) is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS inspectors (
  inspector_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspector_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite (integer)
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  license_no TEXT,                                  -- LOCAL ONLY
  license_expires TEXT,                             -- ISO date
  payout_type TEXT
    CHECK (payout_type IS NULL OR payout_type IN ('flat', 'percent')),
  payout_value REAL,                                -- $ (flat) or % (percent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Assignments: one row per job from a client (a claim they sent you to
-- photograph). An assignment has one or more inspection visits (below). The
-- assignment carries the fee snapshot and the deadline.
--
-- assignment_no is YOUR reference, filled by trigger as 'A-2026-0001' when
-- NULL. client_order_ref is THE CLIENT's file / assignment number (safe to
-- put on an invoice; they issued it).
--
-- claim_no, policy_no, claimant_name, claimant_dob are LOCAL ONLY and never
-- reach ZenSched. The event title is "Inspect {assignment_no} - {street}".
--
-- status: requested | confirmed | completed | denied_access | cancelled | rescheduled.
-- denied_access means the latest visit could not get in; a callback is a new
-- inspections row on the same assignment. rescheduled assignments do not bill
-- (the new row does).
CREATE TABLE IF NOT EXISTS assignments (
  assignment_id INTEGER PRIMARY KEY AUTOINCREMENT,
  assignment_no TEXT UNIQUE,                        -- 'A-2026-0001', filled by trigger if NULL
  client_id INTEGER NOT NULL,
  client_order_ref TEXT,                            -- the client's assignment / file number
  loss_type TEXT NOT NULL DEFAULT 'property'
    CHECK (loss_type IN ('auto', 'property', 'liability', 'catastrophe', 'other')),
  loss_date TEXT,                                   -- ISO date of loss
  due_by TEXT,                                      -- ISO date the client needs photos by
  fee REAL,                                         -- NULL -> client default_fee (trigger)
  trip_fee REAL,                                    -- NULL -> client default_trip_fee (trigger)
  other_fee REAL,                                   -- rush, wait, late-cancel, extra site
  claim_no TEXT,                                    -- LOCAL ONLY
  policy_no TEXT,                                   -- LOCAL ONLY
  claimant_name TEXT,                               -- LOCAL ONLY
  claimant_dob TEXT,                                -- LOCAL ONLY (ISO date) when the order supplies it
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('requested', 'confirmed', 'completed', 'denied_access', 'cancelled', 'rescheduled')),
  notes TEXT,
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,                       -- 1 = sub payout done (agency mode)
  rescheduled_from INTEGER,                         -- previous assignment_id when this row is the reschedule
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE,
  FOREIGN KEY (rescheduled_from) REFERENCES assignments(assignment_id) ON DELETE SET NULL
);

-- Inspections: THE driving table for the phone. One row per visit window on
-- an assignment; each row maps to exactly one ZenSched event (start_date =
-- end_date = the visit date — one event per inspection day) and one shift
-- (the window). A denied-access callback is a second row (visit_no 2).
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' or
-- 'YYYY-MM-DDTHH:MM:SS' with NO offset and no 'Z'; the views append
-- settings.timezone_offset to produce start_iso / end_iso for shift_create.
--
-- loss_type_seen / access / weather_at_visit / denied_reason / photo_* /
-- report_dc_id come from the Claim Photo Report. checked_in_at /
-- checked_out_at / gps_verified / checkin_distance_m are copied from
-- shift_status once, so "was I on site" and the export pack are answered
-- from SQLite for free. photo_urls is the CDN URL list stored after the
-- one metered read so a later pack does not re-bill.
CREATE TABLE IF NOT EXISTS inspections (
  inspection_id INTEGER PRIMARY KEY AUTOINCREMENT,
  assignment_id INTEGER NOT NULL,
  visit_no INTEGER,                                 -- per assignment, filled by trigger if NULL
  place_id INTEGER NOT NULL,
  scheduled_start TEXT NOT NULL                     -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
           AND scheduled_start NOT GLOB '*T*[+-]*'
           AND scheduled_start NOT GLOB '*Z'),
  duration_minutes INTEGER                          -- NULL -> settings.default_inspection_minutes
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 15 AND 480),
  inspector_id INTEGER,                             -- NULL -> settings.default_inspector_id (trigger)
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned', 'completed', 'denied', 'cancelled', 'no_show')),
  zensched_event_id INTEGER,                        -- single-day event for this visit date
  zensched_shift_id INTEGER UNIQUE,                 -- one shift per inspection
  report_dc_id INTEGER,                             -- Claim Photo Report submission_id
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  loss_type_seen TEXT,                              -- form option key: auto, dwelling, contents, ...
  access TEXT,                                      -- form option key: full, partial, denied
  weather_at_visit TEXT,                            -- form option key: clear, rain, snow, other
  denied_reason TEXT,
  photo_overview_count INTEGER,
  photo_detail_count INTEGER,
  photo_urls TEXT,                                  -- JSON array of CDN URLs, filled on the one read
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (assignment_id) REFERENCES assignments(assignment_id) ON DELETE CASCADE,
  FOREIGN KEY (place_id) REFERENCES places(place_id) ON DELETE RESTRICT,
  FOREIGN KEY (inspector_id) REFERENCES inspectors(inspector_id) ON DELETE SET NULL
);

-- Invoices: one per client per billing run. invoice_number is filled by trigger
-- if left NULL. due_date is invoice_date + the client's payment_terms_days.
-- line_items is a JSON array with one object per assignment (assignment_no,
-- date, loss_type, order ref, fee breakdown, shift id). Never put claimant
-- name, DOB, or policy number in line_items.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE
);

-- Payouts: what you owe a subcontracted inspector for one assignment (agency
-- mode). One row per assignment. amount is filled by trigger when left NULL:
-- flat -> inspectors.payout_value; percent -> billable_total * payout_value / 100.
-- Never insert a payout for the owner row. The inspector on the latest
-- completed/denied visit is the one who is paid.
CREATE TABLE IF NOT EXISTS payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspector_id INTEGER NOT NULL,
  assignment_id INTEGER NOT NULL UNIQUE,
  amount REAL,                                      -- trigger fills if NULL
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (inspector_id) REFERENCES inspectors(inspector_id) ON DELETE CASCADE,
  FOREIGN KEY (assignment_id) REFERENCES assignments(assignment_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_places_location ON places(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_assignments_client ON assignments(client_id, invoiced);
CREATE INDEX IF NOT EXISTS idx_assignments_status_due ON assignments(status, due_by);
CREATE INDEX IF NOT EXISTS idx_assignments_loss ON assignments(loss_type, loss_date);
CREATE INDEX IF NOT EXISTS idx_inspections_start ON inspections(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_inspections_status_start ON inspections(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_inspections_assignment ON inspections(assignment_id);
CREATE INDEX IF NOT EXISTS idx_inspections_place ON inspections(place_id);
CREATE INDEX IF NOT EXISTS idx_inspections_inspector ON inspections(inspector_id);
CREATE INDEX IF NOT EXISTS idx_inspections_event ON inspections(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);
CREATE INDEX IF NOT EXISTS idx_payouts_inspector ON payouts(inspector_id, paid);

-- Which fees are billable depends on what happened. This is the single place
-- that rule lives; receivables, invoicing, and payouts all read billable_total
-- from here rather than re-deriving it.
--   completed      -> fee + other
--   denied_access  -> trip + other   (you travelled; nobody let you in)
--   cancelled      -> other_fee only (a late-cancel / rush fee the agent puts in other_fee)
--   requested / confirmed / rescheduled -> 0
CREATE VIEW IF NOT EXISTS billable_assignments AS
SELECT
  a.assignment_id,
  a.assignment_no,
  a.client_id,
  a.client_order_ref,
  a.loss_type,
  a.status,
  a.loss_date,
  a.due_by,
  a.fee,
  a.trip_fee,
  a.other_fee,
  CASE a.status
    WHEN 'completed'     THEN round(COALESCE(a.fee, 0) + COALESCE(a.other_fee, 0), 2)
    WHEN 'denied_access' THEN round(COALESCE(a.trip_fee, 0) + COALESCE(a.other_fee, 0), 2)
    WHEN 'cancelled'     THEN round(COALESCE(a.other_fee, 0), 2)
    ELSE 0
  END                                              AS billable_total,
  a.invoiced,
  a.paid_out,
  (SELECT i.zensched_shift_id FROM inspections i
    WHERE i.assignment_id = a.assignment_id
      AND i.status IN ('completed', 'denied', 'no_show')
    ORDER BY i.scheduled_start DESC, i.inspection_id DESC LIMIT 1) AS zensched_shift_id,
  (SELECT i.report_dc_id FROM inspections i
    WHERE i.assignment_id = a.assignment_id
      AND i.report_dc_id IS NOT NULL
    ORDER BY i.scheduled_start DESC, i.inspection_id DESC LIMIT 1) AS report_dc_id,
  (SELECT date(i.scheduled_start) FROM inspections i
    WHERE i.assignment_id = a.assignment_id
    ORDER BY i.scheduled_start DESC, i.inspection_id DESC LIMIT 1) AS last_visit_date
FROM assignments a;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_place_timestamp
AFTER UPDATE ON places
BEGIN
  UPDATE places SET updated_at = datetime('now') WHERE place_id = NEW.place_id;
END;

CREATE TRIGGER IF NOT EXISTS update_inspector_timestamp
AFTER UPDATE ON inspectors
BEGIN
  UPDATE inspectors SET updated_at = datetime('now') WHERE inspector_id = NEW.inspector_id;
END;

CREATE TRIGGER IF NOT EXISTS update_assignment_timestamp
AFTER UPDATE OF client_id, client_order_ref, loss_type, loss_date, due_by, fee, trip_fee,
                other_fee, claim_no, policy_no, claimant_name, claimant_dob, status, notes,
                invoiced, paid_out, rescheduled_from
ON assignments
BEGIN
  UPDATE assignments SET updated_at = datetime('now') WHERE assignment_id = NEW.assignment_id;
END;

CREATE TRIGGER IF NOT EXISTS update_inspection_timestamp
AFTER UPDATE OF assignment_id, visit_no, place_id, scheduled_start, duration_minutes, inspector_id,
                status, zensched_event_id, zensched_shift_id, report_dc_id, checked_in_at,
                checked_out_at, gps_verified, checkin_distance_m, loss_type_seen, access,
                weather_at_visit, denied_reason, photo_overview_count, photo_detail_count,
                photo_urls, notes
ON inspections
BEGIN
  UPDATE inspections SET updated_at = datetime('now') WHERE inspection_id = NEW.inspection_id;
END;

-- Auto-number assignments: A-2026-0001, A-2026-0002, ... (year of due_by,
-- else loss_date, else today; sequence = assignment_id).
CREATE TRIGGER IF NOT EXISTS number_assignment
AFTER INSERT ON assignments
WHEN NEW.assignment_no IS NULL
BEGIN
  UPDATE assignments
  SET assignment_no = 'A-'
    || strftime('%Y', COALESCE(NEW.due_by, NEW.loss_date, date('now', 'localtime')))
    || '-' || printf('%04d', NEW.assignment_id)
  WHERE assignment_id = NEW.assignment_id;
END;

-- Fill defaults the agent left NULL:
--   fee      <- clients.default_fee, else 0
--   trip_fee <- clients.default_trip_fee, else fee (denied still bills unless they set a lower trip)
--   other_fee <- 0
-- Fees are snapshots: changing a client's defaults later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_assignment_defaults
AFTER INSERT ON assignments
BEGIN
  UPDATE assignments
  SET fee = COALESCE(NEW.fee, (SELECT default_fee FROM clients WHERE client_id = NEW.client_id), 0),
      trip_fee = COALESCE(NEW.trip_fee, (SELECT default_trip_fee FROM clients WHERE client_id = NEW.client_id),
                          NEW.fee, (SELECT default_fee FROM clients WHERE client_id = NEW.client_id), 0),
      other_fee = COALESCE(NEW.other_fee, 0)
  WHERE assignment_id = NEW.assignment_id;
END;

-- Fill inspection defaults the agent left NULL:
--   visit_no          <- next number on this assignment
--   duration_minutes  <- settings.default_inspection_minutes (else 60)
--   inspector_id      <- settings.default_inspector_id (solo mode: you)
CREATE TRIGGER IF NOT EXISTS fill_inspection_defaults
AFTER INSERT ON inspections
BEGIN
  UPDATE inspections
  SET visit_no = COALESCE(NEW.visit_no,
                          (SELECT COALESCE(MAX(visit_no), 0) + 1 FROM inspections
                           WHERE assignment_id = NEW.assignment_id
                             AND inspection_id <> NEW.inspection_id)),
      duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_inspection_minutes'),
                                  60),
      inspector_id = COALESCE(NEW.inspector_id,
                              (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_inspector_id' AND value IS NOT NULL))
  WHERE inspection_id = NEW.inspection_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Payout amount from the inspector's split when the agent leaves it NULL.
-- flat    -> payout_value
-- percent -> billable_total * payout_value / 100, rounded to cents
-- If the inspector has no payout_type the amount stays NULL and payouts_due flags it.
CREATE TRIGGER IF NOT EXISTS fill_payout_amount
AFTER INSERT ON payouts
WHEN NEW.amount IS NULL
BEGIN
  UPDATE payouts
  SET amount = (SELECT CASE n.payout_type
                         WHEN 'flat'    THEN n.payout_value
                         WHEN 'percent' THEN round(b.billable_total * n.payout_value / 100.0, 2)
                       END
                FROM inspectors n
                JOIN billable_assignments b ON b.assignment_id = NEW.assignment_id
                WHERE n.inspector_id = NEW.inspector_id)
  WHERE payout_id = NEW.payout_id;
END;

-- Upcoming planned inspections (today through today + 6, local date of the
-- computer running the database). start_iso / end_iso carry
-- settings.timezone_offset and are ready for shift_create. The three
-- idempotency keys and the ZenSched names are ready too. The event and shift
-- keys include the visit date so a different-day reschedule (shift_cancel +
-- new event/shift on the same row) gets fresh keys instead of replaying the
-- cached event / cancelled shift within ZenSched's 24-hour idempotency window.
--   needs_location = 1 -> the place has no ZenSched location yet
--   needs_shift    = 1 -> the inspection has no ZenSched shift yet
-- Event title is ALWAYS "Inspect {assignment_no} - {street}" — never a
-- claimant name or claim number.
CREATE VIEW IF NOT EXISTS inspections_upcoming AS
SELECT
  i.inspection_id,
  i.visit_no,
  i.status,
  i.scheduled_start,
  i.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', i.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(i.scheduled_start, '+' || i.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  date(i.scheduled_start)                                                          AS visit_date,
  a.assignment_id,
  a.assignment_no,
  a.status                                                                         AS assignment_status,
  a.loss_type,
  a.loss_date,
  a.due_by,
  a.client_order_ref,
  a.claim_no,                                                                      -- LOCAL: show the owner, never ZenSched
  a.claimant_name,                                                                 -- LOCAL
  a.fee,
  a.trip_fee,
  c.client_id,
  c.client_name,
  c.client_type,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.street_name,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Inspect - ' || COALESCE(p.street_name, a.assignment_no)) AS zensched_location_name,
  'Inspect ' || a.assignment_no || ' - ' || COALESCE(p.street_name, 'site')        AS zensched_event_title,
  p.access_notes                                                                   AS place_access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  i.zensched_event_id,
  i.zensched_shift_id,
  CASE WHEN i.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  i.inspector_id,
  n.inspector_name,
  n.zensched_worker_id,
  a.notes                                                                          AS assignment_notes,
  i.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-insp-' || i.inspection_id || '-' || strftime('%Y%m%d', i.scheduled_start) AS event_idempotency_key,
  'shift-insp-' || i.inspection_id || '-' || strftime('%Y%m%d', i.scheduled_start) AS shift_idempotency_key
FROM inspections i
JOIN assignments a ON a.assignment_id = i.assignment_id
JOIN clients c ON c.client_id = a.client_id
JOIN places p ON p.place_id = i.place_id
LEFT JOIN inspectors n ON n.inspector_id = i.inspector_id
WHERE i.status = 'planned'
  AND a.status IN ('requested', 'confirmed', 'denied_access')
  AND date(i.scheduled_start) BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY i.scheduled_start;

-- Open assignments approaching or past due_by. Lead with overdue. A
-- denied_access row stays here until a completed visit or the owner closes it.
CREATE VIEW IF NOT EXISTS assignments_due AS
SELECT
  a.assignment_id,
  a.assignment_no,
  a.status,
  a.loss_type,
  a.loss_date,
  a.due_by,
  CAST(julianday(a.due_by) - julianday(date('now', 'localtime')) AS INTEGER) AS days_left,
  CASE
    WHEN a.due_by IS NULL THEN 'no_deadline'
    WHEN julianday(a.due_by) - julianday(date('now', 'localtime')) < 0 THEN 'overdue'
    WHEN julianday(a.due_by) - julianday(date('now', 'localtime')) <= 1 THEN 'high'
    WHEN julianday(a.due_by) - julianday(date('now', 'localtime')) <= 3 THEN 'medium'
    ELSE 'low'
  END                                              AS overdue_risk,
  CASE WHEN a.due_by IS NOT NULL AND a.due_by < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue,
  c.client_id,
  c.client_name,
  c.client_type,
  a.client_order_ref,
  a.claim_no,                                      -- LOCAL
  a.claimant_name,                                 -- LOCAL
  a.fee,
  (SELECT COUNT(*) FROM inspections i WHERE i.assignment_id = a.assignment_id) AS inspection_count,
  (SELECT COUNT(*) FROM inspections i WHERE i.assignment_id = a.assignment_id AND i.status = 'planned') AS planned_count,
  (SELECT i.access FROM inspections i
    WHERE i.assignment_id = a.assignment_id
      AND i.status IN ('completed', 'denied', 'no_show')
    ORDER BY i.scheduled_start DESC, i.inspection_id DESC LIMIT 1) AS last_access,
  (SELECT MIN(i.scheduled_start) FROM inspections i
    WHERE i.assignment_id = a.assignment_id AND i.status = 'planned') AS next_planned,
  (SELECT CASE WHEN MIN(i.zensched_shift_id) IS NULL THEN 1 ELSE 0 END
     FROM inspections i WHERE i.assignment_id = a.assignment_id AND i.status = 'planned') AS needs_shift
FROM assignments a
JOIN clients c ON c.client_id = a.client_id
WHERE a.status IN ('requested', 'confirmed', 'denied_access')
  AND (a.due_by IS NULL
       OR a.due_by <= date('now', 'localtime', '+7 days'))
ORDER BY
  CASE
    WHEN a.due_by IS NULL THEN 2
    WHEN a.due_by < date('now', 'localtime') THEN 0
    ELSE 1
  END,
  a.due_by;

-- Inspections whose visit happened (or was denied on site) and are ready to
-- pull / pack. needs_pull = 1 means the Claim Photo Report has not been read
-- yet (metered, once ever). photo_urls is the cached CDN list after the read.
CREATE VIEW IF NOT EXISTS reports_ready AS
SELECT
  i.inspection_id,
  i.visit_no,
  i.status,
  date(i.scheduled_start)                          AS visit_date,
  a.assignment_id,
  a.assignment_no,
  a.status                                         AS assignment_status,
  a.loss_type,
  a.due_by,
  a.client_order_ref,
  a.claim_no,                                      -- LOCAL: for the pack the owner sends the client
  c.client_id,
  c.client_name,
  c.client_type,
  c.billing_email,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  p.street_name,
  n.inspector_name,
  i.zensched_event_id,
  i.zensched_shift_id,
  i.report_dc_id,
  CASE WHEN i.report_dc_id IS NULL THEN 1 ELSE 0 END AS needs_pull,
  i.checked_in_at,
  i.checked_out_at,
  i.gps_verified,
  i.checkin_distance_m,
  i.loss_type_seen,
  i.access,
  i.weather_at_visit,
  i.denied_reason,
  i.photo_overview_count,
  i.photo_detail_count,
  i.photo_urls,
  a.invoiced,
  i.notes
FROM inspections i
JOIN assignments a ON a.assignment_id = i.assignment_id
JOIN clients c ON c.client_id = a.client_id
JOIN places p ON p.place_id = i.place_id
LEFT JOIN inspectors n ON n.inspector_id = i.inspector_id
WHERE i.status IN ('completed', 'denied')
ORDER BY i.scheduled_start DESC;

-- Uninvoiced billable work grouped by client, with the billing contact and
-- terms. Completed assignments bill fee + other; denied-access bills trip +
-- other; cancellations bill other_fee only (see billable_assignments).
CREATE VIEW IF NOT EXISTS receivables_by_client AS
SELECT
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  COUNT(b.assignment_id)                           AS assignment_count,
  SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN b.status = 'denied_access' THEN 1 ELSE 0 END) AS denied_count,
  SUM(b.billable_total)                            AS total_billable,
  MIN(b.last_visit_date)                           AS first_date,
  MAX(b.last_visit_date)                           AS last_date
FROM billable_assignments b
JOIN clients c ON c.client_id = b.client_id
WHERE b.invoiced = 0
  AND b.status IN ('completed', 'denied_access', 'cancelled')
  AND b.billable_total > 0
GROUP BY c.client_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging. days_past_due is negative while not yet due.
--   current : not yet due
--   30      : 1-30 days past due
--   60      : 31-60 days past due
--   90+     : more than 60 days past due (chase now)
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  i.invoice_date,
  i.due_date,
  i.sent_date,
  i.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(i.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                              AS aging_bucket,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN clients c ON c.client_id = i.client_id
WHERE i.paid = 0
ORDER BY i.due_date;

-- Agency mode: unpaid sub payouts, one row per assignment, with a running
-- total per inspector (inspector_total_due). Owner rows never appear.
-- needs_amount = 1 means the inspector has no payout_type; ask the owner.
CREATE VIEW IF NOT EXISTS payouts_due AS
SELECT
  p.payout_id,
  n.inspector_id,
  n.inspector_name,
  n.email,
  n.payout_type,
  n.payout_value,
  a.assignment_id,
  a.assignment_no,
  a.loss_type,
  a.status,
  b.last_visit_date,
  b.billable_total,
  p.amount,
  CASE WHEN p.amount IS NULL THEN 1 ELSE 0 END     AS needs_amount,
  SUM(p.amount) OVER (PARTITION BY n.inspector_id) AS inspector_total_due,
  a.invoiced                                       AS client_invoiced
FROM payouts p
JOIN inspectors n ON n.inspector_id = p.inspector_id
JOIN assignments a ON a.assignment_id = p.assignment_id
JOIN billable_assignments b ON b.assignment_id = a.assignment_id
WHERE p.paid = 0
  AND n.is_owner = 0
ORDER BY n.inspector_name, b.last_visit_date;

-- Agency mode: completed / denied-access assignments whose latest visit was
-- worked by a sub and have no payouts row yet.
CREATE VIEW IF NOT EXISTS payouts_missing AS
SELECT
  a.assignment_id,
  a.assignment_no,
  a.status,
  b.last_visit_date,
  n.inspector_id,
  n.inspector_name,
  n.payout_type,
  n.payout_value,
  b.billable_total
FROM assignments a
JOIN billable_assignments b ON b.assignment_id = a.assignment_id
JOIN inspections i ON i.inspection_id = (
  SELECT i2.inspection_id FROM inspections i2
  WHERE i2.assignment_id = a.assignment_id
    AND i2.status IN ('completed', 'denied', 'no_show')
  ORDER BY i2.scheduled_start DESC, i2.inspection_id DESC LIMIT 1
)
JOIN inspectors n ON n.inspector_id = i.inspector_id AND n.is_owner = 0
WHERE a.status IN ('completed', 'denied_access')
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.assignment_id = a.assignment_id)
ORDER BY b.last_visit_date;
