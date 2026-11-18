-- Koridor Ortalama: EGM radar/kontrol sayılarının ortak kaydı (Kasım 2026).
-- EGM cevap verdiğinde sonuç (ilçe → ilçe) saklanır; EGM kesikken uygulamalar son bilinen sayıyı saatiyle gösterir.
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verilere dokunmaz.

create table if not exists egm_sonuc (
  from_id  int not null,
  to_id    int not null,
  radar    int,
  kontrol  int,
  zaman    timestamptz not null default now(),
  primary key (from_id, to_id)
);
alter table egm_sonuc enable row level security;
revoke all on egm_sonuc from anon, authenticated;

create or replace function egm_sonuc_yaz(p_token text, p_from int, p_to int, p_radar int, p_kontrol int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _calisan(p_token);
  if p_radar is null and p_kontrol is null then return; end if;
  insert into egm_sonuc (from_id, to_id, radar, kontrol, zaman) values (p_from, p_to, p_radar, p_kontrol, now())
  on conflict (from_id, to_id) do update set radar = excluded.radar, kontrol = excluded.kontrol, zaman = now();
end $$;

-- Son bilinen sonuç (en çok 7 gün eski)
create or replace function egm_sonuc_oku(p_token text, p_from int, p_to int) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _calisan(p_token);
  return (select json_build_object('radar', radar, 'kontrol', kontrol, 'zaman', extract(epoch from zaman)::bigint)
          from egm_sonuc where from_id = p_from and to_id = p_to and zaman > now() - interval '7 days');
end $$;

grant execute on function egm_sonuc_yaz(text, int, int, int, int), egm_sonuc_oku(text, int, int) to anon, authenticated;
