import {
  Autocomplete as MuiAutocomplete,
  Box,
  TextField as MuiTextField,
  Typography,
} from '@mui/material';
import { useEffect, useState } from 'react';
import {
  AutocompleteArrayInput,
  AutocompleteArrayInputProps,
  AutocompleteInput,
  AutocompleteInputProps,
  BooleanInput,
  BulkDeleteButton,
  ChipField,
  Create,
  CreateButton,
  CreateProps,
  Datagrid,
  DeleteButton,
  Edit,
  EditButton,
  EditProps,
  FieldProps,
  FilterButton,
  FormDataConsumer,
  FunctionField,
  List,
  ReferenceArrayField,
  SelectInput,
  Show,
  SimpleForm,
  SingleFieldList,
  TabbedShowLayout,
  TextField,
  TextInput,
  TopToolbar,
  useDataProvider,
  useGetIdentity,
  useGetList,
  usePermissions,
  useShowController,
} from 'react-admin';
import { useWatch } from 'react-hook-form';

import { CalendarView } from '../charts/CalendarView/CalendarView';
import { SunburstZoomChart } from '../charts/SunburstChart/SunburstZoomChart';
import { ArrayCountField } from '../utils/ArrayCountField';
import {
  DateGranularitySelect,
  DateRangeSelect,
  defaultDaterange,
  Option,
} from '../utils/Dropdowns';
import { handleSummaryExport } from '../utils/utils';

interface EmployeeRecord {
  [key: string]: unknown;
  id: number;
  username: string;
  email: string;
  first_name: string;
  last_name: string;
  position: string;
  member_of_projects: string[];
  lead_of_projects: string[];
  roles: string[];
}

const RolesField = (props: FieldProps<EmployeeRecord>) => (
  <FunctionField
    {...props}
    render={(record: { roles: string[] }) => {
      if (!record || !record.roles) {
        return null;
      }
      return record.roles.map((role, index) => (
        <ChipField key={index} record={{ name: role }} source="name" size="small" />
      ));
    }}
  />
);

const EmployeeSelectInputFilter = (props: AutocompleteInputProps) => {
  const { data, isLoading } = useGetList('employees', {
    pagination: { page: 1, perPage: Number.MAX_SAFE_INTEGER },
    sort: { field: 'username', order: 'asc' },
    meta: { columns: ['id', 'name:username'] },
  });
  if (isLoading) return null;
  return (
    <AutocompleteInput choices={data} optionValue="id" optionText="name" {...props} />
  );
};

const ProjectSelectInput = (props: AutocompleteArrayInputProps) => {
  const { data, isLoading } = useGetList('projects', {
    pagination: { page: 1, perPage: Number.MAX_SAFE_INTEGER },
    sort: { field: 'id', order: 'asc' },
    meta: { columns: ['id', 'name'] },
  });
  const lead_of_project_ids = useWatch({ name: 'lead_of_project_ids' }) || [];
  const member_of_project_ids = useWatch({ name: 'member_of_project_ids' }) || [];
  let filteredData = data || [];
  if (props.source === 'lead_of_project_ids') {
    filteredData = (data || []).filter(
      (employee) => !member_of_project_ids.includes(employee.id),
    );
  } else if (props.source === 'member_of_project_ids') {
    filteredData = (data || []).filter(
      (employee) => !lead_of_project_ids.includes(employee.id),
    );
  }
  if (isLoading) return null;
  return <AutocompleteArrayInput choices={filteredData} {...props} />;
};

// Make Dry
const ProjectSelectInputFilter = (props: AutocompleteInputProps) => {
  const { data, isLoading } = useGetList('projects', {
    pagination: { page: 1, perPage: Number.MAX_SAFE_INTEGER },
    sort: { field: 'id', order: 'asc' },
    meta: { columns: ['id', 'name'] },
  });
  if (isLoading) return null;
  return (
    <AutocompleteInput choices={data} optionValue="id" optionText="name" {...props} />
  );
};

