-- everything computable is a view; points are never stored

-- points of a player in a gameweek; a double gameweek sums both fixtures
CREATE OR REPLACE VIEW player_gameweek_points AS
SELECT s.player_id, f.gameweek_id,
       sum(s.minutes)::int AS minutes,
       sum(  CASE WHEN s.minutes >= 60 THEN 2 WHEN s.minutes > 0 THEN 1 ELSE 0 END
           + s.goals * pos.goal_points
           + s.assists * 3
           + CASE WHEN s.clean_sheet AND s.minutes >= 60 THEN pos.clean_sheet_points ELSE 0 END
           + s.saves / 3
           - s.yellow_cards
           - s.red_cards * 3
           + s.bonus)::int AS points
FROM player_stats s
JOIN fixtures f USING (fixture_id)
JOIN players pl USING (player_id)
JOIN positions pos USING (position_id)
GROUP BY s.player_id, f.gameweek_id;

-- starters only; captain counts double, vice takes over when the captain did not play
CREATE OR REPLACE VIEW team_gameweek_points AS
WITH picks AS (
    SELECT l.team_id, l.gameweek_id, l.is_captain, l.is_vice,
           COALESCE(pp.points, 0)  AS points,
           COALESCE(pp.minutes, 0) AS minutes
    FROM lineups l
    LEFT JOIN player_gameweek_points pp USING (player_id, gameweek_id)
    WHERE l.is_starter
),
captain AS (
    SELECT team_id, gameweek_id, bool_or(is_captain AND minutes > 0) AS played
    FROM picks GROUP BY team_id, gameweek_id
)
SELECT p.team_id, p.gameweek_id,
       sum(p.points * CASE WHEN p.is_captain AND c.played     THEN 2
                           WHEN p.is_vice    AND NOT c.played THEN 2
                           ELSE 1 END)::int AS points
FROM picks p
JOIN captain c USING (team_id, gameweek_id)
GROUP BY p.team_id, p.gameweek_id;

CREATE OR REPLACE VIEW standings AS
SELECT t.team_id, t.name AS team, u.username,
       COALESCE(sum(g.points), 0)::int AS points,
       rank() OVER (ORDER BY COALESCE(sum(g.points), 0) DESC) AS rank
FROM teams t
JOIN users u USING (user_id)
LEFT JOIN team_gameweek_points g USING (team_id)
GROUP BY t.team_id, t.name, u.username;

CREATE OR REPLACE VIEW league_table AS
SELECT l.league_id, l.name AS league, s.team_id, s.team, s.points,
       dense_rank() OVER (PARTITION BY l.league_id ORDER BY s.points DESC) AS position
FROM leagues l
JOIN league_members m USING (league_id)
JOIN standings s USING (team_id);

CREATE OR REPLACE VIEW squad_overview AS
SELECT t.team_id, t.name AS team, pl.player_id, pl.name AS player,
       pos.code AS position, c.short_name AS club, pl.price,
       t.budget - sum(pl.price) OVER (PARTITION BY t.team_id) AS budget_left
FROM teams t
JOIN squad s USING (team_id)
JOIN players pl USING (player_id)
JOIN positions pos USING (position_id)
JOIN clubs c USING (club_id);

-- triggers only cap a lineup; this view says whether it is complete and legal
CREATE OR REPLACE VIEW lineup_status AS
SELECT q.*,
       (q.starters = 11 AND q.bench = 4 AND q.captains = 1 AND q.vices = 1 AND q.formation_ok) AS is_complete
FROM (
    SELECT l.team_id, l.gameweek_id,
           count(*) FILTER (WHERE l.is_starter)     AS starters,
           count(*) FILTER (WHERE NOT l.is_starter) AS bench,
           count(*) FILTER (WHERE l.is_captain)     AS captains,
           count(*) FILTER (WHERE l.is_vice)        AS vices,
           NOT EXISTS (                              -- every position reaches its minimum of starters
               SELECT 1 FROM positions pos
               WHERE pos.min_starters > (SELECT count(*)
                                         FROM lineups x JOIN players px USING (player_id)
                                         WHERE x.team_id = l.team_id AND x.gameweek_id = l.gameweek_id
                                           AND x.is_starter AND px.position_id = pos.position_id)
           ) AS formation_ok
    FROM lineups l
    GROUP BY l.team_id, l.gameweek_id
) q;
