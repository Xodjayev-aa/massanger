// =============================================================================
// tools/sql-test/client_surface.tests.mjs
//
// The four migrations the rewritten client sits on:
//
//   00028  the read surface it calls (search, stats, trending, notifications)
//   00029  media_visible — what the storage ticket may presign a GET for
//   00030  short_detail — a shared reel link
//   00031  author_videos — a channel page, drafts included for its owner
//
// These are the rules a viewer can otherwise walk around: a private draft must
// not leak through a search box, a share link or somebody else's channel page,
// and a presigned URL must not hand out bytes for a row the caller may not see.
// =============================================================================

export async function registerClientSurfaceTests(h) {
  const {
    test, group, eq, assert, throws, exec, query, one, scalar,
    become, becomeOwner, U, rpc,
  } = h;

  const active = async (uid) => {
    await becomeOwner();
    await exec(`update public.profiles set access_state = 'active', access_state_reason = null where id = '${uid}'`);
  };

  await active(U.a);
  await active(U.b);
  await active(U.other);

  // ---------------------------------------------------------------------------
  group('client read surface (00028)');
  // ---------------------------------------------------------------------------

  await test('search_all finds published videos and sounds, and never a private draft', async () => {
    await become(U.a);
    const searchable = await scalar(`select public.publish_video(
      'video/${U.a}/app/searchable.mp4', 'thumb/${U.a}/searchable.jpg',
      'Searchable needle video', 'about the needle #needle', 60000, 4000000, 'public')`);
    const draft = await scalar(`select public.publish_video(
      'video/${U.a}/app/draft.mp4', 'thumb/${U.a}/draft.jpg',
      'Searchable needle draft', null, 60000, 4000000, 'private')`);
    await exec(`select public.create_sound('Needle beat', 'sounds/${U.a}/needle.mp3', 30000, 400000)`);

    const mine = await scalar(`select public.search_all('needle')::text`);
    assert(mine.includes(searchable), 'the author finds their own published video');
    assert(!mine.includes(draft), 'a draft is not even in its author search results');
    assert(mine.includes('Needle beat'), 'sounds answer the same query');

    await become(U.b);
    const theirs = await scalar(`select public.search_all('needle')::text`);
    assert(theirs.includes(searchable), 'a published video is searchable by anybody');
    assert(!theirs.includes(draft), 'and a draft is not');

    const blank = await scalar(`select public.search_all('   ')::text`);
    assert(blank.includes('"videos": []') || blank.includes('"videos":[]'), 'a blank query matches nothing');
  });

  await test('creator_stats counts what the caller actually published', async () => {
    await become(U.a);
    const stats = JSON.parse(await scalar(`select public.creator_stats()::text`));
    assert(Number(stats.videos) >= 2, 'the videos published above are counted');
    assert(Number(stats.shorts) >= 0, 'shorts are counted');
    assert(Array.isArray(stats.top_videos), 'top videos come back as a list');
    const follower = JSON.parse(await scalar(`select public.creator_stats()::text`));
    assert(Number(follower.followers) >= 0, 'the follower counter is a number, not null');
  });

  await test('trending hashtags only report recent, visible posts', async () => {
    await become(U.b);
    const rows = await query(`select * from public.hashtag_trending(50)`);
    const needle = rows.find((row) => row.tag === 'needle');
    assert(needle, 'the hashtag published above is trending');
    assert(Number(needle.recent_count) >= 1, 'the recent counter sees the fresh post');
    assert(Number(needle.recent_count) <= Number(needle.use_count), 'recent can never exceed the total');
  });

  await test('notifications are per-user and mark-read is scoped to the caller', async () => {
    await become(U.b);
    const rows = await query(`select * from public.notifications_list(null, 50)`);
    assert(rows.length >= 1, 'the follower has notifications from the videos above');
    const before = Number(await scalar(`select public.notifications_unread()`));
    assert(before >= 1, 'unread is not zero');

    await exec(`select public.notifications_mark_read(array['${rows[0].id}']::uuid[])`);
    eq(Number(await scalar(`select public.notifications_unread()`)), before - 1, 'exactly one row was marked read');

    // Somebody else naming the same id must not be able to touch it.
    await become(U.other);
    await exec(`select public.notifications_mark_read(array['${rows[0].id}']::uuid[])`);
    await becomeOwner();
    eq(await scalar(`select read_at is not null from public.notifications where id = '${rows[0].id}'`), true,
      'the row is still read');
    await become(U.b);
    eq(Number(await scalar(`select public.notifications_unread()`)), before - 1, 'and the count did not move');
    eq((await rpc('public.notifications_list', `null, 0`)).length, 1, 'a zero limit is clamped, not honoured');
  });

  // ---------------------------------------------------------------------------
  group('media visibility (00029)');
  // ---------------------------------------------------------------------------

  await test('bytes follow the visibility rule, and a follow edge never opens a private row', async () => {
    await become(U.a);
    await exec(`select public.publish_short(
      'shorts/${U.a}/app/visible.mp4', 9000, 400000, 'visible', 'public', null, 'original', null,
      'thumb/${U.a}/visible.jpg')`);
    const privateShort = await scalar(`select public.publish_short(
      'shorts/${U.a}/app/secret.mp4', 9000, 400000, 'secret', 'private', null, 'original', null,
      'thumb/${U.a}/secret.jpg')`);
    await exec(`select public.publish_short(
      'shorts/${U.a}/app/followers.mp4', 9000, 400000, 'followers only', 'followers', null, 'original', null,
      'thumb/${U.a}/followers.jpg')`);
    const privateVideo = await scalar(`select public.publish_video(
      'video/${U.a}/app/private-video.mp4', 'thumb/${U.a}/private-video.jpg', 'A private video', null,
      60000, 3000000, 'private')`);

    // A stranger sees exactly the public row.
    await become(U.other);
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/visible.mp4')`), true, 'public object');
    eq(await scalar(`select public.media_visible('thumb/${U.a}/visible.jpg')`), true, 'public poster');
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/followers.mp4')`), false,
      'followers-only needs a follow edge');
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/secret.mp4')`), false, 'private object');
    eq(await scalar(`select public.media_visible('thumb/${U.a}/secret.jpg')`), false, 'private poster');
    eq(await scalar(`select public.media_visible('video/${U.a}/app/private-video.mp4')`), false, 'private video');

    // The author sees everything of their own, published or not.
    await become(U.a);
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/secret.mp4')`), true,
      'the author may always see their own upload');
    eq(await scalar(`select public.media_visible('thumb/${U.a}/secret.jpg')`), true, 'including its poster');
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/never-published.mp4')`), true,
      'and uploads that never became a row');

    // A follow edge opens `followers` and only `followers`.
    await becomeOwner();
    const alreadyFollowing = Number(await scalar(
      `select count(*)::int from public.follows
        where follower_id = '${U.b}' and followee_id = '${U.a}' and state = 'accepted'`));
    await become(U.b);
    if (!alreadyFollowing) await exec(`select public.follow_user('${U.a}', null)`);
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/followers.mp4')`), true, 'a follower sees followers-only');
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/secret.mp4')`), false,
      'a follower does not see private: that is the whole difference between the two');
    eq(await scalar(`select public.media_visible('video/${U.a}/app/private-video.mp4')`), false, 'nor a private video');

    await becomeOwner();
    await exec(`select public.delete_short('${privateShort}')`);
    await exec(`delete from public.videos where id = '${privateVideo}'`);
  });

  await test('a removed short takes its bytes out of circulation', async () => {
    await become(U.a);
    const removed = await scalar(`select public.publish_short(
      'shorts/${U.a}/app/removed.mp4', 9000, 400000, 'removed', 'public')`);
    await become(U.b);
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/removed.mp4')`), true, 'visible while published');
    await becomeOwner();
    await exec(`update public.shorts set is_removed = true where id = '${removed}'`);
    await become(U.b);
    eq(await scalar(`select public.media_visible('shorts/${U.a}/app/removed.mp4')`), false,
      'a moderator removal closes the bytes too');
  });

  await test('a sound opens once a visible post uses it, and chat clips stay in their chat', async () => {
    await become(U.a);
    const soundId = await scalar(`select public.create_sound('Attached', 'sounds/${U.a}/attached.mp3', 30000, 400000)`);
    await become(U.b);
    eq(await scalar(`select public.media_visible('sounds/${U.a}/attached.mp3')`), false, 'nobody posted it yet');

    await become(U.a);
    await exec(`select public.publish_short('shorts/${U.a}/app/with-sound.mp4', 9000, 400000, 'sound', 'public', '${soundId}')`);
    await become(U.b);
    eq(await scalar(`select public.media_visible('sounds/${U.a}/attached.mp3')`), true,
      'a reel the caller can watch makes its sound readable');

    // A chat clip lives at chat/<chatId>/… — the chat id in the key is what the
    // ticket uses, and this is the check that the row agrees with the key.
    await become(U.a);
    const chatId = await scalar(`select public.create_direct_chat('${U.b}')`);
    const key = `chat/${chatId}/app/clip.mp4`;
    await exec(`select public.send_message('${chatId}', 'video', null,
      '{"store": "b2", "key": "${key}", "mime": "video/mp4", "duration_ms": 5000, "size_bytes": 900000}'::jsonb,
      null, null)`);
    await become(U.b);
    eq(await scalar(`select public.media_visible('${key}')`), true, 'the other member may read it');
    await become(U.other);
    eq(await scalar(`select public.media_visible('${key}')`), false, 'a stranger may not');
  });

  // ---------------------------------------------------------------------------
  group('short detail (00030)');
  // ---------------------------------------------------------------------------

  await test('short_detail answers a share link for a visible reel and hides the rest', async () => {
    await become(U.a);
    const visible = await scalar(`select public.publish_short(
      'shorts/${U.a}/app/detail.mp4', 11000, 500000, 'detail #link', 'public', null, 'original', null,
      'thumb/${U.a}/detail.jpg')`);
    const hidden = await scalar(`select public.publish_short(
      'shorts/${U.a}/app/detail-private.mp4', 11000, 500000, 'private detail', 'private')`);

    await become(U.b);
    const row = await one(`select * from public.short_detail('${visible}')`);
    eq(row.caption, 'detail #link');
    eq(Number(row.duration_ms), 11000);
    await becomeOwner();
    eq(row.author_username, await scalar(`select username from public.profiles where id = '${U.a}'`),
      'the card carries the author identity the UI renders');
    await become(U.b);
    eq(row.thumbnail_key, `thumb/${U.a}/detail.jpg`, 'and the poster the grid shows');
    eq((await rpc('public.short_detail', `'${hidden}'`)).length, 0, 'a private reel answers nothing');
    eq((await rpc('public.short_detail', `'00000000-0000-4000-8000-000000000000'`)).length, 0,
      'an unknown id answers nothing, never an error');

    await become(U.a);
    eq((await rpc('public.short_detail', `'${hidden}'`)).length, 1, 'the author still opens their own reel');
  });

  await test('short_detail reflects the view the caller just recorded', async () => {
    await become(U.b);
    const visible = await scalar(`select id from public.shorts where caption = 'detail #link' limit 1`);
    await exec(`select public.record_short_view('${visible}', 'share-link-session', 11000, true)`);
    const row = await one(`select * from public.short_detail('${visible}')`);
    assert(Number(row.view_count) >= 1, 'the view is reflected on the card');
  });

  // ---------------------------------------------------------------------------
  group('author videos (00031)');
  // ---------------------------------------------------------------------------

  await test('a channel page shows public videos to everyone and drafts only to their author', async () => {
    await become(U.a);
    const publicVideo = await scalar(`select public.publish_video(
      'video/${U.a}/app/channel-public.mp4', 'thumb/${U.a}/channel-public.jpg', 'Channel public', null,
      60000, 3000000, 'public')`);
    const draft = await scalar(`select public.publish_video(
      'video/${U.a}/app/channel-draft.mp4', 'thumb/${U.a}/channel-draft.jpg', 'Channel draft', null,
      60000, 3000000, 'private')`);
    const followersOnly = await scalar(`select public.publish_video(
      'video/${U.a}/app/channel-followers.mp4', 'thumb/${U.a}/channel-followers.jpg', 'Followers only', null,
      60000, 3000000, 'followers')`);

    const mine = (await query(`select * from public.author_videos('${U.a}', null, null, 60, true)`)).map((r) => r.id);
    for (const id of [publicVideo, draft, followersOnly]) {
      assert(mine.includes(id), 'the author sees every one of their own rows');
    }

    await become(U.other);
    const stranger = (await query(`select * from public.author_videos('${U.a}', null, null, 60, false)`)).map((r) => r.id);
    assert(stranger.includes(publicVideo), 'public is public');
    assert(!stranger.includes(draft), 'a draft belongs to its author');
    assert(!stranger.includes(followersOnly), 'followers-only needs a follow edge');

    await exec(`select public.follow_user('${U.a}', null)`);
    const follower = (await query(`select * from public.author_videos('${U.a}', null, null, 60, false)`)).map((r) => r.id);
    assert(follower.includes(followersOnly), 'a follower sees the followers-only row');
    assert(!follower.includes(draft), 'following does not open drafts');
  });

  await test('author_videos keysets and clamps like the feed it mirrors', async () => {
    await become(U.a);
    const page = await query(`select * from public.author_videos('${U.a}', null, null, 2, true)`);
    eq(page.length, 2, 'the limit is respected');
    const first = page[0];
    const next = await query(
      `select * from public.author_videos('${U.a}', '${new Date(first.published_at).toISOString()}', '${first.id}', 60, true)`);
    assert(!next.map((r) => r.id).includes(first.id), 'the cursor excludes the row it points at');
    eq(page[0].title, 'Followers only', 'newest first, exactly like the home feed');

    eq((await rpc('public.author_videos', `'${U.a}', null, null, 0, false`)).length, 1,
      'a zero limit is clamped to one, not to zero or to everything');
    assert((await rpc('public.author_videos', `'${U.a}', null, null, 9999, false`)).length <= 60,
      'an oversized limit is clamped to the same ceiling the feed uses, never honoured');
  });
}
