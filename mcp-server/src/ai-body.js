// The AI routes read a request body of up to 20MB (note text, images). The
// privacy check in ai-privacy.js has to look inside it for the requested
// model, and the handler needs the same payload afterwards. Reading it twice
// meant two copies of a body that size in one Worker isolate, so the check
// parses it once and leaves the result here for the handler to take.
const parsedBodies = new WeakMap();

export function rememberParsedBody(request, body) {
  parsedBodies.set(request, body);
}

/** The body ai-privacy.js already parsed for this request, or `undefined` if none was. */
export function takeParsedBody(request) {
  if (!parsedBodies.has(request)) return undefined;
  const body = parsedBodies.get(request);
  parsedBodies.delete(request);
  return body;
}
