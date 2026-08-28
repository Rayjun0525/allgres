-- pgcrypto is optional.  With it plus `allgres.secret_key` in postgresql.conf,
-- provider API keys are encrypted at rest; without it they are stored in
-- plaintext and the dashboard says so.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS allgres;
