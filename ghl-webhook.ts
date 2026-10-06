// Supabase Edge Function: ghl-webhook
// Go High Level calls this when a teacher's "sociograma-activo" tag is added or removed.
//   Tag added:   POST https://<project>.supabase.co/functions/v1/ghl-webhook?status=active&key=<GHL_WEBHOOK_KEY>
//   Tag removed: POST https://<project>.supabase.co/functions/v1/ghl-webhook?status=inactive&key=<GHL_WEBHOOK_KEY>
// Needs the secret GHL_WEBHOOK_KEY, and "Verify JWT" turned OFF for this function.
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const secret = Deno.env.get("GHL_WEBHOOK_KEY") ?? "";
  if (!secret || url.searchParams.get("key") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  const status = url.searchParams.get("status");
  if (status !== "active" && status !== "inactive") {
    return new Response("status must be active or inactive", { status: 400 });
  }

  let body: Record<string, any> = {};
  try {
    const text = await req.text();
    body = text ? JSON.parse(text) : {};
  } catch {
    body = {};
  }
  const email = String(
    body.email ?? body.contact?.email ?? body.customData?.email ?? url.searchParams.get("email") ?? "",
  ).trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return new Response("no valid email in the webhook", { status: 400 });
  }
  const name =
    String(body.full_name ?? [body.first_name, body.last_name].filter(Boolean).join(" ")).trim() || null;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { error } = await supabase.from("teachers").upsert({
    email,
    active: status === "active",
    name,
    updated_at: new Date().toISOString(),
  });
  if (error) return new Response(error.message, { status: 500 });
  return new Response(`ok: ${email} is ${status}`, { status: 200 });
});
