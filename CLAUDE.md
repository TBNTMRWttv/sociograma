# Sociograma (Generación EPI)

Web app for teachers. They import class survey answers (who each student chooses or rejects) and get a sociogram: a map of the class plus a list of students who need attention. Sold to teachers by Generación EPI (Joseph's mom's company) through its Go High Level community.

All UI text is in Spanish. Talk to Joseph in English, short and simple. No em dashes.

## How it is built

- `index.html`: the whole app. One file, plain JavaScript, no build step.
  - Supabase URL and anon key are in the config block at the top.
  - Libraries load from CDNs: supabase-js, SheetJS (Excel), pdf.js (PDF import).
- `setup.sql`: Supabase tables and row-level security. `teachers` (email, active) and `teacher_data` (one JSON document per teacher with all her classes).
- `setup-share.sql`: sharing a class by link. Run after `setup.sql`. Tables `shared_classes` (one row per shared class: owner, data, version), `class_members` (who joined, role `view` or `edit`), `share_links` (secret tokens, owner only). `join_shared_class(token)` adds the person. People who join don't need a subscription, but the owner's must be active.
- `ghl-webhook.ts`: Supabase Edge Function. GHL calls it when the tag `sociograma-activo` is added (`status=active`) or removed (`status=inactive`). Needs secret `GHL_WEBHOOK_KEY`, JWT verification off.
- `email-template.html`: Supabase login email (Magic Link and Confirm signup templates). Shows the 6-digit code `{{ .Token }}`.
- `logo-*.svg`: official logos taken from the brand manual.
- `SETUP.md`: setup steps for Supabase, Netlify, GHL, Resend.

Hosting: Netlify, auto-deploys from this repo. Login: email code (Supabase Auth). Email sender: Resend on generacionepi.com.

## Brand

Colors from the brand manual: blue `#0944A1`, gold `#C59435`, teal `#10CFC9`. Red stays for "Rechazo". Brand font is Typo Grotesk (licensed, not included). Falls back to Urbanist. Light and dark mode with a toggle. Joseph wants the look to match generacionepi.com and comunidad.generacionepi.com.

## Data model (inside `teacher_data.data`)

```
{ v:2, updatedAt, activeId, classes:[ {
    id, name,
    questions:[{id, text, kind:'pos'|'neg'|'off'}],
    students:[{id, name}],
    answers:{ studentId: { questionId: [studentId, ...] } },
    notDup:[ 'idA|idB' ]
} ] }
```

A student "answered" if `answers[studentId]` exists.

### Shared classes

A shared class moves out of `teacher_data` into `shared_classes`. In the app it stays in `state.classes` with `share:{role:'owner'|'edit'|'view', owner:email}`, and `privateState()` keeps it out of `teacher_data`. Links look like `index.html#unirse=TOKEN`. The app checks for changes every 10 seconds. Saves use the `version` column: if someone saved first, the app merges both edits (`merge3`) and saves again. People with only `view` can't change anything (blocked in the UI and by row-level security).

## Pending changes (from Joseph)

1. **Remove the "Unir con…" merge feature** from the Editar screen. Decide with Joseph whether the "¿Son la misma persona?" suggestion box on the results page also goes.
2. **Update a class from a newer export.** The teacher uploads the latest Google Forms file for a class that already exists. The app finds what changed and updates only that:
   - new students who answered since last time get added
   - students whose answers changed get updated
   - everything else stays the same, including manual corrections the teacher made
   - show a summary before applying ("2 respuestas nuevas, 1 cambio") with a confirm button
   - match students by normalized name, the same way the importer already does
   - consider tracking which students were edited by hand so a re-import doesn't overwrite them
3. **Student list in "Anotar respuestas" looks cut off.** The left list scrolls inside its own box (max-height 640px), so with 25+ students the rest are hidden and Joseph thought they were missing. Make every student visible without a hidden inner scroll (let it grow with the page, or show a clear scroll cue and a "Faltan N" count). Same check for the chip grids.
4. **Import a plain list of names.** If someone uploads or pastes a file that only has student names (one column, or one name per line, from Excel, CSV, PDF, Word, or pasted text), recognize it as a class list and create the class with those students and no answers yet. Today the importer needs a header row plus answer columns, so a names-only list fails. Also allow adding a names list to an existing class.
5. Joseph mentioned "among other details". Ask him before building.

## Testing

Test in a browser before shipping. Imports to check: Google Forms Excel, CSV, the .zip from Forms, a PDF of the sheet, pasted cells, and a manual class. Check light mode, dark mode, and phone width.
