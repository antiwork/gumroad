export type PasskeyRegistrationOptions = {
  challenge: string;
  timeout?: number;
  rp: { id: string; name: string };
  user: { id: string; name: string; displayName: string };
  pubKeyCredParams: { type: "public-key"; alg: number }[];
  excludeCredentials?: { type: "public-key"; id: string; transports?: string[] }[];
  authenticatorSelection?: {
    authenticatorAttachment?: "platform" | "cross-platform";
    residentKey?: ResidentKeyRequirement;
    requireResidentKey?: boolean;
    userVerification?: UserVerificationRequirement;
  };
  attestation?: AttestationConveyancePreference;
};

export type PasskeyRegistrationCredential = {
  id: string;
  rawId: string;
  type: string;
  authenticatorAttachment: string | null;
  response: { attestationObject: string; clientDataJSON: string; transports: string[] };
  clientExtensionResults: AuthenticationExtensionsClientOutputs;
};

export type PasskeyAuthenticationOptions = {
  challenge: string;
  timeout?: number;
  rpId?: string;
  allowCredentials?: { type: "public-key"; id: string; transports?: string[] }[];
  userVerification?: UserVerificationRequirement;
};

export type PasskeyAuthenticationCredential = {
  id: string;
  rawId: string;
  type: string;
  authenticatorAttachment: string | null;
  response: { authenticatorData: string; clientDataJSON: string; signature: string; userHandle: string | null };
  clientExtensionResults: AuthenticationExtensionsClientOutputs;
};

export const isPasskeySupported = () => typeof window !== "undefined" && "PublicKeyCredential" in window;

export const isConditionalMediationSupported = async (): Promise<boolean> => {
  if (!isPasskeySupported() || typeof PublicKeyCredential.isConditionalMediationAvailable !== "function") return false;
  try {
    return await PublicKeyCredential.isConditionalMediationAvailable();
  } catch {
    return false;
  }
};

const base64UrlToBytes = (value: string): Uint8Array => {
  const base64 = value.replace(/-/gu, "+").replace(/_/gu, "/");
  const binary = atob(base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), "="));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
};

const bytesToBase64Url = (buffer: ArrayBuffer): string => {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
};

export const createPasskey = async (options: PasskeyRegistrationOptions): Promise<PasskeyRegistrationCredential> => {
  const publicKey: PublicKeyCredentialCreationOptions = {
    rp: options.rp,
    user: {
      id: new TextEncoder().encode(options.user.id),
      name: options.user.name,
      displayName: options.user.displayName,
    },
    challenge: base64UrlToBytes(options.challenge),
    pubKeyCredParams: options.pubKeyCredParams,
    ...(options.timeout !== undefined ? { timeout: options.timeout } : {}),
    ...(options.excludeCredentials
      ? {
          excludeCredentials: options.excludeCredentials.map((credential) => ({
            type: credential.type,
            id: base64UrlToBytes(credential.id),
          })),
        }
      : {}),
    ...(options.authenticatorSelection ? { authenticatorSelection: options.authenticatorSelection } : {}),
    ...(options.attestation ? { attestation: options.attestation } : {}),
  };

  const credential = await navigator.credentials.create({ publicKey });
  if (!(credential instanceof PublicKeyCredential)) throw new Error("Could not create a passkey.");

  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- create() always yields an attestation response
  const response = credential.response as AuthenticatorAttestationResponse;
  return {
    id: credential.id,
    rawId: bytesToBase64Url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    response: {
      attestationObject: bytesToBase64Url(response.attestationObject),
      clientDataJSON: bytesToBase64Url(response.clientDataJSON),
      transports: response.getTransports(),
    },
    clientExtensionResults: credential.getClientExtensionResults(),
  };
};

export const getPasskey = async (
  options: PasskeyAuthenticationOptions,
  { mediation, signal }: { mediation?: CredentialMediationRequirement; signal?: AbortSignal } = {},
): Promise<PasskeyAuthenticationCredential> => {
  const publicKey: PublicKeyCredentialRequestOptions = {
    challenge: base64UrlToBytes(options.challenge),
    ...(options.timeout !== undefined ? { timeout: options.timeout } : {}),
    ...(options.rpId ? { rpId: options.rpId } : {}),
    ...(options.allowCredentials
      ? {
          allowCredentials: options.allowCredentials.map((credential) => ({
            type: credential.type,
            id: base64UrlToBytes(credential.id),
          })),
        }
      : {}),
    ...(options.userVerification ? { userVerification: options.userVerification } : {}),
  };

  const credential = await navigator.credentials.get({
    publicKey,
    ...(mediation ? { mediation } : {}),
    ...(signal ? { signal } : {}),
  });
  if (!(credential instanceof PublicKeyCredential)) throw new Error("Could not authenticate with a passkey.");

  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- get() always yields an assertion response
  const response = credential.response as AuthenticatorAssertionResponse;
  return {
    id: credential.id,
    rawId: bytesToBase64Url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    response: {
      authenticatorData: bytesToBase64Url(response.authenticatorData),
      clientDataJSON: bytesToBase64Url(response.clientDataJSON),
      signature: bytesToBase64Url(response.signature),
      userHandle: response.userHandle ? bytesToBase64Url(response.userHandle) : null,
    },
    clientExtensionResults: credential.getClientExtensionResults(),
  };
};
