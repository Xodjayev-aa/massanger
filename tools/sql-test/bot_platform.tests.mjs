// =============================================================================
// tools/sql-test/bot_platform.tests.mjs
//
// 00026 — the bot platform: @BotFather, tokens, the Bot API, slash commands,
// per-chat installs, automated moderation, inline queries, webhooks/getUpdates
// and scheduled broadcasts.
// =============================================================================

export async function registerBotTests(h) {
  const {
    test, group, eq, assert, throws, exec, query, one, scalar,
    become, becomeService, becomeOwner, U, rpc,
  } = h;

  const jsonLit = (value) => `'${JSON.stringify(value).replace(/'/g, "''")}'::jsonb`;

  let cmidSeq = 0;
  const cmid = () => `c0000000-0000-4000-8000-${String(++cmidSeq).padStart(12, '0')}`;

  const active = async (uid) => {
    await becomeOwner();
    await exec(`update public.profiles set access_state = 'active', access_state_reason = null where id = '${uid}'`);
  };

  // Shared across the bot tests.
  let chatId = null;
  let communityId = null;
  let generalChannel = null;
  let generalChat = null;
  let botId = null;
  let botHandle = null;
  let botToken = null;
  let botfatherChat = null;
  let botProfileId = null;
  let installId = null;

  // -------------------------------------------------------------------------
  group('bot platform (00026)');
  // -------------------------------------------------------------------------
  await test('@BotFather is provisioned and opens as a normal DM', async () => {
    await becomeOwner();
    const father = await one(`select b.id, b.username, p.id as profile_id, p.account_kind
                                from public.bots b join public.profiles p on p.id = b.profile_id
                               where b.is_botfather`);
    eq(father.username, 'botfather');
    eq(father.account_kind, 'system');

    await active(U.a);
    await become(U.a);
    botfatherChat = await scalar(`select public.botfather_chat()`);
    assert(botfatherChat, 'a DM with @BotFather exists');
    eq(await scalar(`select public.botfather_chat()`), botfatherChat, 'asking twice reuses the chat');
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.chat_participants
                             where chat_id = '${botfatherChat}'`)), 2);
  });

  await test('/newbot mints a bot, a profile and a working token', async () => {
    await become(U.a);
    await exec(`select public.send_message('${botfatherChat}', 'text', '/newbot Delivery Bot', null, null, '${cmid()}')`);
    await becomeOwner();
    const row = await one(`select b.id, b.username, b.profile_id, b.token_hash, b.token_prefix, p.account_kind
                             from public.bots b join public.profiles p on p.id = b.profile_id
                            where b.username like 'delivery%'`);
    botId = row.id;
    botHandle = row.username;
    botProfileId = row.profile_id;
    eq(row.account_kind, 'bot');
    assert(row.username.endsWith('bot'), `handle ends in bot (${row.username})`);
    assert(row.token_hash && row.token_hash.length === 32, 'the token is stored hashed, never in clear');

    // The reply carries the token once — pull it out of BotFather's message.
    await become(U.a);
    const reply = await scalar(`select body from public.messages
                                 where chat_id = '${botfatherChat}' and sender_id =
                                       (select profile_id from public.bots where is_botfather)
                                 order by created_at desc limit 1`);
    assert(reply.includes('mxb_'), 'BotFather handed over a token');
    botToken = (reply.match(/mxb_[a-z0-9_]+/) || [])[0];
    assert(botToken, 'token parsed');
  });

  await test('the token authenticates bot_api, and a bad token does not', async () => {
    await becomeService();
    const me = await scalar(`select public.bot_api('${botToken}', 'getMe', '{}'::jsonb)`);
    eq(me.ok, true);
    eq(me.result.username, botHandle);

    const bad = await scalar(`select public.bot_api('mxb_nope_nope', 'getMe', '{}'::jsonb)`);
    eq(bad.ok, false);
    assert(String(bad.description).includes('invalid or revoked'), 'a bad token is refused as data');

    const unknown = await scalar(`select public.bot_api('${botToken}', 'nonsense', '{}'::jsonb)`);
    eq(unknown.ok, false);
    assert(String(unknown.description).includes('unknown method'), 'unknown methods are refused');
  });

  await test('sendMessage reaches a DM, and requires an install in a group', async () => {
    await become(U.a);
    const dm = await scalar(`select public.create_direct_chat(null, '${botHandle}')`);
    await becomeService();
    const sent = await scalar(`select public.bot_api('${botToken}', 'sendMessage',
      ${jsonLit({ chat_id: dm, text: 'Hello from the API' })})`);
    eq(sent.ok, true);
    assert(sent.result.message_id, 'the message id comes back');

    await becomeOwner();
    eq(await scalar(`select body from public.messages where id = '${sent.result.message_id}'`),
      'Hello from the API');

    // A group the bot is not installed in is off limits.
    await become(U.a);
    const group = await scalar(`select public.create_group_chat('Weekend crew', array['${U.a}', '${U.b}']::uuid[])`);
    await becomeService();
    const blocked = await scalar(`select public.bot_api('${botToken}', 'sendMessage',
      ${jsonLit({ chat_id: group, text: 'spam' })})`);
    eq(blocked.ok, false);
    assert(String(blocked.description).includes('not installed'), 'installs gate group traffic');
  });

  await test('an install is clamped to the installer permissions and adds the bot to the room', async () => {
    await become(U.a);
    communityId = await scalar(`select public.community_create('Bot Lab', 'bot-lab', 'Where bots live', true)`);
    const overview = await scalar(`select public.community_overview('${communityId}')`);
    generalChannel = overview.channels.find((c) => c.kind === 'text').id;
    generalChat = overview.channels.find((c) => c.kind === 'text').chat_id;

    installId = await scalar(`select public.bot_install('${botId}', '${generalChat}', null)`);
    assert(installId, 'installed');

    await becomeOwner();
    const install = await one(`select permissions, community_id, is_enabled from public.bot_installs where id = '${installId}'`);
    eq(install.is_enabled, true);
    eq(install.community_id, communityId);
    // The owner has ADMINISTRATOR, so the clamp leaves the requested default.
    eq(Boolean(Number(install.permissions) & Number(await scalar(`select app.perm_send_messages()`))), true,
      'the bot may speak in the channel');

    // The bot is a participant and a community member, so channel guards pass.
    eq(await scalar(`select exists (select 1 from public.chat_participants cp
                                     where cp.chat_id = '${generalChat}'
                                       and cp.user_id = (select profile_id from public.bots where id = '${botId}')
                                       and cp.left_at is null)`), true);
    eq(await scalar(`select exists (select 1 from public.community_members m
                                     where m.community_id = '${communityId}'
                                       and m.user_id = (select profile_id from public.bots where id = '${botId}'))`), true);

    // A plain member cannot install bots without Manage Bots.
    await become(U.b);
    await exec(`select public.community_join('${communityId}', null, null)`);
    await throws(() => exec(`select public.bot_install('${botId}', '${generalChat}', null)`), /Manage Bots/);
  });

  await test('a slash command runs the builtin and the bot answers in the channel', async () => {
    await become(U.a);
    eq(Number(await scalar(`select public.bot_set_commands('${botId}', null, null, jsonb_build_array(
      jsonb_build_object('name', 'ping', 'description', 'Say pong', 'builtin', 'echo'),
      jsonb_build_object('name', 'ban', 'description', 'Ban a member', 'builtin', 'ban', 'permission', 'moderators')))`)),
      2);

    await become(U.b);
    await exec(`select public.send_message('${generalChat}', 'text', '/ping hello there', null, null, '${cmid()}')`);
    await becomeOwner();
    const reply = await one(`select m.body, m.sender_id from public.messages m
                              where m.chat_id = '${generalChat}'
                                and m.sender_id = (select profile_id from public.bots where id = '${botId}')
                              order by m.created_at desc limit 1`);
    eq(reply.body, 'hello there', 'echo replied with the arguments');

    // A command the invoker is not allowed to use is refused by the bot itself.
    await become(U.b);
    await exec(`select public.send_message('${generalChat}', 'text', '/ban @${'aziz_carrier'}', null, null, '${cmid()}')`);
    await becomeOwner();
    const refusal = await scalar(`select body from public.messages
                                   where chat_id = '${generalChat}'
                                     and sender_id = (select profile_id from public.bots where id = '${botId}')
                                   order by created_at desc limit 1`);
    assert(refusal.includes('not allowed'), `refused a moderator command (${refusal})`);
  });

  await test('moderation builtins act with the install mask, not with more', async () => {
    await become(U.a);
    // Re-install so the mask is the owner's own again (the previous test
    // deliberately narrowed it).
    await exec(`select public.bot_install('${botId}', '${generalChat}', null)`);
    await exec(`select public.bot_set_commands('${botId}', null, null, jsonb_build_array(
      jsonb_build_object('name', 'mute', 'description', 'Mute someone', 'builtin', 'mute')))`);

    // The owner (administrator) may mute through the bot.
    await exec(`select public.send_message('${generalChat}', 'text', '/mute @dilnoza_rustamova 5 spam', null, null, '${cmid()}')`);
    await becomeOwner();
    const muted = await one(`select is_muted, muted_until from public.community_members
                              where community_id = '${communityId}' and user_id = '${U.b}'`);
    eq(muted.is_muted, true);
    assert(muted.muted_until, 'the timeout has an end');

    await become(U.a);
    await exec(`select public.community_member_moderate('${communityId}', '${U.b}', 'unmute')`);

    // Strip the bot's moderation permissions: the same command now refuses.
    await becomeOwner();
    await exec(`update public.bot_installs set permissions = ${'1'}::bigint << 2 where id = '${installId}'`);
    await become(U.a);
    await exec(`select public.send_message('${generalChat}', 'text', '/mute @dilnoza_rustamova 5 again', null, null, '${cmid()}')`);
    await becomeOwner();
    const reply = await scalar(`select body from public.messages
                                 where chat_id = '${generalChat}'
                                   and sender_id = (select profile_id from public.bots where id = '${botId}')
                                 order by created_at desc limit 1`);
    assert(reply.includes('not installed with that permission'), `refused without the mask (${reply})`);
    const still = await one(`select is_muted from public.community_members
                              where community_id = '${communityId}' and user_id = '${U.b}'`);
    eq(still.is_muted, false, 'and the member was not muted');
  });

  await test('automated moderation deletes on arrival and records the hit', async () => {
    await become(U.a);
    const rule = await scalar(`select public.bot_rules_save('${botId}', null, 'keyword',
      ${jsonLit({ words: ['free crypto'] })}, 'delete', '${generalChat}', '${communityId}', null, true)`);
    assert(rule, 'rule saved');

    await become(U.b);
    await exec(`select public.send_message('${generalChat}', 'text', 'come get your FREE CRYPTO now', null, null, '${cmid()}')`);
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.messages
                             where chat_id = '${generalChat}' and body ilike '%crypto%'`)), 0,
      'the message never landed');
    eq(Number(await scalar(`select hits from public.bot_moderation_rules where id = '${rule}'`)), 1);
    eq(Number(await scalar(`select count(*)::int from public.bot_events
                             where bot_id = '${botId}' and kind = 'moderation'`)), 1,
      'the owner can see what the rule caught');

    // Staff are never auto-moderated, and a clean message passes.
    await become(U.a);
    await exec(`select public.send_message('${generalChat}', 'text', 'free crypto is a scam', null, null, '${cmid()}')`);
    await become(U.b);
    await exec(`select public.send_message('${generalChat}', 'text', 'good morning everyone', null, null, '${cmid()}')`);
    await becomeOwner();
    eq(Number(await scalar(`select hits from public.bot_moderation_rules where id = '${rule}'`)), 1,
      'no extra hits');
    eq(Number(await scalar(`select count(*)::int from public.messages
                             where chat_id = '${generalChat}' and body = 'good morning everyone'`)), 1);
    await become(U.a);
    await exec(`select public.bot_rules_save('${botId}', '${rule}', 'keyword', '{}'::jsonb, 'delete',
      '${generalChat}', '${communityId}', null, false)`);
  });

  await test('inline queries round-trip: ask, answer, send via the bot', async () => {
    await become(U.a);
    const q = await scalar(`select public.bot_inline_query('${botHandle}', 'weather', '${generalChat}')`);
    assert(q, 'a query id came back');
    eq((await scalar(`select public.bot_inline_result('${q}')`)).answered, false);

    await becomeService();
    const answered = await scalar(`select public.bot_api('${botToken}', 'answerInlineQuery',
      ${jsonLit({ inline_query_id: q, results: [{ id: 'r1', title: 'Tashkent', text: 'Sunny, 27°C' }] })})`);
    eq(answered.ok, true);

    await become(U.a);
    const result = await scalar(`select public.bot_inline_result('${q}')`);
    eq(result.answered, true);
    eq(result.results.length, 1);
    eq(result.results[0].title, 'Tashkent');

    const sent = await scalar(`select public.bot_inline_send('${q}', 'r1', '${generalChat}')`);
    await becomeOwner();
    eq(await scalar(`select body from public.messages where id = '${sent}'`), 'Sunny, 27°C');
    eq(await scalar(`select via_bot_id from public.messages where id = '${sent}'`), botId,
      'credited to the bot');
  });

  group('bot api and delivery (00026)');

  await test('getUpdates long-polls the outbox and confirms by offset', async () => {
    await become(U.a);
    await exec(`select public.send_message('${generalChat}', 'text', 'hey bot are you there', null, null, '${cmid()}')`);
    await becomeService();
    const first = await scalar(`select public.bot_api('${botToken}', 'getUpdates', ${jsonLit({ offset: 0, limit: 10 })})`);
    eq(first.ok, true);
    assert(first.result.length >= 1, 'an update is waiting');
    const offsets = first.result.map((u) => Number(u.update_id));
    const maxOffset = Math.max(...offsets);

    const next = await scalar(`select public.bot_api('${botToken}', 'getUpdates',
      ${jsonLit({ offset: maxOffset + 1, limit: 10 })})`);
    eq(next.result.length, 0, 'everything below the offset is retired');
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.bot_events
                             where bot_id = '${botId}' and status = 'pending'`)), 0);
  });

  await test('webhooks lease, retry with backoff, and then succeed', async () => {
    await become(U.a);
    const secret = await scalar(`select public.bot_webhook_set('${botId}', 'https://example.com/hook')`);
    assert(secret, 'the signing secret comes back once');
    // Privacy mode is on, so an ordinary message is not delivered — mentioning
    // the bot is what lifts it.
    await exec(`select public.send_message('${generalChat}', 'text', 'webhook please @${botHandle}', null, null, '${cmid()}')`);

    await becomeService();
    const claimed = await query(`select * from app.claim_bot_events('worker-1', 5, 30)`);
    eq(claimed.length >= 1, true, 'something was leased');
    eq(Number(claimed[0].attempts), 1);
    assert(claimed[0].leased_until, 'the lease has an expiry');

    await exec(`select app.bot_event_ack('${claimed[0].id}', false, 'connection refused')`);
    const retried = await one(`select status, attempts, error, available_at > clock_timestamp() as backed_off
                                 from public.bot_events where id = '${claimed[0].id}'`);
    eq(retried.status, 'pending');
    eq(retried.backed_off, true, 'a retry waits before it is claimable again');

    await exec(`select app.bot_event_ack('${claimed[0].id}', true)`);
    await becomeOwner();
    eq(await scalar(`select status from public.bot_events where id = '${claimed[0].id}'`), 'delivered');
    eq(Number(await scalar(`select count(*)::int from public.bot_events
                             where bot_id = '${botId}' and status = 'delivered'`)) >= 1, true);
  });

  await test('scheduled broadcasts send now, and repeat only when asked', async () => {
    await become(U.a);
    const oneShot = await scalar(`select public.bot_broadcast_schedule('${botId}', 'Standup in 5 minutes',
      '${generalChat}', null, clock_timestamp(), null)`);
    const repeating = await scalar(`select public.bot_broadcast_schedule('${botId}', 'Hourly reminder',
      '${generalChat}', null, clock_timestamp(), 3600)`);

    await becomeService();
    eq(Number(await scalar(`select app.run_bot_broadcasts(10)`)), 2, 'both jobs ran');

    await becomeOwner();
    eq(await scalar(`select status from public.bot_broadcasts where id = '${oneShot}'`), 'sent');
    eq(await scalar(`select status from public.bot_broadcasts where id = '${repeating}'`), 'scheduled',
      'a repeating job stays scheduled');
    eq(Number(await scalar(`select count(*)::int from public.messages
                             where chat_id = '${generalChat}' and body = 'Standup in 5 minutes'`)), 1);
    eq(Number(await scalar(`select count(*)::int from public.messages
                             where chat_id = '${generalChat}' and body = 'Hourly reminder'`)), 1);

    await become(U.a);
    await exec(`select public.bot_broadcast_cancel('${repeating}')`);
    await becomeOwner();
    eq(await scalar(`select status from public.bot_broadcasts where id = '${repeating}'`), 'canceled');
    await becomeService();
    eq(Number(await scalar(`select app.run_bot_broadcasts(10)`)), 0, 'a canceled job never runs');
  });

  await test('clients cannot read credentials or another owner update stream', async () => {
    await become(U.a);
    // Column-level grants: token_hash is not even readable.
    await throws(() => exec(`select token_hash from public.bots where id = '${botId}'`), /permission denied/);
    eq(Number(await scalar(`select count(*)::int from public.bot_events where bot_id = '${botId}'`)) >= 1, true,
      'the owner sees their own update stream');
    await become(U.b);
    eq(Number(await scalar(`select count(*)::int from public.bot_events where bot_id = '${botId}'`)), 0,
      'another user sees no events');
    eq(Number(await scalar(`select count(*)::int from public.bots where id = '${botId}'`)), 1,
      'a public bot is discoverable, only the credentials are not');
    await throws(() => exec(`select public.bot_rotate_token('${botId}')`), /not your bot/);
  });

  await test('BotFather lists, rotates and deletes through the DM', async () => {
    await become(U.a);
    await exec(`select public.send_message('${botfatherChat}', 'text', '/mybots', null, null, '${cmid()}')`);
    await becomeOwner();
    const listed = await scalar(`select body from public.messages
                                  where chat_id = '${botfatherChat}'
                                    and sender_id = (select profile_id from public.bots where is_botfather)
                                  order by created_at desc limit 1`);
    assert(listed.includes(botHandle), `the bot is listed (${listed})`);

    await become(U.a);
    await exec(`select public.send_message('${botfatherChat}', 'text', '/token ${botHandle}', null, null, '${cmid()}')`);
    await becomeOwner();
    const rotated = await scalar(`select body from public.messages
                                   where chat_id = '${botfatherChat}'
                                     and sender_id = (select profile_id from public.bots where is_botfather)
                                   order by created_at desc limit 1`);
    const newToken = (rotated.match(/mxb_[a-z0-9_]+/) || [])[0];
    assert(newToken && newToken !== botToken, 'the token was rotated');

    await becomeService();
    const dead = await scalar(`select public.bot_api('${botToken}', 'getMe', '{}'::jsonb)`);
    eq(dead.ok, false, 'the previous token is dead');
    const alive = await scalar(`select public.bot_api('${newToken}', 'getMe', '{}'::jsonb)`);
    eq(alive.ok, true);

    await become(U.a);
    await exec(`select public.send_message('${botfatherChat}', 'text', '/setcommands ${botHandle} ping - Say hello; mute - Silence someone', null, null, '${cmid()}')`);
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.bot_commands where bot_id = '${botId}'`)), 2);

    await become(U.a);
    await exec(`select public.send_message('${botfatherChat}', 'text', '/deletebot ${botHandle}', null, null, '${cmid()}')`);
    await becomeOwner();
    const retired = await one(`select b.is_active, b.username, p.deleted_at
                                 from public.bots b join public.profiles p on p.id = b.profile_id
                                where b.id = '${botId}'`);
    eq(retired.is_active, false, 'the bot is retired');
    assert(retired.username !== botHandle, 'its handle is freed for reuse');
    assert(retired.deleted_at, 'the account is closed');
    eq(Number(await scalar(`select count(*)::int from public.bot_installs where bot_id = '${botId}'`)), 0,
      'installs are removed');
    eq(Number(await scalar(`select count(*)::int from public.bots
                             where owner_id = '${U.a}' and is_active and id = '${botId}'`)), 0,
      'it left the owner list');
    // The history it took part in is still readable — that is the whole point.
    await become(U.a);
    eq(Number(await scalar(`select count(*)::int from public.messages
                             where chat_id = '${generalChat}' and body = 'hello there'`)), 1);
  });
}
