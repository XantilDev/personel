-- Koridor Ortalama: yazarken arama önerileri için ayrı günlük sınır — Kasım 2026.
-- Öneriler rota/trafik/arama hakkından düşmez; çalışan günde 50, firma cihazı kodda belirlenir (boş = sınırsız), misafire kapalı.
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verileri silmez. Önce guncelleme-google.sql çalışmış olmalı.
alter table uygulama_calisan add column if not exists oneri_gunluk int default 50;
alter table erisim_kod add column if not exists oneri_gunluk int;

create or replace function _google_durum(p_tur text, p_ref bigint, out bugun int, out sinir int)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_tur = 'calisan' then
    select coalesce((select u.gunluk from uygulama_calisan u where u.calisan_id = p_ref), 30) into sinir;
    if exists (select 1 from uygulama_calisan u where u.calisan_id = p_ref and u.gunluk is null) then sinir := null; end if;
    select count(*) into bugun from google_istek where calisan_id = p_ref and zaman >= _bugun0() and tur <> 'oneri';
  else
    select k.gunluk_rota into sinir from erisim_kod k where k.id = p_ref;
    select count(*) into bugun from google_istek where kod_id = p_ref and zaman >= _bugun0() and tur <> 'oneri';
  end if;
end $$;

create or replace function google_hak(p_token text, p_kod text, p_cihaz text, p_tur text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e record; g record; t text := case when p_tur in ('rota', 'trafik', 'arama', 'oneri') then p_tur else 'rota' end; on_ int; os_ int;
begin
  select * into e from _erisim(p_token, p_kod, p_cihaz, null);
  if e.tur = '' then return json_build_object('izin', false, 'neden', e.neden); end if;
  if t = 'oneri' then
    -- Yazarken öneri: rota/trafik/arama hakkından ayrı günlük sınır (çalışan 50; firma cihazı kodda belirlenir; misafire yok)
    if e.tur = 'calisan' then
      select coalesce((select u.oneri_gunluk from uygulama_calisan u where u.calisan_id = e.ref), 50) into os_;
      select count(*) into on_ from google_istek where calisan_id = e.ref and tur = 'oneri' and zaman >= _bugun0();
    elsif e.tur = 'firma' then
      select k.oneri_gunluk into os_ from erisim_kod k where k.id = e.ref;
      select count(*) into on_ from google_istek where kod_id = e.ref and tur = 'oneri' and zaman >= _bugun0();
    else
      return json_build_object('izin', false, 'neden', 'oneri_yok');
    end if;
    if os_ is not null and on_ >= os_ then return json_build_object('izin', false, 'neden', 'oneri_sinir', 'oneri', on_, 'oneri_sinir', os_); end if;
    insert into google_istek (cihaz_id, calisan_id, kod_id, tur)
    values (left(p_cihaz, 64), case when e.tur = 'calisan' then e.ref end, case when e.tur <> 'calisan' then e.ref end, 'oneri');
    return json_build_object('izin', true, 'oneri', on_ + 1, 'oneri_sinir', os_);
  end if;
  select * into g from _google_durum(case when e.tur = 'calisan' then 'calisan' else 'kod' end, e.ref);
  if g.sinir is not null and g.bugun >= g.sinir then
    return json_build_object('izin', false, 'neden', 'sinir', 'bugun', g.bugun, 'sinir', g.sinir);
  end if;
  insert into google_istek (cihaz_id, calisan_id, kod_id, tur)
  values (left(p_cihaz, 64), case when e.tur = 'calisan' then e.ref end, case when e.tur <> 'calisan' then e.ref end, t);
  insert into kullanim (cihaz_id, gun, kod_id, calisan_id, rota, arama)
  values (left(p_cihaz, 64), current_date, case when e.tur <> 'calisan' then e.ref end, case when e.tur = 'calisan' then e.ref end,
          case when t = 'arama' then 0 else 1 end, case when t = 'arama' then 1 else 0 end)
  on conflict (cihaz_id, gun) do update set rota = kullanim.rota + excluded.rota, arama = kullanim.arama + excluded.arama;
  if random() < 0.01 then delete from google_istek where zaman < now() - interval '30 days'; end if;
  return json_build_object('izin', true, 'bugun', g.bugun + 1, 'sinir', g.sinir);
end $$;

create or replace function y_kullanicilar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return json_build_object(
    'calisanlar', coalesce((select json_agg(x order by x.son desc nulls last, x.ad) from (
        select c.id, c.ad, c.aktif as hesap_aktif, coalesce(u.aktif, true) as aktif,
          case when u.calisan_id is null then 30 else u.gunluk end as gunluk,
          (select max(d.son) from cihaz d where d.calisan_id = c.id) as son,
          (select string_agg(coalesce(d.model, '?'), ', ') from cihaz d where d.calisan_id = c.id) as cihazlar,
          (select count(*) from google_istek g where g.calisan_id = c.id and g.zaman >= _bugun0() and g.tur <> 'oneri') as bugun,
          (select count(*) from google_istek g where g.calisan_id = c.id and g.zaman >= _bugun0() and g.tur = 'oneri') as oneri_bugun,
          coalesce(u.oneri_gunluk, 50) as oneri_gunluk,
          (select max(g.zaman) from google_istek g where g.calisan_id = c.id) as son_istek,
          (select count(*) from google_istek g where g.calisan_id = c.id) as google30,
          (select coalesce(sum(k.km), 0) from kullanim k where k.calisan_id = c.id and k.gun > current_date - 30) as km30
        from calisan c left join uygulama_calisan u on u.calisan_id = c.id where c.aktif) x), '[]'::json),
    'kodlar', coalesce((select json_agg(x order by x.son desc nulls last) from (
        select k.id, k.kod, k.ad, k.tur, k.aktif, k.bitis, k.gunluk_rota as gunluk,
          (select max(c.son) from erisim_cihaz c where c.kod_id = k.id) as son,
          (select string_agg(coalesce(c.model, '?'), ', ') from erisim_cihaz c where c.kod_id = k.id) as cihazlar,
          (select count(*) from google_istek g where g.kod_id = k.id and g.zaman >= _bugun0() and g.tur <> 'oneri') as bugun,
          (select count(*) from google_istek g where g.kod_id = k.id and g.zaman >= _bugun0() and g.tur = 'oneri') as oneri_bugun,
          (select max(g.zaman) from google_istek g where g.kod_id = k.id) as son_istek,
          (select count(*) from google_istek g where g.kod_id = k.id) as google30,
          (select coalesce(sum(u.km), 0) from kullanim u where u.kod_id = k.id and u.gun > current_date - 30) as km30
        from erisim_kod k) x), '[]'::json),
    'serbest', coalesce((select json_agg(json_build_object('cihaz_id', s.cihaz_id, 'model', s.model, 'ilk', s.ilk, 'son', s.son,
        'engelli', coalesce((select d.engelli from cihaz d where d.id = s.cihaz_id), false)) order by s.son desc)
        from (select * from serbest_cihaz order by son desc limit 50) s), '[]'::json));
end $$;
