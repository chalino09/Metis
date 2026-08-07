import "server-only";
import { createCipheriv, randomBytes } from "node:crypto";

export function getShopifyConfig() {
  const clientId = process.env.SHOPIFY_CLIENT_ID?.trim();
  const clientSecret = process.env.SHOPIFY_CLIENT_SECRET?.trim();
  const encryptionKey = process.env.SHOPIFY_TOKEN_ENCRYPTION_KEY?.trim();
  if (!clientId || !clientSecret || !encryptionKey) throw new Error("SHOPIFY_NOT_CONFIGURED");
  const key = Buffer.from(encryptionKey, "base64");
  if (key.byteLength !== 32) throw new Error("SHOPIFY_ENCRYPTION_KEY_INVALID");
  return { clientId, clientSecret, encryptionKey: key, apiVersion: process.env.SHOPIFY_API_VERSION?.trim() || "2026-07" };
}

export function normalizeShopDomain(value: string) {
  const clean = value.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/$/, "");
  const domain = clean.includes(".") ? clean : `${clean}.myshopify.com`;
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(domain)) throw new Error("SHOPIFY_DOMAIN_INVALID");
  return domain;
}

export function encryptShopifyToken(token: string, key: Buffer) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(token, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1.${iv.toString("base64url")}.${tag.toString("base64url")}.${encrypted.toString("base64url")}`;
}
