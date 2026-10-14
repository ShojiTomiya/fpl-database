-- sample data, set-based; setseed makes the random parts reproducible
-- order: football world, users and teams, squads and lineups, transfers, leagues

DO $$ BEGIN PERFORM setseed(0.42); END $$;

INSERT INTO positions (position_id, code, name, squad_size, min_starters, max_starters, goal_points, clean_sheet_points)
VALUES (1, 'GKP', 'Goalkeeper', 2, 1, 1, 6, 4),
       (2, 'DEF', 'Defender',   5, 3, 5, 6, 4),
       (3, 'MID', 'Midfielder', 5, 2, 5, 5, 1),
       (4, 'FWD', 'Forward',    3, 1, 3, 4, 0);

INSERT INTO clubs (name, short_name) VALUES
('Arsenal', 'ARS'), ('Aston Villa', 'AVL'), ('Bournemouth', 'BOU'), ('Brentford', 'BRE'),
('Brighton', 'BHA'), ('Burnley', 'BUR'), ('Chelsea', 'CHE'), ('Crystal Palace', 'CRY'),
('Everton', 'EVE'), ('Fulham', 'FUL'), ('Leeds', 'LEE'), ('Liverpool', 'LIV'),
('Man City', 'MCI'), ('Man Utd', 'MUN'), ('Newcastle', 'NEW'), ('Nottm Forest', 'NFO'),
('Spurs', 'TOT'), ('Sunderland', 'SUN'), ('West Ham', 'WHU'), ('Wolves', 'WOL');

-- 15 players per club: 2 GKP, 5 DEF, 5 MID, 3 FWD
INSERT INTO players (club_id, position_id, name, price)
WITH names AS (
    SELECT ARRAY['Adam','Ben','Carl','Dan','Eli','Finn','Gus','Hugo','Ian','Jack','Kai','Leo','Max','Noah','Omar'] AS first_names,
           ARRAY['Allen','Brown','Clark','Davis','Evans','Fox','Green','Hall','Irwin','Jones',
                 'King','Lewis','Moore','Nash','Owen','Parker','Quinn','Reed','Scott','Wood'] AS last_names
)
SELECT s.club_id, s.position_id,
       n.first_names[1 + ((s.n - 1) % 15)::int] || ' ' || n.last_names[1 + (((s.n - 1) / 15) % 20)::int],   -- 15 x 20 = 300 unique names
       4.0 + 0.5 * floor(random() * 6)                  -- 4.0 to 6.5
FROM (
    SELECT c.club_id, pos.position_id,
           row_number() OVER (ORDER BY c.club_id, pos.position_id, k) AS n
    FROM clubs c
    CROSS JOIN positions pos
    CROSS JOIN LATERAL generate_series(1, pos.squad_size) k
) s
CROSS JOIN names n;

-- 10 gameweeks, each club plays once per gameweek (circle method)
INSERT INTO gameweeks (gameweek_id, deadline)
SELECT g, timestamptz '2025-08-15 17:30+00' + (g - 1) * interval '7 days'
FROM generate_series(1, 10) g;

INSERT INTO fixtures (gameweek_id, home_club_id, away_club_id, kickoff, home_score, away_score)
WITH numbered AS (
    SELECT club_id, row_number() OVER (ORDER BY club_id) - 1 AS n FROM clubs
),
pairs AS (
    SELECT g.gameweek_id, g.deadline, i.idx,
           CASE WHEN i.idx = 0 THEN 0 ELSE 1 + ((i.idx - 1 + g.gameweek_id) % 19) END AS a,
           1 + ((18 - i.idx + g.gameweek_id) % 19) AS b
    FROM gameweeks g
    CROSS JOIN generate_series(0, 9) i(idx)
)
SELECT p.gameweek_id,
       CASE WHEN (p.idx + p.gameweek_id) % 2 = 0 THEN ca.club_id ELSE cb.club_id END,
       CASE WHEN (p.idx + p.gameweek_id) % 2 = 0 THEN cb.club_id ELSE ca.club_id END,
       p.deadline + interval '1 day' + p.idx * interval '2 hours',
       floor(random() * 4)::int,
       floor(random() * 4)::int
