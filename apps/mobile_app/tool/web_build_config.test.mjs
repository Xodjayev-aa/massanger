import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  FLUTTER_COMMIT,
  FLUTTER_VERSION,
  INTENDED_REDIRECT_URL,
  INTENDED_SITE_ORIGIN,
  assertPublicClientKey,
  resolveWebBuild,
  verifyWebOutput,
} from './web_build_config.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');

function jwt(payload) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'none', typ: 'JWT' })}.${encode(payload)}.signature`;
}

const anonKey = jwt({ role: 'anon', iss: 'supabase' });
const serviceKey = jwt({ role: 'service_role', iss: 'supabase' });

const productionEnv = {
  SUPABASE_URL: 'https://abcdef.supabase.co',
  SUPABASE_ANON_KEY: anonKey,
  VERCEL: '1',
  VERCEL_ENV: 'production',
  VERCEL_PROJECT_PRODUCTION_URL: 'officialmessengerx.vercel.app',
};

describe('public web build config', () => {
  it('pins the same Flutter release CI already uses', () => {
    const workflow = fs.readFileSync(path.join(repo, '.github/workflows/ci.yml'), 'utf8');
    assert.match(workflow, new RegExp(`flutter-version: ${FLUTTER_VERSION}`));
    assert.equal(FLUTTER_COMMIT, 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668');
    assert.doesNotMatch(workflow, /base-href=\/massanger\//);
    assert.doesNotMatch(workflow, /github\.io\/massanger/);
  });

  it('builds a placeholder without a live redirect and refuses that mode on Vercel', () => {
    const config = resolveWebBuild({}, { placeholder: true });
    assert.equal(config.supabaseUrl, 'https://example.supabase.co');
    assert.equal(config.defines.WEB_REDIRECT_URL, undefined);
    assert.equal(config.telegramOidcEnabled, 'false');
    assert.throws(() => resolveWebBuild({ VERCEL: '1' }, { placeholder: true }), /placeholder/);
  });

  it('uses only the public URL and anon key, and redirects to the chosen Vercel root', () => {
    const config = resolveWebBuild(productionEnv);
    assert.equal(config.supabaseUrl, 'https://abcdef.supabase.co');
    assert.equal(config.webRedirectUrl, INTENDED_REDIRECT_URL);
    assert.equal(config.defines.SUPABASE_ANON_KEY, anonKey);
    assert.equal(Object.keys(config.defines).sort().join(','), 'SUPABASE_ANON_KEY,SUPABASE_URL,TELEGRAM_OIDC_ENABLED,WEB_REDIRECT_URL');
    assert.equal(assertPublicClientKey('sb_publishable_example_public_key'), 'publishable');
  });

  it('accepts the publishable key alias and keeps Telegram OIDC off unless exactly true', () => {
    const config = resolveWebBuild({
      ...productionEnv,
      SUPABASE_ANON_KEY: '',
      SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_example_public_key',
      TELEGRAM_OIDC_ENABLED: 'true',
    });
    assert.equal(config.supabaseAnonKey, 'sb_publishable_example_public_key');
    assert.equal(config.telegramOidcEnabled, 'true');
    assert.throws(() => resolveWebBuild({ ...productionEnv, TELEGRAM_OIDC_ENABLED: 'yes' }), /TELEGRAM_OIDC_ENABLED/);
  });

  it('refuses service-role, Google, Telegram and bridge secrets', () => {
    assert.throws(() => resolveWebBuild({ ...productionEnv, SUPABASE_ANON_KEY: serviceKey }), /service-role/);
    assert.throws(() => resolveWebBuild({ ...productionEnv, SUPABASE_ANON_KEY: 'sb_secret_live_key_value' }), /secret key/);
    assert.throws(() => resolveWebBuild({ ...productionEnv, SUPABASE_ANON_KEY: 'GOCSPX-not-a-supabase-key' }), /Google client secret/);
    for (const name of ['SUPABASE_SERVICE_ROLE_KEY', 'GOOGLE_OAUTH_CLIENT_SECRET', 'TELEGRAM_API_HASH', 'SEAL_KEY', 'BRIDGE_TOKEN']) {
      assert.throws(() => resolveWebBuild({ ...productionEnv, [name]: 'x'.repeat(40) }), new RegExp(name));
    }
  });

  it('does not ask for secrets in the missing-key error and refuses the retired base path', () => {
    assert.throws(
      () => resolveWebBuild({ VERCEL: '1', SUPABASE_URL: 'https://abcdef.supabase.co' }),
      /Do not paste keys into chat/,
    );
    assert.throws(() => resolveWebBuild({ ...productionEnv, WEB_REDIRECT_URL: 'https://xodjayev-aa.github.io/massanger/' }), /retired/);
    assert.throws(
      () => resolveWebBuild({ ...productionEnv, VERCEL_PROJECT_PRODUCTION_URL: 'some-other-name.vercel.app' }),
      /ask before using a different name/,
    );
  });

  it('allows a different host only after that host was explicitly agreed', () => {
    const config = resolveWebBuild({
      ...productionEnv,
      VERCEL_PROJECT_PRODUCTION_URL: 'agreed-name.vercel.app',
      MESSENGERX_ACCEPT_SITE_HOST: 'agreed-name.vercel.app',
    });
    assert.equal(config.webRedirectUrl, 'https://agreed-name.vercel.app/');
  });

  it('keeps both Vercel configs on the root SPA, with no Pages base path', () => {
    const app = JSON.parse(fs.readFileSync(path.join(repo, 'apps/mobile_app/vercel.json'), 'utf8'));
    const root = JSON.parse(fs.readFileSync(path.join(repo, 'vercel.json'), 'utf8'));
    for (const config of [app, root]) {
      assert.equal(config.framework, null);
      assert.deepEqual(config.rewrites, [{ source: '/(.*)', destination: '/index.html' }]);
      assert.match(config.buildCommand, /vercel_build\.sh build$/);
      assert.match(config.installCommand, /vercel_build\.sh install$/);
      const headers = config.headers.flatMap((rule) => rule.headers);
      assert.ok(headers.some((header) => header.key === 'X-Content-Type-Options' && header.value === 'nosniff'));
      assert.ok(headers.some((header) => header.key === 'Cache-Control' && header.value.includes('must-revalidate')));
      assert.ok(headers.some((header) => header.key === 'Content-Type' && header.value.startsWith('application/manifest+json')));
      assert.equal(JSON.stringify(config).includes('/massanger/'), false);
    }
    assert.equal(app.outputDirectory, 'build/web');
    assert.equal(root.outputDirectory, 'apps/mobile_app/build/web');
  });

  it('documents the Vercel origin, the Supabase callback, and a production reset refusal', () => {
    const guide = fs.readFileSync(path.join(repo, 'docs/vercel.md'), 'utf8');
    assert.match(guide, new RegExp(INTENDED_SITE_ORIGIN));
    assert.match(guide, /auth\/v1\/callback/);
    assert.match(guide, /ALLOWED_ORIGINS/);
    assert.match(guide, /supabase db reset/);
    assert.match(guide, /Do not paste/i);
    assert.match(guide, /not live|not serving|DEPLOYMENT_NOT_FOUND/i);
  });
});

describe('web output contract', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mx-web-'));
  after(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('accepts a root release and rejects a Pages base path or a missing service worker', () => {
    fs.mkdirSync(path.join(dir, 'icons'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'index.html'), '<html><head><base href="/"><link rel="manifest" href="manifest.json"></head></html>');
    fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({
      id: '/',
      start_url: '/',
      scope: '/',
      display: 'standalone',
      icons: [
        { src: '/icons/icon-192.png', sizes: '192x192' },
        { src: '/icons/icon-512.png', sizes: '512x512' },
      ],
    }));
    const png = Buffer.from(
      '89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de0000000c4944415408d763f8ffff3f0005fe02fe0d0a2a0000000049454e44ae426082',
      'hex',
    );
    fs.writeFileSync(path.join(dir, 'icons/icon-192.png'), png);
    fs.writeFileSync(path.join(dir, 'icons/icon-512.png'), png);
    fs.writeFileSync(path.join(dir, 'icons/icon-maskable-512.png'), png);
    fs.writeFileSync(path.join(dir, 'flutter_service_worker.js'), '/* sw */');
    fs.writeFileSync(path.join(dir, 'flutter_bootstrap.js'), '/* boot */');
    fs.writeFileSync(path.join(dir, 'main.dart.js'), '/* app */');
    assert.doesNotThrow(() => verifyWebOutput(dir));
    fs.writeFileSync(path.join(dir, 'index.html'), '<base href="/massanger/">');
    assert.throws(() => verifyWebOutput(dir), /base href|massanger/);
  });
});
