import assert from 'node:assert/strict';
import { afterEach, describe, it } from 'node:test';

import { BridgeManager } from '../src/manager.js';
import { TelegramSimulator } from '../src/simulator.js';
import { SupabaseBridge } from '../src/supabase.js';
import { CHAT_ID, OWNER, REQUEST_ID, accountContext, recorder, testConfig, until } from './helpers.js';

let manager: BridgeManager | null = null;
afterEach(async () => {
  await manager?.stop();
  manager = null;
});

async function readyManager() {
  const config = testConfig();
  const rec = recorder();
  const sim = new TelegramSimulator({ chats: [] });
  const db = new SupabaseBridge(config, rec.fetchImpl);
  manager = new BridgeManager({ config, db, transportFor: () => sim });

  rec.reply('bridge_account_context', accountContext({ tg_user_id: '777001' }));
  await manager.wake({ kind: 'outbox', user_ids: [OWNER] });
  const session = manager.sessionFor(OWNER);
  assert.ok(session, 'the manager opened the linked account’s TDLib session');
  await session.client.request('setAuthenticationPhoneNumber', { phone_number: '+998901112233', settings: null });
  await session.client.request('checkAuthenticationCode', { code: '12345' });
  await until(() => session.ready);
  await until(() => rec.calls.some((call) => call.url.includes('bridge_set_account_state') &&
    call.json()?.p_last_sync === true));
  return { rec, sim, session, manager };
}

describe('new Telegram contact through a worker wake', () => {
  it('resolves a previously unknown public user and completes the owner-scoped queue row', async () => {
    const { rec, sim, manager: bridge } = await readyManager();
    sim.addChat({ id: 8_882, type: 'private', peerUserId: 8_882, username: 'freshfriend', title: 'Fresh Friend' });
    rec.reply('bridge_claim_chat_request', {
      request_id: REQUEST_ID, user_id: OWNER, username: 'freshfriend', attempts: 1,
    });
    rec.reply('bridge_claim_chat_request', null);
    rec.reply('bridge_resolve_chat', { chat_id: CHAT_ID, created: true, mapping_id: 'mapping-id' });
    rec.reply('bridge_finish_chat_request', true);

    const result = await bridge.wake({ kind: 'chat', user_ids: [OWNER] });
    assert.equal(result.pumped, 1);
    const finished = rec.find('bridge_finish_chat_request');
    assert.equal(finished?.json().p_request_id, REQUEST_ID);
    assert.equal(finished?.json().p_chat_id, CHAT_ID);
    assert.equal(finished?.json().p_error, null);
    assert.equal(rec.find('bridge_resolve_chat')?.json().p_owner_user_id, OWNER);
  });

  it('does not create a group chat or leak Telegram errors on an unknown username', async () => {
    const { rec, sim, manager: bridge } = await readyManager();
    sim.addChat({ id: 8_883, type: 'supergroup', username: 'publicgroup' });
    for (const username of ['publicgroup', 'missinguser']) {
      rec.reply('bridge_claim_chat_request', {
        request_id: REQUEST_ID, user_id: OWNER, username, attempts: 1,
      });
      rec.reply('bridge_claim_chat_request', null);
      rec.reply('bridge_finish_chat_request', true);
      const result = await bridge.wake({ kind: 'chat', user_ids: [OWNER] });
      assert.equal(result.pumped, 1);
      const finished = rec.find('bridge_finish_chat_request')?.json();
      assert.equal(finished.p_chat_id, null);
      assert.match(String(finished.p_error), username === 'publicgroup' ? /group or channel/ : /No Telegram user/);
      assert.equal(finished.p_retry_in, null);
    }
    assert.equal(rec.find('bridge_resolve_chat'), undefined, 'no invalid public chat was mirrored');
  });
});
