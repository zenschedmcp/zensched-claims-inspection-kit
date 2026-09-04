# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **Ridgeview IA**, a solo independent-adjuster / photo-inspection shop (Jordan Hale) in Denver, Colorado, Mountain time (`-06:00` in September). IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: the claimants' names, dates of birth, claim numbers, policy numbers, gate codes. ZenSched sees `Inspect - Pearl St`, a street address, `Inspect A-2026-0001 - Pearl St`, and a photo checklist. This is not an estimate and not XactAnalysis.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Claims Inspection, timezone_offset = -05:00, state = NULL,
    default_inspector_id = NULL, default_inspection_minutes = 60,
    default_travel_buffer_minutes = 30, invoice_due_days = 30, invoice_prefix = INV,
    report_form_id = NULL
sqlite_query:   SELECT * FROM assignments_due;         → (none)
sqlite_query:   SELECT * FROM inspections_upcoming;    → (none)
```

## "We're Ridgeview IA in Denver, Mountain time. It's just me, Jordan Hale, jordan@ridgeviewia.example, 303-555-0144. My CO adjuster license is IA-44018, expires 2027-06-30. Set me up."

```
sqlite_execute: UPDATE settings SET value = 'Ridgeview IA' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-06:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = 'CO' WHERE key = 'state';
```

Agent (first metered call this session, rule 11):

> Saved. Since you're the inspector on the phone, I need to invite you to ZenSched as a worker so your visits show up in the app; that's a one-time $0.25. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "jordan@ridgeviewia.example"
  first_name: "Jordan"
  last_name: "Hale"
  idempotency_key: "worker-jordan@ridgeviewia.example"
  → worker_id: 701, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO inspectors (inspector_name, email, phone, zensched_worker_id, is_owner, license_no, license_expires)
  VALUES ('Jordan Hale', 'jordan@ridgeviewia.example', '303-555-0144', 701, 1, 'IA-44018', '2027-06-30');
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_inspector_id';
```

The license number stays in `inspectors.license_no`; ZenSched got a name and an email.

> You're invited; install the app from the email. Your inspections will land on your own phone. Next, the Claim Photo Report: it's free to create and every visit comes back with loss type seen, access, overview and detail photos, weather, and notes. No signature pad, no claimant name, no claim number. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Claim Photo Report"
  idempotency_key: "form-claim-photo-report"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Claim photo report", "identifier": "sec_visit", "text": "Photo facts only. Do not write the claimant's name, date of birth, claim number, or policy number. This is not an estimate and not a liability opinion."},
  {"type": "select", "label": "Loss type seen", "identifier": "loss_type_seen", "required": true,
   "options": ["Auto", "Dwelling", "Contents", "Liability scene", "Other"]},
  {"type": "select", "label": "Access", "identifier": "access", "required": true,
   "options": ["Full", "Partial", "Denied"]},
  {"type": "photo", "label": "Overview photos", "identifier": "photo_overview", "required": true, "max_images": 6},
  {"type": "photo", "label": "Detail photos", "identifier": "photo_details", "max_images": 6},
  {"type": "select", "label": "Weather at visit", "identifier": "weather_at_visit", "required": true,
   "options": ["Clear", "Rain", "Snow", "Other"]},
  {"type": "textarea", "label": "Denied-access reason", "identifier": "denied_reason",
   "show_if": {"field": "access", "op": "equals", "value": "denied", "action": "show"}},
  {"type": "textarea", "label": "Notes", "identifier": "notes"}
]
```

```
  → form_id: 501, fields: [ ...8 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '501' WHERE key = 'report_form_id';
```

> Claim Photo Report created. I'll attach it to every visit automatically. One policy question: you'll often wait for the claimant and park down the block at apartments; want me to allow early check-in and set the check-in radius to 150 m?

Owner: *"yes"*

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 150, \"checkin_slack_min\": 20, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

The radius is on the **policy**, not on any location.

## "Summit TPA just sent this. Book it." (auto claim)

> *Assignment TPA-8841 — AUTO — Date of loss 9/4/2026 — Inspect Tue Sep 8, 2026 10:00 AM MT — 1840 S Pearl St, Denver, CO 80210 — Claim 26-448190 — Insured: Maya Chen, DOB 03/11/1984 — Policy HO-99102 — Fee $175.00 — Photos due 9/10 — Note: park on street, dog in yard.*

The agent parses: client Summit TPA (`tpa`), order ref `TPA-8841`, type auto, claimant Maya Chen + DOB, claim 26-448190, policy HO-99102, address, Tue 9/8 10:00, fee 175, due 9/10, dog. Claim number, policy, claimant, and DOB are **stored locally only**.

```
sqlite_query: SELECT client_id, payment_terms_days FROM clients WHERE client_name LIKE 'Summit%';   → (none)

sqlite_execute:
  INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days, default_fee, default_trip_fee)
  VALUES ('Summit TPA', 'tpa', 'ap@summittpa.example', 30, 175, 75);
  → lastInsertRowid = 1
