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
  const what = canEdit
    ? "Puedes verla sin crear una cuenta. Para editarla, entra con tu correo y una suscripción activa a Generación EPI."
    : "Puedes verla sin crear una cuenta.";
  const subject = `${owner} te compartió la clase «${className}» en Sociograma`;
  const text = `${owner} te compartió la clase «${className}» en Sociograma.\n\n${what}\n\nAbrir la clase: ${link}\n\nEste enlace es personal. No lo reenvíes.\n\nGeneración EPI`;
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#13254D">
  <p style="font-size:13px;letter-spacing:.04em;color:#C59435;font-weight:700;margin:0 0 6px">GENERACIÓN EPI · SOCIOGRAMA</p>
  <h1 style="font-size:22px;color:#0944A1;margin:0 0 14px">Te compartieron una clase</h1>
  <p style="font-size:16px;line-height:1.5;margin:0 0 10px"><strong>${esc(owner)}</strong> te compartió la clase <strong>«${esc(className)}»</strong>.</p>
  <p style="font-size:16px;line-height:1.5;margin:0 0 22px">${esc(what)}</p>
  <p style="margin:0 0 26px"><a href="${esc(link)}" style="display:inline-block;background:#0944A1;color:#ffffff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:10px">Abrir la clase</a></p>
  <p style="font-size:13px;line-height:1.5;color:#55658A;margin:0">Este enlace es personal. No lo reenvíes.<br>Si el botón no funciona, copia esta dirección: ${esc(link)}</p>
</div>`;

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
