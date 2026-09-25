-- Request an *owner-scoped* Telegram conversation with a public @username.
-- Telegram contact resolution requires a live TDLib user session: clients can
-- only enqueue one limited request and read its projected state. They cannot
-- forge a tg_chat_id, peer identity, chat mapping or a completed request.
create table if not exists public.telegram_chat_requests (
  id          uuid primary key default app.uuid_v7(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  username    text not null check (username ~ '^[a-z][a-z0-9_]{4,31}$'),
  status      text not null default 'queued'
                check (status in ('queued', 'claimed', 'succeeded', 'failed')),
  chat_id     uuid references public.chats (id) on delete set null,
  error       text,
  attempts    smallint not null default 0 check (attempts between 0 and 4),
  claimed_by  text,
  claimed_at  timestamptz,
  retry_at    timestamptz not null default clock_timestamp(),
  expires_at  timestamptz not null default (clock_timestamp() + interval '3 minutes'),
  created_at  timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp()
);
create index if not exists telegram_chat_requests_claim_idx
  on public.telegram_chat_requests (retry_at, created_at)
  where status in ('queued', 'claimed');
create index if not exists telegram_chat_requests_user_idx
  on public.telegram_chat_requests (user_id, created_at desc);

alter table public.telegram_chat_requests enable row level security;
revoke all on public.telegram_chat_requests from public, anon, authenticated;
grant all on public.telegram_chat_requests to service_role;

create or replace function public.telegram_start_chat(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid      uuid := app.current_uid();
  v_name     text := lower(regexp_replace(btrim(coalesce(p_username, '')), '^@', ''));
  v_current  public.telegram_chat_requests%rowtype;
begin
  if v_uid is null or not exists (
    select 1 from public.profiles p
    join public.telegram_accounts ta on ta.user_id = p.id
    where p.id = v_uid and p.access_state = 'active'
      and ta.tg_user_id is not null
      and ta.auth_state in ('linked', 'syncing')
      and ta.mirror_to_app = true
      and ta.sync_direction in ('both', 'to_telegram')
  ) then
    raise exception 'Connect Telegram and enable mirroring/outbound sync first'
      using errcode = '42501';
  end if;
  if v_name !~ '^[a-z][a-z0-9_]{4,31}$' then
    raise exception 'Enter a public Telegram username (5–32 letters, digits or underscores)'
      using errcode = '22023';
  end if;

  -- Serialize same-owner starts, including from two devices. The lock is held
  -- until this RPC commits; an attacker cannot bypass the rate limit by racing
  -- multiple concurrent calls on the same account.
  perform 1 from public.profiles p where p.id = v_uid for update;
  select * into v_current from public.telegram_chat_requests r
   where r.user_id = v_uid and r.username = v_name
     and r.status in ('queued', 'claimed') and r.expires_at > clock_timestamp()
   order by r.created_at desc limit 1;
  if found then
    return jsonb_build_object('request_id', v_current.id, 'status', v_current.status,
                              'expires_at', v_current.expires_at);
  end if;
  if (select count(*) from public.telegram_chat_requests r
       where r.user_id = v_uid and r.created_at > clock_timestamp() - interval '1 minute') >= 5 then
    raise exception 'Too many Telegram lookups. Try again in a minute'
      using errcode = 'P0001';
  end if;
  insert into public.telegram_chat_requests (user_id, username)
    values (v_uid, v_name) returning * into v_current;
  return jsonb_build_object('request_id', v_current.id, 'status', v_current.status,
                            'expires_at', v_current.expires_at);
end;
$$;

create or replace function public.telegram_chat_request_state(p_request_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'request_id', r.id,
    'status', case when r.status in ('queued', 'claimed') and r.expires_at <= clock_timestamp()
                   then 'failed' else r.status end,
    'chat_id', case when r.status = 'succeeded' then r.chat_id else null end,
    'error', case when r.status in ('queued', 'claimed') and r.expires_at <= clock_timestamp()
                   then 'Telegram lookup timed out. Try again.'
                  when r.status = 'failed' then r.error else null end,
    'expires_at', r.expires_at
  )
  from public.telegram_chat_requests r
  where r.id = p_request_id and r.user_id = app.current_uid();
$$;

create or replace function public.bridge_claim_chat_request(
  p_worker text,
  p_owner uuid default null,
  p_lease interval default interval '90 seconds'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_request public.telegram_chat_requests%rowtype;
begin
  if nullif(btrim(coalesce(p_worker, '')), '') is null then
    raise exception 'worker id required' using errcode = '22023';
  end if;
  select r.* into v_request
    from public.telegram_chat_requests r
    join public.profiles p on p.id = r.user_id and p.access_state = 'active'
    join public.telegram_accounts ta on ta.user_id = r.user_id
   where (p_owner is null or r.user_id = p_owner)
     and ta.tg_user_id is not null and ta.auth_state in ('linked', 'syncing')
     and ta.mirror_to_app = true and ta.sync_direction in ('both', 'to_telegram')
     and r.expires_at > clock_timestamp() and r.retry_at <= clock_timestamp()
     and (r.status = 'queued' or
          (r.status = 'claimed' and r.claimed_at < clock_timestamp() - p_lease))
     and r.attempts < 4
   order by r.created_at
   limit 1 for update of r skip locked;
  if not found then return null; end if;

  update public.telegram_chat_requests r
     set status = 'claimed', claimed_by = p_worker, claimed_at = clock_timestamp(),
         attempts = r.attempts + 1, updated_at = clock_timestamp()
   where r.id = v_request.id;
  return jsonb_build_object('request_id', v_request.id, 'user_id', v_request.user_id,
                            'username', v_request.username, 'attempts', v_request.attempts + 1);
end;
$$;

create or replace function public.bridge_finish_chat_request(
  p_request_id uuid,
  p_worker text,
  p_chat_id uuid default null,
  p_error text default null,
  p_retry_in interval default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_request public.telegram_chat_requests%rowtype;
begin
  select * into v_request from public.telegram_chat_requests r
   where r.id = p_request_id and r.status = 'claimed' and r.claimed_by = p_worker
   for update;
  if not found or v_request.expires_at <= clock_timestamp() then return false; end if;

  if p_chat_id is not null then
    if not exists (
      select 1 from public.telegram_chats tc
      join public.telegram_accounts ta on ta.user_id = tc.owner_user_id
      join public.profiles p on p.id = tc.owner_user_id
       where tc.chat_id = p_chat_id and tc.owner_user_id = v_request.user_id
         and tc.tg_chat_type = 'private' and ta.tg_user_id is not null
         and ta.auth_state in ('linked', 'syncing') and ta.mirror_to_app = true
         and ta.sync_direction in ('both', 'to_telegram') and p.access_state = 'active'
    ) then
      raise exception 'Chat must be a private Telegram mirror owned by the requester'
        using errcode = '42501';
    end if;
    update public.telegram_chat_requests r
       set status = 'succeeded', chat_id = p_chat_id, error = null,
           updated_at = clock_timestamp()
     where r.id = p_request_id;
  elsif p_retry_in is not null and v_request.attempts < 4 then
    update public.telegram_chat_requests r
       set status = 'queued', claimed_by = null, claimed_at = null,
           retry_at = clock_timestamp() + greatest(p_retry_in, interval '1 second'),
           updated_at = clock_timestamp()
     where r.id = p_request_id;
  else
    update public.telegram_chat_requests r
       set status = 'failed', error = left(coalesce(nullif(p_error, ''), 'Telegram could not find that user.'), 200),
           updated_at = clock_timestamp()
     where r.id = p_request_id;
  end if;
  return true;
end;
$$;

revoke all on function public.telegram_start_chat(text), public.telegram_chat_request_state(uuid),
  public.bridge_claim_chat_request(text, uuid, interval),
  public.bridge_finish_chat_request(uuid, text, uuid, text, interval)
  from public, anon, authenticated;
grant execute on function public.telegram_start_chat(text),
  public.telegram_chat_request_state(uuid) to authenticated;
grant execute on function public.bridge_claim_chat_request(text, uuid, interval),
  public.bridge_finish_chat_request(uuid, text, uuid, text, interval) to service_role;

comment on function public.telegram_start_chat(text) is
  'Start a rate-limited owner-only lookup of a public Telegram @username on the linked TDLib account.';
comment on function public.telegram_chat_request_state(uuid) is
  'Read only your own Telegram lookup status and the chat ID after a successful private mirror.';