```

> I don't have Summit TPA as a client yet. I've added them as a TPA with a $175 inspection / $75 denied-access trip default; I've assumed net 30. Tell me if their terms differ.

```
sqlite_query: SELECT place_id, zensched_location_id, place_label FROM places
              WHERE normalized_address = '1840 s pearl st denver co 80210';   → (none)

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, access_notes, is_repeat_site)
  VALUES ('1840 s pearl st denver co 80210', '1840 S Pearl St', 'Denver', 'CO', '80210',
          'Pearl St', 'Inspect - Pearl St', 'Park on street. Dog in yard.', 0);
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO assignments (client_id, client_order_ref, loss_type, loss_date, due_by, fee,
                           claim_no, policy_no, claimant_name, claimant_dob, status)
  VALUES (1, 'TPA-8841', 'auto', '2026-09-04', '2026-09-10', 175,
          '26-448190', 'HO-99102', 'Maya Chen', '1984-03-11', 'confirmed');
  → lastInsertRowid = 1
  (triggers fill: assignment_no A-2026-0001, trip_fee 75, other_fee 0)

sqlite_execute:
  INSERT INTO inspections (assignment_id, place_id, scheduled_start, status)
  VALUES (1, 1, '2026-09-08T10:00', 'planned');
  → lastInsertRowid = 1
  (triggers fill: visit_no 1, duration_minutes 60, inspector_id 1)

sqlite_query:
  SELECT assignment_no, visit_no, start_iso, end_iso, zensched_location_name, zensched_event_title,
         street_address, needs_location, zensched_worker_id,
         loc_idempotency_key, event_idempotency_key, shift_idempotency_key
  FROM inspections_upcoming WHERE inspection_id = 1;
  → A-2026-0001 | visit 1 | 2026-09-08T10:00:00-06:00 | 2026-09-08T11:00:00-06:00
    | Inspect - Pearl St | Inspect A-2026-0001 - Pearl St
    | 1840 S Pearl St, Denver, CO 80210 | needs_location 1 | worker 701
    | loc-place-1 | event-insp-1-20260908 | shift-insp-1-20260908
```

> Putting this on ZenSched costs $0.03 to geocode the address; each inspection then costs about $0.35 in GPS check-in/out and reading the photo report ($0.38 total for a new address). OK to proceed for this and future visits?

Owner: *"yes"*

```
location_create:
  name: "Inspect - Pearl St"
  street_address: "1840 S Pearl St, Denver, CO 80210"
  checkin_radius_m: 100
  idempotency_key: "loc-place-1"
  → location_id: 9201, lat: 39.6824, lng: -104.9798, pin_quality: "street",
    radius_note: "Check-in radius is enforced by the talent policy ...",
    billing: { meter: "geocode", units: 1, price: 0.03 }

sqlite_execute: UPDATE places SET zensched_location_id = 9201 WHERE place_id = 1;

event_create:
  location_id: 9201
  title: "Inspect A-2026-0001 - Pearl St"
  start_date: "2026-09-08"
  end_date:   "2026-09-08"
  idempotency_key: "event-insp-1-20260908"
  → event_id: 7201

