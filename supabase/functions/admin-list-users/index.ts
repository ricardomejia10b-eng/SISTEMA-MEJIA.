import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const authHeader = req.headers.get("Authorization");
    if (!url || !anonKey || !serviceKey || !authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Missing server configuration or authorization" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const token = authHeader.slice("Bearer ".length);
    const callerClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
    const { data: authData, error: authError } = await callerClient.auth.getUser(token);
    if (authError || !authData.user) {
      return new Response(JSON.stringify({ error: "Invalid session" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const adminClient = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: callerProfile, error: profileError } = await adminClient
      .from("profiles").select("role").eq("id", authData.user.id).maybeSingle();
    if (profileError || callerProfile?.role !== "admin") {
      return new Response(JSON.stringify({ error: "Administrator access required" }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const authUsers = [];
    for (let page = 1; page <= 20; page++) {
      const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) throw error;
      authUsers.push(...data.users);
      if (data.users.length < 1000) break;
    }
    const { data: profiles, error: profilesError } = await adminClient
      .from("profiles").select("id, full_name, role");
    if (profilesError) throw profilesError;
    const profileById = new Map((profiles || []).map((p) => [p.id, p]));

    const users = authUsers.map((u) => {
      const profile = profileById.get(u.id);
      const bannedUntil = u.banned_until || null;
      const banned = Boolean(bannedUntil && new Date(bannedUntil).getTime() > Date.now());
      const status = banned ? "Suspendido" : (u.email_confirmed_at ? "Activo" : "Correo pendiente");
      return {
        id: u.id,
        email: u.email || null,
        email_confirmed_at: u.email_confirmed_at || null,
        banned_until: bannedUntil,
        status,
        created_at: u.created_at || null,
        full_name: profile?.full_name || null,
        role: profile?.role || "vendedor",
      };
    });

    return new Response(JSON.stringify({ users }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "Unexpected error" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
