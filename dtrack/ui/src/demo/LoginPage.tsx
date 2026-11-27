import WarningIcon from '@mui/icons-material/Warning';
import { Button, Container, Paper, TextField, Typography } from '@mui/material';
import { KJUR } from 'jsrsasign';
import React, { useState } from 'react';
import { Notification, useLogin, useNotify } from 'react-admin';

export const DemoLoginPage = () => {
  const [username, setUsername] = useState('');
  const login = useLogin();
  const notify = useNotify();
  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault();
    const header = { alg: 'HS256', typ: 'JWT' };
    const payload = { preferred_username: username };
    const secret = import.meta.env.VITE_JWT_SECRET as string;
    const token = KJUR.jws.JWS.sign(null, header, payload, secret);
    login(token).catch(() => notify('Invalid username'));
  };
  return (
    <Container component="main" maxWidth="xs">
      <Paper elevation={3} style={{ padding: '20px' }}>
        <Typography variant="h5" gutterBottom>
          Demo Login
        </Typography>
        <Typography variant="body1" color="error" gutterBottom>
          <WarningIcon fontSize="small" /> Demo login: no password, anyone can sign in as
          any user. Never use with real data.
        </Typography>
        <form onSubmit={handleSubmit}>
          <TextField
            variant="outlined"
            margin="normal"
            fullWidth
            name="username"
            type="email"
            value={username}
            onChange={(event) => setUsername(event.target.value)}
            label="Enter any username for DEMO login"
          />
          <Button
            type="submit"
            fullWidth
            variant="contained"
            color="secondary"
            style={{ marginTop: '10px' }}
          >
            Login as this User
          </Button>
        </form>
        <Notification />
      </Paper>
    </Container>
  );
};