FROM pairs p
JOIN numbered ca ON ca.n = p.a
JOIN numbered cb ON cb.n = p.b;

-- who played: 1 goalkeeper and 10 outfield players start, a few substitutes come on
INSERT INTO player_stats (player_id, fixture_id, minutes)
SELECT r.player_id, r.fixture_id,
       CASE WHEN r.is_gk THEN CASE WHEN r.rn = 1 THEN 90 ELSE 0 END
            WHEN r.rn <= 10 THEN 55 + floor(random() * 36)::int
            WHEN r.rn <= 13 AND random() < 0.5 THEN 10 + floor(random() * 36)::int
            ELSE 0 END
FROM (
    SELECT p.player_id, f.fixture_id, (p.position_id = 1) AS is_gk,
           row_number() OVER (PARTITION BY f.fixture_id, p.club_id, (p.position_id = 1)
                              ORDER BY random()) AS rn
    FROM fixtures f
    CROSS JOIN LATERAL (VALUES (f.home_club_id), (f.away_club_id)) side(club_id)
    JOIN players p ON p.club_id = side.club_id
) r;

-- goals and assists follow the fixture scores
CREATE TEMP TABLE tmp_goals AS
SELECT f.fixture_id, side.club_id, g.n,
       (SELECT s.player_id
        FROM player_stats s
        JOIN players p USING (player_id)
        WHERE s.fixture_id = f.fixture_id AND p.club_id = side.club_id
          AND s.minutes > 0 AND p.position_id <> 1
        ORDER BY random() LIMIT 1) AS scorer,
       NULL::integer AS assister
FROM fixtures f
CROSS JOIN LATERAL (VALUES (f.home_club_id, f.home_score),
                           (f.away_club_id, f.away_score)) side(club_id, score)
CROSS JOIN LATERAL generate_series(1, side.score::int) g(n);

UPDATE tmp_goals t
SET assister = (SELECT s.player_id
                FROM player_stats s
                JOIN players p USING (player_id)
                WHERE s.fixture_id = t.fixture_id AND p.club_id = t.club_id
                  AND s.minutes > 0 AND s.player_id <> t.scorer
                ORDER BY random() LIMIT 1)
WHERE random() < 0.7;

UPDATE player_stats s SET goals = c.n
FROM (SELECT fixture_id, scorer AS player_id, count(*)::int AS n
      FROM tmp_goals WHERE scorer IS NOT NULL GROUP BY 1, 2) c
WHERE s.fixture_id = c.fixture_id AND s.player_id = c.player_id;

UPDATE player_stats s SET assists = c.n
FROM (SELECT fixture_id, assister AS player_id, count(*)::int AS n
      FROM tmp_goals WHERE assister IS NOT NULL GROUP BY 1, 2) c
WHERE s.fixture_id = c.fixture_id AND s.player_id = c.player_id;

DROP TABLE tmp_goals;

-- clean sheet: played 60+ minutes and the opponent did not score
UPDATE player_stats s SET clean_sheet = true
FROM fixtures f, players p
WHERE f.fixture_id = s.fixture_id AND p.player_id = s.player_id AND s.minutes >= 60
  AND ((p.club_id = f.home_club_id AND f.away_score = 0)
    OR (p.club_id = f.away_club_id AND f.home_score = 0));

UPDATE player_stats s SET saves = floor(random() * 6)::int
FROM players p
WHERE p.player_id = s.player_id AND p.position_id = 1 AND s.minutes > 0;

UPDATE player_stats SET yellow_cards = (random() < 0.12)::int,
                        red_cards    = (random() < 0.01)::int
WHERE minutes > 0;

-- bonus 3, 2, 1 for the three best of each fixture
UPDATE player_stats s SET bonus = b.bonus
FROM (SELECT player_id, fixture_id, (4 - rank_no)::int AS bonus
      FROM (SELECT player_id, fixture_id,
                   row_number() OVER (PARTITION BY fixture_id
                                      ORDER BY goals * 3 + assists * 2 + random() DESC) AS rank_no
            FROM player_stats WHERE minutes > 0) r
      WHERE rank_no <= 3) b
WHERE s.player_id = b.player_id AND s.fixture_id = b.fixture_id;

