# Sociograma setup

Three pieces:
- **Diploi** hosts the app (`index.html`).
- **Supabase** handles teacher logins and stores each teacher's classes.
- **Go High Level** decides who is active, using the tag `sociograma-activo`.

Do the steps in order. Keep a note open to paste values into.

---

## 1. Supabase project

1. Go to supabase.com, sign up, and click **New project**.
2. Name it `sociograma`. Pick a strong database password and save it. Region: **East US** (closest to Panama).
3. Wait for the project to finish setting up.

## 2. Database

1. Left menu: **SQL Editor** > **New query**.
2. Paste all of `setup.sql`. Click **Run**. It should say "Success".

3. For sharing classes: open another **New query**, paste all of `setup-share.sql`, click **Run**. Until this is run, the app works normally but the **Compartir** window says sharing is not turned on yet.

## 3. Login email

1. Left menu: **Authentication** > **Emails** (Email Templates).
2. Open **Magic Link**. Subject: `Tu código para Sociograma`. Replace the body with `email-template.html`. Save.
3. Do the same for **Confirm signup**. First-time teachers get that one.

The template must contain `{{ .Token }}`. That is the 6-digit code teachers type.

**Before real teachers log in:** Supabase's built-in email only sends to members of your Supabase team and has a very low hourly limit. Set up your own email sender:
1. Make a free account at resend.com and add the domain (for example `generacionepi.com`). Add the DNS records it shows.
2. Create an API key in Resend.
3. In Supabase: **Authentication** > **Emails** > **SMTP Settings**. Turn on custom SMTP:
   - Host `smtp.resend.com`, port `465`, username `resend`, password = the Resend API key
   - Sender email like `no-reply@generacionepi.com`, sender name `Generación EPI`

Until then, test with your own email (you are on the Supabase team, so it works).

## 4. Webhook function

1. Left menu: **Edge Functions** > **Deploy a new function** > **Via Editor**.
2. Name it exactly `ghl-webhook`. Paste all of `ghl-webhook.ts`. Deploy.
3. Open the function's settings and turn **OFF** "Verify JWT" (Enforce JWT verification). Save. Go High Level can't send a Supabase login, so this must be off. The secret key protects it instead.
4. Edge Functions > **Secrets**: add
   - Name: `GHL_WEBHOOK_KEY`
   - Value: a long random password (30+ letters and numbers). Save it in your note.

Your webhook URL is:
`https://YOUR-PROJECT.supabase.co/functions/v1/ghl-webhook`

### Sharing emails (function `share-email`)

When a teacher adds someone to a class, this function emails them their link.
1. **Edge Functions** > **Deploy a new function** > **Via Editor**. Name it exactly `share-email`. Paste all of `share-email.ts`. Deploy.
2. Leave **Verify JWT** ON (the default). Only signed-in teachers can call it, and only for their own classes.
3. Edge Functions > **Secrets**: add
   - `RESEND_API_KEY`: your Resend API key (the same one used for the login emails)
   - `APP_URL`: the app's address, for example `https://sociograma-epi.netlify.app/`
   - `SHARE_FROM` (optional): the sender, default `Generación EPI <no-reply@generacionepi.com>`

Until this is set up, sharing still works: the window says the email could not be sent, and the teacher can copy the person's link and send it herself.

## 5. Connect the app

1. **Project Settings** > **API** (or **Data API** / **API Keys**). Copy:
   - **Project URL** (`https://xxxx.supabase.co`)
   - the **anon public** key (or **publishable** key). Never use the `service_role` or secret key here.
2. In `index.html`, near the top, replace the two placeholders:
   ```
   url:'PEGA_AQUI_EL_PROJECT_URL',
   key:'PEGA_AQUI_LA_ANON_PUBLIC_KEY'
   ```
   The anon key is meant to be public. The database rules in `setup.sql` protect the data.

If the placeholders are left in, the app still runs in "this device only" mode with no logins.

## 6. Deploy on Diploi

1. Diploi: **Pick & build your stack** > **Static** > **Create Repository** > **Launch Stack**.
2. Open the new repo on github.com. **Add file** > **Upload files**. Upload all 5 files (`index.html`, `setup.sql`, `ghl-webhook.ts`, `email-template.html`, `SETUP.md`). Commit.
3. Open the Diploi URL. You should see the login screen.
   If it doesn't update, open the project in Diploi and redeploy.

To change the two config lines later: open `index.html` on github.com, click the pencil, edit, commit.

## 7. Go High Level

1. Create a tag: `sociograma-activo`.
2. **Workflow A** (turn on):
   - Trigger: **Contact Tag** > Tag added > `sociograma-activo`
   - Action: **Webhook**, method POST, URL:
     `https://YOUR-PROJECT.supabase.co/functions/v1/ghl-webhook?status=active&key=YOUR_GHL_WEBHOOK_KEY`
   - Publish.
3. **Workflow B** (turn off):
   - Trigger: **Contact Tag** > Tag removed > `sociograma-activo`
   - Action: **Webhook**, POST, same URL but `status=inactive`
   - Publish.
4. In her payment workflows: **add** the tag when a teacher pays, **remove** it when a payment fails or the subscription is canceled. She can also add or remove the tag by hand for free trials or schools that pay by invoice.

The teacher's GHL contact email must be the email she logs in with.

## 8. Test

1. In GHL, add `sociograma-activo` to a contact with your email.
2. Supabase: **Table Editor** > `teachers`. Your email should be there with `active = true`.
   If not: GHL workflow history shows the webhook response. "forbidden" means the key in the URL doesn't match the secret.
3. Open the Diploi URL, log in with your email, type the code. Create a class.
4. Remove the tag in GHL. Make any change in the app. It should lock you out with "Tu suscripción no está activa". Add the tag back and press "Volver a revisar".

## 9. Optional: show it inside GHL

Add a **Custom Code** element to a GHL page and paste:
```html
<iframe src="https://YOUR-APP.diploi.me" style="width:100%;height:100vh;border:0;"></iframe>
```
Test on an iPad. If Safari keeps logging teachers out inside the frame, link to the Diploi URL instead.

---

## Notes

- **Supabase free plan** pauses a project after about a week with no use. Move to the paid plan before schools rely on it.
- **Privacy:** classes contain minors' names. Only the teacher can read her own data. Supabase team members (you) can see everything in the Table Editor, so keep that team small.
- **Lapsed teachers:** their data is kept, not deleted. If she renews, everything is back.
