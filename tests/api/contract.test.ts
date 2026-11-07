import { beforeAll, describe, expect, test } from 'vitest';

import { ensureProjectWorld, ProjectWorld } from './helpers';

/**
 * The UI ↔ API contract: PostgREST features the react-admin data provider
 * (@raphiniert/ra-data-postgrest) and the UI's queries depend on. If one of
 * these breaks, screens break even though plain CRUD still works.
 */
let w: ProjectWorld;
beforeAll(async () => {
  w = await ensureProjectWorld('contract');
});

describe('UI-API contract', () => {
  test('TC-API-201: column aliasing via select (id,name:username)', async () => {
    const res = await w.power.get('/employees?select=id,name:username&limit=1');
    expect(res.status).toBe(200);
    expect(res.body[0]).toHaveProperty('name');
    expect(res.body[0]).not.toHaveProperty('username');
  });

  test('TC-API-202: jsonb containment filter on embedded relations', async () => {
    // ProjectSelectInput filters projects by area of work this way
    const filter = encodeURIComponent(`[{"id": ${w.aowId}}]`);
    const res = await w.alice.get(`/projects?areas_of_work=cs.${filter}&select=id`);
    expect(res.status).toBe(200);
    expect(res.body.map((r: any) => r.id)).toContain(w.projectId);
  });

  test('TC-API-203: exact counts via Prefer: count=exact', async () => {
    const res = await w.power.get('/employees?select=id&limit=1', {
      Prefer: 'count=exact',
    });
    expect(res.status).toBeLessThan(300);
    const contentRange = res.headers.get('content-range');
    expect(contentRange).toBeTruthy();
    expect(contentRange).toMatch(/\/\d+$/);
  });

  test('TC-API-204: ordering by nested jsonb field (user->name)', async () => {
    // TimeTrackingList sorts by user->name when showing the Employee column
    const res = await w.alice.get('/time_trackings?order=user->name.asc&limit=5');
    expect(res.status).toBe(200);
  });

  test('TC-API-205: created rows come back with Prefer: return=representation', async () => {
    // Note: the INSTEAD OF triggers return NEW as-is, so generated ids are
    // null in the representation — a quirk the UI currently lives with. This
    // test pins the shape (a row is returned), not the id.
    const name = `api contract aow rep ${Date.now()}`;
    const res = await w.power.post(
      '/areas_of_work',
      { name },
      { Prefer: 'return=representation' },
    );
    expect(res.status).toBe(201);
    expect(res.body?.[0]?.name).toBe(name);
  });

  test('TC-API-206: jsonb arrow filters used by list filters (user->>id)', async () => {
    const res = await w.bob.get(`/time_trackings?user->>id=eq.${w.bobId}&select=id`);
    expect(res.status).toBe(200);
  });
});
