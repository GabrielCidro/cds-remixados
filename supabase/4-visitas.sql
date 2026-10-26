-- =====================================================================
-- Habbo Music · contador de visitas (anônimo)
-- Guarda só números por dia: quantas vezes o site foi aberto e de quantos
-- aparelhos diferentes. Nada de IP, nome, cookie de rastreamento ou conta.
-- Cole no SQL Editor do Supabase e clique em "Run". Pode rodar de novo sem problema.
-- =====================================================================

create table if not exists public.visitas (
  dia      date primary key,
  aberturas integer not null default 0,
  pessoas   integer not null default 0
);
alter table public.visitas enable row level security;
revoke all on public.visitas from anon, authenticated;

-- o site chama isto ao abrir; p_novo = primeira visita do aparelho no dia
create or replace function public.registrar_visita(p_novo boolean)
returns void language plpgsql security definer set search_path = public as $$
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  insert into public.visitas (dia, aberturas, pessoas) values (hoje, 1, case when p_novo then 1 else 0 end)
  on conflict (dia) do update set
    aberturas = public.visitas.aberturas + 1,
    pessoas   = public.visitas.pessoas + case when p_novo then 1 else 0 end;
end $$;
revoke execute on function public.registrar_visita(boolean) from public;
grant execute on function public.registrar_visita(boolean) to anon, authenticated;

-- só admin vê os números (últimos 60 dias)
create or replace function public.ver_visitas()
returns table (dia date, aberturas integer, pessoas integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  return query select v.dia, v.aberturas, v.pessoas from public.visitas v
    where v.dia > (now() at time zone 'America/Sao_Paulo')::date - 60 order by v.dia desc;
end $$;
revoke execute on function public.ver_visitas() from public, anon;
grant execute on function public.ver_visitas() to authenticated;
