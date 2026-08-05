// WebAuthn ceremonies with the PRF extension. PRF is REQUIRED: no PRF, no
// account — the alternative would be a passphrase fallback, which
// reintroduces the guessable secret passkeys eliminate
// (docs/data-privacy.md "Crypto design").

import { PRF_SALT, b64u, b64uDecode } from "crypto";
import { t } from "i18n";
import { api } from "api";

export class PrfUnsupportedError extends Error {
  constructor() {
    super(t("errors.prf_unsupported"));
    this.name = "PrfUnsupportedError";
  }
}

function publicKeyCredentialToJSON(cred) {
  const out = { id: cred.id, rawId: b64u(cred.rawId), type: cred.type };
  const r = cred.response;
  out.response = { clientDataJSON: b64u(r.clientDataJSON) };
  if (r.attestationObject) out.response.attestationObject = b64u(r.attestationObject);
  if (r.authenticatorData) out.response.authenticatorData = b64u(r.authenticatorData);
  if (r.signature) out.response.signature = b64u(r.signature);
  if (r.userHandle) out.response.userHandle = b64u(r.userHandle);
  return out;
}

// Registration: create() requests PRF evaluation directly; if the provider
// evaluates at create-time we're done. Otherwise fall back to an immediate
// local get() — PRF evaluation needs an assertion, and the output never goes
// near the server, so the get() uses a client-generated challenge and no
// server round trip.
//
// Real-world quirks this tolerates (observed with 1Password on iOS):
//   - `prf.enabled` at create() is unreliable across providers, so it is
//     never treated as authoritative — only an assertion that yields no PRF
//     output counts as "unsupported".
//   - The follow-up get() can throw NotAllowedError because create() consumed
//     the user-activation gesture; `requestGesture` (a UI hook that resolves
//     after a fresh tap) lets us retry once with activation restored.
export async function registerPasskey({ requestGesture } = {}) {
  const options = await api("/webauthn/registration/options", { method: "POST" });

  const created = await navigator.credentials.create({ publicKey: {
    challenge: b64uDecode(options.challenge),
    rp: options.rp,
    user: {
      id: b64uDecode(options.user.id),
      name: options.user.name,
      displayName: options.user.displayName
    },
    pubKeyCredParams: options.pubKeyCredParams,
    authenticatorSelection: options.authenticatorSelection,
    extensions: { prf: { eval: { first: PRF_SALT } } }
  } });

  let prfOutput = extractPrf(created);
  if (!prfOutput) {
    let assertion;
    try {
      assertion = await evaluationAssertion([ created.rawId ]);
    } catch (e) {
      if (e.name === "NotAllowedError" && requestGesture) {
        await requestGesture();
        assertion = await evaluationAssertion([ created.rawId ]);
      } else {
        throw e;
      }
    }
    prfOutput = extractPrf(assertion);
  }
  if (!prfOutput) throw new PrfUnsupportedError();

  return { credentialJSON: publicKeyCredentialToJSON(created), prfOutput };
}

function extractPrf(credential) {
  const out = credential.getClientExtensionResults().prf?.results?.first;
  return out ? new Uint8Array(out) : null;
}

function evaluationAssertion(allowRawIds) {
  return navigator.credentials.get({ publicKey: {
    challenge: crypto.getRandomValues(new Uint8Array(32)),
    rpId: document.querySelector('meta[name="webauthn-rp-id"]').content,
    userVerification: "required",
    allowCredentials: allowRawIds.map(id => ({ type: "public-key", id })),
    extensions: { prf: { eval: { first: PRF_SALT } } }
  } });
}

// Usernameless login/unlock. One assertion serves both jobs: it authenticates
// to the server AND yields the PRF output that unwraps the DEK.
export async function authenticatePasskey() {
  const options = await api("/webauthn/authentication/options", { method: "POST" });

  const assertion = await navigator.credentials.get({ publicKey: {
    challenge: b64uDecode(options.challenge),
    rpId: options.rpId,
    userVerification: "required",
    extensions: { prf: { eval: { first: PRF_SALT } } }
  } });

  const prfOutput = extractPrf(assertion);
  if (!prfOutput) throw new PrfUnsupportedError();

  const session = await api("/webauthn/authentication", {
    method: "POST",
    body: { credential: publicKeyCredentialToJSON(assertion) }
  });
  return { session, prfOutput };
}
