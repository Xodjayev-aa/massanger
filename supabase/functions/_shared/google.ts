/**
 * Google account-age evidence.
 *
 * The rule MessengerX enforces at registration: a Google identity must be at
 * least `minAgeDays` old. Signals, in descending trust order:
 *
 *   1. Gmail `users/getProfile.initialData.time` — the timestamp Gmail was
 *      provisioned with; the closest thing to a birth date Google exposes.
 *   2. Gmail `users/messages.list` with `older_than:<N>d` — if even one message
 *      in any label predates the cutoff, the mailbox (and therefore the
 *      account) is at least that old. Read-only, one request, no bodies fetched.
 *   3. Drive `files.list(orderBy=createdTime asc, pageSize=1)` — the creation
 *      time of the oldest non-trashed file, used when the mailbox is empty or
 *      Gmail is not in the granted scopes.
 *
 * Deliberate choices:
 *   * `metadataHeaders` only; we never download message bodies, so a rejected
 *     signup does not leave Google-content copies in our logs.
 *   * Signals are combined with `min()`, so a *new* Drive inside an *old*
 *     account cannot be used to pass, and vice versa an old Gmail cannot be
 *     masked by a fresh Drive: the account passes when any signal proves age.
 *   * Every upstream call is time-boxed and retried once on 5xx.
 */

import { HttpError } from './types.ts';

const GOOGLE_TOKEN_HOST = 'https://oauth2.googleapis.com';
const GMAIL_HOST = 'https://gmail.googleapis.com';
const DRIVE_HOST = 'https://www.googleapis.com';

export const AGE_GATE_SCOPES = [
  'https://www.googleapis.com/auth/gmail.metadata',
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/drive.metadata.readonly',
  'openid',
  'email',
  'profile',
];

export type GoogleTokenInfo = {
  azp?: string;
  aud?: string;
  email?: string;
  email_verified?: boolean;
  exp?: number;
  scope?: string;
  [k: string]: unknown;
};

export type AgeSignals = {
  gmail_initial_data?: string;
  gmail_oldest_message?: string;
  gmail_messages_total?: number;
  drive_oldest_file?: string;
  drive_oldest_file_name?: string;
  [k: string]: unknown;
};

export type AgeVerdict = {
  passed: boolean;
  method: 'gmail_profile' | 'gmail_oldest_message' | 'drive_oldest_file' | 'none';
  accountCreatedAt: string | null;
  accountAgeDays: number | null;
  minAgeDays: number;
  signals: AgeSignals;
  reason: string | null;
};

const DAY_MS = 86_400_000;

type FetchOptions = { method?: string; headers?: Record<string, string>; body?: string; timeoutMs?: number };

async function googleFetch(url: string, accessToken: string, options: FetchOptions = {}): Promise<Response> {
  const init: RequestInit = {
    method: options.method ?? 'GET',
    headers: {
      authorization: `Bearer ${accessToken}`,
      accept: 'application/json',
      ...(options.headers ?? {}),
      ...(options.body ? { 'content-type': 'application/json' } : {}),
    },
    body: options.body,
  };
  let lastError: unknown = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await fetch(url, {
        ...init,
        signal: AbortSignal.timeout(options.timeoutMs ?? 8_000),
      });
      // 5xx and 429 are worth one retry; 4xx (revoked/insufficient scope) are not.
      if ((response.status >= 500 || response.status === 429) && attempt === 0) {
        await new Promise((resolve) => setTimeout(resolve, 250 * (attempt + 1)));
        continue;
      }
      return response;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 250 * (attempt + 1)));
    }
  }
  throw new HttpError('upstream_error', 'Google API unreachable', {
    details: { cause: (lastError as Error)?.message ?? 'timeout' },
  });
}

async function googleJson(url: string, accessToken: string, options: FetchOptions = {}): Promise<Record<string, unknown>> {
  const response = await googleFetch(url, accessToken, options);
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new HttpError(
      response.status === 401 || response.status === 403 ? 'forbidden' : 'upstream_error',
      `Google API responded ${response.status}`,
      { details: { status: response.status, blurb: body.slice(0, 180) } },
    );
  }
  return (await response.json().catch(() => ({}))) as Record<string, unknown>;
}

