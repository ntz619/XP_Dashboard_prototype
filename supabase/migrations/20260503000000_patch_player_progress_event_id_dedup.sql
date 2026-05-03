-- Fix: patch_player_progress now accepts p_event_id and uses it as an idempotency key.
-- Previously event_id was sent by the frontend but silently dropped by the function,
-- causing duplicate XP writes when the same event was processed more than once.
--
-- Behaviour:
--   - if p_event_id is provided and the event already exists -> v_xp_to_apply = 0
--     (presence/counters still update, XP and season XP are skipped)
--   - if p_event_id is null -> no dedup, XP applied as before

CREATE OR REPLACE FUNCTION public.patch_player_progress(
  p_username text,
  p_xp_gain integer DEFAULT 0,
  p_source_game text DEFAULT NULL::text,
  p_xp_source text DEFAULT NULL::text,
  p_pet_id integer DEFAULT NULL::integer,
  p_plays_quadclaim integer DEFAULT 0,
  p_plays_memoryclaim integer DEFAULT 0,
  p_plays_gunspleef integer DEFAULT 0,
  p_plays_runspleef integer DEFAULT 0,
  p_plays_chrono_overdrive integer DEFAULT 0,
  p_plays_chrono_loot_extraction_2d integer DEFAULT 0,
  p_wins_quadclaim integer DEFAULT 0,
  p_wins_memoryclaim integer DEFAULT 0,
  p_wins_gunspleef integer DEFAULT 0,
  p_wins_runspleef integer DEFAULT 0,
  p_event_id text DEFAULT NULL::text
)
RETURNS SETOF player_progress
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
declare
  v_today date := (timezone('utc', now()))::date;
  v_yesterday date := v_today - 1;
  v_source_game text := lower(nullif(trim(p_source_game), ''));
  v_xp_source text := lower(nullif(trim(p_xp_source), ''));
  v_xp_gain integer := greatest(coalesce(p_xp_gain, 0), 0);
  v_xp_to_apply integer;
begin

  -- ensure player exists
  insert into public.player_progress (username)
  values (p_username)
  on conflict (username) do nothing;

  -- detect game automatically
  if v_source_game is null then
    if p_plays_quadclaim > 0 or p_wins_quadclaim > 0 then v_source_game := 'quadclaim';
    elsif p_plays_memoryclaim > 0 or p_wins_memoryclaim > 0 then v_source_game := 'memoryclaim';
    elsif p_plays_gunspleef > 0 or p_wins_gunspleef > 0 then v_source_game := 'gunspleef';
    elsif p_plays_runspleef > 0 or p_wins_runspleef > 0 then v_source_game := 'runspleef';
    elsif p_plays_chrono_overdrive > 0 then v_source_game := 'chrono_overdrive';
    elsif p_plays_chrono_loot_extraction_2d > 0 then v_source_game := 'chrono_loot_extraction_2d';
    end if;
  end if;

  -- detect xp source automatically
  if v_xp_source is null then
    if p_wins_quadclaim > 0 then v_xp_source := 'win_from_quadclaim';
    elsif p_wins_memoryclaim > 0 then v_xp_source := 'win_from_memoryclaim';
    elsif p_wins_gunspleef > 0 then v_xp_source := 'win_from_gunspleef';
    elsif p_wins_runspleef > 0 then v_xp_source := 'win_from_runspleef';
    elsif p_plays_quadclaim > 0 then v_xp_source := 'participation_from_quadclaim';
    elsif p_plays_memoryclaim > 0 then v_xp_source := 'participation_from_memoryclaim';
    elsif p_plays_gunspleef > 0 then v_xp_source := 'participation_from_gunspleef';
    elsif p_plays_runspleef > 0 then v_xp_source := 'participation_from_runspleef';
    elsif p_plays_chrono_overdrive > 0 then v_xp_source := 'participation_from_chrono_overdrive';
    elsif p_plays_chrono_loot_extraction_2d > 0 then v_xp_source := 'participation_from_chrono_loot_extraction_2d';
    elsif v_source_game is not null then v_xp_source := 'xp_from_' || v_source_game;
    else v_xp_source := 'unspecified';
    end if;
  end if;

  -- event logging with idempotency via event_id
  v_xp_to_apply := v_xp_gain;

  if v_xp_gain > 0 or v_xp_source = 'login_sync' then
    if p_event_id is not null then
      insert into public.player_xp_events (username, xp_amount, xp_source, source_game, event_id)
      values (p_username, v_xp_gain, v_xp_source, v_source_game, p_event_id)
      on conflict (event_id) do nothing;
      -- duplicate event: skip XP but still update presence/counters
      if not found then
        v_xp_to_apply := 0;
      end if;
    else
      insert into public.player_xp_events (username, xp_amount, xp_source, source_game)
      values (p_username, v_xp_gain, v_xp_source, v_source_game);
    end if;
  end if;

  update public.player_progress pp
  set
    xp = pp.xp + v_xp_to_apply,

    pet_id = coalesce(p_pet_id, pp.pet_id),

    plays_quadclaim = pp.plays_quadclaim + p_plays_quadclaim,
    plays_memoryclaim = pp.plays_memoryclaim + p_plays_memoryclaim,
    plays_gunspleef = pp.plays_gunspleef + p_plays_gunspleef,
    plays_runspleef = pp.plays_runspleef + p_plays_runspleef,
    plays_chrono_overdrive = pp.plays_chrono_overdrive + p_plays_chrono_overdrive,
    plays_chrono_loot_extraction_2d = pp.plays_chrono_loot_extraction_2d + p_plays_chrono_loot_extraction_2d,

    wins_quadclaim = pp.wins_quadclaim + p_wins_quadclaim,
    wins_memoryclaim = pp.wins_memoryclaim + p_wins_memoryclaim,
    wins_gunspleef = pp.wins_gunspleef + p_wins_gunspleef,
    wins_runspleef = pp.wins_runspleef + p_wins_runspleef,

    last_seen_at = timezone('utc', now()),
    last_login_date = v_today,

    active_days_total = case
      when pp.last_login_date is null then pp.active_days_total + 1
      when pp.last_login_date = v_today then pp.active_days_total
      else pp.active_days_total + 1
    end,

    daily_login_streak = case
      when pp.last_login_date is null then 1
      when pp.last_login_date = v_today then pp.daily_login_streak
      when pp.last_login_date = v_yesterday then pp.daily_login_streak + 1
      else 1
    end,

    best_login_streak = greatest(
      pp.best_login_streak,
      case
        when pp.last_login_date = v_yesterday then pp.daily_login_streak + 1
        else pp.daily_login_streak
      end
    ),

    first_game_played = coalesce(pp.first_game_played, v_source_game),
    last_game_played = coalesce(v_source_game, pp.last_game_played),

    updated_at = timezone('utc', now())

  where pp.username = p_username;

  perform public.apply_season_xp(p_username, v_xp_to_apply);

  update public.player_progress pp
  set favorite_game = (
    select game from (
      values
        ('quadclaim', pp.plays_quadclaim),
        ('memoryclaim', pp.plays_memoryclaim),
        ('gunspleef', pp.plays_gunspleef),
        ('runspleef', pp.plays_runspleef),
        ('chrono_overdrive', pp.plays_chrono_overdrive),
        ('chrono_loot_extraction_2d', pp.plays_chrono_loot_extraction_2d)
    ) as t(game, plays)
    order by plays desc
    limit 1
  )
  where pp.username = p_username;

  return query
  select *
  from public.player_progress
  where username = p_username;

end;
$function$;
