-- =====================================================================
-- Habbo Music · banco de dados (Supabase)
-- Cole tudo no SQL Editor do Supabase e clique em "Run".
-- Pode rodar de novo sem problema: ele não apaga dados.
-- =====================================================================

create extension if not exists http with schema extensions;

-- ---------------------------------------------------------------------
-- Perfis: um por conta do Discord. Criado sozinho no primeiro login.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  discord_id    text,
  discord_user  text,
  discord_name  text,
  avatar_url    text,
  habbo_nick    text,
  habbo_hotel   text,
  nick_verified boolean not null default false,
  is_admin      boolean not null default false,
  banned        boolean not null default false,
  created_at    timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, discord_id, discord_user, discord_name, avatar_url)
  values (
    new.id,
    m->>'provider_id',
    coalesce(m->>'full_name', m->>'name'),
    coalesce(m->'custom_claims'->>'global_name', m->>'full_name', m->>'name'),
    m->>'avatar_url'
  )
  on conflict (id) do update set
    discord_id = excluded.discord_id, discord_user = excluded.discord_user,
    discord_name = excluded.discord_name, avatar_url = excluded.avatar_url;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of raw_user_meta_data on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- ---------------------------------------------------------------------
-- Estante: a lista de CDs de cada pessoa (mesmo formato do site atual).
-- Só o dono lê e grava a própria estante.
-- ---------------------------------------------------------------------
create table if not exists public.estantes (
  user_id    uuid primary key default auth.uid() references public.profiles(id) on delete cascade,
  data       jsonb not null default '{"cds":[]}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint estante_tamanho check (octet_length(data::text) < 500000)
);

-- ---------------------------------------------------------------------
-- Anúncios do mural. Preço só em créditos.
-- ---------------------------------------------------------------------
create table if not exists public.anuncios (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  cd          text not null check (char_length(cd) between 1 and 60),
  dj          text not null check (char_length(dj) between 1 and 40),
  price       integer not null check (price between 1 and 1000000),
  qty         integer not null default 1 check (qty between 1 and 99),
  note        text check (note is null or char_length(note) <= 140),
  print_path  text,
  status      text not null default 'ativo' check (status in ('ativo','vendido','removido')),
  cd_ok       boolean not null default false,
  rejected    text,
  created_at  timestamptz not null default now()
);
create index if not exists anuncios_status_idx on public.anuncios (status, created_at desc);

