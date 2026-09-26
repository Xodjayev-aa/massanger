/**
 * Public web-build configuration for the Vercel Hobby static site.
 *
 * The website may contain only the public Supabase URL and anon/publishable
 * key. Service-role keys, Google client secrets and Telegram credentials are
 * refused before they can be passed to `flutter build`.
 */

import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const INTENDED_SITE_HOST = 'officialmessengerx.vercel.app';
export const INTENDED_SITE_ORIGIN = 'https://officialmessengerx.vercel.app';
export const INTENDED_REDIRECT_URL = 'https://officialmessengerx.vercel.app/';
export const FLUTTER_VERSION = '3.24.5';
export const FLUTTER_COMMIT = 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668';

/** Names that must never be present in a website build environment. */
export const FORBIDDEN_ENV = [
  'SUPABASE_SERVICE_ROLE_KEY',
  'SUPABASE_SECRET_KEY',
  'SUPABASE_JWT_SECRET',
  'SUPABASE_DB_PASSWORD',
  'GOOGLE_OAUTH_CLIENT_SECRET',
  'GOOGLE_CLIENT_SECRET',
  'TELEGRAM_API_HASH',
  'TELEGRAM_BOT_TOKEN',
  'TELEGRAM_BOT_SECRET',
  'BOT_TOKEN',
  'SEAL_KEY',
  'LINK_PAYLOAD_KEY',
  'BRIDGE_TOKEN',
  'BRIDGE_HMAC_SECRET',
  'TDLIB_DB_KEY',
];

const PLACEHOLDER_URL = 'https://example.supabase.co';
const PLACEHOLDER_KEY = 'ci-placeholder-not-a-live-project';

function isSet(env, name) {
  const value = env[name];
  return typeof value === 'string' && value.trim() !== '';
}

export function forbiddenEnvNames(env) {
  return FORBIDDEN_ENV.filter((name) => isSet(env, name));
}

export function assertNoForbiddenEnv(env) {
  const present = forbiddenEnvNames(env);
  if (present.length === 0) return;
  throw new Error(
    `Refusing to build the website while secret environment variables are set: ${present.join(', ')}. ` +
      'Remove them from the Vercel project Environment Variables. The web build may contain only the public ' +
      'Supabase URL and the anon/publishable key. Do not paste secrets into chat, Git or a workflow log.',
  );
}

function decodeJwtPayload(key) {
  const payload = key.split('.')[1];
  const padded = payload.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(payload.length / 4) * 4, '=');
  return JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));
}

/** Reject secret-shaped values. Accept a public anon JWT or publishable key. */
export function assertPublicClientKey(key) {
  const value = key.trim();
  if (value.length < 20) {
    throw new Error('SUPABASE_ANON_KEY is missing or too short. Use the public anon or publishable key from the Supabase API settings.');
  }
  if (value.startsWith('sb_secret_') || value.startsWith('sb_service_')) {
    throw new Error('SUPABASE_ANON_KEY is a Supabase secret key. Use the public publishable or anon key. Never compile a secret key into the website.');
  }
  if (/^GOCSPX-/.test(value)) {
    throw new Error('That value looks like a Google client secret. It belongs in Supabase Auth, not in the web build.');
  }
  if (/^\d+:[A-Za-z0-9_-]{20,}$/.test(value)) {
    throw new Error('That value looks like a Telegram bot token. It must not be compiled into the website.');
  }
  if (/service[_-]?role/i.test(value) && !value.startsWith('eyJ')) {
    throw new Error('SUPABASE_ANON_KEY looks like a service-role credential. Use the public anon or publishable key.');
  }
  if (value.startsWith('sb_publishable_') || value.startsWith('sb_anon_')) return 'publishable';
  const parts = value.split('.');
  if (parts.length === 3 && parts[0].startsWith('eyJ')) {
    let payload;
    try {
      payload = decodeJwtPayload(value);
    } catch {
      throw new Error('SUPABASE_ANON_KEY looks like a JWT but its payload could not be read. Use the public anon key, not a secret.');
    }
    if (payload.role === 'service_role') {
      throw new Error('SUPABASE_ANON_KEY is a service-role JWT. Use the anon/publishable key. Never compile the service-role key into the website.');
    }
    if (payload.role && payload.role !== 'anon') {
      throw new Error(`SUPABASE_ANON_KEY JWT role is "${payload.role}", expected "anon".`);
    }
    return 'anon-jwt';
  }
  return 'opaque';
}

export function normalizeSiteRedirect(raw) {
  let url;
  try {
    url = new URL(String(raw).trim());
  } catch {
    throw new Error('The public site URL must be an absolute https URL such as https://officialmessengerx.vercel.app/');
  }
  if (url.username || url.password) {
    throw new Error('The public site URL must not contain credentials.');
  }
  if (url.protocol !== 'https:') {
    throw new Error('The public site URL must use https.');
  }
  if (url.search || url.hash) {
    throw new Error('The public site URL must not contain a query or fragment.');
  }
  if (url.pathname !== '/' && url.pathname !== '') {
    throw new Error(
      `The public site URL must be the site root (/). Refusing path "${url.pathname}". ` +
        'The GitHub Pages /massanger/ base path is retired.',
    );
  }
  url.pathname = '/';
  url.search = '';
  url.hash = '';
  return url.toString();
}

