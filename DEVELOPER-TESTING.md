# Developer End-to-End Testing

## Remote Dev Check

Use this as the primary real-environment test flow.

### Prerequisites

1. Prepare two real machines:
   - server host: ForgeLine will be installed here
   - client host: ForgeLine Bridge will be installed and tested here

2. From this repo on your developer machine, create a real config file from the sample:

```bash
cp .env.sample .env
```

3. Edit `.env` and fill in:
   - `SERVER_HOST`
   - `SERVER_USER`
   - `SERVER_FORGELINE_ROOT`
   - `CLIENT_HOST`
   - `CLIENT_USER`
   - `FORGELINE_BRIDGE_ROOT`

4. Ensure your developer machine can SSH to both hosts:

```bash
ssh -p "${SERVER_SSH_PORT:-22}" "${SERVER_USER}@${SERVER_HOST}" 'echo ok'
ssh -p "${CLIENT_SSH_PORT:-22}" "${CLIENT_USER}@${CLIENT_HOST}" 'echo ok'
```

Each command should print:

```text
ok
```

5. Ensure the client host can SSH to the server host.
   If that trust is not already set up, set:

```bash
BOOTSTRAP_CLIENT_SSH_TO_SERVER=true
```

Then verify from the client host:

```bash
ssh -p "${SERVER_SSH_PORT:-22}" "${SERVER_USER}@${SERVER_HOST}" 'echo ok'
```

### Run

```bash
./remote-devcheck.sh --config ./.env
```

What this does:

- stages this repo to both hosts
- installs ForgeLine on the server host
- ensures the ForgeLine server is running before the real check proceeds
- installs ForgeLine Bridge on the client host
- runs `devcheck.sh` on the client host
- pulls logs back into `.run/remote-devcheck/<timestamp>/`

Useful partial rerun flags:

```bash
./remote-devcheck.sh --config ./.env --skip-devcheck
```

`--skip-devcheck` still installs ForgeLine and ForgeLine Bridge and starts both services. It only skips the final deep real-environment test run.

For a destructive clean rerun that removes both remote ForgeLine roots before reinstalling:

```bash
./remote-devcheck.sh --fresh
```

## Advanced: Run DevCheck Directly On The Client Host

Use this only if you want to run the lower-level real-environment test manually.

### Prerequisites

1. ForgeLine server is already installed and running on the server host.
2. ForgeLine Bridge is already installed on the client host.
3. The client host can SSH to the server host without a password.

### Run on the client host

```bash
export SERVER_HOST=<server-host-or-ip>
export SERVER_USER=<server-ssh-user>
export SERVER_FORGELINE_ROOT=<server-forgeline-root>
export FORGELINE_BRIDGE_ROOT=<client-bridge-root>

bash ./devcheck.sh
```

Or from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/devcheck.sh | bash
```

After the run:

- bridge logs are under `$FORGELINE_BRIDGE_ROOT/.devcheck/logs/`
- `devcheck.sh` manages bridge startup itself
- `devcheck.sh` expects the remote ForgeLine server to already be running
