-- =====================================================================
-- Habbo Music · limites por pessoa e travas de segurança
-- Cole no SQL Editor do Supabase e clique em "Run". Pode rodar de novo sem problema.
-- =====================================================================

-- 1) Limite de anúncios ATIVOS por pessoa (padrão 10). A moderação pode aumentar por usuário.
alter table public.profiles add column if not exists ad_limit integer not null default 10;
alter table public.profiles drop constraint if exists profiles_ad_limit_check;
alter table public.profiles add constraint profiles_ad_limit_check check (ad_limit between 0 and 1000);

create or replace function public.anuncio_antes_de_inserir()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.profiles; ativos int;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.discord_id is null then raise exception 'Entre com o Discord para anunciar.'; end if;
  if p.banned then raise exception 'Sua conta não pode anunciar.'; end if;
  if not p.nick_verified then raise exception 'Confirme seu nick do Habbo antes de anunciar.'; end if;
  select count(*) into ativos from public.anuncios where user_id = p.id and status = 'ativo';
  if ativos >= p.ad_limit then
    raise exception 'Você já tem % anúncios ativos, que é o seu limite. Marque algum como vendido ou apague para anunciar outro. Quer mais espaço? Fale com a moderação.', ativos;
  end if;
  -- trava contra spam, vale para todo mundo
  if (select count(*) from public.anuncios where user_id = p.id and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'Muitos anúncios em pouco tempo. Tente de novo amanhã.';
  end if;
  if new.note ~* '(r\$|reais|pix)' then raise exception 'Anúncios são só em créditos.'; end if;
  new.user_id := p.id; new.status := 'ativo'; new.cd_ok := false; new.rejected := null; new.created_at := now();
  return new;
end $$;

-- reativar um anúncio vendido também respeita o limite
create or replace function public.anuncio_antes_de_editar()
returns trigger language plpgsql security definer set search_path = public as $$
declare lim int; ativos int;
begin
  if old.status = 'removido' and not public.is_admin() then raise exception 'Este anúncio foi removido.'; end if;
  if new.status = 'ativo' and old.status <> 'ativo' and not public.is_admin() then
    select ad_limit into lim from public.profiles where id = old.user_id;
    select count(*) into ativos from public.anuncios where user_id = old.user_id and status = 'ativo';
    if ativos >= lim then raise exception 'Você já está no limite de % anúncios ativos. Marque outro como vendido ou apague antes de reativar.', lim; end if;
  end if;
  return new;
end $$;

create or replace function public.mod_limite(p_user uuid, p_limite integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.profiles set ad_limit = greatest(0, least(1000, p_limite)) where id = p_user;
end $$;
revoke execute on function public.mod_limite(uuid, integer) from public, anon;
grant execute on function public.mod_limite(uuid, integer) to authenticated;

-- 2) Verificação do nick: impede ficar disparando consultas ao Habbo sem parar
alter table public.verificacoes add column if not exists last_check timestamptz;

create or replace function public.iniciar_verificacao(p_nick text, p_hotel text)
returns text language plpgsql security definer set search_path = public as $$
declare c text; ult timestamptz;
begin
  if auth.uid() is null then raise exception 'Entre com o Discord primeiro.'; end if;
  if p_hotel not in ('com.br','com','es','fr','de','it','nl','fi','com.tr') then raise exception 'Hotel inválido.'; end if;
  if p_nick !~ '^[A-Za-z0-9=?!@:.,_-]{1,32}$' then raise exception 'Nick inválido.'; end if;
  select created_at into ult from public.verificacoes where user_id = auth.uid();
  if ult is not null and ult > now() - interval '15 seconds' then raise exception 'Espere alguns segundos antes de gerar outro código.'; end if;
  c := 'HM-' || (1000 + floor(random() * 9000))::int;
  insert into public.verificacoes (user_id, nick, hotel, code) values (auth.uid(), p_nick, p_hotel, c)
  on conflict (user_id) do update set nick = excluded.nick, hotel = excluded.hotel, code = excluded.code, created_at = now(), last_check = null;
  return c;
end $$;

create or replace function public.confirmar_verificacao()
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare v public.verificacoes; r extensions.http_response; j jsonb;
begin
  select * into v from public.verificacoes where user_id = auth.uid();
  if v.user_id is null then raise exception 'Comece a verificação de novo.'; end if;
  if v.created_at < now() - interval '30 minutes' then raise exception 'O código expirou. Gere um novo.'; end if;
  if v.last_check is not null and v.last_check > now() - interval '8 seconds' then raise exception 'Espere alguns segundos e tente de novo.'; end if;
  update public.verificacoes set last_check = now() where user_id = auth.uid();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  select * into r from extensions.http_get('https://www.habbo.' || v.hotel || '/api/public/users?name=' || extensions.urlencode(v.nick));
  if r.status <> 200 then raise exception 'Não achei esse nick no Habbo (ou o Habbo não respondeu). Tente de novo.'; end if;
  j := r.content::jsonb;
  if coalesce(position(v.code in j->>'motto'), 0) = 0 then return false; end if;
  update public.profiles set habbo_nick = null, nick_verified = false
   where lower(habbo_nick) = lower(j->>'name') and habbo_hotel = v.hotel and id <> auth.uid();
  update public.profiles set habbo_nick = j->>'name', habbo_hotel = v.hotel, nick_verified = true where id = auth.uid();
  delete from public.verificacoes where user_id = auth.uid();
  return true;
end $$;

-- 3) Prints: no máximo 50 arquivos guardados por pessoa (evita usar o espaço como depósito)
create or replace function public.meus_prints()
returns integer language sql stable security definer set search_path = public, storage as $$
  select count(*)::int from storage.objects
   where bucket_id = 'prints' and (storage.foldername(name))[1] = auth.uid()::text
$$;
revoke execute on function public.meus_prints() from public, anon;
grant execute on function public.meus_prints() to authenticated;

drop policy if exists prints_enviar on storage.objects;
create policy prints_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'prints' and (storage.foldername(name))[1] = auth.uid()::text and public.meus_prints() < 50);