function productionHost(raw) {
  const trimmed = String(raw).trim();
  if (trimmed.includes('://')) return new URL(trimmed).host.toLowerCase();
  return trimmed.replace(/\/+$/, '').toLowerCase();
}

export function assertIntendedHost(redirectUrl, env) {
  const host = new URL(redirectUrl).host.toLowerCase();
  const accepted = isSet(env, 'MESSENGERX_ACCEPT_SITE_HOST') ? env.MESSENGERX_ACCEPT_SITE_HOST.trim().toLowerCase() : '';
  if (host === INTENDED_SITE_HOST) return;
  if (accepted && accepted === host) return;
  throw new Error(
    `Refusing to build for "${host}". The chosen free hostname is ${INTENDED_SITE_HOST}. ` +
      'If Vercel says that project name is taken, stop and ask before using a different name. ' +
      'Do not set MESSENGERX_ACCEPT_SITE_HOST unless that other hostname was explicitly agreed.',
  );
}

function onVercel(env) {
  return env.VERCEL === '1' || env.VERCEL_ENV === 'production' || env.VERCEL_ENV === 'preview';
}

function resolveRedirect(env) {
  const explicit = [env.WEB_REDIRECT_URL, env.PUBLIC_SITE_URL].map((value) => (value || '').trim()).filter(Boolean);
  const normalizedExplicit = explicit.map(normalizeSiteRedirect);
  if (new Set(normalizedExplicit).size > 1) {
    throw new Error('WEB_REDIRECT_URL and PUBLIC_SITE_URL disagree. Set one public site root.');
  }
  let redirect = normalizedExplicit[0];
  if (isSet(env, 'VERCEL_PROJECT_PRODUCTION_URL')) {
    const fromVercel = normalizeSiteRedirect(`https://${productionHost(env.VERCEL_PROJECT_PRODUCTION_URL)}/`);
    if (redirect && redirect !== fromVercel) {
      throw new Error(
        `The configured site URL ${redirect} does not match Vercel production host ${fromVercel}. Use one hostname.`,
      );
    }
    redirect = redirect || fromVercel;
  }
  redirect = redirect || INTENDED_REDIRECT_URL;
  assertIntendedHost(redirect, env);
  return redirect;
}

function publicSupabaseUrl(raw) {
  const value = String(raw || '').trim().replace(/\/+$/, '');
  if (!value) {
    throw new Error(
      'SUPABASE_URL is not set. In Vercel → Settings → Environment Variables, add the public project URL ' +
        '(https://<project-ref>.supabase.co). Do not paste it into chat.',
    );
  }
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error('SUPABASE_URL must be an absolute https URL. The value was not printed because it was not a URL.');
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error('SUPABASE_URL must be an origin only, with no userinfo, query or fragment.');
  }
  if (url.protocol !== 'https:') {
    throw new Error(`SUPABASE_URL must use https (host ${url.host}).`);
  }
  if (url.host === 'example.supabase.co' || url.hostname === 'localhost' || url.hostname === '127.0.0.1') {
    throw new Error(`Refusing placeholder Supabase host ${url.host} for a deployable build.`);
  }
  return url.origin;
}

export function resolveWebBuild(env, { placeholder = false } = {}) {
  assertNoForbiddenEnv(env);
  if (placeholder) {
    if (onVercel(env)) {
      throw new Error('Refusing a placeholder web build on Vercel. Set the public Supabase URL and anon/publishable key, then build without --placeholder.');
    }
    return {
      placeholder: true,
      supabaseUrl: PLACEHOLDER_URL,
      supabaseAnonKey: PLACEHOLDER_KEY,
      webRedirectUrl: '',
      telegramOidcEnabled: 'false',
      defines: {
        SUPABASE_URL: PLACEHOLDER_URL,
        SUPABASE_ANON_KEY: PLACEHOLDER_KEY,
        TELEGRAM_OIDC_ENABLED: 'false',
      },
    };
  }
  const supabaseUrl = publicSupabaseUrl(env.SUPABASE_URL);
  const anon = (env.SUPABASE_ANON_KEY || '').trim();
  const publishable = (env.SUPABASE_PUBLISHABLE_KEY || '').trim();
  if (anon && publishable && anon !== publishable) {
    throw new Error('SUPABASE_ANON_KEY and SUPABASE_PUBLISHABLE_KEY are both set and differ. Set only the public key you intend to ship.');
  }
  const supabaseAnonKey = anon || publishable;
  if (!supabaseAnonKey) {
    throw new Error(
      'SUPABASE_ANON_KEY is not set. In Vercel → Settings → Environment Variables, add the public anon or publishable key. ' +
        'Do not add the service-role key, a Google client secret, or Telegram credentials. Do not paste keys into chat.',
    );
  }
  if (supabaseAnonKey === PLACEHOLDER_KEY) {
    throw new Error('Refusing the CI placeholder anon key for a deployable build.');
  }
  assertPublicClientKey(supabaseAnonKey);
  const oidcRaw = (env.TELEGRAM_OIDC_ENABLED || '').trim();
  if (oidcRaw && oidcRaw !== 'true' && oidcRaw !== 'false') {
    throw new Error('TELEGRAM_OIDC_ENABLED must be exactly "true" or "false". Leave it unset or false until hosted Telegram OIDC is live-tested.');
  }
  const telegramOidcEnabled = oidcRaw === 'true' ? 'true' : 'false';
  const webRedirectUrl = resolveRedirect(env);
  return {
    placeholder: false,
    supabaseUrl,
    supabaseAnonKey,
    webRedirectUrl,
    telegramOidcEnabled,
    defines: {
      SUPABASE_URL: supabaseUrl,
      SUPABASE_ANON_KEY: supabaseAnonKey,
      WEB_REDIRECT_URL: webRedirectUrl,
      TELEGRAM_OIDC_ENABLED: telegramOidcEnabled,
    },
  };
}

