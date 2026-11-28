import { beforeAll, describe, expect, test } from 'vitest';

import { ensurePersonas, Fixtures, personaEmail } from './helpers';

let f: Fixtures;
beforeAll(async () => {
  f = await ensurePersonas();
});

describe('employees', () => {
  test('TC-EMP-101: power can create an employee through the API', async () => {
    // ensurePersonas already POSTs /employees; assert the result is queryable
    const res = await f.power.get('/employees?username=eq.api.alice');
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0].email).toBe(personaEmail('alice'));
    expect(res.body[0].first_name).toBe('Alice');
  });

  test('TC-EMP-102: a newly created employee can authenticate', async () => {
    const res = await f.carol.get('/current_employee?select=id,username,email');
    expect(res.status).toBe(200);
    expect(res.body[0].username).toBe('api.carol');
  });

  test('TC-EMP-103: a basic user cannot create employees', async () => {
    const res = await f.carol.post('/employees', { username: 'api.mallory' });
    expect(res.status).toBeGreaterThanOrEqual(400);
    const check = await f.power.get('/employees?username=eq.api.mallory');
    expect(check.body).toHaveLength(0);
  });

  test('TC-EMP-104: an unrelated user does not see other employees', async () => {
    const res = await f.carol.get('/employees?select=username');
    expect(res.status).toBe(200);
    const usernames = res.body.map((r: any) => r.username);
    expect(usernames).toContain('api.carol');
    expect(usernames).not.toContain('api.alice');
    expect(usernames).not.toContain('api.bob');
  });

  test('TC-EMP-105: power can update another employee profile', async () => {
    const res = await f.power.patch('/employees?username=eq.api.carol', {
      position: `Tester ${Date.now()}`,
    });
    expect(res.status).toBeLessThan(300);
    const check = await f.power.get('/employees?username=eq.api.carol&select=position');
    expect(check.body[0].position).toMatch(/^Tester /);
  });

  // KNOWN BUG (kept as expected failure, do not "fix" the test):
  // update_users_policy intends self-updates (WITH CHECK email = current_user)
  // but internal.employees_upsert writes via INSERT ... ON CONFLICT DO UPDATE,
  // and only power has INSERT on auth.users — so basic users get 403 when
  // editing their own profile. See docs/testing.md.
  test.fails(
    'TC-EMP-106: employees can update their own profile fields',
    async () => {
      const res = await f.carol.patch('/employees?username=eq.api.carol', {
        position: 'Self-updated',
      });
      expect(res.status).toBeLessThan(300);
    },
  );
});
