-- Personel paneli güncellemesi (Kasım 2026): müşteri etiketi, şirket araçları ve muayene.
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verilere dokunmaz.

-- ---------- Müşteri / iş yeri etiketi (uygulamada kayıtlı yere varınca) ----------
alter table yolculuk add column if not exists yer text;

drop function if exists yolculuk_ekle(text, text, timestamptz, timestamptz, numeric, int, text, text, text, int, int, text, jsonb, int, int);
create or replace function yolculuk_ekle(p_token text, p_istemci text, p_baslangic timestamptz, p_bitis timestamptz, p_km numeric,
  p_sure_dk int, p_arac text, p_plaka text, p_hedef text, p_koridor int, p_asim int,
  p_iz text default null, p_koridorlar jsonb default null, p_ortalama int default null, p_hareket_ort int default null,
  p_yer text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
begin
  if p_km is null or p_km < 0 or p_km > 3000 then raise exception 'Geçersiz mesafe'; end if;
  insert into yolculuk (calisan_id, istemci_id, baslangic, bitis, km, sure_dk, arac, plaka, hedef, koridor, asim, iz, koridorlar, ortalama, hareket_ort, yer)
  values (cid, left(p_istemci, 60), p_baslangic, p_bitis, p_km, coalesce(p_sure_dk, 0), left(p_arac, 60), left(p_plaka, 20),
          left(p_hedef, 160), coalesce(p_koridor, 0), coalesce(p_asim, 0), left(p_iz, 60000), p_koridorlar, p_ortalama, p_hareket_ort,
          nullif(left(trim(coalesce(p_yer, '')), 120), ''))
  on conflict (calisan_id, istemci_id) do update set bitis = excluded.bitis, km = excluded.km, sure_dk = excluded.sure_dk,
    arac = excluded.arac, plaka = excluded.plaka, hedef = excluded.hedef, koridor = excluded.koridor, asim = excluded.asim,
    iz = coalesce(excluded.iz, yolculuk.iz), koridorlar = coalesce(excluded.koridorlar, yolculuk.koridorlar),
    ortalama = coalesce(excluded.ortalama, yolculuk.ortalama), hareket_ort = coalesce(excluded.hareket_ort, yolculuk.hareket_ort),
    yer = coalesce(excluded.yer, yolculuk.yer);
end $$;

-- Liste: kartlardaki küçük rota çizimi için iz de gelir (uygulama izi seyreltip gönderir)
create or replace function y_yolculuklar(p_token text, p_bas date, p_bit date) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object(
      'id', y.id, 'calisan_id', y.calisan_id, 'calisan', c.ad, 'baslangic', y.baslangic, 'bitis', y.bitis, 'km', y.km,
      'sure_dk', y.sure_dk, 'arac', y.arac, 'plaka', y.plaka, 'hedef', y.hedef, 'koridor', y.koridor, 'asim', y.asim,
      'ortalama', y.ortalama, 'hareket_ort', y.hareket_ort, 'yer', y.yer, 'iz_var', y.iz is not null, 'iz', y.iz)
      order by y.baslangic desc)
    from yolculuk y join calisan c on c.id = y.calisan_id
    where (p_bas is null or y.baslangic::date >= p_bas) and (p_bit is null or y.baslangic::date <= p_bit)), '[]'::json);
end $$;

-- ---------- Şirket araçları ve muayene ----------
create table if not exists sirket_arac (
  id         bigint generated always as identity primary key,
  plaka      text not null unique,
  ad         text not null default '',
  muayene    date,
  aktif      boolean not null default true,
  olusturma  timestamptz not null default now()
);
alter table sirket_arac enable row level security;
revoke all on sirket_arac from anon, authenticated;

-- Plaka karşılaştırması boşluk ve harf büyüklüğünden bağımsız
create or replace function _plk(p text) returns text language sql immutable as $$ select upper(regexp_replace(coalesce(p, ''), '\s', '', 'g')) $$;

create or replace function y_araclar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare ay date := date_trunc('month', now())::date;
begin
  perform _yonetici(p_token);
  return json_build_object(
    'araclar', coalesce((select json_agg(json_build_object(
        'id', a.id, 'plaka', a.plaka, 'ad', a.ad, 'muayene', a.muayene, 'aktif', a.aktif,
        'kalan_gun', case when a.muayene is null then null else a.muayene - current_date end,
        'ay_km', (select coalesce(sum(y.km), 0) from yolculuk y where _plk(y.plaka) = _plk(a.plaka) and y.baslangic >= ay),
        'ay_yolculuk', (select count(*) from yolculuk y where _plk(y.plaka) = _plk(a.plaka) and y.baslangic >= ay),
        'suruculer', (select coalesce(json_agg(distinct c.ad), '[]'::json) from yolculuk y join calisan c on c.id = y.calisan_id
                      where _plk(y.plaka) = _plk(a.plaka) and y.baslangic >= ay),
        'son_konum', (select json_build_object('lat', k.lat, 'lon', k.lon, 'zaman', k.zaman, 'ad', c.ad, 'durum', k.durum)
                      from konum k join calisan c on c.id = k.calisan_id where _plk(k.plaka) = _plk(a.plaka) order by k.zaman desc limit 1),
        'son_yolculuk', (select max(y.bitis) from yolculuk y where _plk(y.plaka) = _plk(a.plaka))
      ) order by a.aktif desc, a.muayene nulls last, a.plaka) from sirket_arac a), '[]'::json),
    -- Yolculuklarda görülüp listede olmayan plakalar (tek dokunuşla eklemek için)
    'yeni', coalesce((select json_agg(x.plaka) from (
        select distinct on (_plk(y.plaka)) y.plaka from yolculuk y
        where coalesce(y.plaka, '') <> '' and y.baslangic > now() - interval '120 days'
          and not exists (select 1 from sirket_arac a where _plk(a.plaka) = _plk(y.plaka))) x), '[]'::json));
end $$;

create or replace function y_arac_kaydet(p_token text, p_id bigint, p_plaka text, p_ad text, p_muayene date, p_aktif boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  if coalesce(trim(p_plaka), '') = '' then raise exception 'Plaka gerekli'; end if;
  if p_id is null then
    insert into sirket_arac (plaka, ad, muayene, aktif) values (upper(trim(p_plaka)), left(coalesce(trim(p_ad), ''), 60), p_muayene, coalesce(p_aktif, true));
  else
    update sirket_arac set plaka = upper(trim(p_plaka)), ad = left(coalesce(trim(p_ad), ''), 60), muayene = p_muayene, aktif = coalesce(p_aktif, true) where id = p_id;
  end if;
end $$;

create or replace function y_arac_sil(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  delete from sirket_arac where id = p_id;
end $$;

-- Uygulama: bağlı çalışan, kullandığı şirket aracının muayene tarihini görür (başka bilgi verilmez)
create or replace function arac_muayene(p_token text, p_plaka text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare d date;
begin
  perform _calisan(p_token);
  select muayene into d from sirket_arac where _plk(plaka) = _plk(p_plaka) and aktif limit 1;
  return json_build_object('muayene', d, 'kalan_gun', case when d is null then null else d - current_date end);
end $$;

revoke execute on function _plk(text) from public, anon, authenticated;
grant execute on function
  yolculuk_ekle(text, text, timestamptz, timestamptz, numeric, int, text, text, text, int, int, text, jsonb, int, int, text),
  y_yolculuklar(text, date, date), y_araclar(text), y_arac_kaydet(text, bigint, text, text, date, boolean), y_arac_sil(text, bigint),
  arac_muayene(text, text)
to anon, authenticated;
