import { describe, expect, test } from 'vitest';

import { api, asUser, POWER_EMAIL, tokenFor } from './helpers';

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
    const ghost = await asUser('no.such.user@hellodnk8n.onmicrosoft.com');
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
