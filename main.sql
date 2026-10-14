-- builds the whole database; run from any directory: psql -d <db> -f main.sql
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\ir schema.sql
\ir rules.sql
\ir views.sql
\ir sample_data.sql
