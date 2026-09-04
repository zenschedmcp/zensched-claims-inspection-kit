# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not an estimating tool" and "PHI / PII boundary" sections of `README.md`. Short version: this kit is GPS + photos + billing, not XactAnalysis; claimant name, claim number, policy number, and DOB stay on your computer; ZenSched only ever sees `Inspect A-2026-0001 - Pearl St`, an address, and a photo checklist. No BAA.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\claims-ops` (Windows) or `/Users/yourname/claims-ops` (Mac). Note the full path. It will hold claimant names, claim numbers, policy numbers, and dates of birth, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\claims-ops\\claims-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call account_create with org_name "My Claims Inspection". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more.

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my claims-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Ridgeview IA in Denver, Mountain time. It's just me, Jordan Hale, jordan@example.com, 303-555-0144. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the inspector on the phone), and calls `form_create` once (free) to build the Claim Photo Report you fill in at each site: loss type seen, access, overview photos (required, max 6), detail photos (max 6), weather, denied-access reason, and notes. No signature pad, no claimant name, no claim number. It stores the form id so every visit gets it. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

Optional but recommended: "Allow check-in 20 minutes early and set the radius to 150 m." Inspectors wait for claimants and often park far from an apartment or shop entrance. The radius is a **policy** setting, not per location.

Agency mode: "Add my sub Reese Okonkwo, reese@example.com, I pay them $90 an assignment" for each inspector you dispatch.

## 6. Book your first assignment

Paste the order you received, then:

> Book it.

Behind the scenes the AI extracts the client, order number, loss type, claimant, claim number, address, window, and fee; **stashes claim number / policy / claimant / DOB in SQLite only**; adds the client if new (asks for their payment terms); checks whether you have been to that address before, and if not calls `location_create` (geocode, $0.03, may trigger the $5 activation deposit the first time); saves the assignment as `A-2026-0001`; creates a single-day `event_create` titled `Inspect A-2026-0001 - Pearl St`, attaches the Claim Photo Report with `form_assign`, and creates the `shift_create` for the visit window. You get one line back with the assignment number, the fee, and the due-by.

## 7. The inspection

Your phone shows the visit. At the site, **Check in** (GPS-verified). Shoot overview and detail photos. Open the **Claim Photo Report** on the shift: loss type seen, access (Full / Partial / Denied), overview photos, detail photos, weather. If access is Denied, write why. Submit. **Check out**.

## 8. Close out

> Pull today's photos.

The AI pulls your GPS-verified arrival and departure (free), reads each Claim Photo Report (metered, so it tells you the cost first, about $0.15 with photos, **once ever**), updates the visit, and tells you what is now receivable.

> Was I on site at Pearl?

Answered from the local record, free: scheduled vs GPS-verified check-in, distance from the pin.

> Export pack for A-2026-0001.

A plain-text pack with the order ref, GPS facts, access, weather, and photo URLs. No claimant name, DOB, or policy number. Not an estimate.

> Willow was denied. Get me the trip fee.

Marks the assignment denied-access (trip fee stays billable) and offers a callback visit on the same assignment.

## 9. Money

> Invoice Summit TPA.

A plain-text invoice under Summit's terms with one line per assignment (your number, date, loss type, their order ref, fee breakdown). Nothing about claimants on it.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Summit paid INV-2026-0001.

Marks it paid.

Agency: "What do I owe Reese?" lists their unpaid assignments and total; "paid Reese" marks them.

## What next

- `README.md` for the full explanation, the estimating / BAA / PII boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
