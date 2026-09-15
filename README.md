# ZenSched Claims-Inspection Reference Kit

A copy-pasteable setup for a solo insurance claim photo inspector / independent adjuster (IA), or a 2–8 inspector shop that dispatches subcontracted (1099) inspectors, that wants an AI assistant to run assignment intake, GPS-verified arrival at each loss site, a Claim Photo Report with overview and detail photos, an export pack for the TPA or carrier, receivables, and sub payouts. ZenSched handles the phone app, the GPS check-in at each loss address, the one-off event and shift per inspection day, and the Claim Photo Report. A small local database on your computer holds your clients, the addresses you have been to, your assignments (with the claimant's name, claim number, policy number, and date of birth), each visit, invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste an assignment into your AI assistant ("Summit TPA just sent this, book it"), ask "what's today", "was I on site at Pearl", "pull today's photos", "export pack for A-2026-0001", "invoice Summit", "who owes me money", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not an estimating tool, not XactAnalysis, and there is no BAA — read this first

**What this kit is:** a way for a photo inspector / IA to get every loss-site visit onto their phone from a pasted assignment, prove GPS-verified arrival, record what was seen (loss type, access, weather, overview and detail photos), and turn those records into a pack the TPA can file, invoices, receivables follow-up, and sub payouts, with an AI assistant doing the clerical work.

**What it is not:**

- **It is not an estimating tool and it is not XactAnalysis / Xactimate / Symbility / CoreLogic.** Nothing in this kit writes a scope, a line item, a replacement-cost figure, depreciation, or a coverage decision. A carrier assignment email that *arrived* from XactAnalysis is treated as a dispatch ticket only: the AI extracts the address, window, and fee, and **stashes the claim number locally**. It never opens, writes, or syncs an estimate. The Claim Photo Report's header says so again. If you need a sketch and a line-item estimate, you still do that in the tool you already pay for.
- **There is no BAA.** ZenShows / ZenSched is not a HIPAA business associate and this kit does not make you one. Use it for auto, property, liability-scene, and catastrophe **photo** inspections. Do not run medical-records retrieval, recorded statements about injury, IME transport, or workers-comp health visits on it. Claimant date of birth, when the order supplies it, is stored locally as ordinary PII, not as PHI under a BAA.
- **It does not decide coverage or liability.** Access + photos + weather are facts. "Is this covered" and "who is at fault" stay with the desk adjuster.
- **Photo stamp is opt-in per field.** Compliance photo fields in the kit set `"stamp_photos": true` so the server burns readable date, time, and GPS onto exported JPEGs from capture metadata (default off if you remove the flag). Gallery picks without EXIF may show date/time only.

If any of that is a deal-breaker, this kit is not for you. If you want a phone schedule with GPS proof at the loss site, a photo report you can pack for the TPA, and receivables you can actually chase, read on.

## PHI / PII boundary

Everything that identifies a claimant or a claim file lives only in the local database:

| Field | Column | Goes to ZenSched? | Goes on the invoice / pack? |
|---|---|---|---|
| Claimant name | `assignments.claimant_name` | **Never** | **Never** |
| Date of birth | `assignments.claimant_dob` | **Never** | **Never** |
| Policy number | `assignments.policy_no` | **Never** | **Never** |
| Claim number | `assignments.claim_no` | **Never** | Only if you ask — the TPA already has it |
| Client's assignment / file number | `assignments.client_order_ref` | No | Yes (identifies the file to them) |
| Your assignment number | `assignments.assignment_no` | Yes, in the event title | Yes |
| Loss-site street address | `places.address` | Yes (required for the geofence) | City / street only on the pack |
| Gate codes / unit hints | `places.access_notes` | **Never** | **Never** |

ZenSched titles are always `Inspect {assignment_no} - {street}` (for example `Inspect A-2026-0001 - Pearl St`). Location labels are `Inspect - {street}` or `{client} - {city}` for a repeat shop. `SKILL.md` forbids the AI from putting any local-only column into any ZenSched field, including cancellation reasons (subs see those). The Claim Photo Report has **no** claimant-name, claim-number, policy, or DOB fields.

You are still responsible for your own privacy obligations (the local database, your email, your phone). This kit narrows what a third party sees; it does not make you compliant by itself. There is no BAA.

## What lives where

**ZenSched (source of truth for where you were and when):**

- Locations (one per loss-site address, cached locally so a repeat body shop is created once; the check-in radius is a **policy** setting, not per location)
- Workers (you, in solo mode; you plus your subs in agency mode, each with the mobile app)
- Events (one single-day event per inspection day)
- Shifts (one per visit: the inspection window, 60 minutes by default, with a push notification to the inspector)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Claim Photo Report form (loss type seen, access, overview photos, detail photos, weather, denied reason, notes) and every submission with its photos

**Local SQLite database (`claims-ops.db`, on your computer):**

- Clients: carriers, TPAs, IA firms, attorneys, direct insureds, with payment terms and default fees
- Places: every address you have been sent to, normalized, with its ZenSched location id and access notes — **access notes never leave your computer**
- Inspectors: you (and your subs), license number — **never leaves your computer**; payout split per sub
- Assignments: order ref, loss type, loss date, due-by, fee, **claim number / policy / claimant name / DOB (local only)**, status
- Inspections: each visit window, the ZenSched event/shift/submission ids, GPS stamps copied once, the report summary and photo URL list
- Invoices per client with aging; payouts per sub per assignment
- Your settings (timezone, state, default inspector, default visit length, invoice terms and prefix, Claim Photo Report form id)

**Never duplicated:** the live schedule, punches, and photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "was I on site", "export the pack", and "who owes me" without paying to re-read records.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `claims-ops.db` on your computer.

When you paste an assignment, the AI extracts the client, order number, loss type, claimant, claim number, address, window, and fee; **stashes claim number / policy / claimant / DOB in SQLite only**; adds the client if new; looks the address up in your `places` cache (a shop you have been to before is reused, a new address is geocoded once); saves the assignment as `A-2026-0001`; creates a single-day event titled `Inspect A-2026-0001 - Pearl St` and a shift on ZenSched with the Claim Photo Report attached; and confirms in one line. You see the visit on your phone, check in at the site (GPS-verified), shoot the photos, fill in the report (access, weather, overview + detail), check out. In the evening you say "pull today's photos" and the AI reads each report **once** (metered, then free forever), updates each visit, and tells you what is receivable. "Export pack for A-2026-0001" writes the photo URLs and GPS facts for the TPA. "Invoice Summit" produces a plain-text invoice under their terms; "who owes me money" ages what is open. In agency mode, "what do I owe Reese" lists their split per assignment. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\claims-ops`
- Mac: `/Users/yourname/claims-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain claimant names, claim numbers, policy numbers, and dates of birth; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\claims-ops.db` (Windows) or `/claims-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "claims-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/claims-ops/claims-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\claims-ops\\claims-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `account_create` with org_name "My Claims Inspection" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my claims-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 49 statements and confirm the tables exist. The `claims-ops.db` file now exists in your folder with default settings (60-minute visits, net 30) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 claims-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Ridgeview IA in Denver, Mountain time. It's just me, Jordan Hale, jordan@example.com. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the inspector on the phone; $0.25, one time), creates the Claim Photo Report form on ZenSched (free), and saves the form id so every visit gets it automatically. In agency mode you then say "add my sub Reese Okonkwo, reese@example.com, I pay them $90 an assignment" for each inspector you dispatch.

**Check-in radius.** ZenSched enforces the radius through the account's **policy**, not per address, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so a house and its driveway are covered as is. For apartments, rural driveways, and body-shop lots where you park a long way from the pin, ask the AI to "set the check-in radius to 150 m" or 300 m (`policy_update`), or to move the pin onto the entrance for a repeat site (`location_update`, free; the `places` cache keeps it). Inspectors often wait for the claimant: ask for "allow check-in 20 minutes before the shift" (`checkin_slack_min`). `remote_checkin` turns GPS verification off for every visit and should be a last resort, because it also turns off the proof.

**Forgotten check-outs.** Ask the AI to "remind me to check out 15 minutes after the shift ends" (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached repeat address), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading a Claim Photo Report ($0.05, or $0.15 when it has photos, which this form does; each record is billed **once, ever**). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

An inspection at a new address costs $0.03 + $0.20 + $0.15 = **$0.38**; a visit at a cached shop costs $0.35. A day of many photo-report reads costs $0.15 × those visits the first time you pull them (replays are free). Twenty inspections a month is about $7.50. The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- (paste a TPA / carrier / IA-firm assignment) "Book it."
- "What's today?" / "What's this week?"
- "What's overdue?"
- "Was I on site at Pearl?"
- "Pull today's photos."
- "Export pack for A-2026-0001."
- "Willow was denied — book a callback Thursday 2 pm."
- "The 10 o'clock moved to 1." / "Move A-2026-0002 to Monday."
- "Cancel the Pearl visit; they owe a $40 trip."
- "Invoice Summit TPA." / "Invoice everyone."
- "Who owes me money?"
- "Summit paid INV-2026-0001."
- Agency: "Add my sub Reese Okonkwo, reese@example.com, $90 an assignment." / "Give Thursday's dwelling to Reese." / "What do I owe Reese?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### What "invoice" means here

"Invoice Summit TPA" records the invoice in your database (number, date, due date under that client's terms, total, which assignments with their fee breakdown) and the AI writes out a plain-text invoice you can paste into an email or the TPA's payables portal, with a line per assignment (your assignment number, date, loss type, their order ref, fees) and, for denied access, the GPS-verified arrival. It does **not** generate a PDF, submit it for you, or collect payment. Invoices never carry a claimant name, date of birth, or policy number; the order ref identifies the file to them. When the client pays, tell the AI ("Summit paid INV-2026-0001") and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due.

### What "payouts" means here (agency mode)

Subs are paid per assignment, not by the hour. Each sub has a split (`$90 flat` or `60%` of what the client is billed for that assignment). When a sub's assignment is closed out, a payout row is created with the amount; "what do I owe Reese" lists their unpaid assignments and the total, and "paid Reese" marks them. Your own visits never generate payouts. The kit does not calculate taxes, issue 1099s, or pay anyone. If you also want an hours record for your own books, ZenSched's `timesheet_export(mode="hours")` is free; the kit does not use timesheets for pay.

## Mobile app for inspectors

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [TestFlight](https://testflight.apple.com/join/Wp51m5Yq)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your inspections appear as they are booked. Each one shows the address and time (`Inspect A-2026-0001 - Pearl St`); you check in on arrival (GPS-verified), shoot the photos, fill in the Claim Photo Report, and check out. Subs get the same email when you add them.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `claims-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to -06:00 in settings" (use your own offset; Mountain is -06:00 in summer, -07:00 in winter) |
| Inspection not on my phone | Booked locally but the ZenSched shift was never created (`needs_shift = 1`) | "Put today's inspections on my phone"; the AI finishes the intake steps |
| Check-in not GPS-verified at an apartment / shop lot | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update`), or "move the pin to the entrance" (`location_update`, free; the cached place keeps it), or `location_refine` ($0.10). Do **not** ask to widen the radius on that location — the policy enforces it. |
| App would not let me check in 15 minutes early | Early check-in window too small | "Allow check-in 20 minutes before the shift" (`checkin_slack_min`) |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; ask for a 15-minute check-out reminder |
| Claim Photo Report not on the phone | Form not assigned to that visit's event | "Attach the Claim Photo Report to A-2026-0004" (`form_assign(form_id, event_id=...)` installs it on the shifts already on that event; no need to cancel and recreate the shift) |
| "Denied-access reason" shows even when Access is Full | Conditional fields are web-only on ZenSched | Harmless; leave it blank |
| AI refuses to put a claim number on the phone event | Working as intended | Claim numbers stay in SQLite; the title is `Inspect A-2026-0001 - Pearl St` |
| Same body shop geocoded twice | Address typed differently (suite on a new line, "Ave" vs "Avenue") | Tell the AI it is the same place; it merges the `places` rows and keeps one location |
| Visit moved to another day fails on `shift_update` | Events are single-day (one event per inspection day) | The AI cancels the shift and opens a new event for the new date; ask it to |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions); SQLite is authoritative for clients, places, roster, assignments (including all claimant / claim PII), inspections, billing, and payouts; each side stores only the other's **integer** IDs, plus a per-inspection summary, GPS stamps, and photo URL list cached locally because submission reads are metered. The PII boundary is enforced by data placement (claimant / claim / policy / DOB columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rules 1–3; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **One-off assignments, not recurring routes.** Lawn / pet-care kits expand a `visit_schedule` onto a per-site event rolled every 60 days. Claim photo work is a different address almost every time, so there is no recurrence table and no event roll. `assignments` is the job; `inspections` is the visit. Each inspection maps to exactly one `event_create(location_id, title, start_date=<date>, end_date=<date>, idempotency_key="event-insp-{inspection_id}-{YYYYMMDD}")` and one `shift_create(..., idempotency_key="shift-insp-{inspection_id}-{YYYYMMDD}")`, with `form_assign(form_id, event_id=...)` in between. **One event per inspection day** — the 60-day event cap is irrelevant.
- **`places` is an address de-dup cache.** `places.normalized_address` is `UNIQUE`; the agent normalizes (lowercase, strip `,` `.` `#`, collapse whitespace, include city/state/zip) and looks it up before any `location_create`. A hit reuses `zensched_location_id`, which saves the $0.03 geocode and preserves any hand-tuned pin. `street_name` (no house number) feeds event titles. `is_repeat_site` is a hint for labelling (`<client> - <city>` for shops, `Inspect - <street>` for dwellings).
- **Solo mode is the default; agency mode is additive.** The owner is invited as a ZenSched worker (`worker_invite` with their own email, $0.25) and stored on `inspectors` with `is_owner = 1`; `settings.default_inspector_id` points at that row and `fill_inspection_defaults` assigns it when `inspector_id` is left NULL. Subs are further `inspectors` rows with `payout_type` `CHECK IN ('flat', 'percent')` and `payout_value`. `payouts_due` and `payouts_missing` exclude `is_owner = 1`. One payout per assignment, paid to the inspector on the latest completed/denied visit.
- **Receivables and payouts, not timesheets.** Inspectors are paid per assignment by the TPA / carrier, often net 30, so the money model is per-assignment fees → `billable_assignments` → `invoices` with the client's `payment_terms_days` → `invoices_outstanding` aging. `timesheet_export` appears in `SKILL.md` only as an optional free hours record.
- **`billable_total` is computed in a view, not stored.** The fee columns on `assignments` (`fee`, `trip_fee`, `other_fee`) are snapshots filled by trigger from the client's defaults when left NULL. `trip_fee` falls back to `fee` so a denial still bills unless the client has a lower trip. Which of them are owed depends on `status`, and that rule lives once, in `billable_assignments`: `completed` → fee + other; `denied_access` → trip + other; `cancelled` → `other_fee` only; everything else → 0. A completed callback on a previously denied assignment supersedes the denial (one `fee`, not trip + fee); if the client pays both, the agent puts the trip on `other_fee` before flipping status.
- **`assignment_no`** is assigned by trigger as `A-{YYYY of due_by, else loss_date, else today}-{assignment_id:04d}` when left NULL. `inspections.visit_no` is the next integer per assignment. `invoices.invoice_number` is `{prefix}-{YYYY}-{invoice_id:04d}` the same way.
- **`scheduled_start` is local wall-clock time without an offset** (`2026-09-08T10:00`, `CHECK`-constrained to reject a trailing offset or `Z`). `inspections_upcoming` emits `start_iso` and `end_iso` by appending `settings.timezone_offset`. Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer.
- **No signature field on the form.** ZenSched replaces the Submit button with the signature pad when a form has a `signature` field. Overview photos are `photo` (`max_images: 6`, required); detail photos are `photo` (`max_images: 6`). A submission with photos bills $0.15 instead of $0.05, once ever.
- **GPS stamps and photo URLs are copied once.** `checked_in_at`, `checked_out_at`, `gps_verified`, `checkin_distance_m`, and `photo_urls` are filled at close-out so "was I on site" and the export pack are answered locally. ZenSched remains the original.
- **Reschedules.** Same day → `shift_update` and update `scheduled_start`. Different day → the single-day event cannot move, so `shift_cancel`, clear the event/shift ids, update `scheduled_start`, and create a new event/shift on the same inspection row with the new date-scoped keys the view emits. Withdrawing the *job* marks the assignment `rescheduled` and inserts a new assignment with `rescheduled_from`.
- `inspections.zensched_shift_id`, `inspectors.zensched_worker_id`, `payouts.assignment_id`, and `places.normalized_address` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a client cascades to assignments, inspections, invoices, and payouts; deleting an inspector sets `inspections.inspector_id` NULL and removes their payouts; `places` is `ON DELETE RESTRICT` while inspections reference it.

**Claim Photo Report form.** Created once with `form_create(title, fields_json, idempotency_key="form-claim-photo-report")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's `_validate_fields`. Every field carries an explicit `identifier` so submission `data` keys are stable (`loss_type_seen`, `access`, `photo_overview`, `photo_details`, `weather_at_visit`, `denied_reason`, `notes`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters): `auto` / `dwelling` / `contents` / `liability_scene` / `other`; `full` / `partial` / `denied`; `clear` / `rain` / `snow` / `other`. One `show_if` references `access` with value `denied`. Attaching is `form_assign(form_id, event_id=...)` per inspection.

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-place-{place_id}`
- event: `event-insp-{inspection_id}-{YYYYMMDD}` (visit date)
- shift: `shift-insp-{inspection_id}-{YYYYMMDD}` (visit date; an inspector swap appends `-2`)
- assignment: `assign-report-{event_id}`
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-claim-photo-report`

ZenSched caches idempotent responses for 24 hours, keyed by tool + key only (not by payload). That is why the event and shift keys carry the visit date: a different-day reschedule reuses the same `inspections` row, and without the date the retried `event_create` / `shift_create` would silently return the old event and the just-cancelled shift. `inspections_upcoming` emits `loc_idempotency_key`, `event_idempotency_key`, and `shift_idempotency_key` per row, already dated.

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-08T10:00:00-06:00`), never `Z`. The views build these strings so the agent does not have to.

**Metered reads.** `form_submissions(form_id, event_id=...)` is the natural per-inspection read because every inspection has its own event; `form_export` covers a week or month in one call. Both bill $0.05 per submission ($0.15 with photos), once per submission ever. `shift_list`, `shift_status`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`, which is informational; with geofencing on, values under 100 m are raised to about 91 m. The kit's example sets 150 m / 20 min slack / 15 min check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `payouts_due` uses a window function (`SUM() OVER`), which needs SQLite ≥ 3.25 (2018); `better-sqlite3` bundles a current SQLite.

**Schema test.** The schema was verified by splitting the file into its 49 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 8 tables, 8 views, and 10 triggers present; every view on an empty database; `places.normalized_address`, `inspectors.zensched_worker_id`, `inspections.zensched_shift_id`, and `payouts.assignment_id` `UNIQUE`; the `number_assignment` trigger (`A-YYYY-0001`, explicit number kept); `fill_assignment_defaults` (fee from client, trip_fee from client else fee, explicit fee kept, trip falls back to fee when the client has no trip); `fill_inspection_defaults` (`visit_no` 1 then 2, duration from settings and following a changed setting, inspector from `default_inspector_id`, explicit duration kept); `inspections_upcoming` (`start_iso` / `end_iso` with offset for `HH:MM` and 60/90-minute durations, `needs_location` when the place has no location id, `needs_shift`, the three idempotency keys, `zensched_event_title` = `Inspect {assignment_no} - {street}` with no claimant name or claim number, `zensched_location_name` from `place_label`, 7-day window bounds, cancelled excluded); `assignments_due` (within 7 days included, +10 excluded, overdue flag and negative `days_left`); `updated_at` on assignments; `billable_assignments` for completed (fee), denied_access (trip), cancelled (`other_fee` only), and confirmed (0); `reports_ready` (completed + denied, `needs_pull` when `report_dc_id` is NULL); `receivables_by_client` totals and counts and the drop-off after invoicing; invoice numbering, total, due date = +30 days from the client's terms, `line_items` JSON with no claim PII; `invoices_outstanding` aging buckets `90+` / `60` / `30` / `current` with paid excluded; `payouts_missing` (owner excluded, sub-worked denied included); `payouts_due` math for flat (90) and percent (60% of 250 = 150), `needs_amount` for an inspector without a split, owner exclusion, paid rows dropping out; `rescheduled_from`; every `CHECK` (client type, loss type, assignment status, inspection status, payout type, `scheduled_start` format with offset and `Z` rejected, duration range); foreign keys rejecting an unknown client, `RESTRICT` on places, `SET NULL` on inspector delete, and the full cascade on client delete; integer affinity on every `zensched_*_id` and `report_dc_id`. The Claim Photo Report `fields_json` was validated against ZenSched's `_validate_fields` (8 fields, no signature, identifiers stable, option keys untruncated, `show_if` on `access` / `denied`). 122 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
