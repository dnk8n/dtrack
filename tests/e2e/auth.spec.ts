import { expect, test } from '@playwright/test';

import { login, POWER_EMAIL } from './helpers';

test('TC-E2E-001: power user can log in and out via the debug login', async ({
  page,
}) => {
  await login(page, POWER_EMAIL);

  // The main navigation is available
  await expect(page.getByRole('menuitem', { name: 'Projects' })).toBeVisible();
  await expect(page.getByRole('menuitem', { name: 'Employees' })).toBeVisible();

  // Log out again
  await page.getByLabel('Profile').click();
  await page.getByText('Logout').click();
  await expect(
    page.getByRole('button', { name: 'Login as this User' }),
  ).toBeVisible({ timeout: 10_000 });
});

test('TC-E2E-002: an unknown user cannot reach the workspace', async ({ page }) => {
  await page.goto('/');
  await page
    .getByLabel('Enter any username for DEBUG login')
    .fill('ghost.user@hellodnk8n.onmicrosoft.com');
  await page.getByRole('button', { name: 'Login as this User' }).click();

  // Whatever the exact failure UX, the authenticated menu must not appear.
  await page.waitForTimeout(3000);
  await expect(page.getByRole('menuitem', { name: 'Time Trackings' })).toHaveCount(0);
});
