-- Koridor Ortalama: çalışanların yolda gördüğü radar / çevirme noktaları (Kasım 2026).
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verilere dokunmaz.

create table if not exists radar_isaret (
  id          bigint generated always as identity primary key,
  calisan_id  bigint references calisan(id) on delete set null,
  cihaz_id    text,
  tur         text not null default 'radar' check (tur in ('radar', 'cevirme')),
  lat         double precision not null,
  lon         double precision not null,
  yon         int,                 -- aracın gidiş yönü (derece); karşı şerit ayrılsın diye
  hiz         int,
  zaman       timestamptz not null default now(),
  istemci_id  text,                -- çevrimdışı kuyruk tekrar gönderirse çift kayıt olmasın
  unique (calisan_id, istemci_id)
);
create index if not exists radar_isaret_zaman on radar_isaret (zaman desc);
alter table radar_isaret enable row level security;
revoke all on radar_isaret from anon, authenticated;

-- Uygulama: "Radar gördüm" / "Çevirme gördüm"
create or replace function radar_isaretle(p_token text, p_istemci text, p_tur text, p_lat double precision, p_lon double precision,
  p_yon int, p_hiz int, p_zaman timestamptz, p_cihaz text) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token); rid bigint;
begin
  if p_lat is null or p_lon is null or p_lat not between 35 and 43 or p_lon not between 25 and 46 then raise exception 'Geçersiz konum'; end if;
  insert into radar_isaret (calisan_id, cihaz_id, tur, lat, lon, yon, hiz, zaman, istemci_id)
  values (cid, left(p_cihaz, 64), case when p_tur = 'cevirme' then 'cevirme' else 'radar' end, p_lat, p_lon,
          case when p_yon between 0 and 360 then p_yon end, p_hiz, least(coalesce(p_zaman, now()), now()), left(p_istemci, 60))
  on conflict (calisan_id, istemci_id) do update set tur = excluded.tur
  returning id into rid;
  return rid;
end $$;

-- Uygulama: yanlışlıkla basıldıysa kendi işaretini 30 dakika içinde geri alır
create or replace function radar_isaret_geri(p_token text, p_istemci text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
begin
  delete from radar_isaret where calisan_id = cid and istemci_id = p_istemci and zaman > now() - interval '30 minutes';
end $$;

-- Uygulama: bütün işaretler (son 3 yıl); telefon bunları yakın olanları birleştirerek "tahmini nokta" yapar
create or replace function radar_noktalari(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _calisan(p_token);
  -- son alan: işaretleyen çalışanın adı (uygulamada "son dün (Ramazan)" diye gösterilir)
  return coalesce((select json_agg(json_build_array(r.id, r.tur, round(r.lat::numeric, 6), round(r.lon::numeric, 6), r.yon,
      extract(epoch from r.zaman)::bigint, c.ad) order by r.zaman)
    from radar_isaret r left join calisan c on c.id = r.calisan_id where r.zaman > now() - interval '3 years'), '[]'::json);
end $$;

-- Panel: işaretler (kim, ne zaman)
create or replace function y_radar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('id', r.id, 'tur', r.tur, 'lat', r.lat, 'lon', r.lon, 'yon', r.yon, 'hiz', r.hiz,
      'zaman', r.zaman, 'calisan', c.ad) order by r.zaman desc)
    from radar_isaret r left join calisan c on c.id = r.calisan_id), '[]'::json);
end $$;

create or replace function y_radar_sil(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  delete from radar_isaret where id = p_id;
end $$;

grant execute on function radar_isaretle(text, text, text, double precision, double precision, int, int, timestamptz, text),
  radar_isaret_geri(text, text), radar_noktalari(text), y_radar(text), y_radar_sil(text, bigint) to anon, authenticated;

-- ---------- Panelden ekleme (Kasım 2026, ek) ----------
alter table radar_isaret add column if not exists ekleyen text;

create or replace function y_radar_ekle(p_token text, p_tur text, p_lat double precision, p_lon double precision, p_yon int) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare rid bigint;
begin
  perform _yonetici(p_token);
  if p_lat is null or p_lon is null or p_lat not between 35 and 43 or p_lon not between 25 and 46 then raise exception 'Geçersiz konum (Türkiye dışında)'; end if;
  insert into radar_isaret (calisan_id, tur, lat, lon, yon, zaman, ekleyen)
  values (null, case when p_tur = 'cevirme' then 'cevirme' else 'radar' end, p_lat, p_lon,
          case when p_yon between 0 and 360 then p_yon end, now(), 'Panel')
  returning id into rid;
  return rid;
end $$;

create or replace function radar_noktalari(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _calisan(p_token);
  return coalesce((select json_agg(json_build_array(r.id, r.tur, round(r.lat::numeric, 6), round(r.lon::numeric, 6), r.yon,
      extract(epoch from r.zaman)::bigint, coalesce(c.ad, r.ekleyen)) order by r.zaman)
    from radar_isaret r left join calisan c on c.id = r.calisan_id where r.zaman > now() - interval '3 years'), '[]'::json);
end $$;

create or replace function y_radar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('id', r.id, 'tur', r.tur, 'lat', r.lat, 'lon', r.lon, 'yon', r.yon, 'hiz', r.hiz,
      'zaman', r.zaman, 'calisan', coalesce(c.ad, r.ekleyen)) order by r.zaman desc)
    from radar_isaret r left join calisan c on c.id = r.calisan_id), '[]'::json);
end $$;

grant execute on function y_radar_ekle(text, text, double precision, double precision, int) to anon, authenticated;
