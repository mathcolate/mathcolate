import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}
function getPublishableKey(): string | null {
  const legacy = Deno.env.get("SUPABASE_ANON_KEY");
  if (legacy) return legacy;
  try { const keys = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}"); return keys.default || (Object.values(keys)[0] as string) || null; }
  catch { return null; }
}
function parseJsonText(text: string): Record<string, unknown> {
  const trimmed = text.trim().replace(/^\x60{3}(?:json)?\s*/i, "").replace(/\s*\x60{3}$/, "");
  const value = JSON.parse(trimmed);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("AI returned invalid JSON.");
  return value as Record<string, unknown>;
}
async function callGemini(prompt: string, image?: { mimeType: string; data: string }) {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("Gemini is not configured yet. Add GEMINI_API_KEY to Supabase Edge Function secrets.");
  const parts: Record<string, unknown>[] = [{ text: prompt }];
  if (image) parts.push({ inlineData: { mimeType: image.mimeType, data: image.data } });
  const response = await fetch("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" + encodeURIComponent(apiKey), {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ contents: [{ role: "user", parts }], generationConfig: { temperature: 0.1, responseMimeType: "application/json" } }),
  });
  if (!response.ok) {
    const detail = await response.text(); console.error("Gemini request failed", response.status, detail.slice(0, 400));
    throw new Error(response.status === 429 ? "AI request limit reached. Please try again later." : "AI service could not process this request.");
  }
  const payload = await response.json();
  const text = payload?.candidates?.[0]?.content?.parts?.map((part: { text?: string }) => part.text || "").join("");
  if (typeof text !== "string" || !text.trim()) throw new Error("AI returned no result. Try a clearer image or shorter text.");
  return parseJsonText(text);
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "Method not allowed." });
  try {
    const token = (req.headers.get("Authorization") || "").match(/^Bearer\s+(.+)$/i)?.[1];
    const supabaseUrl = Deno.env.get("SUPABASE_URL"), publishableKey = getPublishableKey();
    if (!token || !supabaseUrl || !publishableKey) return json(401, { error: "Please sign in again before using AI assistance." });
    const client = createClient(supabaseUrl, publishableKey, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: "Bearer " + token } } });
    const { data: authData, error: authError } = await client.auth.getUser(token);
    if (authError || !authData.user) return json(401, { error: "Your session is invalid or expired. Please sign in again." });
    const { data: profile, error: profileError } = await client.from("users_acc_info").select("role").eq("id", authData.user.id).maybeSingle();
    if (profileError || !profile || !["teacher", "admin"].includes(String(profile.role || "").toLowerCase())) return json(403, { error: "AI question assistance is available to teachers and admins only." });

    const body = await req.json();
    if (body?.action === "ocr") {
      const image = body.image;
      if (!image || !["image/png", "image/jpeg", "image/webp"].includes(image.mimeType) || typeof image.data !== "string") return json(400, { error: "Choose a PNG, JPEG or WebP image." });
      if (image.data.length > 7_000_000) return json(413, { error: "Image is too large. Use an image up to 5 MB." });
      const question = await callGemini(
        "Act as OCR for a secondary-school maths question. Return JSON only with schema " +
        '{"detectedLanguage":"en or zh","kind":"MC or SQ","stem":"verbatim question stem","choices":[{"key":"A","text":"verbatim option"}],"subparts":[{"key":"a","prompt":"verbatim subpart","points":1,"unit_required":false}],"points":1}. ' +
        "Use zh for Chinese, en for English or mostly symbolic text. Preserve maths meaning and use readable LaTeX delimited by $...$ when possible. Preserve visible choice labels A-F and subpart labels. Return empty arrays if absent. Do not solve, do not infer the correct answer, and do not translate; transcribe only. Use MC only if choices are clearly present, otherwise SQ. Use integer points only if visibly shown, otherwise 1. Return empty stem if unreadable.",
        { mimeType: image.mimeType, data: image.data },
      );
      const language = question.detectedLanguage === "zh" ? "zh" : "en", stem = typeof question.stem === "string" ? question.stem.slice(0, 12000) : "";
      if (!stem.trim()) return json(422, { error: "No readable question text was found. Try a clearer image." });
      const choices = Array.isArray(question.choices) ? question.choices.slice(0, 6).map((c: Record<string, unknown>, i: number) => ({
        key: /^[A-F]$/i.test(String(c.key || "")) ? String(c.key).toUpperCase() : "ABCDEF"[i], text: typeof c.text === "string" ? c.text.slice(0, 4000) : "",
      })).filter((c: { text: string }) => c.text.trim()) : [];
      const subparts = Array.isArray(question.subparts) ? question.subparts.slice(0, 20).map((p: Record<string, unknown>, i: number) => ({
        key: typeof p.key === "string" && p.key.length <= 12 ? p.key : String.fromCharCode(97 + i),
        prompt: typeof p.prompt === "string" ? p.prompt.slice(0, 4000) : "",
        points: Number.isInteger(p.points) && Number(p.points) > 0 && Number(p.points) <= 100 ? Number(p.points) : 1, unit_required: p.unit_required === true,
      })).filter((p: { prompt: string }) => p.prompt.trim()) : [];
      return json(200, { question: { detectedLanguage: language, kind: question.kind === "SQ" ? "SQ" : "MC", stem, choices, subparts, points: Number.isInteger(question.points) && Number(question.points) >= 1 && Number(question.points) <= 100 ? Number(question.points) : 1 } });
    }
    if (body?.action === "translate") {
      const target = body.targetLanguage === "zh" ? "zh" : body.targetLanguage === "en" ? "en" : null, question = body.question;
      if (!target || !question || typeof question !== "object") return json(400, { error: "Translation request is invalid." });
      const source = JSON.stringify(question); if (source.length > 30000) return json(413, { error: "Question text is too long to translate in one request." });
      const translated = await callGemini(
        "Translate this math-question JSON into " + (target === "zh" ? "Traditional Chinese using Hong Kong educational terms" : "clear mathematical English") + ". Return JSON only with schema " +
        '{"stem":"translated stem","choices":[{"key":"A","text":"translated option"}],"subparts":[{"key":"a","prompt":"translated prompt"}],"explanation":"translated explanation"}. ' +
        "Translate text values only. Keep keys, order and numbers exactly. Preserve math expressions, variables, LaTeX commands and delimiters exactly; do not alter anything inside $...$, \\(...\\), or \\[...\\]. Do not solve, change mathematical meaning or invent content. Empty source fields must remain empty. Input JSON: " + source,
      );
      const choices = Array.isArray(translated.choices) ? translated.choices.slice(0, 6).map((c: Record<string, unknown>) => ({ key: String(c.key || ""), text: typeof c.text === "string" ? c.text.slice(0, 4000) : "" })) : [];
      const subparts = Array.isArray(translated.subparts) ? translated.subparts.slice(0, 20).map((p: Record<string, unknown>) => ({ key: String(p.key || ""), prompt: typeof p.prompt === "string" ? p.prompt.slice(0, 4000) : "" })) : [];
      return json(200, { translation: { stem: typeof translated.stem === "string" ? translated.stem.slice(0, 12000) : "", choices, subparts, explanation: typeof translated.explanation === "string" ? translated.explanation.slice(0, 8000) : "" } });
    }
    return json(400, { error: "Unsupported AI assistance action." });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected AI assistance error.", status = message.includes("GEMINI_API_KEY") ? 503 : 500;
    if (status === 500) console.error("math-question-assist failed", message);
    return json(status, { error: message });
  }
});