-- Regras ao publicar: conta não banida, nick confirmado, no máximo 10 anúncios por dia
create or replace function public.anuncio_antes_de_inserir()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null then raise exception 'Entre com o Discord para anunciar.'; end if;
  if p.banned then raise exception 'Sua conta não pode anunciar.'; end if;
  if not p.nick_verified then raise exception 'Confirme seu nick do Habbo antes de anunciar.'; end if;
  if (select count(*) from public.anuncios where user_id = p.id and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'Limite de 10 anúncios por dia.';
  end if;
  if new.note ~* '(r\$|reais|pix)' then raise exception 'Anúncios são só em créditos.'; end if;
  new.user_id := p.id; new.status := 'ativo'; new.cd_ok := false; new.rejected := null; new.created_at := now();
  return new;
end $$;
drop trigger if exists anuncio_insert on public.anuncios;
create trigger anuncio_insert before insert on public.anuncios
  for each row execute function public.anuncio_antes_de_inserir();

-- Anúncio removido pela moderação não pode ser reativado pelo dono
create or replace function public.anuncio_antes_de_editar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'removido' and not public.is_admin() then raise exception 'Este anúncio foi removido.'; end if;
  return new;
end $$;
drop trigger if exists anuncio_update on public.anuncios;
create trigger anuncio_update before update on public.anuncios
  for each row execute function public.anuncio_antes_de_editar();

-- ---------------------------------------------------------------------
-- Denúncias (só a moderação vê)
-- ---------------------------------------------------------------------
create table if not exists public.denuncias (
  id          bigint generated always as identity primary key,
  anuncio_id  bigint not null references public.anuncios(id) on delete cascade,
  reporter    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  motivo      text not null check (char_length(motivo) between 1 and 300),
  created_at  timestamptz not null default now()
);

create or replace function public.denuncia_antes_de_inserir()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre com o Discord para denunciar.'; end if;
  if (select count(*) from public.denuncias where reporter = auth.uid() and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'Limite de denúncias por dia atingido.';
  end if;
  new.reporter := auth.uid(); new.created_at := now();
  return new;
end $$;
drop trigger if exists denuncia_insert on public.denuncias;
create trigger denuncia_insert before insert on public.denuncias
  for each row execute function public.denuncia_antes_de_inserir();

-- ---------------------------------------------------------------------
-- Verificação do nick pela missão (o código fica guardado só no servidor)
-- ---------------------------------------------------------------------
create table if not exists public.verificacoes (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  nick       text not null,
  hotel      text not null,
  code       text not null,
  created_at timestamptz not null default now()
);

create or replace function public.iniciar_verificacao(p_nick text, p_hotel text)
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if auth.uid() is null then raise exception 'Entre com o Discord primeiro.'; end if;
  if p_hotel not in ('com.br','com','es','fr','de','it','nl','fi','com.tr') then raise exception 'Hotel inválido.'; end if;
  if p_nick !~ '^[A-Za-z0-9=?!@:.,_-]{1,32}$' then raise exception 'Nick inválido.'; end if;
  c := 'HM-' || (1000 + floor(random() * 9000))::int;
  insert into public.verificacoes (user_id, nick, hotel, code) values (auth.uid(), p_nick, p_hotel, c)
  on conflict (user_id) do update set nick = excluded.nick, hotel = excluded.hotel, code = excluded.code, created_at = now();
  return c;
end $$;

create or replace function public.confirmar_verificacao()
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare v public.verificacoes; r extensions.http_response; j jsonb;
begin
  select * into v from public.verificacoes where user_id = auth.uid();
  if v.user_id is null then raise exception 'Comece a verificação de novo.'; end if;
  if v.created_at < now() - interval '30 minutes' then raise exception 'O código expirou. Gere um novo.'; end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  select * into r from extensions.http_get('https://www.habbo.' || v.hotel || '/api/public/users?name=' || extensions.urlencode(v.nick));
  if r.status <> 200 then raise exception 'Não achei esse nick no Habbo (ou o Habbo não respondeu). Tente de novo.'; end if;
  j := r.content::jsonb;
  if coalesce(position(v.code in j->>'motto'), 0) = 0 then return false; end if;
  -- o mesmo nick não pode ficar verificado em duas contas
  update public.profiles set habbo_nick = null, nick_verified = false
   where lower(habbo_nick) = lower(j->>'name') and habbo_hotel = v.hotel and id <> auth.uid();
  update public.profiles set habbo_nick = j->>'name', habbo_hotel = v.hotel, nick_verified = true where id = auth.uid();
  delete from public.verificacoes where user_id = auth.uid();
  return true;
end $$;

-- ---------------------------------------------------------------------
-- Moderação (só admin)
-- ---------------------------------------------------------------------
create or replace function public.mod_print(p_id bigint, p_ok boolean, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.anuncios set cd_ok = p_ok, rejected = case when p_ok then null else coalesce(p_motivo, 'Print recusado') end where id = p_id;
end $$;

create or replace function public.mod_remover(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.anuncios set status = 'removido' where id = p_id;
  delete from public.denuncias where anuncio_id = p_id;
end $$;

create or replace function public.mod_ignorar_denuncia(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  delete from public.denuncias where id = p_id;
end $$;

create or replace function public.mod_banir(p_user uuid, p_ban boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.profiles set banned = p_ban where id = p_user and not is_admin;
  if p_ban then update public.anuncios set status = 'removido' where user_id = p_user; end if;
end $$;

-- ---------------------------------------------------------------------
-- Regras de acesso (Row Level Security)
-- ---------------------------------------------------------------------
alter table public.profiles     enable row level security;
alter table public.estantes     enable row level security;
alter table public.anuncios     enable row level security;
alter table public.denuncias    enable row level security;
alter table public.verificacoes enable row level security;

revoke all on public.profiles, public.estantes, public.anuncios, public.denuncias, public.verificacoes from anon, authenticated;

-- perfis: todo mundo pode ver (nick, Discord e avatar aparecem nos anúncios); ninguém edita direto
grant select on public.profiles to anon, authenticated;
drop policy if exists perfis_leitura on public.profiles;
create policy perfis_leitura on public.profiles for select using (true);

-- estante: só o dono
grant select, insert, update on public.estantes to authenticated;
drop policy if exists estante_dono on public.estantes;
create policy estante_dono on public.estantes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- anúncios: mural público; cada um só mexe nos seus (e só em status, preço, quantidade e observação)
grant select on public.anuncios to anon, authenticated;
grant insert (cd, dj, price, qty, note, print_path) on public.anuncios to authenticated;
grant update (status, price, qty, note) on public.anuncios to authenticated;
drop policy if exists anuncios_leitura on public.anuncios;
create policy anuncios_leitura on public.anuncios for select
  using (status <> 'removido' or user_id = auth.uid() or public.is_admin());
drop policy if exists anuncios_criar on public.anuncios;
create policy anuncios_criar on public.anuncios for insert to authenticated with check (user_id = auth.uid());
drop policy if exists anuncios_editar on public.anuncios;
create policy anuncios_editar on public.anuncios for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- denúncias: qualquer pessoa logada denuncia; só admin lê
grant insert (anuncio_id, motivo) on public.denuncias to authenticated;
grant select on public.denuncias to authenticated;
drop policy if exists denuncias_criar on public.denuncias;
create policy denuncias_criar on public.denuncias for insert to authenticated with check (reporter = auth.uid());
drop policy if exists denuncias_admin on public.denuncias;
create policy denuncias_admin on public.denuncias for select to authenticated using (public.is_admin());

-- verificações: ninguém acessa direto (só pelas funções acima)

-- funções: só quem está logado
revoke execute on function public.iniciar_verificacao(text, text), public.confirmar_verificacao(),
  public.mod_print(bigint, boolean, text), public.mod_remover(bigint), public.mod_ignorar_denuncia(bigint),
  public.mod_banir(uuid, boolean) from public, anon;
grant execute on function public.iniciar_verificacao(text, text), public.confirmar_verificacao(),
  public.mod_print(bigint, boolean, text), public.mod_remover(bigint), public.mod_ignorar_denuncia(bigint),
  public.mod_banir(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Prints: só imagem, até 5 MB, cada pessoa envia só na própria pasta
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('prints', 'prints', true, 5242880, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/png','image/jpeg','image/webp'];

drop policy if exists prints_enviar on storage.objects;
create policy prints_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'prints' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists prints_apagar on storage.objects;
create policy prints_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'prints' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