form_assign:
  form_id: 501
  event_id: 7201
  idempotency_key: "assign-report-7201"
  → status: "assigned", form_id: 501, event_id: 7201, policy_id: 0

shift_create:
  event_id: 7201
  worker_id: 701
  start: "2026-09-08T10:00:00-06:00"
  end:   "2026-09-08T11:00:00-06:00"
  idempotency_key: "shift-insp-1-20260908"
  → shift_id: 89101, status: "scheduled", forms_installed: [501]

sqlite_execute: UPDATE inspections SET zensched_event_id = 7201, zensched_shift_id = 89101 WHERE inspection_id = 1;
```

Nothing about Maya Chen, claim 26-448190, policy HO-99102, or the dog is in `name`, `title`, or `notes`.

> Booked **A-2026-0001** visit 1: auto photos, Summit TPA order TPA-8841, Tue Sep 8 10:00–11:00 at Pearl St, Denver. $175, due Sep 10, net 30. It's on your phone with the Claim Photo Report attached. Maya Chen, claim 26-448190, policy HO-99102, and DOB are only on your computer.

## "Summit also sent a dwelling water. Book it."

> *Assignment TPA-8847 — PROPERTY / water — DOL 9/5/2026 — Inspect Wed Sep 9, 2026 2:00 PM MT — 412 Willow Ln, Boulder, CO 80302 — Claim 26-448311 — Insured: Luis Ortega, DOB 1979-08-22 — Policy HO-77410 — Fee $225.00 — Photos due 9/11 — Note: call from drive, gate 3312.*

```
sqlite_execute: (Summit TPA already exists as client 1; fee 225 is explicit on this assignment)

sqlite_query:   SELECT place_id, zensched_location_id FROM places
                WHERE normalized_address = '412 willow ln boulder co 80302';   → (none)

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, access_notes, is_repeat_site)
  VALUES ('412 willow ln boulder co 80302', '412 Willow Ln', 'Boulder', 'CO', '80302',
          'Willow Ln', 'Inspect - Willow Ln', 'Call from drive. Gate 3312.', 0);
  → lastInsertRowid = 2

sqlite_execute:
  INSERT INTO assignments (client_id, client_order_ref, loss_type, loss_date, due_by, fee,
                           claim_no, policy_no, claimant_name, claimant_dob, status)
  VALUES (1, 'TPA-8847', 'property', '2026-09-05', '2026-09-11', 225,
          '26-448311', 'HO-77410', 'Luis Ortega', '1979-08-22', 'confirmed');
  → 2   (A-2026-0002, trip_fee 75 from client default)

sqlite_execute:
  INSERT INTO inspections (assignment_id, place_id, scheduled_start, status)
  VALUES (2, 2, '2026-09-09T14:00', 'planned');
  → 2   (visit_no 1, 60 min, inspector 1)

location_create: name "Inspect - Willow Ln", street_address "412 Willow Ln, Boulder, CO 80302",
                 checkin_radius_m 100, idempotency_key "loc-place-2"
  → location_id 9202
sqlite_execute:  UPDATE places SET zensched_location_id = 9202 WHERE place_id = 2;
event_create:    location_id 9202, title "Inspect A-2026-0002 - Willow Ln",
                 start_date "2026-09-09", end_date "2026-09-09", idempotency_key "event-insp-2-20260909"
  → event_id 7202
form_assign:     form_id 501, event_id 7202, idempotency_key "assign-report-7202"
shift_create:    event_id 7202, worker_id 701,
                 start "2026-09-09T14:00:00-06:00", end "2026-09-09T15:00:00-06:00",
                 idempotency_key "shift-insp-2-20260909"
  → shift_id 89102
