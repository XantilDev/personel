-- Koridor Ortalama: teknik loglar, cihaz listesi (çevrimiçi durumu) ve EGM il/ilçe listesi (Kasım 2026).
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verilere dokunmaz.

-- ---------- EGM il / ilçe listesi (trafik.gov.tr'deki kimlikler ve ilçe merkezleri) ----------
create table if not exists egm_ilce (
  id          int primary key,            -- EGM ilçe kimliği
  il_id       int not null,
  il          text not null,
  ad          text not null,
  lat         double precision not null,
  lon         double precision not null,
  guncelleme  timestamptz not null default now()
);
alter table egm_ilce enable row level security;
revoke all on egm_ilce from anon, authenticated;

-- Uygulama listeyi bir kez indirir, telefonda saklar (veri kamuya açık EGM verisi)
create or replace function egm_ilceler() returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object(
    'surum', (select coalesce(extract(epoch from max(guncelleme))::bigint, 0) from egm_ilce),
    'ilceler', coalesce((select json_agg(json_build_array(id, il_id, il, ad, lat, lon) order by il_id, ad) from egm_ilce), '[]'::json));
$$;

-- ---------- Cihazlar ----------
create table if not exists cihaz (
  id          text primary key,             -- uygulamanın kurulumda ürettiği kimlik
  calisan_id  bigint references calisan(id) on delete set null,
  model       text,
  android     text,
  surum       int,
  surum_ad    text,
  durum       text,                          -- son bildirilen durum (sürüş, hazır, arka planda…)
  lat         double precision,
  lon         double precision,
  ilk         timestamptz not null default now(),
  son         timestamptz not null default now()
);
alter table cihaz enable row level security;
revoke all on cihaz from anon, authenticated;

-- ---------- Teknik loglar ----------
create table if not exists teknik_log (
  id          bigint generated always as identity primary key,
  cihaz_id    text not null,
  calisan_id  bigint,
  zaman       timestamptz not null,           -- olayın telefondaki saati
  alindi      timestamptz not null default now(),
  surum       int,
  tur         text not null default 'bilgi',  -- bilgi / uyari / hata / cokme
  olay        text not null,                  -- rota, egm, konum, harita, yon, uygulama…
  mesaj       text,
  veri        jsonb,
  lat         double precision,
  lon         double precision,
  hiz         int,
  sahsi       boolean not null default false
);
create index if not exists teknik_log_zaman on teknik_log (zaman desc);
create index if not exists teknik_log_cihaz on teknik_log (cihaz_id, zaman desc);
alter table teknik_log enable row level security;
revoke all on teknik_log from anon, authenticated;

-- Uygulama: logları toplu gönderir (en çok 500 kayıt), cihaz bilgisini ve "son görülme"yi günceller.
create or replace function log_ekle(p_token text, p_cihaz jsonb, p_kayitlar jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
        did text := left(coalesce(p_cihaz->>'id', ''), 64);
        n int := 0;
begin
  if did = '' then raise exception 'Cihaz kimliği yok'; end if;
  insert into cihaz (id, calisan_id, model, android, surum, surum_ad, durum, lat, lon, son)
  values (did, cid, left(p_cihaz->>'model', 80), left(p_cihaz->>'android', 20), (p_cihaz->>'surum')::int, left(p_cihaz->>'surum_ad', 40),
          left(p_cihaz->>'durum', 80), (p_cihaz->>'lat')::double precision, (p_cihaz->>'lon')::double precision, now())
  on conflict (id) do update set calisan_id = excluded.calisan_id, model = excluded.model, android = excluded.android,
    surum = excluded.surum, surum_ad = excluded.surum_ad, durum = excluded.durum,
    lat = coalesce(excluded.lat, cihaz.lat), lon = coalesce(excluded.lon, cihaz.lon), son = now();

  if jsonb_typeof(p_kayitlar) = 'array' then
    insert into teknik_log (cihaz_id, calisan_id, zaman, surum, tur, olay, mesaj, veri, lat, lon, hiz, sahsi)
    select did, cid,
           least(coalesce(to_timestamp((k->>'t')::bigint / 1000.0), now()), now() + interval '5 minutes'),
           (p_cihaz->>'surum')::int,
           left(coalesce(k->>'tur', 'bilgi'), 10), left(coalesce(k->>'olay', '?'), 30), left(k->>'m', 1000),
           case when k ? 'v' and length((k->'v')::text) < 4000 then k->'v' end,
           (k->>'lat')::double precision, (k->>'lon')::double precision, (k->>'hiz')::int,
           coalesce((k->>'sahsi')::boolean, false)
    from (select value k from jsonb_array_elements(p_kayitlar) limit 500) x;
    get diagnostics n = row_count;
  end if;

  -- 30 günden eski kayıtlar arada bir temizlenir
  if random() < 0.02 then delete from teknik_log where zaman < now() - interval '30 days'; end if;
  return json_build_object('eklendi', n);
end $$;

-- Panel: loglar (süzgeçli, en yeniler önce)
create or replace function y_loglar(p_token text, p_bas timestamptz, p_bit timestamptz, p_cihaz text, p_tur text, p_ara text, p_limit int)
returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(x) from (
      select l.id, l.cihaz_id, c.ad as calisan, d.model, l.zaman, l.surum, l.tur, l.olay, l.mesaj, l.veri, l.lat, l.lon, l.hiz, l.sahsi
      from teknik_log l left join calisan c on c.id = l.calisan_id left join cihaz d on d.id = l.cihaz_id
      where (p_bas is null or l.zaman >= p_bas) and (p_bit is null or l.zaman < p_bit)
        and (coalesce(p_cihaz, '') = '' or l.cihaz_id = p_cihaz)
        and (coalesce(p_tur, '') = '' or l.tur = p_tur or l.olay = p_tur)
        and (coalesce(p_ara, '') = '' or l.mesaj ilike '%' || p_ara || '%' or l.olay ilike '%' || p_ara || '%')
      order by l.zaman desc
      limit least(greatest(coalesce(p_limit, 300), 1), 2000)) x), '[]'::json);
end $$;

-- Panel: cihaz listesi; son 3 dakikada haber veren çevrimiçi sayılır
create or replace function y_cihazlar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object(
      'id', d.id, 'calisan', c.ad, 'model', d.model, 'android', d.android, 'surum', d.surum, 'surum_ad', d.surum_ad,
      'durum', d.durum, 'lat', d.lat, 'lon', d.lon, 'ilk', d.ilk, 'son', d.son,
      'cevrimici', d.son > now() - interval '3 minutes',
      'hata_24s', (select count(*) from teknik_log l where l.cihaz_id = d.id and l.tur in ('hata', 'cokme') and l.zaman > now() - interval '24 hours'),
      'log_24s', (select count(*) from teknik_log l where l.cihaz_id = d.id and l.zaman > now() - interval '24 hours'))
      order by d.son desc)
    from cihaz d left join calisan c on c.id = d.calisan_id), '[]'::json);
end $$;

grant execute on function egm_ilceler() to anon, authenticated;
grant execute on function log_ekle(text, jsonb, jsonb), y_loglar(text, timestamptz, timestamptz, text, text, text, int), y_cihazlar(text)
  to anon, authenticated;
