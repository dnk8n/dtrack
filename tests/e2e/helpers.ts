import { expect, Page } from '@playwright/test';

/** The initial power user created by initdb.sh ($POSTGRES_USER_APP_POWER). */
export const POWER_EMAIL =
  process.env.DTRACK_TEST_POWER_EMAIL ?? 'Dummy.User@example.com';

/** Unique per test run so created entities never collide with residue. */
export const runId = Date.now().toString(36);

/** Log in through the debug login page (VITE_ENVIRONMENT=DEBUG builds). */
export async function login(page: Page, email: string): Promise<void> {
  await page.goto('/');
  await page.getByLabel('Enter any username for DEBUG login').fill(email);
  await page.getByRole('button', { name: 'Login as this User' }).click();
  await expect(page.getByRole('menuitem', { name: 'Time Trackings' })).toBeVisible({
    timeout: 15_000,
  });
}

/** Fill a react-admin (MUI) autocomplete input and pick the matching option. */
export async function pickOption(
  page: Page,
  label: string | RegExp,
  optionText: string,
): Promise<void> {
  const input = page.getByRole('combobox', { name: label });
  await input.click();
  await input.fill(optionText);
  await page.getByRole('option', { name: optionText, exact: true }).click();
}

/** Wait for react-admin's "Element created" snackbar. */
export async function expectCreated(page: Page): Promise<void> {
  await expect(page.getByText('Element created')).toBeVisible({ timeout: 10_000 });
}