/**
 * Confirms the access token really belongs to *this* OAuth client and (when we
 * know the expected address) to the email on the user's auth record. Without
 * this, a caller could hand in a token for somebody else's old Gmail account.
 */
export async function assertTokenOwnership(
  accessToken: string,
  allowedClientIds: string[],
  expectedEmail: string | null,
): Promise<GoogleTokenInfo> {
  const url = `${GOOGLE_TOKEN_HOST}/tokeninfo?access_token=${encodeURIComponent(accessToken)}`;
  let info: GoogleTokenInfo;
  try {
    const response = await fetch(url, { method: 'GET', signal: AbortSignal.timeout(6_000) });
    if (!response.ok) throw new Error(`status ${response.status}`);
    info = (await response.json()) as GoogleTokenInfo;
  } catch (error) {
    throw new HttpError('unauthorized', 'Google rejected the access token', {
      details: { cause: (error as Error).message },
    });
  }
  const aud = info.aud ?? info.azp;
  if (allowedClientIds.length > 0 && (!aud || !allowedClientIds.includes(String(aud)))) {
    throw new HttpError('unauthorized', 'access token was not issued to this app');
  }
  if (expectedEmail && info.email && info.email.toLowerCase() !== expectedEmail.toLowerCase()) {
    throw new HttpError('unauthorized', 'access token belongs to a different Google account');
  }
  if (info.email && info.email_verified === false) {
    throw new HttpError('forbidden', 'Google account email is not verified');
  }
  return info;
}

