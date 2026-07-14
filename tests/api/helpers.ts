import { SignJWT } from 'jose';

/**
 * Shared plumbing for the HTTP tests against PostgREST.
 *
 * Tokens are signed with the debug-mode HS256 secret
 * (config/docker-compose.overrides/debug.yaml), exactly like the UI's debug
 * login page does, so these tests exercise the same JWT → role-switch path
 * as production (only the signature scheme differs).
 */

export const API_URI = process.env.DTRACK_TEST_API_URI ?? 'http://localhost:3000';
const JWT_SECRET =
  process.env.DTRACK_TEST_JWT_SECRET ?? 'Dummy5ecr3t4D3bug0n1yN0T4Pr0D123';

/** The initial power user created by initdb.sh ($POSTGRES_USER_APP_POWER). */
export const POWER_EMAIL =
  process.env.DTRACK_TEST_POWER_EMAIL ?? 'Dummy.User@example.com';

/** The only domain auth.del_user accepts; test personas live here. */
export const TEST_DOMAIN = 'hellodnk8n.onmicrosoft.com';

/** Unique per test run, so run-scoped entities never collide with residue. */
export const runId = Date.now().toString(36);

export const tokenFor = (email: string): Promise<string> =>
  new SignJWT({ preferred_username: email })
    .setProtectedHeader({ alg: 'HS256' })
    .sign(new TextEncoder().encode(JWT_SECRET));

export interface ApiResponse {
  status: number;
  headers: Headers;
  body: any;
}

export async function api(
  method: string,
  path: string,
  opts: { token?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<ApiResponse> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    ...(opts.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
    ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
    ...opts.headers,
  };
  const res = await fetch(`${API_URI}${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  const text = await res.text();
  let body: any = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: res.status, headers: res.headers, body };
}

/** Convenience client bound to one user's JWT. */
export async function asUser(email: string) {
  const token = await tokenFor(email);
  return {
    email,
    token,
    get: (path: string, headers?: Record<string, string>) =>
      api('GET', path, { token, headers }),
    post: (path: string, body?: unknown, headers?: Record<string, string>) =>
      api('POST', path, { token, body, headers }),
    patch: (path: string, body?: unknown, headers?: Record<string, string>) =>
      api('PATCH', path, { token, body, headers }),
    delete: (path: string, headers?: Record<string, string>) =>
      api('DELETE', path, { token, headers }),
  };
}
export type UserClient = Awaited<ReturnType<typeof asUser>>;

/**
 * Standard personas. Employee creation goes through the API itself
 * (api.employees INSTEAD OF trigger → auth.create_user), which is idempotent,
 * so personas are stable across runs while projects/teams are run-scoped.
 */
export const personaEmail = (name: string) => `api.${name}@${TEST_DOMAIN}`;

export interface Fixtures {
  power: UserClient;
  alice: UserClient; // project lead / AoE team supervisor
  bob: UserClient; // plain member of alice's project and team
  carol: UserClient; // unrelated outsider
  aliceId: number;
  bobId: number;
  carolId: number;
}

async function employeeId(power: UserClient, username: string): Promise<number> {
  const res = await power.get(`/employees?username=eq.${username}&select=id`);
  if (res.status !== 200 || !res.body?.[0]) {
    throw new Error(`fixture employee ${username} missing: ${JSON.stringify(res)}`);
  }
  return res.body[0].id;
}

export async function ensurePersonas(): Promise<Fixtures> {
  const power = await asUser(POWER_EMAIL);
  for (const [username, first, last] of [
    ['api.alice', 'Alice', 'Lead'],
    ['api.bob', 'Bob', 'Member'],
    ['api.carol', 'Carol', 'Outsider'],
  ]) {
    const res = await power.post('/employees', {
      username,
      first_name: first,
      last_name: last,
    });
    if (res.status >= 300) {
      throw new Error(`persona ${username} creation failed: ${JSON.stringify(res)}`);
    }
  }
  return {
    power,
    alice: await asUser(personaEmail('alice')),
    bob: await asUser(personaEmail('bob')),
    carol: await asUser(personaEmail('carol')),
    aliceId: await employeeId(power, 'api.alice'),
    bobId: await employeeId(power, 'api.bob'),
    carolId: await employeeId(power, 'api.carol'),
  };
}

/**
 * Run-scoped project world: a project led by alice with member bob, linked
 * to a fresh AoW and activity, plus an AoE team where alice leads bob.
 */
export interface ProjectWorld extends Fixtures {
  projectId: number;
  projectName: string;
  aowId: number;
  activityId: number;
  aoeId: number;
}

export async function ensureProjectWorld(tag: string): Promise<ProjectWorld> {
  const f = await ensurePersonas();
  const name = (kind: string) => `api ${kind} ${tag} ${runId}`;

  // The INSTEAD OF triggers return NEW as-is, so return=representation gives
  // back null ids for generated keys; fetch created rows by name instead.
  const created = async (path: string, body: { name: string; [key: string]: unknown }) => {
    const res = await f.power.post(path, body);
    if (res.status >= 300) {
      throw new Error(`fixture POST ${path} failed: ${JSON.stringify(res)}`);
    }
    const row = await f.power.get(
      `${path}?name=eq.${encodeURIComponent(body.name)}&select=id,name`,
    );
    if (!row.body?.[0]) {
      throw new Error(`fixture ${path} row not found after create`);
    }
    return row.body[0];
  };

  const aow = await created('/areas_of_work', { name: name('aow') });
  const activity = await created('/activities', { name: name('activity') });
  await created('/projects', {
    name: name('project'),
    description: 'fixture',
    lead_ids: [f.aliceId],
    member_ids: [f.bobId],
    activity_ids: [activity.id],
    aow_ids: [aow.id],
  });
  const project = (
    await f.power.get(`/projects?name=eq.${encodeURIComponent(name('project'))}`)
  ).body[0];

  const aoe = await created('/areas_of_expertise', { name: name('aoe') });
  const team = await f.power.post('/aoe_teams', {
    aoe: { id: aoe.id },
    lead: { id: f.aliceId },
    member_ids: [f.bobId],
  });
  if (team.status >= 300) {
    throw new Error(`fixture aoe_team failed: ${JSON.stringify(team)}`);
  }

  return {
    ...f,
    projectId: project.id,
    projectName: project.name,
    aowId: aow.id,
    activityId: activity.id,
    aoeId: aoe.id,
  };
}
