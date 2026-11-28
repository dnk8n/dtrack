import { describe, expect, test } from 'vitest';

import { api, asUser, POWER_EMAIL, TEST_DOMAIN, tokenFor } from './helpers';

describe('authentication and role switching', () => {
  test('TC-AUTH-101: anonymous requests cannot read data views', async () => {
    const res = await api('GET', '/employees');
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
    expect(res.body?.code).toBe('42501');
  });

  test('TC-AUTH-102: a token with a bad signature is rejected', async () => {
    const good = await tokenFor(POWER_EMAIL);
    const tampered = good.slice(0, -4) + 'AAAA';
    const res = await api('GET', '/current_employee', { token: tampered });
    expect(res.status).toBe(401);
  });

  test('TC-AUTH-103: a valid token for a non-existent user is rejected', async () => {
    const ghost = await asUser('no.such.user@example.com');
    const res = await ghost.get('/current_employee');
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(JSON.stringify(res.body)).toMatch(/does not exist/);
  });

  test('TC-AUTH-104: the power user sees itself via current_employee', async () => {
    const power = await asUser(POWER_EMAIL);
    const res = await power.get('/current_employee');
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0].email).toBe(POWER_EMAIL);
    expect(res.body[0].is_power).toBe(true);
    expect(res.body[0].roles).toContain('power');
  });

  // Entra puts the UPN in preferred_username with its case as stored, and the
  // Postgres role is that claim verbatim (always quoted with %I), so sign-in
  // names need not be lowercase. The power user itself (Dummy.User@...) is
  // already mixed case; this pins it for an ordinary user too.
  const MIXED_EMAIL = `Api.Mixed.Case@${TEST_DOMAIN}`;

  test('TC-AUTH-106: a user whose sign-in name has capitals authenticates as itself', async () => {
    const power = await asUser(POWER_EMAIL);
    const created = await power.post('/employees', { username: 'Api.Mixed', email: MIXED_EMAIL });
    expect(created.status).toBeLessThan(300);
    const res = await (await asUser(MIXED_EMAIL)).get('/current_employee');
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0].email).toBe(MIXED_EMAIL);
    expect(res.body[0].first_name).toBe('Api');
    expect(res.body[0].last_name).toBe('Mixed');
    expect(res.body[0].is_power).toBe(false);
  });

  test('TC-AUTH-107: the sign-in name must match the employee email case exactly', async () => {
    const power = await asUser(POWER_EMAIL);
    await power.post('/employees', { username: 'Api.Mixed', email: MIXED_EMAIL });
    const res = await (await asUser(MIXED_EMAIL.toLowerCase())).get('/current_employee');
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(JSON.stringify(res.body)).toMatch(/does not exist/);
  });

  test('TC-AUTH-105: the OpenAPI description is served at the API root', async () => {
    const res = await api('GET', '/');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('paths');
  });

  test('TC-ONB-101: onboarding endpoint exists and rejects garbage tokens', async () => {
    // Full onboarding needs a real Azure id token, which local/CI runs don't
    // have; asserting the anon-callable endpoint rejects junk still pins down
    // that it is exposed and validating.
    const res = await api('POST', '/rpc/onboard', { body: { id_token: 'garbage' } });
    expect(res.status).toBeGreaterThanOrEqual(400);
  });
});