// Make Dry
const TeamSelectInputFilter = (props: AutocompleteInputProps) => {
  const { data, isLoading } = useGetList('aoe_teams', {
    pagination: { page: 1, perPage: Number.MAX_SAFE_INTEGER },
    sort: { field: 'id', order: 'asc' },
    meta: { columns: ['id', 'name'] },
  });
  if (isLoading) return null;
  const choices = data?.map((item) => ({
    id: `"${item.id}"`,
    name: item.name,
  }));
  return (
    <AutocompleteInput choices={choices} optionValue="id" optionText="name" {...props} />
  );
};

const EmployeeFilters = [
  <EmployeeSelectInputFilter key="n" label="Employee" source="id" />,
  <SelectInput
    key="r"
    label="Role"
    choices={['Basic', 'Lead', 'PM', 'Power'].map((role) => ({
      id: `"${role.toLowerCase()}"`,
      name: role,
    }))}
    source="roles@cs"
  />,
  <ProjectSelectInputFilter key="lop" label="PMs of" source="lead_of_project_ids@cs" />,
  <ProjectSelectInputFilter
    key="mop"
    label="Members of Project"
    source="member_of_project_ids@cs"
  />,
  <TeamSelectInputFilter key="lot" label="Team Leads of" source="lead_of_team_ids@cs" />,
  <TeamSelectInputFilter
    key="mot"
    label="Members of Teams"
    source="member_of_team_ids@cs"
  />,
  <TextInput key="fn" label="First Name" source="first_name@ilike" />,
  <TextInput key="ln" label="Last Name" source="last_name@ilike" />,
  <TextInput key="p" label="Position" source="position@ilike" />,
];

export const EmployeeList = () => {
  const { data: identity, isLoading: identityLoading } = useGetIdentity();
  const { permissions, isLoading: permissionsLoading } = usePermissions();
  if (identityLoading || permissionsLoading) return null;
  return (
    <List
      sort={{ field: 'username', order: 'asc' }}
      actions={
        <TopToolbar>
          {permissions.roles.includes('power') && (
            <>
              <CreateButton />
              <FilterButton />
            </>
          )}
        </TopToolbar>
      }
      empty={false}
      filters={permissions.roles.includes('power') ? EmployeeFilters : []}
      filter={permissions.roles.includes('power') ? {} : { id: identity?.id }}
    >
      <Datagrid
        rowClick="show"
        bulkActionButtons={
          permissions.roles.includes('power') ? (
            <BulkDeleteButton mutationMode="pessimistic" />
          ) : (
            false
          )
        }
      >
        <TextField source="username" />
        <RolesField source="roles" sortable={false} />
        <ArrayCountField label="# of Projects PM of" source="lead_of_projects" />
        <ArrayCountField label="# of Projects Member of" source="member_of_projects" />
        <ArrayCountField label="# of Teams Lead of" source="lead_of_teams" />
        <ArrayCountField label="# of Teams Member of" source="member_of_teams" />
        <TextField source="first_name" />
        <TextField source="last_name" />
        <TextField source="position" />
      </Datagrid>
    </List>
  );
};

