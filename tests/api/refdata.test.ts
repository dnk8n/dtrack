import { beforeAll, describe, expect, test } from 'vitest';

import { ensurePersonas, Fixtures, runId } from './helpers';

let f: Fixtures;
beforeAll(async () => {
  f = await ensurePersonas();
});

describe('reference data (areas of work, activities)', () => {
  test('TC-AOW-101: power can create an area of work', async () => {
    const res = await f.power.post('/areas_of_work', { name: `api refdata aow ${runId}` });
    expect(res.status).toBe(201);
  });

  test('TC-AOW-102: basic users cannot create areas of work', async () => {
    const res = await f.bob.post('/areas_of_work', { name: `api evil aow ${runId}` });
    expect(res.status).toBe(403);
    expect(res.body?.code).toBe('42501');
  });

  test('TC-AOW-103: areas of work are readable by all authenticated users', async () => {
    const res = await f.carol.get('/areas_of_work?select=id,name');
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
  });

  test('TC-ACT-101: power can create an activity', async () => {
    const res = await f.power.post('/activities', {
      name: `api refdata activity ${runId}`,
      description: 'created by API tests',
    });
    expect(res.status).toBe(201);
  });

  test('TC-ACT-102: basic users cannot create activities', async () => {
    const res = await f.bob.post('/activities', { name: `api evil activity ${runId}` });
    expect(res.status).toBe(403);
  });
});
