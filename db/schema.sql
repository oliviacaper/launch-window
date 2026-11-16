-- Launch Window database
-- Missions are released by date (America/New_York); scores are written only through the functions below.

create table if not exists public.missions (
  day date primary key,
  num int not null unique,
  liftoff jsonb not null,   -- {cat, par, list}
  signal jsonb not null,    -- {type, ans, alias, clues[5]}
  landing jsonb not null,   -- [{key, q, a, u, f, s, url?}] x3
  created_at timestamptz not null default now()
);
-- never repeat a Liftoff category or a Signal Lock answer
create unique index if not exists missions_lift_cat on public.missions (lower(liftoff->>'cat'));
create unique index if not exists missions_sig_ans on public.missions (lower(signal->>'ans'));

-- never repeat a Redshift question (one key per question, filled automatically)
create table if not exists public.landing_keys (
  key text primary key,
  day date not null references public.missions(day) on delete cascade
);
create or replace function public.missions_landing_keys() returns trigger language plpgsql as $$
begin
  insert into public.landing_keys(key, day)
  select lower(q->>'key'), new.day from jsonb_array_elements(new.landing) q;
  return new;
end $$;
drop trigger if exists missions_landing_keys on public.missions;
create trigger missions_landing_keys after insert on public.missions
  for each row execute function public.missions_landing_keys();

alter table public.missions enable row level security;
alter table public.landing_keys enable row level security;
drop policy if exists "released missions are readable" on public.missions;
create policy "released missions are readable" on public.missions
  for select to anon, authenticated
  using (day <= (now() at time zone 'America/New_York')::date);

-- players claim a callsign inside a crew with a private device token
create table if not exists public.players (
  crew text not null,
  player text not null,
  token uuid not null,
  created_at timestamptz not null default now(),
  primary key (crew, player)
);
create table if not exists public.plays (
  crew text not null,
  mission int not null,
  player text not null,
  lift_answers text[],
  sig_clue int, sig_wrong int, sig_lost boolean, sig_score int,
  land_guesses float8[], land_score int,
  updated_at timestamptz not null default now(),
  primary key (crew, mission, player)
);
alter table public.players enable row level security;  -- no policies: only the functions below can touch these
alter table public.plays enable row level security;

create or replace function public.lw_today_num() returns int language sql stable as $$
  select ((now() at time zone 'America/New_York')::date - date '2026-11-16') + 1;
$$;

create or replace function public.claim_callsign(p_crew text, p_player text, p_token uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  p_crew := lower(trim(p_crew)); p_player := trim(p_player);
  if length(p_player) not between 1 and 16 or length(p_crew) not between 3 and 40 then return false; end if;
  select token into t from players where crew = p_crew and player = p_player;
  if t is null then
    insert into players(crew, player, token) values (p_crew, p_player, p_token) on conflict do nothing;
    select token into t from players where crew = p_crew and player = p_player;
  end if;
  return t = p_token;
end $$;

create or replace function public.submit_stage(p_crew text, p_mission int, p_player text, p_token uuid, p_stage text, p_data jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  p_crew := lower(trim(p_crew)); p_player := trim(p_player);
  if p_mission <> lw_today_num() then return false; end if;
  if not claim_callsign(p_crew, p_player, p_token) then return false; end if;
  insert into plays(crew, mission, player) values (p_crew, p_mission, p_player) on conflict do nothing;
  if p_stage = 'lift' then
    update plays set lift_answers = (select coalesce(array_agg(x), '{}') from (select left(jsonb_array_elements_text(p_data->'answers'), 60) x limit 200) s), updated_at = now()
      where crew = p_crew and mission = p_mission and player = p_player and lift_answers is null;
  elsif p_stage = 'sig' then
    update plays set sig_clue = (p_data->>'clue')::int, sig_wrong = least((p_data->>'wrong')::int, 50),
      sig_lost = (p_data->>'lost')::boolean, sig_score = least(greatest((p_data->>'score')::int, 0), 1000), updated_at = now()
      where crew = p_crew and mission = p_mission and player = p_player and sig_score is null;
  elsif p_stage = 'land' then
    update plays set land_guesses = (select array_agg(x::float8) from jsonb_array_elements_text(p_data->'guesses') x),
      land_score = least(greatest((p_data->>'score')::int, 0), 1000), updated_at = now()
      where crew = p_crew and mission = p_mission and player = p_player and land_score is null;
  else
    return false;
  end if;
  return true;
end $$;

create or replace function public.get_plays(p_crew text, p_from int, p_to int)
returns table(mission int, player text, lift_answers text[], sig_clue int, sig_wrong int, sig_lost boolean, sig_score int, land_guesses float8[], land_score int)
language sql stable security definer set search_path = public as $$
  select mission, player, lift_answers, sig_clue, sig_wrong, sig_lost, sig_score, land_guesses, land_score
  from plays where crew = lower(trim(p_crew)) and mission between p_from and least(p_to, lw_today_num());
$$;

revoke all on function public.claim_callsign(text, text, uuid) from public;
revoke all on function public.submit_stage(text, int, text, uuid, text, jsonb) from public;
revoke all on function public.get_plays(text, int, int) from public;
grant execute on function public.claim_callsign(text, text, uuid) to anon, authenticated;
grant execute on function public.submit_stage(text, int, text, uuid, text, jsonb) to anon, authenticated;
grant execute on function public.get_plays(text, int, int) to anon, authenticated;
grant select on public.missions to anon, authenticated;
