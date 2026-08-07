import { createClient } from "@supabase/supabase-js";
import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";
import { encryptShopifyToken, getShopifyConfig, normalizeShopDomain } from "@/app/lib/shopify";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type TokenResponse = { access_token?: string; scope?: string; expires_in?: number };
type ShopResponse = { data?: { shop?: { id?: string; myshopifyDomain?: string } } };

export async function POST(request: NextRequest) {
  try {
    const config = getShopifyConfig();
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData } = await supabase.auth.getUser();
    if (!authData.user) return message("La sesión terminó. Inicia sesión y vuelve a intentar.", 401);
    const body = await request.json() as { companyId?: string; shop?: string };
    const companyId = String(body.companyId ?? "");
    const shop = normalizeShopDomain(String(body.shop ?? ""));
    if (!companyId) return message("Selecciona una empresa antes de conectar Shopify.", 400);
    const { error: permissionError } = await supabase.rpc("authorize_shopify_connection", { p_company_id: companyId });
    if (permissionError) return message(permissionError.message, 403);

    const tokenResponse = await fetch(`https://${shop}/admin/oauth/access_token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({ grant_type: "client_credentials", client_id: config.clientId, client_secret: config.clientSecret }),
      cache: "no-store",
    });
    const tokenData = await tokenResponse.json() as TokenResponse;
    if (!tokenResponse.ok || !tokenData.access_token) throw new Error("SHOPIFY_TOKEN_FAILED");

    const shopResponse = await fetch(`https://${shop}/admin/api/${config.apiVersion}/graphql.json`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-shopify-access-token": tokenData.access_token },
      body: JSON.stringify({ query: "query SatrapyConnectedShop { shop { id myshopifyDomain } }" }),
      cache: "no-store",
    });
    const shopData = await shopResponse.json() as ShopResponse;
    const connectedShop = shopData.data?.shop;
    if (!shopResponse.ok || !connectedShop?.id || !connectedShop.myshopifyDomain) throw new Error("SHOPIFY_SHOP_VERIFY_FAILED");

    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!supabaseUrl || !serviceKey) throw new Error("SHOPIFY_STORAGE_NOT_CONFIGURED");
    const admin = createClient(supabaseUrl, serviceKey, { auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false } });
    const expiresAt = tokenData.expires_in ? new Date(Date.now() + tokenData.expires_in * 1000).toISOString() : null;
    const { error: saveError } = await admin.rpc("complete_shopify_connection", {
      p_company_id: companyId,
      p_actor_id: authData.user.id,
      p_shop_domain: connectedShop.myshopifyDomain,
      p_shop_gid: connectedShop.id,
      p_access_token_ciphertext: encryptShopifyToken(tokenData.access_token, config.encryptionKey),
      p_granted_scopes: (tokenData.scope ?? "").split(",").map(scope => scope.trim()).filter(Boolean),
      p_token_expires_at: expiresAt,
    });
    if (saveError) throw new Error("SHOPIFY_STORAGE_FAILED");
    return NextResponse.json({ message: "Shopify se conectó correctamente." }, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    const code = error instanceof Error ? error.message : "";
    if (code === "SHOPIFY_NOT_CONFIGURED") return message("Configura las credenciales generales de Shopify en el servidor.", 503);
    if (code === "SHOPIFY_ENCRYPTION_KEY_INVALID") return message("La clave de cifrado de Shopify no es válida.", 503);
    if (code === "SHOPIFY_DOMAIN_INVALID") return message("Usa el dominio permanente de la tienda, por ejemplo mitienda.myshopify.com.", 400);
    if (code === "SHOPIFY_TOKEN_FAILED") return message("Shopify rechazó la conexión. Confirma que instalaste esta app en esa tienda y que su versión tiene permisos de lectura.", 422);
    if (code === "SHOPIFY_SHOP_VERIFY_FAILED") return message("No fue posible verificar esta tienda de Shopify.", 422);
    if (code === "SHOPIFY_STORAGE_NOT_CONFIGURED" || code === "SHOPIFY_STORAGE_FAILED") return message("No fue posible guardar la conexión de Shopify.", 503);
    return message("No fue posible conectar Shopify.", 422);
  }
}

function message(value: string, status: number) {
  return NextResponse.json({ message: value }, { status, headers: { "cache-control": "no-store" } });
}
