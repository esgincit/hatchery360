// Photo disease triage. Input: { batch_id, media_ids[] }. Reads the photos from the private
// `evidence` bucket, asks Claude (vision) for a ranked differential using the disease cards in
// disease_master, writes a disease_case row, and notifies the farm's vet. Advisory only — the
// vet confirms in-app and that label trains the fine-tuned model later.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.27.0";

Deno.serve(async (req) => {
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response("unauthorized", { status: 401 });
  const { batch_id, media_ids } = await req.json();

  const { data: media } = await supabase.from("media").select("storage_path").in("id", media_ids);
  const { data: diseases } = await supabase.from("disease_master").select("code,name,signs,first_actions");
  const { data: batch } = await supabase.from("batch").select("farm_type, placed_on, doc_count").eq("id", batch_id).single();

  const images = [];
  for (const m of media ?? []) {
    const { data } = await supabase.storage.from("evidence").download(m.storage_path);
    if (!data) continue;
    const b64 = btoa(String.fromCharCode(...new Uint8Array(await data.arrayBuffer())));
    images.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: b64 } });
  }
  const ageDays = Math.round((Date.now() - Date.parse(batch!.placed_on)) / 864e5);
  const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const msg = await client.messages.create({
    model: "claude-sonnet-5-5",
    max_tokens: 800,
    system: `You are a poultry veterinary triage assistant for Indian ${batch!.farm_type} farms. Rank the most likely conditions from the provided disease list only. Return strict JSON: {"ranked":[{"code":"ND","confidence":0.81,"evidence":"..."}],"first_actions":"...","call_vet":true}. Never present a diagnosis as certain.`,
    messages: [{ role: "user", content: [
      { type: "text", text: `Flock age ${ageDays} days, ${batch!.doc_count} birds placed. Disease list: ${JSON.stringify(diseases)}. Photos follow.` },
      ...images,
    ] }],
  });
  const text = msg.content.find((c) => c.type === "text")?.text ?? "{}";
  const parsed = JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1));
  const top = parsed.ranked?.[0];

  const { data: kase } = await supabase.from("disease_case").insert({
    batch_id, opened_on: new Date().toISOString().slice(0, 10),
    disease_code: top?.code ?? "OTHER", ai_top_condition: diseases?.find((d) => d.code === top?.code)?.name ?? "Unknown",
    ai_confidence: top?.confidence ?? null, ai_model_version: "vlm-claude-sonnet-5-5", status: "open",
    notes: `${parsed.first_actions ?? ""}\nAI evidence: ${top?.evidence ?? ""}`,
  }).select().single();

  if (parsed.call_vet) {
    await supabase.from("notification").insert({
      kind: "alert", severity: (top?.confidence ?? 0) > 0.7 ? "critical" : "warning",
      title: `AI flag: ${kase?.ai_top_condition} (${Math.round((top?.confidence ?? 0) * 100)}%)`,
      body: parsed.first_actions, entity_type: "disease_case", entity_id: kase?.id,
    });
  }
  return Response.json({ case: kase, ranked: parsed.ranked, first_actions: parsed.first_actions });
});
