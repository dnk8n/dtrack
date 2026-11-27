import AccessTimeIcon from '@mui/icons-material/AccessTime';
import EmojiObjectsIcon from '@mui/icons-material/EmojiObjects';
import FolderSpecialIcon from '@mui/icons-material/FolderSpecial';
import GroupsIcon from '@mui/icons-material/Groups';
import HelpOutlineIcon from '@mui/icons-material/HelpOutline';
import ListAltIcon from '@mui/icons-material/ListAlt';
import PersonIcon from '@mui/icons-material/Person';
import PlaceIcon from '@mui/icons-material/Place';
import { LoginPage as ProductionLoginPage } from 'ra-auth-msal';
import { Admin, AuthProvider, DataProvider, LoginComponent, Resource } from 'react-admin';
import { defaultTheme } from 'react-admin';
import { BrowserRouter } from 'react-router-dom';

import { authProvider as productionAuthProvider } from './authConfig';
import { config } from './config';
import { Dashboard } from './Dashboard';
import { dataProvider as productionDataProvider } from './dataConfig';
import { debugAuthProvider } from './debug/authConfig';
import { debugDataProvider } from './debug/dataConfig';
import { DebugLoginPage } from './debug/LoginPage';
import { CustomLayout } from './Layout';
import {
  ActivityCreate,
  ActivityEdit,
  ActivityList,
  ActivityShow,
} from './sections/activities';
import { AoECreate, AoEEdit, AoEList, AoEShow } from './sections/areas_of_expertise';
import { AoWCreate, AoWEdit, AoWList, AoWShow } from './sections/areas_of_work';
import {
  EmployeeCreate,
  EmployeeEdit,
  EmployeeList,
  EmployeeShow,
} from './sections/employees';
import { FaqCreate, FaqEdit, FaqList, FaqShow } from './sections/faq';
import {
  ProjectCreate,
  ProjectEdit,
  ProjectList,
  ProjectShow,
} from './sections/projects';
import { TeamCreate, TeamEdit, TeamList, TeamShow } from './sections/teams';
import {
  TimeTrackingCreate,
  TimeTrackingEdit,
  TimeTrackingList,
  TimeTrackingShow,
} from './sections/time_trackings';

let LoginPage: LoginComponent;
let authProvider: AuthProvider;
let dataProvider: DataProvider;

if (import.meta.env.VITE_ENVIRONMENT === 'DEBUG') {
  console.warn('VITE_ENVIRONMENT === DEBUG');
  LoginPage = DebugLoginPage;
  authProvider = debugAuthProvider;
  dataProvider = debugDataProvider;
} else {
  LoginPage = ProductionLoginPage;
  authProvider = productionAuthProvider;
  dataProvider = productionDataProvider;
}

const theme = {
  ...defaultTheme,
  palette: {
    primary: {
      main: config.palettePrimary,
    },
    secondary: {
      main: config.paletteSecondary,
    },
  },
};

export const App = () => {
  return (
    <BrowserRouter>
      <Admin
        title="DTrack"
        loginPage={LoginPage}
        dashboard={Dashboard}
        layout={CustomLayout}
        theme={theme}
        dataProvider={dataProvider}
        authProvider={authProvider}
        requireAuth
        disableTelemetry
      >
        {(_permissions) => (
          <>
            <Resource
              name="time_trackings"
              list={TimeTrackingList}
              edit={TimeTrackingEdit}
              show={TimeTrackingShow}
              create={TimeTrackingCreate}
              icon={AccessTimeIcon}
            />
            <Resource
              name="areas_of_work"
              list={AoWList}
              create={AoWCreate}
              edit={AoWEdit}
              show={AoWShow}
              icon={PlaceIcon}
              options={{ label: 'AoWs' }}
            />
            <Resource
              name="projects"
              list={ProjectList}
              create={ProjectCreate}
              edit={ProjectEdit}
              show={ProjectShow}
              icon={FolderSpecialIcon}
            />
            <Resource
              name="activities"
              list={ActivityList}
              create={ActivityCreate}
              edit={ActivityEdit}
              show={ActivityShow}
              icon={ListAltIcon}
            />
            <Resource
              name="areas_of_expertise"
              list={AoEList}
              create={AoECreate}
              edit={AoEEdit}
              show={AoEShow}
              icon={EmojiObjectsIcon}
              options={{ label: 'AoEs' }}
            />
            <Resource
              name="aoe_teams"
              list={TeamList}
              create={TeamCreate}
              edit={TeamEdit}
              show={TeamShow}
              icon={GroupsIcon}
              options={{ label: 'Teams' }}
            />
            <Resource
              name="employees"
              list={EmployeeList}
              show={EmployeeShow}
              icon={PersonIcon}
              edit={EmployeeEdit}
              create={EmployeeCreate}
            />
            <Resource
              name="faqs"
              list={FaqList}
              edit={FaqEdit}
              create={FaqCreate}
              show={FaqShow}
              icon={HelpOutlineIcon}
              options={{ label: 'FAQs' }}
            />
          </>
        )}
      </Admin>
    </BrowserRouter>
  );
};
export default App;
