import { beforeAll, describe, expect, test } from 'vitest';

import { ensurePersonas, Fixtures, runId } from './helpers';

let f: Fixtures;
beforeAll(async () => {
  f = await ensurePersonas();
});

describe('faqs', () => {
  test('TC-FAQ-101: power can create published and draft FAQs', async () => {
    for (const [q, published] of [
      [`api faq published ${runId}`, true],
      [`api faq draft ${runId}`, false],
    ] as const) {
      const res = await f.power.post('/faqs', {
        question: q,
        answer: 'because the tests say so',
        is_published: published,
      });
      expect(res.status).toBe(201);
    }
  });

  test('TC-FAQ-102: basic users see only published FAQs', async () => {
    const res = await f.bob.get(`/faqs?question=like.api faq*${runId}&select=question`);
    expect(res.status).toBe(200);
    expect(res.body.map((r: any) => r.question)).toEqual([
      `api faq published ${runId}`,
    ]);
  });

  test('TC-FAQ-103: basic users cannot create FAQs', async () => {
    const res = await f.bob.post('/faqs', {
      question: `api faq evil ${runId}`,
      answer: 'nope',
      is_published: true,
    });
    expect(res.status).toBe(403);
  });

  test('TC-FAQ-104: power sees drafts too', async () => {
    const res = await f.power.get(
      `/faqs?question=like.api faq*${runId}&select=question`,
    );
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(2);
  });
});
