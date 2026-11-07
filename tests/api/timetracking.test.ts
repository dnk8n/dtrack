import { beforeAll, describe, expect, test } from 'vitest';

import { ensureProjectWorld, ProjectWorld, runId } from './helpers';

let w: ProjectWorld;
beforeAll(async () => {
  w = await ensureProjectWorld('tt');
});

const today = new Date().toISOString().slice(0, 10);

const entryFor = (userId: number, description: string) => ({
  description,
  date: today,
  duration: '0.25 hrs',
  user: { id: userId },
  project: { id: w.projectId },
  activity: { id: w.activityId },
  aow: { id: w.aowId },
});

describe('time tracking', () => {
  test('TC-TT-101: a member can log their own time in UI duration format', async () => {
    const res = await w.bob.post(
      '/time_trackings',
      entryFor(w.bobId, `api tt own ${runId}`),
      { Prefer: 'return=representation' },
    );
    expect(res.status).toBe(201);

    const check = await w.bob.get(
      `/time_trackings?description=eq.${encodeURIComponent(`api tt own ${runId}`)}`,
    );
    expect(check.body).toHaveLength(1);
    expect(check.body[0].duration).toBe('0.25 hrs');
    expect(check.body[0].user.id).toBe(w.bobId);
  });

  test('TC-TT-102: a member cannot log time for someone else', async () => {
    const res = await w.bob.post(
      '/time_trackings',
      entryFor(w.aliceId, `api tt forged ${runId}`),
    );
    expect(res.status).toBe(403);
    expect(res.body?.code).toBe('42501');
  });

  test('TC-TT-103: a team lead sees and can log their members entries', async () => {
    const seen = await w.alice.get(
      `/time_trackings?description=eq.${encodeURIComponent(`api tt own ${runId}`)}`,
    );
    expect(seen.status).toBe(200);
    expect(seen.body).toHaveLength(1);

    const logged = await w.alice.post(
      '/time_trackings',
      entryFor(w.bobId, `api tt bylead ${runId}`),
    );
    expect(logged.status).toBe(201);
  });

  test('TC-TT-104: outsiders see none of these entries', async () => {
    const res = await w.carol.get(
      `/time_trackings?description=like.api tt*${runId}`,
    );
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(0);
  });

  test('TC-TT-105: durations must be multiples of 15 minutes', async () => {
    const res = await w.bob.post('/time_trackings', {
      ...entryFor(w.bobId, `api tt invalid ${runId}`),
      duration: '20 minutes',
    });
    expect(res.status).toBe(400);
    expect(res.body?.code).toBe('23514');
  });

  test('TC-PLOT-101: duration calendar aggregates the user entries', async () => {
    const res = await w.bob.get(`/duration_calendar?user_id=eq.${w.bobId}`);
    expect(res.status).toBe(200);
    expect(res.body.length).toBeGreaterThanOrEqual(1);
  });

  test('TC-PLOT-102: timetracking_summary RPC responds for the caller', async () => {
    const res = await w.bob.get(
      '/rpc/timetracking_summary?axes=%7Buser,daterange%7D&date_part=day&zoom_level=2',
    );
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
  });
});
