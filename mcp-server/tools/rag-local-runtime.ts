// Local-only test tooling. Use the runtime bundled with the installed Wrangler
// so compatibility dates match the bundler instead of the older direct pin.
import {createRequire} from 'node:module';
const runtime = createRequire(import.meta.resolve('wrangler'))('miniflare');
export const Miniflare = runtime.Miniflare;
export const convertV4MiniflareOptions = runtime.convertV4MiniflareOptions ?? ((options: unknown) => options);
