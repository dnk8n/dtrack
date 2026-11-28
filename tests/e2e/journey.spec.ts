import { expect, test } from '@playwright/test';

import { expectCreated, login, pickOption, POWER_EMAIL, runId } from './helpers';

/**
 * TC-E2E-010: the core user journey, end to end. As the power user, build up
 * the reference data a time tracking needs (AoW → Activity → Project with
 * both linked), then log time against it using the cascading selects, and
 * see the entry in the list.
 */
const aowName = `E2E AoW ${runId}`;
const activityName = `E2E Activity ${runId}`;
const projectName = `E2E Project ${runId}`;
const taskDescription = `E2E logged time ${runId}`;

test.describe.configure({ mode: 'serial' });

test('TC-E2E-010a: create an area of work', async ({ page }) => {
  await login(page, POWER_EMAIL);
  await page.getByRole('menuitem', { name: 'AoWs' }).click();
  await page.getByRole('link', { name: 'Create' }).click();
  await page.getByLabel('Name').fill(aowName);
  await page.getByRole('button', { name: 'Save' }).click();
  await expectCreated(page);
});

test('TC-E2E-010b: create an activity', async ({ page }) => {
  await login(page, POWER_EMAIL);
  await page.getByRole('menuitem', { name: 'Activities' }).click();
  await page.getByRole('link', { name: 'Create' }).click();
  await page.getByLabel('Name', { exact: true }).fill(activityName);
  await page.getByLabel('Description').fill('Created by the E2E suite');
  await page.getByRole('button', { name: 'Save' }).click();
  await expectCreated(page);
});

test('TC-E2E-010c: create a project linking AoW, activity and a manager', async ({
  page,
}) => {
  await login(page, POWER_EMAIL);
  await page.getByRole('menuitem', { name: 'Projects' }).click();
  await page.getByRole('link', { name: 'Create' }).click();
  await page.getByLabel('Name', { exact: true }).fill(projectName);
  await page.getByLabel('Description').fill('Created by the E2E suite');
  await pickOption(page, 'AoWs', aowName);
  await pickOption(page, 'Activities', activityName);
  await pickOption(page, 'Managers', 'Dummy.User');
  await page.getByRole('button', { name: 'Save' }).click();
  await expectCreated(page);
});

test('TC-E2E-010d: log time through the cascading selects', async ({ page }) => {
  await login(page, POWER_EMAIL);
  await page.getByRole('menuitem', { name: 'Time Trackings' }).click();
  await page.getByRole('link', { name: 'Create' }).click();

  // Employee Name defaults to the logged-in identity; drive the cascade
  await pickOption(page, 'Area of Work', aowName);
  await pickOption(page, 'Project', projectName);
  await pickOption(page, 'Activity', activityName);
  await page.getByLabel('Task Description').fill(taskDescription);
  await pickOption(page, 'Duration', '0.25 hrs');
  await page.getByRole('button', { name: 'Save' }).click();
  await expectCreated(page);
});

test('TC-E2E-010e: the logged entry appears in the list', async ({ page }) => {
  await login(page, POWER_EMAIL);
  await page.getByRole('menuitem', { name: 'Time Trackings' }).click();
  await expect(page.getByText(taskDescription)).toBeVisible({ timeout: 15_000 });
});

test('TC-E2E-020: the dashboard renders for a user with data', async ({ page }) => {
  await login(page, POWER_EMAIL);
  // Dashboard is the default route
  await page.goto('/');
  await expect(page.getByRole('tab', { name: 'Chart' })).toBeVisible({
    timeout: 15_000,
  });
});
