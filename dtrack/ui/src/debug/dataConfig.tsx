import postgrestRestProvider from '@raphiniert/ra-data-postgrest';
import { fetchUtils, Options } from 'react-admin';

import { config } from '../config';
const postgrestHttpClient =
  () =>
  async (url: string, options: Options = {}) => {
    const token = localStorage.getItem('debug-token');
    const user = { authenticated: !!token, token: `Bearer ${token}` };
    return fetchUtils.fetchJson(url, { ...options, user });
  };
export const debugDataProvider = postgrestRestProvider(
  config.apiBaseUri,
  postgrestHttpClient(),
);
