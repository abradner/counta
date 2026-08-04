// Account/session orchestration. Ties the WebAuthn ceremonies (passkeys.js)
// to the envelope (crypto.js). The DEK lives only in this module's returned
// values — callers keep it in memory; it is never persisted client-side.

import { api } from "api";
import { registerPasskey, authenticatePasskey } from "passkeys";
import {
  generateDek, randomBytes, kekFromPrf, kekFromMasterKey, wrapDek, unwrapDek,
  recoveryAuthProof, sha256Hex, masterKeyToWords, wordsToMasterKey
} from "crypto";

// Signup: passkey + PRF wrap AND recovery-kit wrap, created together so the
// account never exists without a recovery path.
export async function signup(opts = {}) {
  const dek = generateDek();
  const masterKey = randomBytes(32);

  const { credentialJSON, prfOutput } = await registerPasskey(opts);

  const kek = await kekFromPrf(prfOutput);
  const recoveryKek = await kekFromMasterKey(masterKey);
  const proof = await recoveryAuthProof(masterKey);

  const res = await api("/webauthn/registration", { method: "POST", body: {
    credential: credentialJSON,
    wrapped_dek: await wrapDek(kek, dek),
    recovery_wrapped_dek: await wrapDek(recoveryKek, dek),
    recovery_auth_digest: await sha256Hex(proof)
  } });

  return { dek, accountId: res.account_id, kitWords: await masterKeyToWords(masterKey) };
}

// Login and unlock are the same ceremony: one assertion authenticates to the
// server and yields the PRF output that unwraps the returned wrapped DEK.
export async function signIn() {
  const { session, prfOutput } = await authenticatePasskey();
  const kek = await kekFromPrf(prfOutput);
  const dek = await unwrapDek(kek, session.wrapped_dek);
  return { dek, accountId: session.account_id };
}

// Add passkey: requires the DEK in memory (unlocked session) — it is wrapped
// for the new credential entirely client-side.
export async function addPasskey(dek, opts = {}) {
  const { credentialJSON, prfOutput } = await registerPasskey(opts);
  const kek = await kekFromPrf(prfOutput);
  await api("/webauthn/registration", { method: "POST", body: {
    credential: credentialJSON,
    wrapped_dek: await wrapDek(kek, dek)
  } });
}

// Kit recovery: words → master key → proof authenticates; recovery-wrapped
// DEK comes back and unwraps client-side.
export async function recoverWithKit(accountId, words) {
  const masterKey = await wordsToMasterKey(words);
  const proof = await recoveryAuthProof(masterKey);
  const res = await api("/recovery/session", { method: "POST", body: {
    account_id: accountId, proof
  } });
  const kek = await kekFromMasterKey(masterKey);
  const dek = await unwrapDek(kek, res.recovery_wrapped_dek);
  return { dek, accountId: res.account_id };
}

export function signOut() {
  return api("/webauthn/session", { method: "DELETE" });
}

export function deleteAccount() {
  return api("/api/account", { method: "DELETE" });
}
