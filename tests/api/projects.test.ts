import { beforeAll, describe, expect, test } from 'vitest';

import { ensureProjectWorld, ProjectWorld } from './helpers';

let w: ProjectWorld;
beforeAll(async () => {
  w = await ensureProjectWorld('projects');
});

describe('projects', () => {
  test('TC-PROJ-101: project created with lead, member and links', async () => {
    const res = await w.alice.get(`/projects?id=eq.${w.projectId}`);
    expect(res.status).toBe(200);
    const project = res.body[0];
    expect(project.lead_ids).toContain(w.aliceId);
    expect(project.member_ids).toContain(w.bobId);
    expect(project.aow_ids).toContain(w.aowId);
    expect(project.activity_ids).toContain(w.activityId);
  });

  test('TC-PROJ-102: being made project lead grants the pm role', async () => {
    const res = await w.alice.get('/current_employee?select=roles');
    expect(res.status).toBe(200);
    expect(res.body[0].roles).toContain('pm');
  });

  test('TC-PROJ-103: the project lead can update their project', async () => {
    const res = await w.alice.patch(`/projects?id=eq.${w.projectId}`, {
      description: `updated by lead ${Date.now()}`,
    });
    expect(res.status).toBeLessThan(300);
    const check = await w.alice.get(`/projects?id=eq.${w.projectId}&select=description`);
    expect(check.body[0].description).toMatch(/^updated by lead /);
  });

  test('TC-PROJ-104: unrelated users cannot see the project', async () => {
    const res = await w.carol.get(`/projects?id=eq.${w.projectId}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(0);
  });

  // KNOWN BUG (kept as expected failure, do not "fix" the test):
  // select_projects_policy on internal.projects lacks FOR SELECT, so as a
  // permissive FOR ALL policy it also authorizes UPDATE for any project
  // member. See TC-RLS-012 in tests/db/03-rls.sql and docs/testing.md.
  test.fails(
    'TC-PROJ-105: a non-lead member cannot update the project',
    async () => {
      await w.bob.patch(`/projects?id=eq.${w.projectId}`, {
        description: 'member should not be able to write this',
      });
      const check = await w.alice.get(
        `/projects?id=eq.${w.projectId}&select=description`,
      );
      expect(check.body[0].description).not.toBe(
        'member should not be able to write this',
      );
    },
  );

  test('TC-PROJ-106: members see their project in the list', async () => {
    const res = await w.bob.get(`/projects?id=eq.${w.projectId}&select=name`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(1);
  });
});
