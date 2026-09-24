/**
 * The simulator is what makes the bridge testable at all, so its contract with
 * TdLibClient is pinned here: correlation by @extra, updates, errors, close.
 */

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { TelegramSimulator } from '../src/simulator.js';
import { TdLibClient, TdLibError } from '../src/tdlib.js';

const withClient = async (
  run: (client: TdLibClient, sim: TelegramSimulator) => Promise<void>,
  options: ConstructorParameters<typeof TelegramSimulator>[0] = {},
): Promise<void> => {
  const sim = new TelegramSimulator(options);
  const client = new TdLibClient(sim, { timeoutMs: 2_000 });
  await client.start();
  try {
    await run(client, sim);
  } finally {
    await client.close();
  }
};

describe('TdLibClient over the simulator', () => {
  it('correlates responses by @extra and exposes the auth state', async () => {
    await withClient(async (client, sim) => {
      // Silent until the parameters arrive, exactly like TDLib.
      assert.equal(client.authorizationState, 'unknown');
      await client.request('setTdlibParameters', { api_id: 1 });
      assert.equal(client.authorizationState, 'wait_phone_number');
      await client.request('setAuthenticationPhoneNumber', { phone_number: '+10000000000', settings: null });
      assert.equal(client.authorizationState, 'wait_code');
      assert.equal(sim.authorizationState, 'wait_code');
    });
  });

  it('rejects pre-1.8.43 phone flags and invented QR/login-token methods', async () => {
    await withClient(async (client) => {
      await client.request('setTdlibParameters', { api_id: 1 });
      await assert.rejects(() => client.request('setAuthenticationPhoneNumber', {
        phone_number: '+10000000000', allow_flash_call: false,
      }), /PHONE_SETTINGS_INVALID/);
      assert.equal(client.authorizationState, 'wait_phone_number');
      for (const method of ['requestQrCode', 'checkAuthenticationToken', 'exportLoginToken', 'importLoginToken']) {
        await assert.rejects(() => client.request(method), /not modelled/);
      }
    });
  });

  it('walks phone → code → password → ready only with the right secrets', async () => {
    await withClient(
      async (client) => {
        await client.request('setTdlibParameters', { api_id: 1 });
        await client.request('setAuthenticationPhoneNumber', { phone_number: '+10000000000', settings: null });
        await assert.rejects(
          () => client.request('checkAuthenticationCode', { code: '00000' }),
          (error: unknown) => error instanceof TdLibError && /PHONE_CODE_INVALID/.test(error.message),
        );
        await client.request('checkAuthenticationCode', { code: '12345' });
        assert.equal(client.authorizationState, 'wait_password');
        await assert.rejects(() => client.request('checkAuthenticationPassword', { password: 'nope' }), /PASSWORD_HASH_INVALID/);
        await client.request('checkAuthenticationPassword', { password: 'hunter2' });
        assert.equal(client.authorizationState, 'ready');
        const me = await client.request('getMe');
        assert.equal(me['@type'], 'user');
      },
      { password: 'hunter2' },
    );
  });

  it('returns the sent message and echoes it back as updateNewMessage', async () => {
    await withClient(async (client, sim) => {
      await client.request('setTdlibParameters', { api_id: 1 });
      await client.request('setAuthenticationPhoneNumber', { phone_number: '+10000000000', settings: null });
      // The simulator flips to ready while answering the code request, which is
      // exactly TDLib's ordering: the state update precedes the response.
      await client.request('checkAuthenticationCode', { code: '12345' });
      assert.equal(client.authorizationState, 'ready');
      sim.addChat({ id: 4242, title: 'Dilnoza' });
      await assert.rejects(() => client.request('sendMessage', {
        chat_id: 4242,
        options: { '@type': 'messageSendingOptions', sending_id: 12 },
        input_message_content: { '@type': 'inputMessageText', text: { '@type': 'formattedText', text: 'bad', entities: [] } },
      }), /MESSAGE_SEND_OPTIONS_INVALID/, 'the simulator rejects the old type that real TDLib rejects');
      const echo: Array<Record<string, unknown>> = [];
      client.on((update) => {
        if (update['@type'] === 'updateNewMessage') echo.push(update as unknown as Record<string, unknown>);
      });
      const response = await client.request('sendMessage', {
        chat_id: 4242,
        options: { '@type': 'messageSendOptions', sending_id: 12 },
        input_message_content: { '@type': 'inputMessageText', text: { '@type': 'formattedText', text: 'hi', entities: [] } },
      });
      assert.equal((response.content as Record<string, unknown>)['@type'], 'inputMessageText');
      assert.ok(Number(response.id) > 0);
      assert.equal(sim.sentMessages.length, 1);

      await client.waitForUpdate((update) => update['@type'] === 'updateMessageSendAcknowledged', { timeoutMs: 2_000 });
      assert.equal(echo.length, 1, 'the echo is delivered like any other update');
      assert.equal((echo[0]?.message as Record<string, unknown>).is_outgoing, true);
    });
  });

  it('surfaces Telegram errors as TdLibError with the flood hint attached', async () => {
    await withClient(async (client) => {
      await assert.rejects(
        () => client.request('totallyUnknownMethod', {}),
        (error: unknown) => {
          assert.ok(error instanceof TdLibError);
          assert.equal(error.code, 404);
          // An unimplemented method must not be retried: the answer never changes.
          assert.equal(error.retryable, false);
          assert.equal(error.floodWaitSeconds, null);
          return true;
        },
      );

      assert.equal(new TdLibError(500, 'INTERNAL_SERVER_ERROR').retryable, true);
      assert.equal(new TdLibError(400, 'FLOOD_WAIT_37').floodWaitSeconds, 37);
      assert.equal(new TdLibError(400, 'FLOOD_WAIT_37').retryable, true);
      assert.equal(new TdLibError(400, 'AUTH_KEY_UNREGISTERED').retryable, false);
    });
  });

  it('injectIncoming produces the updates a real peer would', async () => {
    await withClient(async (client, sim) => {
      sim.addChat({ id: 7 });
      const seen: string[] = [];
      client.on((update) => seen.push(String((update.message as Record<string, unknown> | undefined)?.id ?? update['@type'])));
      sim.injectIncoming({ chatId: 7, text: 'from the peer' });
      assert.equal(seen.length, 1, 'an injected peer message reaches every handler');
      assert.ok(sim.injectIncoming({ chatId: 7, voice: { duration: 3 } }));
    });
  });

  it('rejects pending requests when the client closes', async () => {
    const sim = new TelegramSimulator();
    const client = new TdLibClient(sim, { timeoutMs: 5_000 });
    await client.start();
    const pending = client.request('getChat', { chat_id: 1 });
    await client.close();
    await assert.rejects(pending, /client closed|abort/i);
    assert.equal(client.pendingRequests, 0);
    assert.equal(client.closed, true);
  });

  it('times out a request the transport never answers', async () => {
    const silent = {
      kind: 'memory' as const,
      start: async () => undefined,
      stop: async () => undefined,
      send: () => undefined,
      onReceive: () => () => undefined,
    };
    const client = new TdLibClient(silent, { timeoutMs: 40 });
    await client.start();
    await assert.rejects(() => client.request('getMe'), /timed out after 40ms/);
    await client.close();
  });
});
