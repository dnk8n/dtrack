import { EmployeeProfile, getEmployeeProfile } from '../EmployeeProfile';

let cachedProfile: EmployeeProfile | null = null;
const getCachedEmployeeProfile = async () => {
  if (cachedProfile) return cachedProfile;
  const token = localStorage.getItem('debug-token') || undefined;
  cachedProfile = await getEmployeeProfile(token);
  return cachedProfile;
};

export const debugAuthProvider = {
  async login(token: string) {
    localStorage.setItem('debug-token', token);
    return Promise.resolve();
  },
  async logout() {
    localStorage.removeItem('debug-token');
    cachedProfile = null;
    return Promise.resolve();
  },
  async checkAuth() {
    return localStorage.getItem('debug-token') ? Promise.resolve() : Promise.reject();
  },
  async getIdentity() {
    try {
      const employeeProfile = await getCachedEmployeeProfile();
      return Promise.resolve({
        id: employeeProfile?.id,
        email: employeeProfile?.email,
        fullName: employeeProfile?.fullName,
      });
    } catch (error) {
      return Promise.reject(error);
    }
  },
  async getPermissions() {
    try {
      const employeeProfile = await getCachedEmployeeProfile();
      return Promise.resolve({ roles: employeeProfile?.roles });
    } catch (error) {
      return Promise.reject(error);
    }
  },
  async checkError(error: { status: number }) {
    const status = error.status;
    if (status === 401 || status === 403) {
      return Promise.reject();
    }
    return Promise.resolve();
  },
  async handleCallback() {
    const query = window.location.search;
    console.log(query);
    // if (!query.includes('code=') && !query.includes('state=')) {
    //   throw new Error('Failed to handle login callback.');
    // }
    // // If we did receive the Auth0 parameters,
    // // get an access token based on the query paramaters
    // await Auth0Client.handleRedirectCallback();
    return Promise.reject();
  },
};
