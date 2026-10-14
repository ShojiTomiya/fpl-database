-- example queries on the sample data; plain SQL, runs in psql or DBeaver

-- 1. league table of all teams
SELECT rank, team, username, points FROM standings ORDER BY rank, team;

-- 2. running total of a team gameweek by gameweek (window function)
SELECT gameweek_id, points,
       sum(points) OVER (ORDER BY gameweek_id) AS total
FROM team_gameweek_points
WHERE team_id = 1
ORDER BY gameweek_id;

-- 3. top 3 players per position (rank within a group)
SELECT position, player, club, points
FROM (SELECT pos.code AS position, pl.name AS player, c.short_name AS club,
             sum(pp.points) AS points,
             rank() OVER (PARTITION BY pos.code ORDER BY sum(pp.points) DESC) AS rnk
      FROM player_gameweek_points pp
      JOIN players pl USING (player_id)
      JOIN positions pos USING (position_id)
      JOIN clubs c USING (club_id)
      GROUP BY pos.code, pl.player_id, pl.name, c.short_name) t
WHERE rnk <= 3
ORDER BY position, rnk, player;

-- 4. best value: points per million
SELECT pl.name, c.short_name AS club, pl.price, sum(pp.points) AS points,
       round(sum(pp.points) / pl.price, 1) AS points_per_million
FROM player_gameweek_points pp
JOIN players pl USING (player_id)
JOIN clubs c USING (club_id)
GROUP BY pl.player_id, pl.name, c.short_name, pl.price
HAVING sum(pp.minutes) >= 300
ORDER BY points_per_million DESC
LIMIT 10;

-- 5. mini-league tables
SELECT league, position, team, points FROM league_table ORDER BY league, position, team;

-- 6. squad of one team with the budget left
SELECT position, player, club, price, budget_left
FROM squad_overview
WHERE team_id = 1
ORDER BY CASE position WHEN 'GKP' THEN 1 WHEN 'DEF' THEN 2 WHEN 'MID' THEN 3 ELSE 4 END, player;

-- 7. transfer log with player names
SELECT t.gameweek_id, tm.name AS team, po.name AS player_out, pi.name AS player_in,
       t.price_out, t.price_in
FROM transfers t
JOIN teams tm USING (team_id)
JOIN players po ON po.player_id = t.player_out
JOIN players pi ON pi.player_id = t.player_in
ORDER BY t.gameweek_id, tm.name;

-- 8. incomplete lineups, expected to return no rows
SELECT * FROM lineup_status WHERE NOT is_complete;