sqlite_execute:  UPDATE inspections SET zensched_event_id = 7202, zensched_shift_id = 89102 WHERE inspection_id = 2;
```

> Booked **A-2026-0002** visit 1: dwelling water, Summit TPA order TPA-8847, Wed Sep 9 2:00–3:00 at Willow Ln, Boulder. $225, due Sep 11. Gate code is only on your computer. ZenSched sees "Inspect A-2026-0002 - Willow Ln".

## Tuesday: auto inspection

9:52, outside 1840 S Pearl St, in the ZenSched app: Jordan taps **Check in** (GPS: 12 m from the pin, verified, $0.10). Shoots 6 overview (vehicle + scene) and 4 detail (hail/panel). Opens **Claim Photo Report**: Loss type seen = Auto; Access = Full; Overview photos = 6; Detail photos = 4; Weather = Clear; Notes = "Parked in drive, no airbags, hail on hood and roof." Submits. **Check out** 10:41 ($0.10).

## "Pearl is done. Pull today's photos."

```
shift_status: shift_id 89101
  → status "checked_out", actual_in "2026-09-08T09:52:10-06:00", actual_out "2026-09-08T10:41:20-06:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 12 },
               { type: "out", gps_verified: true, distance_from_site_m: 9 } ]
(free)
```

> Reading the Claim Photo Report for A-2026-0001 costs $0.15 because it has photos. It bills once; after this I answer from the local record and any export pack is free. OK?

Owner: *"go"*

```
form_submissions:
  form_id: 501
  event_id: 7201
  limit: 5
  → submissions: [
      { submission_id: 3501, worker_id: 701, event_id: 7201, submitted_at: "2026-09-08 10:38:12",
        data: { loss_type_seen: "auto", access: "full", weather_at_visit: "clear",
                notes: "Parked in drive, no airbags, hail on hood and roof." },
        media: [
          { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../ov1.jpg" },
          { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../ov2.jpg" },
          { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../ov3.jpg" },
          { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../ov4.jpg" },
          { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../ov5.jpg" },
          { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../ov6.jpg" },
          { field: "photo_details",  cdn_url: "https://cdn.zensched.com/m/.../dt1.jpg" },
          { field: "photo_details",  cdn_url: "https://cdn.zensched.com/m/.../dt2.jpg" },
          { field: "photo_details",  cdn_url: "https://cdn.zensched.com/m/.../dt3.jpg" },
          { field: "photo_details",  cdn_url: "https://cdn.zensched.com/m/.../dt4.jpg" }
        ] }
    ], count: 1, billing: { meter: "form_media", units: 1, price: 0.15 }

sqlite_execute:
  UPDATE inspections
  SET status = 'completed', loss_type_seen = 'auto', access = 'full', weather_at_visit = 'clear',
      photo_overview_count = 6, photo_detail_count = 4,
      photo_urls = '["https://cdn.zensched.com/m/.../ov1.jpg","https://cdn.zensched.com/m/.../ov2.jpg","https://cdn.zensched.com/m/.../ov3.jpg","https://cdn.zensched.com/m/.../ov4.jpg","https://cdn.zensched.com/m/.../ov5.jpg","https://cdn.zensched.com/m/.../ov6.jpg","https://cdn.zensched.com/m/.../dt1.jpg","https://cdn.zensched.com/m/.../dt2.jpg","https://cdn.zensched.com/m/.../dt3.jpg","https://cdn.zensched.com/m/.../dt4.jpg"]',
      report_dc_id = 3501,
      checked_in_at = '2026-09-08T09:52:10-06:00', checked_out_at = '2026-09-08T10:41:20-06:00',
      gps_verified = 1, checkin_distance_m = 12,
      notes = 'Parked in drive, no airbags, hail on hood and roof.'
  WHERE inspection_id = 1;

sqlite_execute: UPDATE assignments SET status = 'completed' WHERE assignment_id = 1;
```

> A-2026-0001 closed. Full access, auto, clear, 6 overview + 4 detail, GPS-verified on site 9:52–10:41 (12 m from the pin). $175 is now receivable from Summit TPA, net 30. This is a photo record, not an estimate. Say "export pack" when you want the URLs for their file.

## Wednesday: dwelling water — denied access

Jordan arrives at 412 Willow Ln at 13:54, checks in (GPS-verified, 18 m). Calls from the drive. No answer. Waits. Neighbor says the family is out of town. Shoots 3 overview photos of the exterior / water line on the foundation from the yard. Claim Photo Report: Loss type seen = Dwelling; Access = Denied; Overview = 3; Weather = Rain; Denied-access reason = "No answer 55 min. Neighbor said family out of town until Friday. Exterior only from yard." Checks out 14:50.

## "Willow was denied. Pull the report and get me the trip fee."

```
shift_status: shift_id 89102
  → status "checked_out", actual_in "2026-09-09T13:54:05-06:00", actual_out "2026-09-09T14:50:40-06:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 18 },
               { type: "out", gps_verified: true, distance_from_site_m: 21 } ]

form_submissions: form_id 501, event_id 7202, limit 5   ($0.15)
  → [ { submission_id: 3502, submitted_at: "2026-09-09 14:48:10",
        data: { loss_type_seen: "dwelling", access: "denied", weather_at_visit: "rain",
                denied_reason: "No answer 55 min. Neighbor said family out of town until Friday. Exterior only from yard." },
        media: [ { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../w1.jpg" },
                 { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../w2.jpg" },
                 { field: "photo_overview", cdn_url: "https://cdn.zensched.com/m/.../w3.jpg" } ] } ]

sqlite_execute:
  UPDATE inspections
  SET status = 'denied', loss_type_seen = 'dwelling', access = 'denied', weather_at_visit = 'rain',
      denied_reason = 'No answer 55 min. Neighbor said family out of town until Friday. Exterior only from yard.',
      photo_overview_count = 3, photo_detail_count = 0,
      photo_urls = '["https://cdn.zensched.com/m/.../w1.jpg","https://cdn.zensched.com/m/.../w2.jpg","https://cdn.zensched.com/m/.../w3.jpg"]',
      report_dc_id = 3502,
      checked_in_at = '2026-09-09T13:54:05-06:00', checked_out_at = '2026-09-09T14:50:40-06:00',
      gps_verified = 1, checkin_distance_m = 18
  WHERE inspection_id = 2;

sqlite_execute: UPDATE assignments SET status = 'denied_access' WHERE assignment_id = 2;
```

`fee` 225 is still on the row but `billable_assignments` bills only trip + other for `denied_access`: $75. A-2026-0002 stays on `assignments_due` (due 9/11, denied) so a callback is obvious.

> A-2026-0002 recorded as denied access. Billable: $75 trip to Summit TPA. GPS-verified on site 1:54–2:50 PM, 18 m from the pin, rain, 3 exterior photos. Neighbor said they're back Friday — want me to book a callback Friday 2 pm on the same assignment (visit 2)? If that visit completes, I'll bill the $225 inspection fee and not the trip, unless you want both (I'll put the trip on other_fee).

Owner: *"Leave it denied for now. Invoice Summit."*

## "Export pack for A-2026-0001, then invoice Summit TPA."

```
sqlite_query: SELECT * FROM reports_ready WHERE assignment_id = 1;
  → A-2026-0001 | completed | auto | TPA-8841 | needs_pull 0 | gps 1 | 12 m
    | access full | weather clear | 6 + 4 photos | photo_urls [...]
```

> Ridgeview IA — photo pack — A-2026-0001
> To: Summit TPA (order TPA-8841)
> Visit: Tue Sep 8, 2026  9:52–10:41 MT  GPS-verified 12 m from pin
> Loss type seen: Auto    Access: Full    Weather: Clear
> This is a photo inspection record, not an estimate.
>
> Overview:
>   1. https://cdn.zensched.com/m/.../ov1.jpg
>   ...
>   6. https://cdn.zensched.com/m/.../ov6.jpg
> Detail:
>   7–10. (dt1–dt4)
>
> Claimant name, DOB, and policy number are not on this pack.

```
sqlite_query: SELECT * FROM receivables_by_client;
  → Summit TPA | tpa | ap@summittpa.example | net 30
    | 2 assignments (1 completed, 1 denied) | 250.00 | 2026-09-08 .. 2026-09-09

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'),
         date('now', 'localtime', '+' || (SELECT payment_terms_days FROM clients WHERE client_id = 1) || ' days'),
         SUM(b.billable_total),
         json_group_array(json_object('assignment_no', b.assignment_no, 'date', b.last_visit_date,
                                      'type', b.loss_type, 'status', b.status, 'order_ref', b.client_order_ref,
                                      'fee', b.fee, 'trip_fee', b.trip_fee, 'other_fee', b.other_fee,
                                      'billable', b.billable_total, 'shift_id', b.zensched_shift_id))
  FROM billable_assignments b WHERE b.invoiced = 0 AND b.client_id = 1 AND b.billable_total > 0
  GROUP BY b.client_id;
sqlite_execute: UPDATE assignments SET invoiced = 1 WHERE invoiced = 0 AND client_id = 1
                AND status IN ('completed', 'denied_access', 'cancelled');
sqlite_query:   SELECT invoice_number, invoice_date, due_date, total_amount FROM invoices
                WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001 | 2026-09-09 | 2026-10-09 | 250.00
```

> Here's the Summit TPA invoice, ready for their payables portal:
>
> ```
> Ridgeview IA
> Invoice INV-2026-0001
> To: Summit TPA (ap@summittpa.example)
> Date: Sep 9, 2026    Due: Oct 9, 2026 (net 30)
>
>   A-2026-0001  Tue Sep 8   Auto, order TPA-8841         Inspection $175.00              $175.00
>   A-2026-0002  Wed Sep 9   Property, order TPA-8847     Trip fee $75.00                 $75.00
>                            Access denied; inspector GPS-verified on site 1:54–2:50 PM
>
> Total due: $250.00
> ```
>
> No claimant names, dates of birth, or policy numbers. The order refs identify the files. Say "sent" when it's submitted.

```
sqlite_query: SELECT * FROM invoices_outstanding;
  → INV-2026-0001 | Summit TPA | due 2026-10-09 | 250.00 | days_past_due -30 | current
```

> Outstanding: $250, current. I'll flag Summit after Oct 9 if they haven't paid.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Maya Chen / Luis Ortega, DOBs, claim numbers, policy numbers, gate code, dog | SQLite **only** (`assignments.claim_*`, `claimant_*`, `policy_no`, `places.access_notes`) | Claim PII never reaches ZenSched |
| Summit TPA: terms, billing email, default fees | SQLite (`clients`) | Billing; ZenSched does not model clients or fees |
| Each address, normalized, with its ZenSched location id | SQLite (`places`) | De-dup cache; repeat shops skip the $0.03 geocode |
| `Inspect - Pearl St`, `Inspect - Willow Ln` and their street addresses and GPS pins | ZenSched (ID in `places`) | Needed for geofenced check-in; labels carry no claimant identity |
| One single-day event per inspection (`Inspect A-2026-0001 - Pearl St`, ...) | ZenSched (ID in `inspections`) | Shifts hang off events; title is assignment number + street only |
| One shift per visit (the 60-minute window) | ZenSched (ID in `inspections`) | Live schedule and push notification; never copied |
| Jordan as a ZenSched worker | ZenSched (ID in `inspectors`, `is_owner = 1`) | Solo mode: the owner is the inspector on the phone |
| GPS punches, arrival time, distance from pin | ZenSched (originals); stamps copied once to `inspections` | Proof of on-site arrival, answered from SQLite afterwards |
| The Claim Photo Report form | ZenSched (ID in `settings`) | Installed on the phone per shift; no signature field; no claimant fields |
| Two Claim Photo Report submissions | ZenSched (originals); access, weather, counts, `photo_urls`, `report_dc_id` in `inspections` | Read once (metered), then the pack is free |
| Check-in policy (150 m radius, 20 min early check-in, 15 min check-out reminder) | ZenSched (policy 0) | Radius is enforced by the policy, not per location |
| Fees per assignment, billable totals, one invoice, aging | SQLite (`assignments`, `billable_assignments`, `invoices`, `invoices_outstanding`) | Receivables from the TPA |
| Sub payouts | SQLite (`payouts`) | Not used this week (solo); agency mode only |
