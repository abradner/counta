// counta envelope crypto — all key material handled here stays client-side.
//
//   passkey PRF output ──HKDF("counta/kek/v1")──▶ KEK ──AES-GCM──▶ wraps DEK
//   recovery master key ─HKDF("counta/recovery-kek/v1")─▶ KEK ─▶ wraps DEK
//   recovery master key ─HKDF("counta/recovery-auth/v1")─▶ server login proof
//   DEK (random 256-bit, per account) ──AES-256-GCM──▶ pen blobs
//
// The server only ever sees: wrapped DEKs, the SHA-256 digest of the recovery
// proof, and blob ciphertext (docs/data-privacy.md "Crypto design").

import { WORDLIST } from "wordlist";
import { t } from "i18n";

const te = new TextEncoder();

// PRF evaluation input. A fixed application constant is fine: the PRF output
// is already unique per credential (keyed on the authenticator's secret).
export const PRF_SALT = te.encode("counta/prf/v1");

/* ---------- encoding helpers ---------- */

export function b64u(bytes) {
  // Chunked rather than String.fromCharCode(...all): spreading a whole buffer
  // into an argument list throws RangeError once it passes the engine's
  // argument limit, which a pen with a long dose history would eventually hit.
  const u8 = new Uint8Array(bytes);
  let binary = "";
  for (let i = 0; i < u8.length; i += 8192) {
    binary += String.fromCharCode(...u8.subarray(i, i + 8192));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function b64uDecode(str) {
  const s = str.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
}

export function hex(bytes) {
  return [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, "0")).join("");
}

export function randomBytes(n) {
  return crypto.getRandomValues(new Uint8Array(n));
}

/* ---------- HKDF / AES-GCM envelope ---------- */

async function hkdfKey(secretBytes, info) {
  const ikm = await crypto.subtle.importKey("raw", secretBytes, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: te.encode(info) },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
}

export function kekFromPrf(prfOutput) {
  return hkdfKey(prfOutput, "counta/kek/v1");
}

export function kekFromMasterKey(masterKey) {
  return hkdfKey(masterKey, "counta/recovery-kek/v1");
}

async function aesGcmEncrypt(key, plainBytes) {
  const iv = randomBytes(12);
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plainBytes);
  const out = new Uint8Array(iv.length + ct.byteLength);
  out.set(iv, 0);
  out.set(new Uint8Array(ct), iv.length);
  return b64u(out);
}

async function aesGcmDecrypt(key, packed) {
  const bytes = b64uDecode(packed);
  const iv = bytes.slice(0, 12);
  const ct = bytes.slice(12);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ct);
  return new Uint8Array(plain);
}

export function generateDek() {
  return randomBytes(32);
}

export function wrapDek(kek, dekBytes) {
  return aesGcmEncrypt(kek, dekBytes);
}

export function unwrapDek(kek, wrapped) {
  return aesGcmDecrypt(kek, wrapped);
}

async function dekCryptoKey(dekBytes, usage) {
  return crypto.subtle.importKey("raw", dekBytes, "AES-GCM", false, [usage]);
}

// Pen blobs are padded to a fixed bucket before encryption. AES-GCM ciphertext
// is plaintext length + 16, and a pen's payload grows by roughly one JSON
// entry per dose — so without padding, `blob_length` estimates how many doses
// someone has logged. That is the very inference the blob-per-pen design
// exists to prevent (docs/data-privacy.md "Data map"), and it's readable from
// a database dump without touching a key.
//
// Padding is trailing whitespace inside the JSON text, which JSON.parse
// ignores. That keeps it backward compatible: blobs written before this still
// decrypt, and nothing needs migrating.
const PAD_BUCKET = 4096;

function padded(json) {
  const size = te.encode(json).length;
  const target = Math.ceil((size + 1) / PAD_BUCKET) * PAD_BUCKET;
  return json + " ".repeat(target - size);
}

export async function encryptPayload(dekBytes, obj) {
  const key = await dekCryptoKey(dekBytes, "encrypt");
  return aesGcmEncrypt(key, te.encode(padded(JSON.stringify(obj))));
}

export async function decryptPayload(dekBytes, blob) {
  const key = await dekCryptoKey(dekBytes, "decrypt");
  const plain = await aesGcmDecrypt(key, blob);
  return JSON.parse(new TextDecoder().decode(plain));
}

/* ---------- recovery kit ---------- */

// The proof authenticates kit-based recovery to the server; the server stores
// only SHA-256(proof), so a DB dump can't be replayed as a login.
export async function recoveryAuthProof(masterKey) {
  const key = await crypto.subtle.importKey("raw", masterKey, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: te.encode("counta/recovery-auth/v1") },
    key, 256
  );
  return hex(bits);
}

export async function sha256Hex(str) {
  return hex(await crypto.subtle.digest("SHA-256", te.encode(str)));
}

// BIP39: 256-bit entropy + 8-bit SHA-256 checksum = 264 bits = 24 words.
export async function masterKeyToWords(masterKey) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", masterKey));
  const bits = [];
  for (const byte of masterKey) for (let i = 7; i >= 0; i--) bits.push((byte >> i) & 1);
  for (let i = 7; i >= 0; i--) bits.push((digest[0] >> i) & 1);
  const words = [];
  for (let w = 0; w < 24; w++) {
    let idx = 0;
    for (let b = 0; b < 11; b++) idx = (idx << 1) | bits[w * 11 + b];
    words.push(WORDLIST[idx]);
  }
  return words;
}

export async function wordsToMasterKey(words) {
  const list = words.map(w => w.trim().toLowerCase()).filter(Boolean);
  if (list.length !== 24) throw new Error(t("errors.kit_words_count"));
  const bits = [];
  for (const word of list) {
    const idx = WORDLIST.indexOf(word);
    if (idx < 0) throw new Error(t("errors.kit_words_unknown", { word }));
    for (let b = 10; b >= 0; b--) bits.push((idx >> b) & 1);
  }
  const entropy = new Uint8Array(32);
  for (let i = 0; i < 256; i++) entropy[i >> 3] = (entropy[i >> 3] << 1) | bits[i];
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", entropy));
  let checksum = 0;
  for (let i = 256; i < 264; i++) checksum = (checksum << 1) | bits[i];
  if (checksum !== digest[0]) {
    throw new Error(t("errors.kit_words_checksum"));
  }
  return entropy;
}