export function summaryLine(config) {
  const host = new URL(config.supabaseUrl).host;
  const redirect = config.webRedirectUrl || '(unset)';
  return `web-build supabase_host=${host} redirect=${redirect} oidc=${config.telegramOidcEnabled}`;
}

function pngBitDepth(buffer) {
  const signature = buffer.subarray(0, 8).toString('hex');
  if (signature !== '89504e470d0a1a0a') throw new Error('not a PNG');
  return buffer[24];
}

export function verifyWebOutput(dir) {
  const indexPath = path.join(dir, 'index.html');
  const index = fs.readFileSync(indexPath, 'utf8');
  if (!/<base href="\/">/.test(index)) {
    throw new Error('build/web/index.html does not set <base href="/">. Host the site at the domain root, not /massanger/.');
  }
  if (index.includes('/massanger/')) {
    throw new Error('GitHub Pages base path /massanger/ leaked into index.html.');
  }
  if (!index.includes('rel="manifest"')) {
    throw new Error('index.html does not link the web app manifest, so the PWA cannot be installed.');
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
  if (manifest.start_url !== '/' || manifest.scope !== '/' || manifest.id !== '/') {
    throw new Error('PWA manifest start_url, scope and id must be "/" for root hosting.');
  }
  if (manifest.display !== 'standalone') {
    throw new Error('PWA manifest display must be standalone.');
  }
  const icons = Array.isArray(manifest.icons) ? manifest.icons : [];
  const sizes = new Set(icons.map((icon) => icon.sizes));
  if (!sizes.has('192x192') || !sizes.has('512x512')) {
    throw new Error('PWA manifest needs 192x192 and 512x512 PNG icons.');
  }
  for (const file of [
    'flutter_service_worker.js',
    'flutter_bootstrap.js',
    'main.dart.js',
    'icons/icon-192.png',
    'icons/icon-512.png',
    'icons/icon-maskable-512.png',
  ]) {
    if (!fs.existsSync(path.join(dir, file))) {
      throw new Error(`Web build is missing ${file}. A release build at / must include the service worker and icons so the PWA can install.`);
    }
  }
  for (const icon of ['icons/icon-192.png', 'icons/icon-512.png', 'icons/icon-maskable-512.png']) {
    const depth = pngBitDepth(fs.readFileSync(path.join(dir, icon)));
    if (depth !== 8) {
      throw new Error(`${icon} is ${depth}-bit PNG. Installability needs an 8-bit PNG.`);
    }
  }
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = { command, placeholder: false, out: '', dir: '' };
  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    if (arg === '--placeholder') options.placeholder = true;
    else if (arg === '--out') options.out = rest[++i];
    else if (arg === '--dir') options.dir = rest[++i];
    else throw new Error(`Unknown argument ${arg}`);
  }
  return options;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.command === 'write-defines') {
    if (!options.out) throw new Error('--out is required');
    const config = resolveWebBuild(process.env, { placeholder: options.placeholder });
    fs.writeFileSync(options.out, `${JSON.stringify(config.defines, null, 2)}\n`, { mode: 0o600 });
    process.stdout.write(`${summaryLine(config)}\n`);
    return;
  }
  if (options.command === 'verify-output') {
    if (!options.dir) throw new Error('--dir is required');
    verifyWebOutput(options.dir);
    process.stdout.write(`web-output ok ${options.dir}\n`);
    return;
  }
  throw new Error('Usage: web_build_config.mjs <write-defines|verify-output> [--placeholder] [--out file] [--dir dir]');
}

const invokedDirectly = process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (invokedDirectly) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