export const EmployeeShow = () => {
  const { record } = useShowController({ resource: 'employees' });
  const [axes, setAxes] = useState<Option[]>([
    { label: 'Activity', value: 'activity' },
    { label: 'Project', value: 'project' },
    { label: 'AoW', value: 'aow' },
  ]);
  const [granularity, setGranularity] = useState<Option>({
    label: 'Month',
    value: 'month',
  });
  const [daterange, setDaterange] = useState<Option>(defaultDaterange(granularity));
  useEffect(() => {
    setDaterange(defaultDaterange(granularity));
  }, [granularity]);
  const axesValues = axes.map((option) => option.value);
  const { data, isLoading: timetrackingLoading } = useGetList(
    'rpc/timetracking_summary',
    {
      pagination: { page: 1, perPage: Number.MAX_SAFE_INTEGER },
      filter: {
        'axes@': `{${['user', 'daterange', ...axesValues].join(',')}}`,
        'date_part@': granularity.value,
        'zoom_level@': '2',
        ...(record ? { user_id: record?.id } : {}),
        'daterange@cs': daterange.value,
      },
      meta: { columns: ['id', 'user_id', 'daterange', 'data'] },
    },
    { enabled: Number.isInteger(record?.id) },
  );
  const dataProvider = useDataProvider();
  const handleDownload = async () => {
    // The reason for using the dataProvider directly is that the getList method can be defined
    // to trigger on condition of clicking the download button, which is not possible with the
    // useGetList hook.
    const { data } = await dataProvider.getList('rpc/timetracking_summary_export', {
      pagination: { page: 1, perPage: Number.MAX_SAFE_INTEGER },
      filter: {
        'user->id': record?.id,
        'axes@': `{${['user', 'daterange', ...axesValues].join(',')}}`,
        'date_part@': granularity.value,
        'daterange@cs': daterange.value,
      },
      sort: { field: 'id', order: 'ASC' },
      meta: {
        columns: ['id', 'user', 'daterange', ...axesValues, 'total_duration'],
      },
    });
    handleSummaryExport(data);
  };
  const { data: identity, isLoading: identityLoading } = useGetIdentity();
  const { permissions, isLoading: permissionsLoading } = usePermissions();
  const { data: isTeamMember, isLoading: isTeamMemberLoading } = useGetList(
    'aoe_teams',
    {
      pagination: { page: 1, perPage: 1 },
      filter: {
        'and@': `(member_ids.cs.${record?.id},lead->id.eq.${identity?.id})`,
      },
      meta: { columns: ['id'] },
    },
    {
      enabled:
        !permissions.roles.includes('power') &&
        permissions.roles.includes('lead') &&
        Number.isInteger(record?.id) &&
        Number.isInteger(identity?.id),
    },
  );
  if (permissionsLoading || timetrackingLoading || identityLoading || isTeamMemberLoading)
    return null;
  const canViewComponents =
    permissions.roles.includes('power') ||
    record?.id === identity?.id ||
    (isTeamMember || [])?.length > 0;
  return (
    <Show
      actions={
        <TopToolbar>
          {permissions.roles.includes('power') && (
            <>
              <EditButton /> <DeleteButton mutationMode="pessimistic" />
            </>
          )}
        </TopToolbar>
      }
    >
      <TabbedShowLayout>
        <TabbedShowLayout.Tab label="Summary">
          <TextField source="username" />
          <TextField source="email" />
          <RolesField source="roles" sortable={false} />
          <ReferenceArrayField
            label="PM of"
            source="lead_of_project_ids"
            reference="projects"
          >
            <SingleFieldList linkType="show">
              <ChipField source="name" size="small" clickable />
            </SingleFieldList>
          </ReferenceArrayField>
          <ReferenceArrayField
            label="Member of Projects"
            source="member_of_project_ids"
            reference="projects"
          >
            <SingleFieldList linkType="show">
              <ChipField source="name" size="small" clickable />
            </SingleFieldList>
          </ReferenceArrayField>
          <ReferenceArrayField
            label="Team Lead of"
            source="lead_of_team_ids"
            reference="aoe_teams"
          >
            <SingleFieldList linkType="show">
              <ChipField source="name" size="small" clickable />
            </SingleFieldList>
          </ReferenceArrayField>
          <ReferenceArrayField
            label="Member of Teams"
            source="member_of_team_ids"
            reference="aoe_teams"
          >
            <SingleFieldList linkType="show">
              <ChipField source="name" size="small" clickable />
            </SingleFieldList>
          </ReferenceArrayField>
          <TextField source="first_name" />
          <TextField source="last_name" />
          <TextField source="position" />
        </TabbedShowLayout.Tab>
        {canViewComponents && (
          <TabbedShowLayout.Tab label="Chart">
            <Box display="flex" className="chart-container">
              <Box className="chart-left">
                <TextField source="username" />
                <MuiAutocomplete
                  size="small"
                  multiple
                  value={axes}
                  options={[
                    { label: 'Activity', value: 'activity' },
                    { label: 'Project', value: 'project' },
                    { label: 'AoW', value: 'aow' },
                  ]}
                  filterSelectedOptions
                  isOptionEqualToValue={(option, value) => option.value === value.value}
                  onChange={(_event, newValue: Option[]) => {
                    if (newValue !== null) {
                      setAxes(newValue);
                    }
                  }}
                  renderInput={(params) => <MuiTextField {...params} label="Axes" />}
                />
                <DateGranularitySelect
                  granularity={granularity}
                  setGranularity={setGranularity}
                />
                <DateRangeSelect
                  daterange={daterange}
                  setDaterange={setDaterange}
                  filter={{ 'dims@': '{user_id}', 'dimensions->>user_id': record?.id }}
                  granularity={granularity}
                />
              </Box>
              {data?.length === 0 ? (
                <Box className="chart">
                  <Typography variant="h6" align="center">
                    No data available for the current filter combinations.
                  </Typography>
                </Box>
              ) : data?.length === 1 ? (
                <SunburstZoomChart
                  data={{ name: 'Timetracking Summary', children: data[0].data || [] }}
                  handleDownload={handleDownload}
                />
              ) : (
                <Box className="chart" />
              )}
              <Box className="chart-right" />
            </Box>
          </TabbedShowLayout.Tab>
        )}
        {canViewComponents && (
          <TabbedShowLayout.Tab label="Calendar">
            {record && <CalendarView userId={record.id} />}
          </TabbedShowLayout.Tab>
        )}
      </TabbedShowLayout>
    </Show>
  );
};

