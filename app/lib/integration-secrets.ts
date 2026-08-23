import "server-only";
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export function integrationEncryptionKey() {
  const encoded = process.env.INTEGRATION_TOKEN_ENCRYPTION_KEY?.trim() || process.env.SHOPIFY_TOKEN_ENCRYPTION_KEY?.trim();
  if (!encoded) throw new Error("INTEGRATION_ENCRYPTION_NOT_CONFIGURED");
  const key = Buffer.from(encoded, "base64");
  if (key.byteLength !== 32) throw new Error("INTEGRATION_ENCRYPTION_KEY_INVALID");
  return key;
}

export function encryptIntegrationSecret(secret: Record<string, string>, key: Buffer) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(JSON.stringify(secret), "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1.${iv.toString("base64url")}.${tag.toString("base64url")}.${encrypted.toString("base64url")}`;
}

export function decryptIntegrationSecret(ciphertext: string, key: Buffer) {
  const [version, encodedIv, encodedTag, encodedPayload] = ciphertext.split(".");
  if (version !== "v1" || !encodedIv || !encodedTag || !encodedPayload) throw new Error("INTEGRATION_SECRET_INVALID");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(encodedIv, "base64url"));
  decipher.setAuthTag(Buffer.from(encodedTag, "base64url"));
  const decrypted = Buffer.concat([decipher.update(Buffer.from(encodedPayload, "base64url")), decipher.final()]);
  const parsed = JSON.parse(decrypted.toString("utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("INTEGRATION_SECRET_INVALID");
  return parsed as Record<string, string>;
}