-- 12 users, one team each
INSERT INTO users (username, email)
SELECT lower(n), lower(n) || '@example.com'
FROM unnest(ARRAY['Alice','Bob','Carol','Dave','Erin','Frank',
                  'Grace','Heidi','Ivan','Judy','Mallory','Niaj']) AS n;

INSERT INTO teams (user_id, name)
SELECT user_id, initcap(username) || ' FC' FROM users;

-- squads: every team takes 15 different clubs, so the 3-per-club limit holds by construction
INSERT INTO squad (team_id, player_id)
WITH numbered_teams AS (
    SELECT team_id, row_number() OVER (ORDER BY team_id) - 1 AS t FROM teams
),
slots AS (
    SELECT pos.position_id, row_number() OVER (ORDER BY pos.position_id, k) - 1 AS slot
    FROM positions pos
    CROSS JOIN LATERAL generate_series(1, pos.squad_size) k
),
numbered_clubs AS (
    SELECT club_id, row_number() OVER (ORDER BY club_id) - 1 AS c FROM clubs
),
ranked AS (
    SELECT player_id, club_id, position_id,
           row_number() OVER (PARTITION BY club_id, position_id ORDER BY player_id) - 1 AS idx,
           count(*)     OVER (PARTITION BY club_id, position_id) AS n
    FROM players
)
SELECT nt.team_id, r.player_id
FROM numbered_teams nt
CROSS JOIN slots s
JOIN numbered_clubs nc ON nc.c = (nt.t * 3 + s.slot) % 20
JOIN ranked r ON r.club_id = nc.club_id AND r.position_id = s.position_id
             AND r.idx = (nt.t + s.slot) % r.n;

-- lineups for every gameweek: 4-4-2, captain best forward, vice best midfielder, bench order by position
INSERT INTO lineups (team_id, gameweek_id, player_id, is_starter, is_captain, is_vice, bench_order)
WITH ranked AS (
    SELECT s.team_id, s.player_id, pl.position_id,
           row_number() OVER (PARTITION BY s.team_id, pl.position_id
                              ORDER BY pl.price DESC, pl.player_id) AS rn
    FROM squad s JOIN players pl USING (player_id)
),
picked AS (
    SELECT *, rn <= CASE position_id WHEN 1 THEN 1 WHEN 2 THEN 4 WHEN 3 THEN 4 ELSE 2 END AS is_starter
    FROM ranked
)
SELECT p.team_id, g.gameweek_id, p.player_id, p.is_starter,
       p.position_id = 4 AND p.rn = 1,
       p.position_id = 3 AND p.rn = 1,
       CASE WHEN p.is_starter THEN NULL ELSE p.position_id END
FROM picked p
CROSS JOIN gameweeks g;

-- three transfers before the last gameweek: a midfielder out, another one in
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT t.team_id,
               (SELECT s.player_id FROM squad s JOIN players p USING (player_id)
                WHERE s.team_id = t.team_id AND p.position_id = 3
                ORDER BY s.player_id LIMIT 1) AS out_id,
               (SELECT p.player_id FROM players p
                WHERE p.position_id = 3
                  AND p.player_id NOT IN (SELECT player_id FROM squad WHERE team_id = t.team_id)
                ORDER BY (p.player_id * 31 + t.team_id * 17) % 101, p.player_id LIMIT 1) AS in_id
        FROM teams t
        WHERE t.team_id <= 3
    LOOP
        CALL make_transfer(r.team_id, r.out_id, r.in_id, 10);
    END LOOP;
END;
$$;

INSERT INTO leagues (name, owner_user_id, join_code)
SELECT 'Office League', user_id, 'OFFICE' FROM users WHERE username = 'alice';
INSERT INTO leagues (name, owner_user_id, join_code)
SELECT 'Friends', user_id, 'FRIEND' FROM users WHERE username = 'dave';

INSERT INTO league_members (league_id, team_id)
SELECT l.league_id, t.team_id
FROM leagues l
JOIN teams t ON (l.name = 'Office League' AND t.team_id BETWEEN 1 AND 6)
             OR (l.name = 'Friends'       AND t.team_id BETWEEN 4 AND 9);
