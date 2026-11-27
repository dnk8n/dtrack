import {
  AccountInfo,
  Configuration,
  PublicClientApplication,
  RedirectRequest,
  SilentRequest,
} from '@azure/msal-browser';
import { msalAuthProvider } from 'ra-auth-msal';

import { EmployeeProfile, getEmployeeProfile } from './EmployeeProfile';

const msalConfig: Configuration = {
  auth: {
    clientId: import.meta.env.VITE_MSAL_CLIENT_ID,
    authority: import.meta.env.VITE_MSAL_AUTHORITY,
    redirectUri: `${import.meta.env.VITE_APP_BASE_URI}/auth-callback`,
    navigateToLoginRequestUrl: false,
  },
  cache: {
    cacheLocation: 'localStorage',
  },
};

const loginRequest: RedirectRequest = {
  scopes: ['User.Read'],
};

interface CachedProfile {
  idToken?: string;
  profile?: EmployeeProfile;
}
let cachedProfile: CachedProfile = {};
const getCachedEmployeeProfile = async (idToken?: string) => {
  if (cachedProfile.idToken === idToken) {
    return cachedProfile.profile;
  }
  try {
    const profile = await getEmployeeProfile(idToken);
    cachedProfile = { idToken, profile };
    return profile;
  } catch (error) {
    throw new Error(`Error fetching employee profile: ${error}`);
  }
};

const getIdentityFromAccount = async (account: AccountInfo) => {
  const employeeProfile = await getCachedEmployeeProfile(account.idToken);
  return {
    ...account,
    id: employeeProfile?.id,
    email: employeeProfile?.email,
    fullName: employeeProfile?.fullName || account.name,
  };
};

const getPermissionsFromAccount = async (account: AccountInfo) => {
  const employeeProfile = await getCachedEmployeeProfile(account.idToken);
  return { roles: employeeProfile?.roles };
};

export const tokenRequest: SilentRequest = {
  scopes: ['User.Read'],
  forceRefresh: false,
};

export const msalInstance = new PublicClientApplication(msalConfig);

export const authProvider = msalAuthProvider({
  msalInstance,
  loginRequest,
  tokenRequest,
  getPermissionsFromAccount,
  getIdentityFromAccount,
  redirectOnCheckAuth: true,
});
