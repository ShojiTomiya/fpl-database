-- game rules the database enforces: squad limits, lineup picks, transfers

-- squad: size, positions, 3 per club, budget; limits are upper bounds, so a squad is built one player at a time
CREATE OR REPLACE FUNCTION check_squad_limits() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_price    numeric;
    v_club     integer;
    v_position smallint;
    v_code     text;
    v_limit    smallint;
    v_budget   numeric;
    v_total    integer;
    v_in_pos   integer;
    v_in_club  integer;
    v_spent    numeric;
BEGIN
    -- lock the team row so concurrent inserts into one squad are serialized
    SELECT budget INTO v_budget FROM teams WHERE team_id = NEW.team_id FOR UPDATE;

    SELECT price, club_id, position_id INTO v_price, v_club, v_position
    FROM players WHERE player_id = NEW.player_id;
    SELECT code, squad_size INTO v_code, v_limit FROM positions WHERE position_id = v_position;

    SELECT count(*),
           count(*) FILTER (WHERE pl.position_id = v_position),
           count(*) FILTER (WHERE pl.club_id = v_club),
           COALESCE(sum(pl.price), 0)
    INTO v_total, v_in_pos, v_in_club, v_spent
    FROM squad s JOIN players pl USING (player_id)
    WHERE s.team_id = NEW.team_id;

    IF v_total + 1 > (SELECT sum(squad_size) FROM positions) THEN
        RAISE EXCEPTION 'squad is full' USING ERRCODE = 'check_violation';
    END IF;
    IF v_in_pos + 1 > v_limit THEN
        RAISE EXCEPTION 'too many % players, max %', v_code, v_limit USING ERRCODE = 'check_violation';
    END IF;
    IF v_in_club + 1 > 3 THEN                                   -- max 3 per club
        RAISE EXCEPTION 'max 3 players from one club' USING ERRCODE = 'check_violation';
    END IF;
    IF v_spent + v_price > v_budget THEN
        RAISE EXCEPTION 'over budget: % > %', v_spent + v_price, v_budget USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS squad_limits ON squad;
CREATE TRIGGER squad_limits
    BEFORE INSERT ON squad
    FOR EACH ROW EXECUTE FUNCTION check_squad_limits();


-- lineup: player must be in the squad, at most 11 starters, per-position starter maximum
CREATE OR REPLACE FUNCTION check_lineup_pick() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_position smallint;
    v_code     text;
    v_max      smallint;
    v_other    integer;       -- the row being replaced is not counted
    v_starters integer;
    v_in_pos   integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM squad WHERE team_id = NEW.team_id AND player_id = NEW.player_id) THEN
        RAISE EXCEPTION 'player % is not in the squad of team %', NEW.player_id, NEW.team_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.is_starter THEN
        v_other := CASE WHEN TG_OP = 'UPDATE' THEN OLD.player_id ELSE NEW.player_id END;

        SELECT position_id INTO v_position FROM players WHERE player_id = NEW.player_id;
        SELECT code, max_starters INTO v_code, v_max FROM positions WHERE position_id = v_position;

        SELECT count(*), count(*) FILTER (WHERE pl.position_id = v_position)
        INTO v_starters, v_in_pos
        FROM lineups l JOIN players pl USING (player_id)
        WHERE l.team_id = NEW.team_id AND l.gameweek_id = NEW.gameweek_id AND l.is_starter
          AND l.player_id <> NEW.player_id AND l.player_id <> v_other;

        IF v_starters + 1 > 11 THEN
            RAISE EXCEPTION 'max 11 starters' USING ERRCODE = 'check_violation';
        END IF;
        IF v_in_pos + 1 > v_max THEN
            RAISE EXCEPTION 'too many % starters, max %', v_code, v_max USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS lineup_pick ON lineups;
CREATE TRIGGER lineup_pick
    BEFORE INSERT OR UPDATE ON lineups
    FOR EACH ROW EXECUTE FUNCTION check_lineup_pick();


-- transfer: swap a player in the squad and the lineup, and log it, in one transaction
-- squad limits still apply, so a full squad can only swap within a position
CREATE OR REPLACE PROCEDURE make_transfer(p_team integer, p_out integer, p_in integer, p_gameweek integer)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM squad WHERE team_id = p_team AND player_id = p_out) THEN
        RAISE EXCEPTION 'player % is not in the squad of team %', p_out, p_team
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO transfers (team_id, gameweek_id, player_out, player_in, price_out, price_in)
    SELECT p_team, p_gameweek, p_out, p_in, o.price, i.price
    FROM players o, players i
    WHERE o.player_id = p_out AND i.player_id = p_in;

    DELETE FROM squad WHERE team_id = p_team AND player_id = p_out;
    INSERT INTO squad (team_id, player_id) VALUES (p_team, p_in);

    UPDATE lineups SET player_id = p_in
    WHERE team_id = p_team AND gameweek_id = p_gameweek AND player_id = p_out;
END;
$$;