export async function refreshAccessToken(options: {
  clientId: string;
  clientSecret: string;
  refreshToken: string;
}): Promise<{ accessToken: string; expiresInSeconds: number; scope: string }> {
  const response = await fetch(`${GOOGLE_TOKEN_HOST}/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: options.clientId,
      client_secret: options.clientSecret,
      refresh_token: options.refreshToken,
      grant_type: 'refresh_token',
    }).toString(),
    signal: AbortSignal.timeout(8_000),
  });
  if (!response.ok) {
    throw new HttpError('forbidden', 'Google could not refresh the stored consent', {
      details: { status: response.status },
    });
  }
  const json = (await response.json()) as { access_token?: string; expires_in?: number; scope?: string };
  if (!json.access_token) throw new HttpError('upstream_error', 'Google returned no access token');
  return {
    accessToken: json.access_token,
    expiresInSeconds: json.expires_in ?? 3600,
    scope: json.scope ?? '',
  };
}

export async function revokeAccessToken(accessToken: string): Promise<void> {
  await fetch(`${GOOGLE_TOKEN_HOST}/revoke`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ token: accessToken }).toString(),
    signal: AbortSignal.timeout(6_000),
  }).catch(() => undefined);
}

type ProfileResponse = {
  emailAddress?: string;
  messagesTotal?: number;
  initialData?: { time?: string; size?: number };
};

type ListResponse = { messages?: Array<{ id: string; threadId?: string }>; nextPageToken?: string };
type MessageResponse = { internalDate?: string; snippet?: string; payload?: { headers?: Array<{ name: string; value: string }> } };
type DriveListResponse = { files?: Array<{ createdTime?: string; name?: string }> };

async function gmailProfile(accessToken: string): Promise<ProfileResponse> {
  return (await googleJson(`${GMAIL_HOST}/gmail/v1/users/me/profile`, accessToken)) as ProfileResponse;
}

/** True when the mailbox holds at least one message older than `days`. */
async function gmailHasMailOlderThan(accessToken: string, days: number): Promise<string | null> {
  const params = new URLSearchParams({
    q: `in:anywhere older_than:${days}d`,
    maxResults: '1',
    includeSparseSnippets: 'false',
  });
  const list = (await googleJson(
    `${GMAIL_HOST}/gmail/v1/users/me/messages?${params.toString()}`,
    accessToken,
  )) as ListResponse;
  const hit = list.messages?.[0];
  if (!hit?.id) return null;
  const meta = (await googleJson(
    `${GMAIL_HOST}/gmail/v1/users/me/messages/${encodeURIComponent(hit.id)}?format=metadata&metadataHeaders=Date`,
    accessToken,
  )) as MessageResponse;
  const internal = meta.internalDate ? Number.parseInt(meta.internalDate, 10) : NaN;
  if (Number.isFinite(internal)) return new Date(internal).toISOString();
  const headerDate = meta.payload?.headers?.find((h) => h.name?.toLowerCase() === 'date')?.value;
  const parsed = headerDate ? Date.parse(headerDate) : NaN;
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : new Date(Date.now() - days * DAY_MS).toISOString();
}

async function driveOldestFile(accessToken: string): Promise<{ createdTime: string; name: string } | null> {
  const params = new URLSearchParams({
    q: 'trashed = false',
    orderBy: 'createdTime',
    pageSize: '1',
    fields: 'files(createdTime,name)',
  });
  const list = (await googleJson(`${DRIVE_HOST}/drive/v3/files?${params.toString()}`, accessToken, {
    headers: { 'x-goog-api-version': '20150728' },
  })) as DriveListResponse;
  const file = list.files?.[0];
  if (!file?.createdTime) return null;
  return { createdTime: file.createdTime, name: file.name ?? 'file' };
}

const ageDays = (iso: string, nowMs: number): number =>
  Math.floor((nowMs - Date.parse(iso)) / DAY_MS);

/** The oldest provable moment, plus the pass/fail verdict. */
export async function evaluateAccountAge(options: {
  accessToken: string;
  minAgeDays: number;
  /** scope names granted on the OAuth token, to skip calls that would 403 */
  grantedScopes: string[];
  nowMs?: number;
}): Promise<AgeVerdict> {
  const now = options.nowMs ?? Date.now();
  const signals: AgeSignals = {};
  const candidates: Array<{ iso: string; method: AgeVerdict['method'] }> = [];
  const hasScope = (...needles: string[]): boolean =>
    options.grantedScopes.length === 0 || needles.some((needle) => options.grantedScopes.includes(needle));

  let gmailFailed: string | null = null;
  if (hasScope('gmail.metadata', 'gmail.readonly')) {
    try {
      const profile = await gmailProfile(options.accessToken);
      if (typeof profile.messagesTotal === 'number') signals.gmail_messages_total = profile.messagesTotal;
      const initial = profile.initialData?.time;
      if (initial && Number.isFinite(Date.parse(initial))) {
        signals.gmail_initial_data = new Date(Date.parse(initial)).toISOString();
        candidates.push({ iso: signals.gmail_initial_data, method: 'gmail_profile' });
      }
      if (candidates.length === 0) {
        const oldest = await gmailHasMailOlderThan(options.accessToken, options.minAgeDays);
        if (oldest) {
          signals.gmail_oldest_message = oldest;
          candidates.push({ iso: oldest, method: 'gmail_oldest_message' });
        }
      }
    } catch (error) {
      if (error instanceof HttpError && error.code === 'forbidden') {
        gmailFailed = 'gmail_scope_not_granted';
      } else {
        throw error;
      }
    }
  }

  if (candidates.length === 0 && hasScope('drive.metadata.readonly', 'drive')) {
    try {
      const oldest = await driveOldestFile(options.accessToken);
      if (oldest) {
        signals.drive_oldest_file = oldest.createdTime;
        signals.drive_oldest_file_name = oldest.name;
        candidates.push({ iso: oldest.createdTime, method: 'drive_oldest_file' });
      }
    } catch (error) {
      if (error instanceof HttpError && error.code === 'forbidden') {
        signals.drive_error = 'drive_scope_not_granted';
      } else {
        throw error;
      }
    }
  }

  if (gmailFailed) signals.gmail_error = gmailFailed;

  if (candidates.length === 0) {
    return {
      passed: false,
      method: 'none',
      accountCreatedAt: null,
      accountAgeDays: null,
      minAgeDays: options.minAgeDays,
      signals,
      reason:
        'No Google account-age signal was readable. Make sure MessengerX was granted Gmail/Drive metadata access, then retry.',
    };
  }

  // Oldest provable moment ⇒ the most conservative age estimate wins.
  const sorted = candidates
    .map((c) => ({ ...c, days: ageDays(c.iso, now) }))
    .sort((a, b) => b.days - a.days);
  const best = sorted[0]!;

  return {
    passed: best.days >= options.minAgeDays,
    method: best.method,
    accountCreatedAt: best.iso,
    accountAgeDays: best.days,
    minAgeDays: options.minAgeDays,
    signals,
    reason: best.days >= options.minAgeDays
      ? null
      : `Google account is ${best.days} days old; ${options.minAgeDays} days are required.`,
  };
}
