import { config } from './config';

let onboardInProgress = false;
let lastOnboardFailureTime = 0;

export interface EmployeeProfile {
  id: number;
  fullName: string;
  email: string;
  roles: string[];
}

export const getEmployeeProfile = async (
  idToken?: string,
  depth = 0,
): Promise<EmployeeProfile> => {
  if (idToken) {
    // Too early to be able to use data provider here as it is not yet initialised at this stage
    // TODO: Possibly implement error handling in case the call to current_employee fails
    const response = await fetch(
      `${config.apiBaseUri}/current_employee?select=id,email,first_name,last_name,roles`,
      {
        method: 'GET',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          Authorization: `Bearer ${idToken}`,
        },
      },
    );
    if (response.ok) {
      const data = await response.json();
      return {
        id: data[0].id,
        email: data[0].email,
        fullName: `${data[0].first_name} ${data[0].last_name}`,
        roles: data[0].roles,
      };
    } else {
      // TODO: Consider async-mutex for race conditions
      const errorMsg = await response.text();
      if (errorMsg && errorMsg.includes('role') && errorMsg.includes('does not exist')) {
        if (!onboardInProgress) {
          const currentTime = Date.now();
          if (currentTime - lastOnboardFailureTime > 3600000) {
            // 1 hour in milliseconds
            onboardInProgress = true;
            try {
              await fetch(`${config.apiBaseUri}/rpc/onboard`, {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/json',
                  Accept: 'application/json',
                },
                body: JSON.stringify({ id_token: idToken }),
              });
            } catch (error) {
              lastOnboardFailureTime = currentTime;
              throw error;
            } finally {
              onboardInProgress = false;
            }
          }
        } else {
          const maxWaitTime = 100000; // 100 seconds
          const startTime = Date.now();
          while (onboardInProgress && Date.now() - startTime < maxWaitTime) {
            await new Promise((resolve) => setTimeout(resolve, 100));
          }
          if (onboardInProgress) {
            // Assume that onboardInProgress is actually false
            onboardInProgress = false;
          }
        }
        // Since Onboarding appears to be successful, rerun getEmployment so
        // that we can call current_employee
        if (depth < 3) {
          return await getEmployeeProfile(idToken, depth + 1);
        }
      }
    }
  }
  throw new Error('Invalid token or unexpected error in getEmployeeProfile');
};