type EmployeeFormProps = {
  mode: 'create' | 'edit';
};

const validateUsername = (value: string) => {
  const regex = /^[A-Z][a-z]*\.[A-Z][a-z]*$/;
  return regex.test(value)
    ? undefined
    : 'Invalid format. The username should be "{FirstName}.{LastName}"';
};

const EmployeeForm: React.FC<EmployeeFormProps> = ({ mode }) => {
  const { permissions, isLoading: permissionsLoading } = usePermissions();
  const { data: identity, isLoading: identityLoading } = useGetIdentity();
  if (permissionsLoading || identityLoading) return null;
  // New employees get the signed-in admin's email domain, mirroring
  // internal.employees_upsert, so no tenant domain is hard-coded.
  const emailDomain = String(identity?.email ?? '').split('@')[1] ?? '';
  return (
    <SimpleForm>
      <TextInput
        disabled={mode === 'edit'}
        source="username"
        validate={validateUsername}
      />
      {mode === 'create' && (
        <FormDataConsumer>
          {({ formData, ...rest }) =>
            formData.username && (
              <>
                <TextInput
                  disabled
                  source="email"
                  format={() => `${formData.username}@${emailDomain}`}
                />
                <TextInput
                  disabled
                  source="first_name"
                  format={() => formData.username.split('.')[0] || ''}
                  {...rest}
                />
                <TextInput
                  disabled
                  source="last_name"
                  format={() => formData.username.split('.')[1] || ''}
                  {...rest}
                />
              </>
            )
          }
        </FormDataConsumer>
      )}
      {mode === 'edit' && (
        <>
          <TextInput disabled source="email" />
          <TextInput disabled source="roles" />
          <TextInput source="first_name" />
          <TextInput source="last_name" />
        </>
      )}
      <TextInput source="position" />
      <ProjectSelectInput label="PM of" source="lead_of_project_ids" fullWidth />
      <ProjectSelectInput
        label="Member of Projects"
        source="member_of_project_ids"
        fullWidth
      />
      {permissions.roles.includes('power') && (
        <>
          <BooleanInput label="Is Power User?" source="is_power" defaultValue={false} />
        </>
      )}
    </SimpleForm>
  );
};

export const EmployeeCreate: React.FC<CreateProps> = (props) => (
  <Create {...props}>
    <EmployeeForm mode="create" />
  </Create>
);

export const EmployeeEdit: React.FC<EditProps> = (props) => (
  <Edit {...props}>
    <EmployeeForm mode="edit" />
  </Edit>
);
