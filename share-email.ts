// Supabase Edge Function: share-email
// The app calls this right after a teacher adds someone to a class by email.
// It sends that person an email with their personal link to the class.
//   POST https://<project>.supabase.co/functions/v1/share-email   body: { class_id, email }
// Keep "Verify JWT" ON (the default): only signed-in teachers can call it, and only for their own classes.
// Needs the secrets:
//   RESEND_API_KEY  the Resend API key (the same one used for the login emails)
//   APP_URL         the app's address, for example https://sociograma.generacionepi.com/
//   SHARE_FROM      optional, defaults to "Generación EPI <no-reply@generacionepi.com>"
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, reason: "method" }, 405);

  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const appUrl = Deno.env.get("APP_URL") ?? "";
  const from = Deno.env.get("SHARE_FROM") || "Generación EPI <no-reply@generacionepi.com>";
  if (!resendKey || !/^https:\/\//.test(appUrl)) return json({ ok: false, reason: "not_configured" }, 500);

  let body: { class_id?: string; email?: string } = {};
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, reason: "body" }, 400);
  }
  const classId = String(body.class_id ?? "");
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!classId || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ ok: false, reason: "body" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await admin.auth.getUser(jwt);
  const user = auth?.user;
  if (!user) return json({ ok: false, reason: "signed_out" }, 401);

  const { data: cls } = await admin.from("shared_classes").select("id, owner, owner_email, data").eq("id", classId).maybeSingle();
  if (!cls || cls.owner !== user.id) return json({ ok: false, reason: "forbidden" }, 403);
  const { data: inv } = await admin.from("class_invites").select("email, role, token, notified_at")
    .eq("class_id", classId).eq("email", email).maybeSingle();
  if (!inv) return json({ ok: false, reason: "not_invited" }, 404);
  if (inv.notified_at && Date.now() - new Date(inv.notified_at).getTime() < 60_000) {
    return json({ ok: false, reason: "too_soon" }, 429);
  }

  const className = String(cls.data?.name ?? "una clase").slice(0, 80);
  const owner = String(cls.owner_email || user.email || "Una docente");
  const link = appUrl.replace(/#.*$/, "") + "#unirse=" + inv.token;
  const canEdit = inv.role === "edit";
  const roleLabel = canEdit ? "Puede editar" : "Puede ver";
  const what = canEdit
    ? "Puedes verla sin crear una cuenta. Para editarla, entra con este correo y una suscripción activa a Generación EPI."
    : "Puedes ver el mapa del grupo y los resultados sin crear una cuenta.";
  const subject = `Te compartieron la clase «${className}» en Sociograma`;
  const text = `${owner} te compartió la clase «${className}» en Sociograma (${roleLabel.toLowerCase()}).\n\n${what}\n\nAbrir la clase: ${link}\n\nEste enlace es personal. No lo reenvíes.\n\nGeneración EPI · Empoderadora, Positiva, Innovadora`;
  const html = `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:#EEF2F8;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${esc(owner)} te compartió «${esc(className)}». Ábrela con un clic.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#EEF2F8;"><tr><td align="center" style="padding:32px 16px;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;background:#FFFFFF;border-radius:16px;overflow:hidden;font-family:Arial,Helvetica,sans-serif;color:#13254D;">
    <tr><td style="background:#0944A1;padding:22px 32px;">
      <span style="font-size:22px;font-weight:700;color:#FFFFFF;letter-spacing:-.2px;">Generación <span style="color:#C59435;">EPI</span></span>
      <span style="font-size:14px;color:#C9D6EE;padding-left:10px;">Sociograma</span>
    </td></tr>
    <tr><td style="height:4px;background:#C59435;line-height:4px;font-size:0;">&nbsp;</td></tr>
    <tr><td style="padding:34px 32px 8px;">
      <h1 style="margin:0 0 12px;font-size:26px;line-height:1.25;color:#0944A1;">Te compartieron una clase</h1>
      <p style="margin:0 0 22px;font-size:16px;line-height:1.55;color:#33456E;"><strong style="color:#13254D;">${esc(owner)}</strong> te invitó a ${canEdit ? "colaborar en" : "ver"} su sociograma.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F5F7FB;border:1px solid #D6DEEC;border-radius:12px;">
        <tr><td style="padding:18px 20px;">
          <div style="font-size:13px;color:#55658A;margin-bottom:4px;">Clase</div>
          <div style="font-size:20px;font-weight:700;color:#13254D;">${esc(className)}</div>
          <div style="margin-top:12px;"><span style="display:inline-block;background:${canEdit ? "#DAF6F5" : "#E3EBF8"};color:${canEdit ? "#07716D" : "#0944A1"};font-size:13px;font-weight:700;padding:4px 12px;border-radius:999px;">${roleLabel}</span></div>
        </td></tr>
      </table>
      <p style="margin:20px 0 26px;font-size:15px;line-height:1.55;color:#33456E;">${esc(what)}</p>
      <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td style="border-radius:10px;background:#0944A1;">
        <a href="${esc(link)}" style="display:inline-block;padding:14px 28px;font-size:16px;font-weight:700;color:#FFFFFF;text-decoration:none;border-radius:10px;">Abrir la clase</a>
      </td></tr></table>
    </td></tr>
    <tr><td style="padding:26px 32px 30px;">
      <p style="margin:0 0 8px;font-size:13px;line-height:1.5;color:#55658A;">Este enlace es personal. No lo reenvíes: quien lo tenga podrá ver la clase.</p>
      <p style="margin:0;font-size:12px;line-height:1.5;color:#7A88A6;">Si el botón no funciona, copia esta dirección en tu navegador:<br><a href="${esc(link)}" style="color:#0944A1;word-break:break-all;">${esc(link)}</a></p>
    </td></tr>
    <tr><td style="background:#F5F7FB;border-top:1px solid #D6DEEC;padding:16px 32px;font-size:12px;color:#7A88A6;">
      Generación EPI · Empoderadora, Positiva, Innovadora
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [inv.email], subject, html, text }),
  });
  if (!r.ok) return json({ ok: false, reason: "send_failed", detail: (await r.text()).slice(0, 300) }, 502);

  await admin.from("class_invites").update({ notified_at: new Date().toISOString() })
    .eq("class_id", classId).eq("email", email);
  return json({ ok: true });
});
