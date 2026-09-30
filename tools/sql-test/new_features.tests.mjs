// =============================================================================
// tools/sql-test/new_features.tests.mjs
//
// The 00020–00025 surface: social graph, long-form video, shorts, communities
// and channels, the messaging upgrade, and the Stars economy.
//
// Kept in its own module so `run.mjs` stays readable: it receives the harness
// (test/group/eq/throws/exec/query/one/scalar/become/…) and the fixture user
// ids, and returns the list of tests it registered.
// =============================================================================

export async function registerNewFeatureTests(h) {
  const {
    test, group, eq, assert, throws, exec, query, one, scalar,
    become, becomeService, becomeOwner, U, rpc,
  } = h;

  // client_message_id is a uuid in the schema (it backs the dedupe index), so
  // the tests mint real ones instead of readable strings.
  let cmidSeq = 0;
  const cmid = () => `b0000000-0000-4000-8000-${String(++cmidSeq).padStart(12, '0')}`;
  const jsonLit = (value) => `'${JSON.stringify(value).replace(/'/g, "''")}'::jsonb`;

  const active = async (uid) => {
    await becomeOwner();
    await exec(`update public.profiles set access_state = 'active', access_state_reason = null where id = '${uid}'`);
  };

  // -------------------------------------------------------------------------
  group('social graph (00020)');
  // -------------------------------------------------------------------------
  await test('every profile gets a discriminator, unique per handle', async () => {
    await becomeOwner();
    eq(await scalar(`select count(*)::int from public.profiles where discriminator is null`), 0,
      'the trigger assigned one everywhere');
    const rows = await query(`select username_norm, discriminator, count(*)::int as n
                                from public.profiles group by 1, 2 having count(*) > 1`);
    eq(rows.length, 0, 'no duplicate handle#tag');
  });

  await test('following a public account is immediate and moves both counters', async () => {
    await active(U.a);
    await active(U.b);
    await become(U.a);
    eq(await scalar(`select public.follow_user('${U.b}', null)`), 'accepted');
    await becomeOwner();
    eq(await scalar(`select state::text from public.follows
                      where follower_id = '${U.a}' and followee_id = '${U.b}'`), 'accepted');
    await become(U.a);
    await becomeOwner();
    eq(Number(await scalar(`select follower_count from public.profiles where id = '${U.b}'`)), 1);
    eq(Number(await scalar(`select following_count from public.profiles where id = '${U.a}'`)), 1);

    await become(U.a);
    await exec(`select public.unfollow_user('${U.b}')`);
    await becomeOwner();
    eq(Number(await scalar(`select follower_count from public.profiles where id = '${U.b}'`)), 0, 'unfollow decrements');
  });

  await test('a private account turns a follow into a request', async () => {
    await becomeOwner();
    await exec(`update public.profiles set is_private = true where id = '${U.b}'`);

    await become(U.a);
    eq(await scalar(`select public.follow_user('${U.b}', null)`), 'pending');
    // A pending follower does not see a private profile's content.
    eq(await scalar(`select app.can_view_user('${U.a}', '${U.b}')`), false);
    eq(await scalar(`select public.profile_identity('${U.b}') is null`), true);

    await become(U.b);
    eq(Number(await scalar(`select count(*)::int from public.follow_list('${U.b}', 'requests', 50)`)), 1);
    await exec(`select public.respond_follow_request('${U.a}', true)`);
    eq(await scalar(`select app.can_view_user('${U.a}', '${U.b}')`), true, 'accepted request unlocks the profile');

    // Declining is sticky: the row survives as 'declined', so a repeat request
    // cannot ping the owner again and cannot flip back to accepted.
    await active(U.other);
    await become(U.other);
    eq(await scalar(`select public.follow_user('${U.b}', null)`), 'pending');
    await become(U.b);
    await exec(`select public.respond_follow_request('${U.other}', false)`);
    await become(U.other);
    eq(await scalar(`select public.follow_user('${U.b}', null)`), 'declined');
    await becomeOwner();
    eq(await scalar(`select state::text from public.follows
                      where follower_id = '${U.other}' and followee_id = '${U.b}'`), 'declined');
    eq(await scalar(`select app.can_view_user('${U.other}', '${U.b}')`), false, 'a decline is not access');

    // Unfollowing removes the edge outright, which is how a person resets.
    await become(U.a);
    await exec(`select public.unfollow_user('${U.b}')`);
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.follows
                             where follower_id = '${U.a}'`)), 0);
  });

  await test('blocking removes the follows in both directions and hides the profile', async () => {
    await becomeOwner();
    await exec(`update public.profiles set is_private = false where id = '${U.b}'`);
    await become(U.a);
    await exec(`select public.follow_user('${U.b}', null)`);
    await become(U.b);
    await exec(`select public.follow_user('${U.a}', null)`);
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.follows
                             where follower_id in ('${U.a}', '${U.b}')
                               and followee_id in ('${U.a}', '${U.b}')`)), 2, 'two edges exist');

    await become(U.a);
    await exec(`select public.block_user('${U.b}', 'one too many pings')`);
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.follows
                             where follower_id in ('${U.a}', '${U.b}')
                               and followee_id in ('${U.a}', '${U.b}')`)), 0,
      'the block cleaned the graph');
    eq(await scalar(`select app.can_view_user('${U.b}', '${U.a}')`), false, 'the blocked side cannot see back in');

    await become(U.a);
    await exec(`select public.unblock_user('${U.b}')`);
    eq(Number(await scalar(`select count(*)::int from public.blocks`)), 0);
  });

  await test('follow_user accepts a handle#tag and refuses self and strangers', async () => {
    await becomeOwner();
    const tag = await one(`select username, discriminator from public.profiles where id = '${U.b}'`);
    await become(U.a);
    eq(await scalar(`select public.follow_user(null, '${tag.username}#${tag.discriminator}')`), 'accepted');
    await throws(() => exec(`select public.follow_user('${U.a}', null)`), /cannot follow yourself/);
    await throws(() => exec(`select public.follow_user(null, 'nobody_here')`), /does not exist/);
    await become(U.a);
    await exec(`select public.unfollow_user('${U.b}')`);
  });

  await test('discriminator, verified and the counters are not client-writable', async () => {
    await become(U.a);
    await throws(() => exec(`update public.profiles set follower_count = 999 where id = '${U.a}'`), /server-managed/);
    await throws(() => exec(`update public.profiles set verified = true where id = '${U.a}'`), /server-managed/);
    await throws(() => exec(`update public.profiles set discriminator = 1 where id = '${U.a}'`), /server-managed/);
    // …while the fields a person owns stay editable.
    await exec(`update public.profiles set pronouns = 'they/them', location = 'Tashkent' where id = '${U.a}'`);
  });

  // -------------------------------------------------------------------------
  group('long-form video (00021)');
  // -------------------------------------------------------------------------
  let videoId = null;
  await test('publishing validates key ownership, the thumbnail rule and the caps', async () => {
    await active(U.a);
    await become(U.a);
    await throws(
      () => exec(`select public.publish_video('video/${U.b}/app/x.mp4', 'thumb/${U.a}/x.jpg', 'Stolen', null, 1000, 10)`),
      /does not belong to this account/,
    );
    await throws(
      () => exec(`select public.publish_video('video/${U.a}/app/x.mp4', null, 'No poster', null, 1000, 10, 'public')`),
      /needs a thumbnail/,
    );
    await throws(
      () => exec(`select public.publish_video('video/${U.a}/app/x.mp4', 'thumb/${U.a}/x.jpg', 'No duration')`),
      /verified duration/,
    );
    await throws(
      () => exec(`select public.publish_video('video/${U.a}/app/x.mp4', 'thumb/${U.a}/x.jpg', 'Bad category', null, 1000, 10, 'public', 'nope')`),
      /unknown category/,
    );
  });

  await test('publishing stores the row, derives hashtags and notifies subscribers', async () => {
    await become(U.b);
    await exec(`select public.follow_user('${U.a}', null)`);
    await become(U.a);
    videoId = await scalar(`select public.publish_video(
      'video/${U.a}/app/1700000001.mp4', 'thumb/${U.a}/1700000001.jpg',
      'Building a messenger in public', 'Episode one #supabase #flutter',
      240000, 18000000, 'public', 'technology', array['flutter','backend'],
      '[{"t": 0, "label": "Intro"}, {"t": 60000, "label": "The schema"}]'::jsonb)`);
    assert(videoId, 'a row id came back');

    const row = await one(`select title, duration_ms, thumbnail_key, visibility from public.videos where id = '${videoId}'`);
    eq(row.title, 'Building a messenger in public');
    eq(Number(row.duration_ms), 240000);

    const tags = await query(`select tag from public.video_hashtags where video_id = '${videoId}' order by tag`);
    eq(tags.map((t) => t.tag).join(','), 'backend,flutter,supabase', 'explicit + #tokens, normalised');
    eq(Number(await scalar(`select use_count from public.hashtags where tag = 'supabase'`)), 1);

    await become(U.b);
    eq(Number(await scalar(`select count(*)::int from public.notifications where user_id = '${U.b}' and kind = 'new_video'`)), 1,
      'the follower was notified');
  });

  await test('chapters must be ordered and well shaped', async () => {
    await become(U.a);
    await throws(
      () => exec(`select public.publish_video('video/${U.a}/app/2.mp4', 'thumb/${U.a}/2.jpg', 'Bad chapters', null,
                1000, 10, 'unlisted', null, '{}'::text[], '[{"t": 100, "label": "b"}, {"t": 50, "label": "a"}]'::jsonb)`),
      /strictly increasing/,
    );
  });

  await test('the feed respects visibility and the following tab', async () => {
    await become(U.b);
    const forYou = await rpc('public.video_feed', `'for_you', null, null, null, 24, null`);
    eq(forYou.length >= 1, true, 'the public video is in For You');
    const following = await rpc('public.video_feed', `'following', null, null, null, 24, null`);
    eq(following.length, 1, 'the followed author is in Following');

    // A stranger sees nothing on the Following tab and nothing private.
    await become(U.other);
    eq((await rpc('public.video_feed', `'following', null, null, null, 24, null`)).length, 0);

    await become(U.a);
    await exec(`select public.update_video('${videoId}', null, null, 'private')`);
    await become(U.other);
    await throws(() => exec(`select public.video_detail('${videoId}')`), /not available/);
    await become(U.a);
    await exec(`select public.update_video('${videoId}', null, null, 'public')`);
  });

  await test('likes and dislikes are one verdict per person', async () => {
    await become(U.b);
    eq(await scalar(`select public.rate_video('${videoId}', 'like')`), 'like');
    await becomeOwner();
    eq(Number(await scalar(`select like_count from public.videos where id = '${videoId}'`)), 1);

    await become(U.b);
    eq(await scalar(`select public.rate_video('${videoId}', 'dislike')`), 'dislike');
    await becomeOwner();
    const counts = await one(`select like_count, dislike_count from public.videos where id = '${videoId}'`);
    eq(Number(counts.like_count), 0, 'the like moved off');
    eq(Number(counts.dislike_count), 1, '…and onto the dislike');

    await become(U.b);
    eq(await scalar(`select public.rate_video('${videoId}', 'none')`), 'none');
    await becomeOwner();
    eq(Number(await scalar(`select dislike_count from public.videos where id = '${videoId}'`)), 0);
  });

  await test('views deduplicate per session and leave a resume point', async () => {
    await become(U.b);
    await exec(`select public.record_video_view('${videoId}', 'session-aaaaaa', 4000, 4000)`);
    await exec(`select public.record_video_view('${videoId}', 'session-aaaaaa', 9000, 9000)`);
    await exec(`select public.record_video_view('${videoId}', 'session-bbbbbb', 5000, 5000)`);
    await becomeOwner();
    eq(Number(await scalar(`select view_count from public.videos where id = '${videoId}'`)), 2,
      'two sessions, two views');

    await become(U.b);
    const progress = await one(`select * from public.watch_history(10)`);
    eq(Number(progress.position_ms), 9000, 'the later position of the same session won');
    await exec(`select public.clear_watch_history()`);
    eq(Number(await scalar(`select count(*)::int from public.watch_progress`)), 0);
  });

  await test('comments thread, count, like and pin — with the creator in charge', async () => {
    await become(U.b);
    const root = await scalar(`select public.comment_create('first!', '${videoId}', null, null)`);
    await become(U.other);
    const reply = await scalar(`select public.comment_create('nice work', '${videoId}', null, '${root}')`);
    await becomeOwner();
    eq(Number(await scalar(`select comment_count from public.videos where id = '${videoId}'`)), 1,
      'replies do not inflate the thread count');
    eq(Number(await scalar(`select reply_count from public.comments where id = '${root}'`)), 1);

    await become(U.other);
    const nested = await scalar(`select public.comment_create('replying to a reply', '${videoId}', null, '${reply}')`);
    eq(await scalar(`select parent_id = '${root}' from public.comments where id = '${nested}'`), true,
      'a reply to a reply attaches to the root thread');

    await exec(`select public.comment_like('${root}', true)`);
    await becomeOwner();
    eq(Number(await scalar(`select like_count from public.comments where id = '${root}'`)), 1);

    await become(U.b);
    await throws(() => exec(`select public.comment_pin('${root}', true)`), /only the creator/);
    await become(U.a);
    await exec(`select public.comment_pin('${root}', true)`);
    await exec(`select public.comment_heart('${root}', true)`);
    await become(U.other);
    const thread = await rpc('public.comment_thread', `'${videoId}', null, null, null, 20, 'top'`);
    eq(thread[0].is_pinned, true, 'the pinned comment sorts first');
    eq(thread[0].hearted_by_author, true, 'the heart renders');
    await throws(() => exec(`select public.comment_delete('${root}')`), /not allowed/);
    await exec(`select public.comment_delete('${nested}')`);
    eq(Number(await scalar(`select count(*)::int from public.comments where id = '${nested}'`)), 0,
      'authors delete their own comment for real');
  });

  await test('watch later is a system playlist that cannot be renamed away', async () => {
    await become(U.b);
    eq(await scalar(`select public.toggle_watch_later('${videoId}')`), true);
    const lists = await query(`select * from public.my_playlists()`);
    eq(lists.length, 1);
    eq(lists[0].system_slug, 'watch-later');
    eq(Number(lists[0].item_count), 1);
    // RLS filters rather than raising, so the proof is that nothing moved.
    const renamed = await query(`update public.playlists set title = 'mine now'
                                  where system_slug = 'watch-later' returning id`);
    eq(renamed.length, 0, 'a system playlist cannot be renamed');
    await becomeOwner();
    eq(await scalar(`select title from public.playlists where system_slug = 'watch-later' and owner_id = '${U.b}'`),
      'Watch later');
    await become(U.b);
    eq(await scalar(`select public.toggle_watch_later('${videoId}')`), false, 'toggling twice removes it');
    eq(Number(await scalar(`select save_count from public.videos where id = '${videoId}'`)), 0);
  });

  await test('video_detail returns the watch page in one call', async () => {
    await become(U.b);
    const detail = await scalar(`select public.video_detail('${videoId}')`);
    assert(detail && detail.video, 'the row is present');
    assert(Array.isArray(detail.up_next), 'up_next is an array');
    eq(detail.video.author_username !== null, true);
  });

  // -------------------------------------------------------------------------
  group('shorts (00022)');
  // -------------------------------------------------------------------------
  let shortId = null;
  let soundId = null;
  await test('sounds are created by their owner and counted when used', async () => {
    await become(U.a);
    soundId = await scalar(`select public.create_sound('Beat drop', 'sounds/${U.a}/beat.mp3', 30000, 400000)`);
    await throws(
      () => exec(`select public.create_sound('Stolen', 'sounds/${U.b}/x.mp3', 1000, 1000)`),
      /does not belong/,
    );
    await throws(
      () => exec(`select public.create_sound('AI take', 'sounds/${U.a}/ai.mp3', 1000, 1000, 'audio/mpeg', 'tts')`),
      /keeps its script/,
    );
  });

  await test('publishing a short validates the key, the caps and duet targets', async () => {
    await become(U.a);
    await throws(
      () => exec(`select public.publish_short('shorts/${U.b}/app/x.mp4', 12000, 900000)`),
      /does not belong/,
    );
    await throws(
      () => exec(`select public.publish_short('shorts/${U.a}/app/long.mp4', 61000, 900000)`),
      /between 0 and 60 seconds/,
    );
    await throws(
      () => exec(`select public.publish_short('shorts/${U.a}/app/duet.mp4', 12000, 900000, 'duet', 'public', null, 'duet')`),
      /needs the short it answers/,
    );

    shortId = await scalar(`select public.publish_short(
      'shorts/${U.a}/app/1700000002.mp4', 12000, 900000, 'first clip #launch', 'public', ${soundId ? `'${soundId}'` : 'null'})`);
    await becomeOwner();
    eq(Number(await scalar(`select use_count from public.sounds where id = '${soundId}'`)), 1,
      'attaching the sound moved its counter');
  });

  await test('the shorts feed answers every tab', async () => {
    await become(U.b);
    eq((await rpc('public.shorts_feed', `'for_you', null, null, 10, null, null`)).length, 1);
    await exec(`select public.unfollow_user('${U.a}')`);
    eq((await rpc('public.shorts_feed', `'following', null, null, 10, null, null`)).length, 0,
      'not following ⇒ nothing on the Following tab');
    await exec(`select public.follow_user('${U.a}', null)`);
    eq((await rpc('public.shorts_feed', `'following', null, null, 10, null, null`)).length, 1);
    eq((await rpc('public.shorts_feed', `'sound', null, null, 10, '${soundId}', null`)).length, 1);
    eq((await rpc('public.shorts_feed', `'profile', null, null, 10, null, '${U.a}'`)).length, 1);

    await exec(`select public.rate_short('${shortId}', 'save')`);
    eq((await rpc('public.shorts_feed', `'saved', null, null, 10, null, null`)).length, 1,
      'the saved tab is the caller own saves');
    await becomeOwner();
    eq(Number(await scalar(`select save_count from public.shorts where id = '${shortId}'`)), 1);
  });

  await test('likes toggle, counters move server-side, views deduplicate', async () => {
    await become(U.b);
    eq(await scalar(`select public.rate_short('${shortId}', 'like')`), true);
    eq(await scalar(`select public.rate_short('${shortId}', 'like')`), false, 'the second tap unlikes');
    eq(await scalar(`select public.rate_short('${shortId}', 'like')`), true);
    await becomeOwner();
    eq(Number(await scalar(`select like_count from public.shorts where id = '${shortId}'`)), 1);

    await become(U.b);
    await exec(`select public.record_short_view('${shortId}', 'watch-aaaaaa', 11000, true)`);
    await exec(`select public.record_short_view('${shortId}', 'watch-aaaaaa', 12000, true)`);
    await becomeOwner();
    eq(Number(await scalar(`select view_count from public.shorts where id = '${shortId}'`)), 1, 'one session, one view');
  });

  await test('a private short stays visible to its author only', async () => {
    await become(U.a);
    const hidden = await scalar(`select public.publish_short('shorts/${U.a}/app/hidden.mp4', 8000, 500000, 'draft', 'private')`);
    await become(U.b);
    eq((await rpc('public.shorts_feed', `'for_you', null, null, 10, null, null`)).length, 1, 'not in the feed');
    await throws(() => exec(`select public.rate_short('${hidden}', 'like')`), /not available/);
    await become(U.a);
    await exec(`select public.delete_short('${hidden}')`);
  });

  // -------------------------------------------------------------------------
  group('communities and channels (00023)');
  // -------------------------------------------------------------------------
  let communityId = null;
  let generalChannel = null;
  let privateChannel = null;
  let communityChatId = null;
  await test('creating a community bootstraps #general, a voice room and an @everyone role', async () => {
    await become(U.a);
    communityId = await scalar(`select public.community_create('Builders', 'builders', 'Ship things', true)`);
    const overview = await scalar(`select public.community_overview('${communityId}')`);
    eq(overview.community.joined, true);
    eq(overview.channels.length, 2, 'text + voice');
    eq(overview.roles.length, 1);
    eq(overview.roles[0].is_default, true);
    eq(overview.community.my_permissions > 0, true);
    eq(await scalar(`select (app.community_permissions('${communityId}', '${U.a}') & app.perm_administrator()) <> 0`), true,
      'the owner is an administrator');

    const text = overview.channels.find((c) => c.kind === 'text');
    communityChatId = text.chat_id;
    generalChannel = text.id;
  });

  await test('a member joins by invite, gets @everyone, and can talk in #general', async () => {
    await become(U.a);
    const code = await scalar(`select public.community_invite_create('${communityId}', 5, 24)`);
    await become(U.b);
    eq(await scalar(`select public.community_join(null, null, '${code}')`), communityId);
    eq(await scalar(`select (app.channel_permissions('${generalChannel}', '${U.b}') & app.perm_send_messages()) <> 0`), true);

    await exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                values ('${communityChatId}', '${U.b}', 'text', 'hello builders', '${cmid()}')`);
    eq(Number(await scalar(`select count(*)::int from public.messages where chat_id = '${communityChatId}'`)), 1);
  });

  await test('a private channel is invisible without permission and a deny overwrite locks a role out', async () => {
    await become(U.a);
    privateChannel = await scalar(`select public.community_channel_create('${communityId}', 'staff-room', 'text', null, null, true)`);
    const privateChat = await scalar(`select chat_id from public.community_channels where id = '${privateChannel}'`);

    await become(U.b);
    const overview = await scalar(`select public.community_overview('${communityId}')`);
    eq(overview.channels.some((c) => c.id === '${privateChannel}'), false, 'the private channel is not in the list');
    await throws(
      () => exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                  values ('${privateChat}', '${U.b}', 'text', 'sneaking in', '${cmid()}')`),
      /permission/,
    );

    // Explicit role overwrite: deny SEND_MESSAGES for @everyone on #general.
    await becomeOwner();
    const everyone = await one(`select id from public.community_roles where community_id = '${communityId}' and is_default`);
    await become(U.a);
    await exec(`select public.community_overwrite_set('${generalChannel}', 'role', '${everyone.id}', 0, 1::bigint << 2)`);
    await become(U.b);
    await throws(
      () => exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                  values ('${communityChatId}', '${U.b}', 'text', 'still talking', '${cmid()}')`),
      /do not have permission/,
    );
    await become(U.a);
    await exec(`select public.community_overwrite_set('${generalChannel}', 'role', '${everyone.id}', 0, 0)`);
  });

  await test('slowmode is timed against the sender own last message', async () => {
    await become(U.a);
    await exec(`select public.community_channel_update('${generalChannel}', null, null, null, null, 300)`);
    // U.b posted in this channel seconds ago, so the window still applies.
    await become(U.b);
    await throws(
      () => exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                  values ('${communityChatId}', '${U.b}', 'text', 'too soon', '${cmid()}')`),
      /slowmode/,
    );
    // A moderator (MANAGE_MESSAGES) is exempt — that is what makes slowmode a
    // moderation tool rather than a wall for everyone.
    await become(U.a);
    await exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                values ('${communityChatId}', '${U.a}', 'text', 'moderator here', '${cmid()}')`);
    await exec(`select public.community_channel_update('${generalChannel}', null, null, null, null, 0)`);
    await become(U.b);
    await exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                values ('${communityChatId}', '${U.b}', 'text', 'after the window', '${cmid()}')`);
    eq(Number(await scalar(`select count(*)::int from public.messages
                             where chat_id = '${communityChatId}' and sender_id = '${U.b}'`)), 2,
      'the first "hello builders" and the post after the window');
  });

  await test('mute, kick and ban each land, and a ban survives a re-invite', async () => {
    await become(U.a);
    await exec(`select public.community_member_moderate('${communityId}', '${U.b}', 'mute', 'too loud', 10)`);
    await become(U.b);
    await throws(
      () => exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                  values ('${communityChatId}', '${U.b}', 'text', 'muted?', '${cmid()}')`),
      /muted/,
    );

    await become(U.a);
    await exec(`select public.community_member_moderate('${communityId}', '${U.b}', 'unmute')`);
    await exec(`select public.community_member_moderate('${communityId}', '${U.b}', 'ban', 'spam')`);
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.community_bans where community_id = '${communityId}'`)), 1);
    eq(Number(await scalar(`select count(*)::int from public.community_members where community_id = '${communityId}' and user_id = '${U.b}'`)), 0);

    await become(U.a);
    const code = await scalar(`select public.community_invite_create('${communityId}', 0, 1)`);
    await become(U.b);
    await throws(() => exec(`select public.community_join(null, null, '${code}')`), /banned/);

    await become(U.a);
    await exec(`select public.community_member_moderate('${communityId}', '${U.b}', 'unban')`);
    await become(U.b);
    await exec(`select public.community_join('${communityId}', null, null)`);
  });

  await test('roles are managed, assigned, and cannot be escalated by a non-admin', async () => {
    await become(U.a);
    const modRole = await scalar(`select public.community_role_create('${communityId}', 'Moderator', '#ff5500',
      (1::bigint << 3) | (1::bigint << 14))`);
    await exec(`select public.community_member_set_roles('${communityId}', '${U.b}', array['${modRole}']::uuid[])`);
    eq(await scalar(`select (app.community_permissions('${communityId}', '${U.b}') & app.perm_moderate_members()) <> 0`), true);

    await become(U.b);
    await throws(
      () => exec(`select public.community_role_create('${communityId}', 'Sneaky', '#000000', 1::bigint << 0)`),
      /may not manage roles/,
    );

    await become(U.a);
    await exec(`select public.community_role_delete('${modRole}')`);
  });

  await test('broadcast channels: post policy, subscribers, directory', async () => {
    await become(U.a);
    const chatId = await scalar(`select public.channel_create('Release notes', 'messengerx_news', 'What shipped', true, 'admins')`);
    eq(Number(await scalar(`select subscriber_count from public.chats where id = '${chatId}'`)), 1, 'the owner counts');

    await become(U.b);
    const joined = await scalar(`select public.channel_join(null, '@messengerx_news')`);
    eq(joined, chatId);
    await becomeOwner();
    eq(Number(await scalar(`select subscriber_count from public.chats where id = '${chatId}'`)), 2);

    await become(U.b);
    await throws(
      () => exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                  values ('${chatId}', '${U.b}', 'text', 'let me post', '${cmid()}')`),
      /only the channel admin/,
    );
    await become(U.a);
    await exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                values ('${chatId}', '${U.a}', 'text', 'v3.0 is out', '${cmid()}')`);

    await become(U.b);
    const directory = await rpc('public.channel_directory', `null, 20`);
    eq(directory.length >= 1, true, 'the channel is discoverable');
    eq(directory[0].joined, true);
    eq(Number(await scalar(`select public.mark_channel_views('${chatId}', array[(select id from public.messages where chat_id = '${chatId}' limit 1)]::uuid[])`)), 1);

    await become(U.a);
    await exec(`select public.channel_set_role('${chatId}', '${U.b}', 'admin')`);
    await become(U.b);
    await exec(`insert into public.messages (chat_id, sender_id, kind, body, client_message_id)
                values ('${chatId}', '${U.b}', 'text', 'an admin may post', '${cmid()}')`);
    await exec(`select public.channel_leave('${chatId}')`);
    await becomeOwner();
    eq(Number(await scalar(`select subscriber_count from public.chats where id = '${chatId}'`)), 1);
  });

  // -------------------------------------------------------------------------
  group('messaging upgrade (00024)');
  // -------------------------------------------------------------------------
  let chatId = null;
  let messageId = null;
  await test('a direct chat is created for the messaging tests', async () => {
    await become(U.a);
    chatId = await scalar(`select public.create_direct_chat('${U.b}', null)`);
    messageId = await scalar(`select id from public.messages where chat_id = '${chatId}' limit 1`);
    if (!messageId) {
      await exec(`select public.send_message('${chatId}', 'text', 'hello there', null, null, '${cmid()}')`);
      messageId = await scalar(`select id from public.messages where chat_id = '${chatId}' limit 1`);
    }
    assert(chatId && messageId, 'chat and message exist');
  });

  await test('reactions toggle per person and aggregate per emoji', async () => {
    await become(U.a);
    const target = await scalar(`select (public.send_message('${chatId}', 'text', 'react to this', null, null, '${cmid()}')).id`);
    await become(U.b);
    eq(Number(await scalar(`select public.react_message('${target}', '🔥')`)), 1, 'one reaction on the message');
    eq(Number(await scalar(`select public.react_message('${target}', '🔥')`)), 0, 'tapping again removes it');
    await exec(`select public.react_message('${target}', '🔥')`);
    await exec(`select public.react_message('${target}', '👍')`);

    const grouped = await rpc('public.chat_reactions', `'${chatId}', array['${target}']::uuid[]`);
    eq(grouped.length, 2, 'two emoji, one row each');
    eq(grouped.every((r) => r.count === 1), true);
    eq(grouped.every((r) => r.mine === true), true);
    eq(Number(await scalar(`select reaction_count from public.messages where id = '${target}'`)), 2);

    await throws(() => exec(`select public.react_message('${target}', 'xxxxxxxxxxxxxxxxxxxxxxxx')`), /pick one emoji/);

    // The palette the composer renders is the server's own list.
    eq(await scalar(`select array_length(app.reaction_palette(), 1) >= 8`), true);
    // A reaction on somebody else's message notifies its sender.
    await becomeOwner();
    eq(Number(await scalar(`select count(*)::int from public.notifications
                             where user_id = '${U.a}' and kind = 'mention'
                               and payload->>'message_id' = '${target}'`)), 3,
      'each reaction insert pings the sender (the re-added flame counts again)');
  });

  await test('replies thread, pins are admin-only, edits keep history', async () => {
    await become(U.b);
    const reply = await scalar(`select (public.send_message('${chatId}', 'text', 'replying to you', null, '${messageId}', '${cmid()}')).id`);
    await becomeOwner();
    eq(Number(await scalar(`select reply_count from public.messages where id = '${messageId}'`)), 1);

    await become(U.b);
    await throws(() => exec(`select public.pin_message('${reply}', true)`), /only an admin/);
    await exec(`update public.messages set body = 'replying to you (edited)' where id = '${reply}' and sender_id = '${U.b}'`);
    await becomeOwner();
    eq(Number(await scalar(`select edited_count from public.messages where id = '${reply}'`)), 1);
    eq(await scalar(`select body from public.message_edits where message_id = '${reply}'`), 'replying to you',
      'the previous body is retained');
  });

  await test('forwarding copies the message into the chosen chat', async () => {
    await become(U.a);
    const copied = await scalar(`select public.forward_message('${messageId}', array['${communityChatId}']::uuid[])`);
    eq(Number(copied), 1);
    await becomeOwner();
    eq(await scalar(`select forwarded_from_message_id from public.messages
                      where chat_id = '${communityChatId}' and forwarded_from_message_id is not null limit 1`),
      messageId);
  });

  await test('mentions resolve server-side into rows and notifications', async () => {
    await becomeOwner();
    const handle = await scalar(`select username from public.profiles where id = '${U.b}'`);
    await become(U.a);
    const mid = cmid();
    await exec(`select public.send_message('${chatId}', 'text', 'ping @${handle} about the release', null, null, '${mid}')`);
    await becomeOwner();
    const mentioned = await one(`select m.user_id from public.message_mentions m
                                  join public.messages msg on msg.id = m.message_id
                                 where msg.client_message_id = '${mid}'`);
    eq(mentioned.user_id, U.b, 'the @handle resolved to the right account');
  });

  await test('polls: vote, switch, multi-answer and quiz grading', async () => {
    await become(U.a);
    const regular = await scalar(`select public.poll_create('${chatId}', 'Ship on Friday?',
      array['yes','no','maybe'], 'regular', true, false, null, null, null, '${cmid()}')`);
    await become(U.b);
    const results = await scalar(`select public.poll_results((select id from public.polls where message_id = '${regular}'))`);
    eq(results.total_votes, 0);
    const pollId = await scalar(`select id from public.polls where message_id = '${regular}'`);
    const optionIds = (await query(`select id from public.poll_options where poll_id = '${pollId}' order by position`)).map((r) => r.id);

    await exec(`select public.poll_vote('${pollId}', array['${optionIds[0]}']::uuid[])`);
    eq(Number(await scalar(`select total_votes from public.polls where id = '${pollId}'`)), 1);
    // Voting again replaces the previous answer rather than stacking.
    await exec(`select public.poll_vote('${pollId}', array['${optionIds[1]}']::uuid[])`);
    const after = await scalar(`select public.poll_results('${pollId}')`);
    eq(after.total_votes, 1, 'still one vote');
    eq(after.options[0].votes, 0, 'the first option lost the vote');
    eq(after.my_options[0], optionIds[1]);
    eq(after.options[0].voters === null || after.options[0].voters.length === 0, true, 'anonymous polls hide voters');

    await throws(
      () => exec(`select public.poll_vote('${pollId}', array['${optionIds[0]}','${optionIds[1]}']::uuid[])`),
      /one answer/,
    );

    await become(U.a);
    const quiz = await scalar(`select public.poll_create('${chatId}', 'Which year?',
      array['2026','2025'], 'quiz', false, false, 0, 'It is 2026.', null, '${cmid()}')`);
    const quizId = await scalar(`select id from public.polls where message_id = '${quiz}'`);
    const quizOptions = (await query(`select id from public.poll_options where poll_id = '${quizId}' order by position`)).map((r) => r.id);
    await become(U.b);
    eq(await scalar(`select public.poll_vote('${quizId}', array['${quizOptions[0]}']::uuid[])`), true, 'the right answer');
    await exec(`select public.poll_vote('${quizId}', array['${quizOptions[1]}']::uuid[])`);
    eq(await scalar(`select public.poll_vote('${quizId}', array['${quizOptions[1]}']::uuid[])`), false, 'the wrong one');
  });

  await test('folders, archive and saved messages behave like the real thing', async () => {
    await become(U.b);
    const folder = await scalar(`select public.chat_folder_save(null, 'Direct', '💬',
      '{"kinds": ["direct"]}'::jsonb, 0)`);
    const counts = await query(`select * from public.chat_folders_with_counts()`);
    eq(counts.length, 1);
    eq(counts[0].title, 'Direct');
    eq(Number(counts[0].chat_count) >= 1, true, 'the direct chat is in the folder');

    await exec(`select public.set_chat_archived('${chatId}', true)`);
    await becomeOwner();
    eq(await scalar(`select archived_at is not null from public.chat_participants
                      where chat_id = '${chatId}' and user_id = '${U.b}'`), true);

    await become(U.b);
    const saved = await scalar(`select public.saved_chat()`);
    await becomeOwner();
    eq(await scalar(`select is_saved from public.chats where id = '${saved}'`), true);
    eq(Number(await scalar(`select count(*)::int from public.chat_participants where chat_id = '${saved}'`)), 1,
      'Saved Messages is a one-participant chat');
    await become(U.b);
    eq(await scalar(`select public.saved_chat()`), saved, 'asking twice returns the same chat');

    await exec(`select public.chat_folder_delete('${folder}')`);
    await exec(`select public.set_chat_archived('${chatId}', false)`);
  });

  await test('scheduled sends are leased, sent once, and cancellable', async () => {
    await become(U.b);
    const due = await scalar(`select public.schedule_message('${chatId}', 'scheduled hello',
      clock_timestamp() + interval '40 seconds', 'text', null, null, '${cmid()}')`);
    await becomeOwner();
    await exec(`update public.scheduled_messages set scheduled_for = clock_timestamp() - interval '1 second' where id = '${due}'`);

    await become(U.b);
    const claimed = await rpc('app.claim_scheduled_messages', `'test-worker', 5, 60`);
    eq(claimed.length, 1, 'the due row was leased');
    const sentId = await scalar(`select app.send_scheduled_message('${due}')`);
    assert(sentId, 'the message was created');
    await becomeOwner();
    eq(await scalar(`select state from public.scheduled_messages where id = '${due}'`), 'sent');
    eq(await scalar(`select body from public.messages where id = '${sentId}'`), 'scheduled hello');

    await become(U.b);
    const cancelled = await scalar(`select public.schedule_message('${chatId}', 'never mind',
      clock_timestamp() + interval '60 seconds', 'text', null, null, '${cmid()}')`);
    await exec(`select public.cancel_scheduled_message('${cancelled}')`);
    eq(Number(await scalar(`select count(*)::int from public.scheduled_messages_list()`)), 0);
  });

  await test('disappearing messages expire on the sweep', async () => {
    await become(U.a);
    await exec(`select public.set_chat_ttl('${chatId}', 3600)`);
    const ttlMid = cmid();
    await exec(`select public.send_message('${chatId}', 'text', 'this will vanish', null, null, '${ttlMid}')`);
    await becomeOwner();
    eq(await scalar(`select expires_at is not null from public.messages where client_message_id = '${ttlMid}'`), true);
    await exec(`update public.messages set expires_at = clock_timestamp() - interval '1 second'
                 where client_message_id = '${ttlMid}'`);
    await become(U.a);
    eq(Number(await scalar(`select public.sweep_expiring_messages(100)`)), 1);
    await exec(`select public.set_chat_ttl('${chatId}', null)`);
  });

  // -------------------------------------------------------------------------
  group('stars, tags and payments (00025)');
  // -------------------------------------------------------------------------
  await test('a wallet starts empty and no client role may write the ledger', async () => {
    await become(U.a);
    const wallet = await scalar(`select public.wallet_summary()`);
    eq(Number(wallet.balance), 0);
    await throws(
      () => exec(`insert into public.star_ledger (user_id, delta, reason) values ('${U.a}', 100000, 'purchase')`),
      /permission denied/i,
    );
    await throws(
      () => exec(`update public.star_wallets set balance = 999999 where user_id = '${U.a}'`),
      /permission denied/i,
    );
    await throws(
      () => exec(`select app.stars_credit('${U.a}', 500, 'purchase')`),
      /permission denied/i,
    );
  });

  await test('a paid Stripe session credits stars and the tag entitlement exactly once', async () => {
    await becomeService();
    const pending = await scalar(`select public.payment_create_pending('${U.a}', 'tag.custom', 'cs_test_tag_1', 249,
      '{"sku": "tag.custom", "user_id": "${U.a}"}'::jsonb)`);
    assert(pending, 'a pending payment row exists');

    const event = {
      id: 'evt_test_tag_1',
      type: 'checkout.session.completed',
      data: {
        object: {
          id: 'cs_test_tag_1',
          payment_intent: 'pi_test_1',
          amount_total: 249,
          metadata: { sku: 'tag.custom', user_id: U.a },
        },
      },
    };
    const settled = await scalar(`select public.payment_settle(${jsonLit(event)})`);
    eq(settled.ok, true);
    eq(settled.stars_granted, 0, 'the tag product grants a credit, not stars');

    // The same event redelivered must not pay twice.
    const replay = await scalar(`select public.payment_settle(${jsonLit(event)})`);
    eq(replay.duplicate, true);
    eq(Number(await scalar(`select remaining from public.user_entitlements
                              where user_id = '${U.a}' and entitlement = 'tag_mint'`)), 1);
  });

  await test('minting a tag spends the credit, sanitises the text, and renders publicly', async () => {
    await become(U.a);
    const tagId = await scalar(`select public.mint_tag('[grand] 🔥', '{}'::jsonb, null, '🔥', 0)`);
    await becomeOwner();
    const tag = await one(`select text, emoji from public.profile_tags where id = '${tagId}'`);
    eq(tag.text, 'GRAND', 'brackets stripped, upper-cased');
    eq(tag.emoji, '🔥');

    await become(U.a);
    eq(Number(await scalar(`select remaining from public.user_entitlements
                             where user_id = '${U.a}' and entitlement = 'tag_mint'`)), 0, 'the credit was consumed');

    const identity = await scalar(`select public.profile_identity('${U.a}')`);
    eq(identity.tags.length, 1);
    eq(identity.tags[0].text, 'GRAND');
    eq(identity.discriminator !== null, true);
  });

  await test('a second tag costs stars at the advertised rate', async () => {
    await become(U.a);
    // 20 Stars per dollar, $2.49 product ⇒ 49 Stars (floor of 249*20/100).
    await throws(() => exec(`select public.mint_tag('PAID', '{}'::jsonb, null, null, 1)`), /not enough stars/);

    await becomeService();
    await exec(`select app.stars_credit('${U.a}', 100, 'purchase', 'test', 'seed')`);
    await become(U.a);
    await exec(`select public.mint_tag('paid', '{}'::jsonb, null, null, 1)`);
    await becomeOwner();
    eq(Number(await scalar(`select balance from public.star_wallets where user_id = '${U.a}'`)), 51,
      '100 - 49 Stars');
    eq(Number(await scalar(`select count(*)::int from public.star_ledger where user_id = '${U.a}' and reason = 'tag_mint'`)), 1);
    // The ledger is the truth: the wallet equals the sum of its rows.
    eq(await scalar(`select balance = (select sum(delta) from public.star_ledger where user_id = '${U.a}')
                       from public.star_wallets where user_id = '${U.a}'`), true);
  });

  await test('cosmetics are bought with stars and equipped one per kind', async () => {
    await becomeService();
    await exec(`select app.stars_credit('${U.b}', 500, 'purchase', 'test', 'seed')`);
    await become(U.b);
    const item = await scalar(`select public.cosmetic_buy('tag.grand')`);
    assert(item, 'bought');
    eq(Number(await scalar(`select balance from public.star_wallets where user_id = '${U.b}'`)), 425, '75 Stars spent');
    await exec(`select public.cosmetic_buy('tag.grand')`);
    eq(Number(await scalar(`select balance from public.star_wallets where user_id = '${U.b}'`)), 425,
      'buying again is idempotent, not a double charge');
    await exec(`select public.cosmetic_equip('${item}', true)`);
    await becomeOwner();
    eq(await scalar(`select equipped from public.user_cosmetics where user_id = '${U.b}' and cosmetic_id = '${item}'`), true);
  });

  await test('gifts move stars between wallets and refuse nonsense', async () => {
    await become(U.b);
    await throws(() => exec(`select public.gift_send('${U.b}', 10)`), /cannot gift yourself/);
    await throws(() => exec(`select public.gift_send('${U.a}', 1000000)`), /between 1 and 100000|not enough stars/);

    const giftId = await scalar(`select public.gift_send('${U.a}', 50, 'tip', '${videoId}', null, null, null, 'great video', false)`);
    assert(giftId, 'the gift landed');
    await becomeOwner();
    eq(Number(await scalar(`select balance from public.star_wallets where user_id = '${U.b}'`)), 375);
    eq(Number(await scalar(`select balance from public.star_wallets where user_id = '${U.a}'`)), 101);
    eq(Number(await scalar(`select sum(stars) from public.gifts where recipient_id = '${U.a}'`)), 50);

    await become(U.a);
    const received = await rpc('public.gifts_received', `10`);
    eq(received.length, 1);
    eq(received[0].sender_username, 'dilnoza_rustamova');
    const wallet = await scalar(`select public.wallet_summary()`);
    eq(Number(wallet.earned_from_gifts), 50);
  });

  await test('an anonymous gift hides the sender but still pays', async () => {
    await become(U.b);
    await exec(`select public.gift_send('${U.a}', 25, 'gift', null, null, null, null, null, true)`);
    await become(U.a);
    const received = await rpc('public.gifts_received', `10`);
    const anon = received.find((g) => Number(g.stars) === 25);
    eq(anon.is_anonymous, true);
    eq(anon.sender_username, null, 'the sender is not exposed');
    eq(anon.sender_name, 'Anonymous');
  });

  await test('payouts are requested against a real balance and audited', async () => {
    await becomeService();
    await exec(`select app.stars_credit('${U.a}', 2000, 'purchase', 'test', 'payout-seed')`);
    await become(U.a);
    const before = Number(await scalar(`select balance from public.star_wallets where user_id = '${U.a}'`));
    await throws(() => exec(`select public.payout_request(100, 'bank')`), /minimum payout/);
    const request = await scalar(`select public.payout_request(1000, 'wise: me@example.com')`);
    assert(request, 'a request row exists');
    await becomeOwner();
    eq(await scalar(`select state from public.payout_requests where id = '${request}'`), 'requested');
    eq(Number(await scalar(`select balance from public.star_wallets where user_id = '${U.a}'`)), before - 1000,
      'the Stars are held, not spendable twice');
    eq(await scalar(`select balance = (select sum(delta) from public.star_ledger where user_id = '${U.a}')
                       from public.star_wallets where user_id = '${U.a}'`), true, 'the ledger still reconciles');
    await become(U.a);
    eq(Number((await query(`select * from public.payout_requests_list()`)).length), 1);
  });
}
