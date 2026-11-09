// A software passkey, so the Worker's real WebAuthn routes can be exercised
// without a device. It produces the same ES256 "none" attestation and assertion a
// platform authenticator does; the server-side verification is the real one.
import { createHash, createPublicKey, generateKeyPairSync, randomBytes, sign, type KeyObject } from 'node:crypto';

/** The production defaults in src/passkeys.ts; the drill sets no override. */
const RP_ID = 'api.studiquo.app';
const ORIGIN = `https://${RP_ID}`;

const head = (major: number, length: number) => {
  if (length < 24) return Buffer.from([(major << 5) | length]);
  if (length < 256) return Buffer.from([(major << 5) | 24, length]);
  return Buffer.from([(major << 5) | 25, length >> 8, length & 0xff]);
};

type Cbor = number | string | Buffer | Map<number | string, Cbor>;

/** The small part of CBOR that attestation objects and COSE keys use. */
export function cborEncode(value: Cbor): Buffer {
  if (typeof value === 'number') return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (typeof value === 'string') return Buffer.concat([head(3, Buffer.byteLength(value)), Buffer.from(value)]);
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  const parts = [head(5, value.size)];
  for (const [key, item] of value) parts.push(cborEncode(key), cborEncode(item));
  return Buffer.concat(parts);
}

const sha256 = (value: Buffer | string) => createHash('sha256').update(value).digest();
const b64 = (value: Buffer | string) => Buffer.from(value).toString('base64url');

export interface SoftwarePasskey {
  readonly credentialId: string;
  registrationResponse(challenge: string): Record<string, unknown>;
  assertionResponse(challenge: string): Record<string, unknown>;
}

export function createSoftwarePasskey(): SoftwarePasskey {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const jwk = createPublicKey(privateKey as KeyObject).export({ format: 'jwk' }) as { x: string; y: string };
  const rawId = randomBytes(32);
  const credentialId = b64(rawId);
  let counter = 0;
  const authenticatorPrefix = (flags: number) => {
    counter += 1;
    const count = Buffer.alloc(4);
    count.writeUInt32BE(counter);
    return Buffer.concat([sha256(RP_ID), Buffer.from([flags]), count]);
  };
  const clientData = (type: string, challenge: string) => Buffer.from(JSON.stringify({ type, challenge, origin: ORIGIN, crossOrigin: false }));
  return {
    credentialId,
    registrationResponse(challenge) {
      const coseKey = cborEncode(new Map<number, Cbor>([[1, 2], [3, -7], [-1, 1], [-2, Buffer.from(jwk.x, 'base64url')], [-3, Buffer.from(jwk.y, 'base64url')]]));
      const idLength = Buffer.alloc(2);
      idLength.writeUInt16BE(rawId.length);
      // User present, user verified, attested credential data included.
      const authData = Buffer.concat([authenticatorPrefix(0x45), Buffer.alloc(16), idLength, rawId, coseKey]);
      const attestationObject = cborEncode(new Map<string, Cbor>([['fmt', 'none'], ['attStmt', new Map()], ['authData', authData]]));
      return {
        id: credentialId, rawId: credentialId, type: 'public-key', authenticatorAttachment: 'platform', clientExtensionResults: {},
        response: { clientDataJSON: b64(clientData('webauthn.create', challenge)), attestationObject: b64(attestationObject), transports: ['internal'] },
      };
    },
    assertionResponse(challenge) {
      const authData = authenticatorPrefix(0x05);
      const client = clientData('webauthn.get', challenge);
      const signature = sign('sha256', Buffer.concat([authData, sha256(client)]), { key: privateKey as KeyObject, dsaEncoding: 'der' });
      return {
        id: credentialId, rawId: credentialId, type: 'public-key', clientExtensionResults: {},
        response: { clientDataJSON: b64(client), authenticatorData: b64(authData), signature: b64(signature) },
      };
    },
  };
}
