-- =====================================================================
-- Habbo Music · "Apagar minha conta"
-- Cole no SQL Editor do Supabase e clique em "Run". Pode rodar de novo sem problema.
-- =====================================================================

-- cada pessoa pode listar os próprios prints (para o site apagá-los junto com a conta)
drop policy if exists prints_listar on storage.objects;
create policy prints_listar on storage.objects for select to authenticated
  using (bucket_id = 'prints' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- apaga a conta de quem está logado; o resto (perfil, estante, anúncios, denúncias) vai junto
create or replace function public.apagar_minha_conta()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre com o Discord primeiro.'; end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.apagar_minha_conta() from public, anon;
grant execute on function public.apagar_minha_conta() to authenticated;
