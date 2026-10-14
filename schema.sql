-- tables, keys, constraints, indexes; safe to re-run

DROP TABLE IF EXISTS league_members, leagues, transfers, lineups, squad, teams, users,
                     player_stats, fixtures, gameweeks, players, clubs, positions CASCADE;

-- football side

-- positions carry squad limits and position-specific scoring
CREATE TABLE positions (
    position_id        smallint PRIMARY KEY,
    code               text     NOT NULL UNIQUE,      -- GKP, DEF, MID, FWD
    name               text     NOT NULL,
    squad_size         smallint NOT NULL,             -- players of this position in a squad
    min_starters       smallint NOT NULL,
    max_starters       smallint NOT NULL,
    goal_points        smallint NOT NULL,
    clean_sheet_points smallint NOT NULL,
    CHECK (1 <= min_starters AND min_starters <= max_starters AND max_starters <= squad_size)
);

CREATE TABLE clubs (
    club_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text    NOT NULL UNIQUE,
    short_name text    NOT NULL UNIQUE CHECK (length(short_name) = 3)
);

CREATE TABLE players (
    player_id   integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    club_id     integer      NOT NULL REFERENCES clubs,
    position_id smallint     NOT NULL REFERENCES positions,
    name        text         NOT NULL,
    price       numeric(4,1) NOT NULL CHECK (price > 0)     -- millions
);

CREATE TABLE gameweeks (
    gameweek_id smallint    PRIMARY KEY CHECK (gameweek_id BETWEEN 1 AND 38),
    deadline    timestamptz NOT NULL
);

CREATE TABLE fixtures (
    fixture_id   integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gameweek_id  smallint    NOT NULL REFERENCES gameweeks,
    home_club_id integer     NOT NULL REFERENCES clubs,
    away_club_id integer     NOT NULL REFERENCES clubs,
    kickoff      timestamptz NOT NULL,
    home_score   smallint    CHECK (home_score >= 0),
    away_score   smallint    CHECK (away_score >= 0),
    UNIQUE (gameweek_id, home_club_id, away_club_id),
    CHECK (home_club_id <> away_club_id),
    CHECK ((home_score IS NULL) = (away_score IS NULL))     -- both or none
);

CREATE TABLE player_stats (
    player_id    integer  NOT NULL REFERENCES players,
    fixture_id   integer  NOT NULL REFERENCES fixtures,
    minutes      smallint NOT NULL DEFAULT 0 CHECK (minutes BETWEEN 0 AND 120),
    goals        smallint NOT NULL DEFAULT 0 CHECK (goals >= 0),
    assists      smallint NOT NULL DEFAULT 0 CHECK (assists >= 0),
    clean_sheet  boolean  NOT NULL DEFAULT false,
    saves        smallint NOT NULL DEFAULT 0 CHECK (saves >= 0),
    yellow_cards smallint NOT NULL DEFAULT 0 CHECK (yellow_cards BETWEEN 0 AND 2),
    red_cards    smallint NOT NULL DEFAULT 0 CHECK (red_cards BETWEEN 0 AND 1),
    bonus        smallint NOT NULL DEFAULT 0 CHECK (bonus BETWEEN 0 AND 3),
    PRIMARY KEY (player_id, fixture_id),
    CHECK (minutes > 0 OR (goals = 0 AND assists = 0 AND NOT clean_sheet))
);

-- game side

CREATE TABLE users (
    user_id    integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username   text        NOT NULL UNIQUE CHECK (length(username) BETWEEN 3 AND 30),
    email      text        NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- one team per user
CREATE TABLE teams (
    team_id integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id integer      NOT NULL UNIQUE REFERENCES users,
    name    text         NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
    budget  numeric(5,1) NOT NULL DEFAULT 100.0 CHECK (budget > 0)
);

-- current squad; limits are enforced in rules.sql
CREATE TABLE squad (
    team_id   integer NOT NULL REFERENCES teams ON DELETE CASCADE,
    player_id integer NOT NULL REFERENCES players,
    PRIMARY KEY (team_id, player_id)
);

-- picks per gameweek; history of who actually counted
CREATE TABLE lineups (
    team_id     integer  NOT NULL REFERENCES teams ON DELETE CASCADE,
    gameweek_id smallint NOT NULL REFERENCES gameweeks,
    player_id   integer  NOT NULL REFERENCES players,
    is_starter  boolean  NOT NULL,
    is_captain  boolean  NOT NULL DEFAULT false,
    is_vice     boolean  NOT NULL DEFAULT false,
    bench_order smallint CHECK (bench_order BETWEEN 1 AND 4),
    PRIMARY KEY (team_id, gameweek_id, player_id),
    CHECK (NOT is_captain OR is_starter),
    CHECK (NOT is_vice OR is_starter),
    CHECK (NOT (is_captain AND is_vice)),
    CHECK ((is_starter AND bench_order IS NULL) OR (NOT is_starter AND bench_order IS NOT NULL))
);

-- at most one captain, vice and bench slot per team and gameweek
CREATE UNIQUE INDEX uq_lineups_captain ON lineups (team_id, gameweek_id) WHERE is_captain;
CREATE UNIQUE INDEX uq_lineups_vice    ON lineups (team_id, gameweek_id) WHERE is_vice;
CREATE UNIQUE INDEX uq_lineups_bench   ON lineups (team_id, gameweek_id, bench_order) WHERE bench_order IS NOT NULL;

CREATE TABLE transfers (
    transfer_id integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_id     integer      NOT NULL REFERENCES teams ON DELETE CASCADE,
    gameweek_id smallint     NOT NULL REFERENCES gameweeks,
    player_out  integer      NOT NULL REFERENCES players,
    player_in   integer      NOT NULL REFERENCES players,
    price_out   numeric(4,1) NOT NULL,
    price_in    numeric(4,1) NOT NULL,
    made_at     timestamptz  NOT NULL DEFAULT now(),
    CHECK (player_out <> player_in)
);

CREATE TABLE leagues (
    league_id     integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          text        NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
    owner_user_id integer     NOT NULL REFERENCES users,
    join_code     text        NOT NULL UNIQUE CHECK (join_code ~ '^[A-Z0-9]{6}$'),
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE league_members (
    league_id integer NOT NULL REFERENCES leagues ON DELETE CASCADE,
    team_id   integer NOT NULL REFERENCES teams ON DELETE CASCADE,
    PRIMARY KEY (league_id, team_id)
);

CREATE INDEX idx_players_club    ON players (club_id);
CREATE INDEX idx_players_pos     ON players (position_id);
CREATE INDEX idx_fixtures_gw     ON fixtures (gameweek_id);
CREATE INDEX idx_stats_fixture   ON player_stats (fixture_id);
CREATE INDEX idx_squad_player    ON squad (player_id);
CREATE INDEX idx_lineups_gw      ON lineups (gameweek_id, player_id);
CREATE INDEX idx_transfers_team  ON transfers (team_id, gameweek_id);
