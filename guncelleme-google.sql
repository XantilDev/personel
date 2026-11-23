-- Koridor Ortalama: kişi başı günlük Google hakkı, firma cihazı kodu, ortak limit düzeltmeleri,
-- kodsuz (ücretsiz) kullanım ve kullanıcı listesi — Kasım 2026.
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verileri silmez.
-- Önce guncelleme-erisim.sql çalışmış olmalı.

-- ---------- Tablolar ----------
-- Kod türü: misafir (Google sınırlı, firma özellikleri kapalı) / firma (ör. BYD tableti: firma özellikleri açık)
alter table erisim_kod add column if not exists tur text not null default 'misafir';
alter table erisim_kod drop constraint if exists erisim_kod_tur_chk;
alter table erisim_kod add constraint erisim_kod_tur_chk check (tur in ('misafir', 'firma'));
alter table erisim_kod alter column gunluk_rota set default 20;
-- Firma kodlu cihazın oturum anahtarı (radar, teknik kayıt, EGM ortak kayıt için)
alter table erisim_cihaz add column if not exists token text unique;

-- Çalışanların uygulama ayarı (yoksa: aktif, günde 30)
create table if not exists uygulama_calisan (
  calisan_id  bigint primary key references calisan(id) on delete cascade,
  gunluk      int default 30,                    -- boşsa sınırsız
  aktif       boolean not null default true
);
alter table uygulama_calisan enable row level security;
revoke all on uygulama_calisan from anon, authenticated;

-- Her Google isteği (rota / trafik / arama); 30 gün saklanır
create table if not exists google_istek (
  id          bigint generated always as identity primary key,
  zaman       timestamptz not null default now(),
  cihaz_id    text,
  calisan_id  bigint references calisan(id) on delete set null,
  kod_id      bigint references erisim_kod(id) on delete set null,
  tur         text not null default 'rota'
);
create index if not exists google_istek_calisan on google_istek (calisan_id, zaman desc);
create index if not exists google_istek_kod on google_istek (kod_id, zaman desc);
create index if not exists google_istek_zaman on google_istek (zaman desc);
alter table google_istek enable row level security;
revoke all on google_istek from anon, authenticated;

-- Kodsuz (ücretsiz modda) kullanan cihazlar
create table if not exists serbest_cihaz (
  cihaz_id  text primary key,
  model     text,
  ilk       timestamptz not null default now(),
  son       timestamptz not null default now()
);
alter table serbest_cihaz enable row level security;
revoke all on serbest_cihaz from anon, authenticated;

-- Levhaya göre düzeltilmiş koridor limitleri (ortak)
create table if not exists koridor_limit (
  anahtar     text primary key,                  -- koridorun başlangıç/bitiş koordinatı (uygulamadaki anahtar)
  ad          text,
  limit_kmh   int not null check (limit_kmh between 20 and 160),
  egm_limit   int,
  calisan_id  bigint references calisan(id) on delete set null,
  ekleyen     text,
  cihaz_id    text,
  zaman       timestamptz not null default now()
);
alter table koridor_limit enable row level security;
revoke all on koridor_limit from anon, authenticated;

-- ---------- Yardımcılar ----------
create or replace function _bugun0() returns timestamptz
language sql stable as $$ select date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul' $$;

-- Çalışan oturumu ya da firma cihazı anahtarı → (çalışan id, ad). Firma cihazında çalışan id boştur.
create or replace function _surucu(p_token text, out cid bigint, out ad text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(p_token, '') like 'F-%' then
    select k.ad into ad from erisim_cihaz c join erisim_kod k on k.id = c.kod_id
      where c.token = p_token and not c.engelli and k.aktif and k.tur = 'firma'
        and (k.bitis is null or k.bitis >= current_date)
        and not exists (select 1 from cihaz d where d.id = c.cihaz_id and d.engelli);
    if not found then raise exception 'Oturum süresi doldu, tekrar giriş yap.'; end if;
    cid := null; ad := coalesce(nullif(trim(ad), ''), 'Firma cihazı');
    return;
  end if;
  cid := _calisan(p_token);
  if exists (select 1 from uygulama_calisan u where u.calisan_id = cid and not u.aktif) then
    raise exception 'Uygulama erişimin kapalı. Yöneticine başvur.';
  end if;
  select c.ad into ad from calisan c where c.id = cid;
end $$;
revoke execute on function _surucu(text) from public, anon, authenticated;

-- Erişim: ('calisan', id) / ('kod', id) / ('firma', id) / ('', null) + neden
create or replace function _erisim(p_token text, p_kod text, p_cihaz text, p_model text, out tur text, out ref bigint, out neden text)
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint; k erisim_kod; ec erisim_cihaz; n int;
begin
  tur := ''; ref := null; neden := null;
  if coalesce(p_cihaz, '') = '' then neden := 'cihaz_yok'; return; end if;
  if exists (select 1 from cihaz where id = p_cihaz and engelli) then neden := 'cihaz_engelli'; return; end if;
  if coalesce(p_token, '') <> '' and p_token not like 'F-%' then
    begin
      cid := _calisan(p_token);
      if exists (select 1 from uygulama_calisan u where u.calisan_id = cid and not u.aktif) then neden := 'calisan_pasif'; return; end if;
      tur := 'calisan'; ref := cid; return;
    exception when others then
      if sqlerrm like 'Hesabın kapalı%' then neden := 'calisan_kapali'; return; end if;
      neden := 'oturum_bitti';
    end;
  end if;
  if coalesce(trim(p_kod), '') = '' then neden := coalesce(neden, 'giris_gerekli'); return; end if;
  select * into k from erisim_kod where upper(kod) = upper(trim(p_kod));
  if k.id is null then neden := 'kod_yok'; insert into erisim_red (kod, cihaz_id, model, neden) values (left(p_kod, 20), p_cihaz, left(p_model, 80), neden); return; end if;
  if not k.aktif then neden := 'kod_kapali'; insert into erisim_red (kod, kod_id, cihaz_id, model, neden) values (k.kod, k.id, p_cihaz, left(p_model, 80), neden); return; end if;
  if k.bitis is not null and k.bitis < current_date then neden := 'kod_bitti'; insert into erisim_red (kod, kod_id, cihaz_id, model, neden) values (k.kod, k.id, p_cihaz, left(p_model, 80), neden); return; end if;
  select * into ec from erisim_cihaz where kod_id = k.id and cihaz_id = p_cihaz;
  if ec.id is not null then
    if ec.engelli then neden := 'cihaz_engelli'; return; end if;
    update erisim_cihaz set son = now(), model = coalesce(left(p_model, 80), model) where id = ec.id;
  else
    select count(*) into n from erisim_cihaz where kod_id = k.id and not engelli;
    if n >= k.cihaz_limit then
      neden := 'cihaz_siniri';
      insert into erisim_red (kod, kod_id, cihaz_id, model, neden) values (k.kod, k.id, p_cihaz, left(p_model, 80), neden);
      return;
    end if;
    insert into erisim_cihaz (kod_id, cihaz_id, model) values (k.id, p_cihaz, left(p_model, 80));
  end if;
  tur := case when k.tur = 'firma' then 'firma' else 'kod' end; ref := k.id; neden := null;
end $$;
revoke execute on function _erisim(text, text, text, text) from public, anon, authenticated;

-- Bugünkü Google istek sayısı ve sınırı
create or replace function _google_durum(p_tur text, p_ref bigint, out bugun int, out sinir int)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_tur = 'calisan' then
    select coalesce((select u.gunluk from uygulama_calisan u where u.calisan_id = p_ref), 30) into sinir;
    if exists (select 1 from uygulama_calisan u where u.calisan_id = p_ref and u.gunluk is null) then sinir := null; end if;
    select count(*) into bugun from google_istek where calisan_id = p_ref and zaman >= _bugun0();
  else
    select k.gunluk_rota into sinir from erisim_kod k where k.id = p_ref;
    select count(*) into bugun from google_istek where kod_id = p_ref and zaman >= _bugun0();
  end if;
end $$;
revoke execute on function _google_durum(text, bigint) from public, anon, authenticated;

-- ---------- Uygulama ----------
-- Açılışta ve 6 saatte bir. Kodsuz cihaz da kaydedilir (ücretsiz modda çalışır).
create or replace function erisim_kontrol(p_token text, p_kod text, p_cihaz text, p_model text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e record; k erisim_kod; g record; tok text;
begin
  select * into e from _erisim(p_token, p_kod, p_cihaz, p_model);
  if e.tur = '' then
    if coalesce(p_cihaz, '') <> '' and e.neden not in ('cihaz_engelli', 'calisan_pasif', 'calisan_kapali') then
      insert into serbest_cihaz (cihaz_id, model) values (left(p_cihaz, 64), left(p_model, 80))
      on conflict (cihaz_id) do update set son = now(), model = coalesce(excluded.model, serbest_cihaz.model);
    end if;
    return json_build_object('izin', false, 'neden', e.neden);
  end if;
  select * into g from _google_durum(case when e.tur = 'calisan' then 'calisan' else 'kod' end, e.ref);
  if e.tur in ('kod', 'firma') then
    select * into k from erisim_kod where id = e.ref;
    if e.tur = 'firma' then
      select token into tok from erisim_cihaz where kod_id = k.id and cihaz_id = p_cihaz;
      if tok is null then
        tok := 'F-' || encode(gen_random_bytes(24), 'hex');
        update erisim_cihaz set token = tok where kod_id = k.id and cihaz_id = p_cihaz;
      end if;
    end if;
    return json_build_object('izin', true, 'tur', e.tur, 'ad', k.ad, 'bitis', k.bitis, 'gunluk', g.sinir, 'bugun', g.bugun, 'token', tok);
  end if;
  return json_build_object('izin', true, 'tur', 'calisan', 'gunluk', g.sinir, 'bugun', g.bugun);
end $$;

-- Her Google isteğinden önce: hakkı varsa sayar ve izin verir
create or replace function google_hak(p_token text, p_kod text, p_cihaz text, p_tur text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e record; g record; t text := case when p_tur in ('rota', 'trafik', 'arama') then p_tur else 'rota' end;
begin
  select * into e from _erisim(p_token, p_kod, p_cihaz, null);
  if e.tur = '' then return json_build_object('izin', false, 'neden', e.neden); end if;
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

-- Kullanım ve "çevrimiçi" bilgisi (10 dakikada bir). Google sayıları artık google_hak ile tutulur.
create or replace function kullanim_ekle(p_token text, p_kod text, p_cihaz text, p_rota int, p_arama int, p_km numeric, p_yolculuk int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e record; g record;
begin
  select * into e from _erisim(p_token, p_kod, p_cihaz, null);
  if e.tur = '' then
    if coalesce(p_cihaz, '') <> '' then
      insert into serbest_cihaz (cihaz_id) values (left(p_cihaz, 64)) on conflict (cihaz_id) do update set son = now();
    end if;
    return json_build_object('bugun', 0);
  end if;
  insert into kullanim (cihaz_id, gun, kod_id, calisan_id, km, yolculuk)
  values (left(p_cihaz, 64), current_date, case when e.tur <> 'calisan' then e.ref end, case when e.tur = 'calisan' then e.ref end,
          greatest(coalesce(p_km, 0), 0), greatest(coalesce(p_yolculuk, 0), 0))
  on conflict (cihaz_id, gun) do update set km = kullanim.km + excluded.km, yolculuk = kullanim.yolculuk + excluded.yolculuk;
  if e.tur = 'calisan' then
    insert into cihaz (id, calisan_id, son) values (left(p_cihaz, 64), e.ref, now())
    on conflict (id) do update set son = now(), calisan_id = excluded.calisan_id;
  end if;
  select * into g from _google_durum(case when e.tur = 'calisan' then 'calisan' else 'kod' end, e.ref);
  return json_build_object('bugun', g.bugun, 'sinir', g.sinir);
end $$;

-- Firma cihazı anahtarıyla da çalışsın diye: teknik kayıt, radar, EGM ortak kayıt
create or replace function log_ekle(p_token text, p_cihaz jsonb, p_kayitlar jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s record; cid bigint;
        did text := left(coalesce(p_cihaz->>'id', ''), 64);
        n int := 0;
begin
  select * into s from _surucu(p_token); cid := s.cid;
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
  if random() < 0.02 then delete from teknik_log where zaman < now() - interval '30 days'; end if;
  return json_build_object('eklendi', n);
end $$;

create or replace function radar_isaretle(p_token text, p_istemci text, p_tur text, p_lat double precision, p_lon double precision,
  p_yon int, p_hiz int, p_zaman timestamptz, p_cihaz text) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare s record; rid bigint;
begin
  select * into s from _surucu(p_token);
  if p_lat is null or p_lon is null or p_lat not between 35 and 43 or p_lon not between 25 and 46 then raise exception 'Geçersiz konum'; end if;
  if s.cid is null then
    -- Firma cihazı: çalışan yok; tekrar gönderimde çift kayıt olmasın
    select id into rid from radar_isaret where calisan_id is null and cihaz_id = left(p_cihaz, 64) and istemci_id = left(p_istemci, 60);
    if rid is not null then return rid; end if;
    insert into radar_isaret (calisan_id, cihaz_id, tur, lat, lon, yon, hiz, zaman, istemci_id, ekleyen)
    values (null, left(p_cihaz, 64), case when p_tur = 'cevirme' then 'cevirme' else 'radar' end, p_lat, p_lon,
            case when p_yon between 0 and 360 then p_yon end, p_hiz, least(coalesce(p_zaman, now()), now()), left(p_istemci, 60), s.ad)
    returning id into rid;
    return rid;
  end if;
  insert into radar_isaret (calisan_id, cihaz_id, tur, lat, lon, yon, hiz, zaman, istemci_id)
  values (s.cid, left(p_cihaz, 64), case when p_tur = 'cevirme' then 'cevirme' else 'radar' end, p_lat, p_lon,
          case when p_yon between 0 and 360 then p_yon end, p_hiz, least(coalesce(p_zaman, now()), now()), left(p_istemci, 60))
  on conflict (calisan_id, istemci_id) do update set tur = excluded.tur
  returning id into rid;
  return rid;
end $$;

create or replace function radar_isaret_geri(p_token text, p_istemci text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s record;
begin
  select * into s from _surucu(p_token);
  if s.cid is null then
    delete from radar_isaret where calisan_id is null and ekleyen = s.ad and istemci_id = p_istemci and zaman > now() - interval '30 minutes';
  else
    delete from radar_isaret where calisan_id = s.cid and istemci_id = p_istemci and zaman > now() - interval '30 minutes';
  end if;
end $$;

create or replace function radar_noktalari(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _surucu(p_token);
  return coalesce((select json_agg(json_build_array(r.id, r.tur, round(r.lat::numeric, 6), round(r.lon::numeric, 6), r.yon,
      extract(epoch from r.zaman)::bigint, coalesce(c.ad, r.ekleyen)) order by r.zaman)
    from radar_isaret r left join calisan c on c.id = r.calisan_id where r.zaman > now() - interval '3 years'), '[]'::json);
end $$;

create or replace function egm_sonuc_yaz(p_token text, p_from int, p_to int, p_radar int, p_kontrol int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _surucu(p_token);
  if p_radar is null and p_kontrol is null then return; end if;
  insert into egm_sonuc (from_id, to_id, radar, kontrol, zaman) values (p_from, p_to, p_radar, p_kontrol, now())
  on conflict (from_id, to_id) do update set radar = excluded.radar, kontrol = excluded.kontrol, zaman = now();
end $$;

create or replace function egm_sonuc_oku(p_token text, p_from int, p_to int) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _surucu(p_token);
  return (select json_build_object('radar', radar, 'kontrol', kontrol, 'zaman', extract(epoch from zaman)::bigint)
          from egm_sonuc where from_id = p_from and to_id = p_to and zaman > now() - interval '7 days');
end $$;

-- Limit düzeltmeleri: çalışan / firma cihazı ekler; misafir sadece görür (isimsiz)
create or replace function limit_duzeltmeleri(p_token text, p_kod text, p_cihaz text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare isimli boolean := true; e record;
begin
  begin
    perform _surucu(p_token);
  exception when others then
    select * into e from _erisim(null, p_kod, p_cihaz, null);
    if e.tur = '' then raise exception 'Erişim yok'; end if;
    isimli := false;
  end;
  return coalesce((select json_agg(json_build_array(l.anahtar, l.limit_kmh, case when isimli then coalesce(c.ad, l.ekleyen) end,
      extract(epoch from l.zaman)::bigint))
    from koridor_limit l left join calisan c on c.id = l.calisan_id), '[]'::json);
end $$;

create or replace function limit_duzelt(p_token text, p_anahtar text, p_ad text, p_limit int, p_egm int, p_cihaz text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s record;
begin
  select * into s from _surucu(p_token);
  if coalesce(p_anahtar, '') = '' or p_limit is null or p_limit not between 20 and 160 then raise exception 'Geçersiz limit'; end if;
  insert into koridor_limit (anahtar, ad, limit_kmh, egm_limit, calisan_id, ekleyen, cihaz_id, zaman)
  values (left(p_anahtar, 80), left(p_ad, 120), p_limit, p_egm, s.cid, s.ad, left(p_cihaz, 64), now())
  on conflict (anahtar) do update set ad = coalesce(excluded.ad, koridor_limit.ad), limit_kmh = excluded.limit_kmh,
    egm_limit = coalesce(excluded.egm_limit, koridor_limit.egm_limit), calisan_id = excluded.calisan_id,
    ekleyen = excluded.ekleyen, cihaz_id = excluded.cihaz_id, zaman = now();
end $$;

-- ---------- Panel ----------
-- Kod oluştur / düzenle (tür eklendi)
drop function if exists y_kod_kaydet(text, bigint, text, int, date, boolean, int);
create or replace function y_kod_kaydet(p_token text, p_id bigint, p_ad text, p_limit int, p_bitis date, p_aktif boolean, p_gunluk int, p_tur text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare yeni text; i int := 0; t text := case when p_tur = 'firma' then 'firma' else 'misafir' end;
begin
  perform _yonetici(p_token);
  if p_id is null then
    loop
      yeni := 'AYM-' || (select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 5));
      exit when not exists (select 1 from erisim_kod where kod = yeni);
      i := i + 1; if i > 20 then raise exception 'Kod üretilemedi'; end if;
    end loop;
    insert into erisim_kod (kod, ad, cihaz_limit, bitis, aktif, gunluk_rota, tur)
    values (yeni, left(coalesce(trim(p_ad), ''), 80), greatest(coalesce(p_limit, 1), 1), p_bitis, coalesce(p_aktif, true), p_gunluk, t);
    return yeni;
  end if;
  update erisim_kod set ad = left(coalesce(trim(p_ad), ''), 80), cihaz_limit = greatest(coalesce(p_limit, 1), 1), bitis = p_bitis,
    aktif = coalesce(p_aktif, true), gunluk_rota = p_gunluk, tur = t where id = p_id returning kod into yeni;
  return yeni;
end $$;

-- Kodlar listesi: tür, bugünkü Google sayısı
create or replace function y_erisim(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return json_build_object(
    'kodlar', coalesce((select json_agg(json_build_object(
        'id', k.id, 'kod', k.kod, 'ad', k.ad, 'tur', k.tur, 'cihaz_limit', k.cihaz_limit, 'bitis', k.bitis, 'aktif', k.aktif,
        'gunluk_rota', k.gunluk_rota, 'olusturma', k.olusturma,
        'bugun', (select count(*) from google_istek g where g.kod_id = k.id and g.zaman >= _bugun0()),
        'cihazlar', coalesce((select json_agg(json_build_object('id', c.id, 'cihaz_id', c.cihaz_id, 'model', c.model, 'ilk', c.ilk, 'son', c.son,
              'engelli', c.engelli,
              'km30', (select coalesce(sum(u.km), 0) from kullanim u where u.cihaz_id = c.cihaz_id and u.gun > current_date - 30),
              'yolculuk30', (select coalesce(sum(u.yolculuk), 0) from kullanim u where u.cihaz_id = c.cihaz_id and u.gun > current_date - 30),
              'google30', (select count(*) from google_istek g where g.cihaz_id = c.cihaz_id and g.kod_id = k.id),
              'google_bugun', (select count(*) from google_istek g where g.cihaz_id = c.cihaz_id and g.kod_id = k.id and g.zaman >= _bugun0()))
            order by c.son desc) from erisim_cihaz c where c.kod_id = k.id), '[]'::json),
        'red', coalesce((select json_agg(json_build_object('model', r.model, 'neden', r.neden, 'zaman', r.zaman) order by r.zaman desc)
            from (select * from erisim_red r where r.kod_id = k.id order by r.zaman desc limit 10) r), '[]'::json))
      order by k.aktif desc, k.olusturma desc) from erisim_kod k), '[]'::json),
    'calisanlar', '[]'::json,
    'bilinmeyen_kod', coalesce((select json_agg(json_build_object('kod', r.kod, 'model', r.model, 'zaman', r.zaman) order by r.zaman desc)
        from (select * from erisim_red where kod_id is null order by zaman desc limit 10) r), '[]'::json));
end $$;

-- Kullanıcılar: çalışanlar, kodlar (misafir / firma), kodsuz cihazlar
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
          (select count(*) from google_istek g where g.calisan_id = c.id and g.zaman >= _bugun0()) as bugun,
          (select max(g.zaman) from google_istek g where g.calisan_id = c.id) as son_istek,
          (select count(*) from google_istek g where g.calisan_id = c.id) as google30,
          (select coalesce(sum(k.km), 0) from kullanim k where k.calisan_id = c.id and k.gun > current_date - 30) as km30
        from calisan c left join uygulama_calisan u on u.calisan_id = c.id where c.aktif) x), '[]'::json),
    'kodlar', coalesce((select json_agg(x order by x.son desc nulls last) from (
        select k.id, k.kod, k.ad, k.tur, k.aktif, k.bitis, k.gunluk_rota as gunluk,
          (select max(c.son) from erisim_cihaz c where c.kod_id = k.id) as son,
          (select string_agg(coalesce(c.model, '?'), ', ') from erisim_cihaz c where c.kod_id = k.id) as cihazlar,
          (select count(*) from google_istek g where g.kod_id = k.id and g.zaman >= _bugun0()) as bugun,
          (select max(g.zaman) from google_istek g where g.kod_id = k.id) as son_istek,
          (select count(*) from google_istek g where g.kod_id = k.id) as google30,
          (select coalesce(sum(u.km), 0) from kullanim u where u.kod_id = k.id and u.gun > current_date - 30) as km30
        from erisim_kod k) x), '[]'::json),
    'serbest', coalesce((select json_agg(json_build_object('cihaz_id', s.cihaz_id, 'model', s.model, 'ilk', s.ilk, 'son', s.son,
        'engelli', coalesce((select d.engelli from cihaz d where d.id = s.cihaz_id), false)) order by s.son desc)
        from (select * from serbest_cihaz order by son desc limit 50) s), '[]'::json));
end $$;

-- Bir kişinin (çalışan ya da kod) son 7 günlük Google istekleri
create or replace function y_istekler(p_token text, p_calisan bigint, p_kod bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('zaman', g.zaman, 'tur', g.tur,
      'model', coalesce((select d.model from cihaz d where d.id = g.cihaz_id), (select c.model from erisim_cihaz c where c.cihaz_id = g.cihaz_id limit 1)))
      order by g.zaman desc)
    from (select * from google_istek g where g.zaman > now() - interval '7 days'
          and ((p_calisan is not null and g.calisan_id = p_calisan) or (p_kod is not null and g.kod_id = p_kod))
          order by g.zaman desc limit 500) g), '[]'::json);
end $$;

-- Çalışanın uygulama ayarı: günlük Google sınırı (boş = sınırsız) ve aktif/pasif
create or replace function y_calisan_uygulama(p_token text, p_calisan bigint, p_gunluk int, p_aktif boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  insert into uygulama_calisan (calisan_id, gunluk, aktif) values (p_calisan, p_gunluk, coalesce(p_aktif, true))
  on conflict (calisan_id) do update set gunluk = excluded.gunluk, aktif = excluded.aktif;
end $$;

-- Limit düzeltmeleri (panel)
create or replace function y_limitler(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('anahtar', l.anahtar, 'ad', l.ad, 'limit', l.limit_kmh, 'egm', l.egm_limit,
      'ekleyen', coalesce(c.ad, l.ekleyen), 'zaman', l.zaman) order by l.zaman desc)
    from koridor_limit l left join calisan c on c.id = l.calisan_id), '[]'::json);
end $$;

create or replace function y_limit_kaydet(p_token text, p_anahtar text, p_limit int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  if p_limit is null or p_limit not between 20 and 160 then raise exception 'Limit 20–160 arası olmalı'; end if;
  update koridor_limit set limit_kmh = p_limit, calisan_id = null, ekleyen = 'Yönetici', zaman = now() where anahtar = p_anahtar;
end $$;

create or replace function y_limit_sil(p_token text, p_anahtar text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  delete from koridor_limit where anahtar = p_anahtar;
end $$;

grant execute on function erisim_kontrol(text, text, text, text), google_hak(text, text, text, text),
  kullanim_ekle(text, text, text, int, int, numeric, int), log_ekle(text, jsonb, jsonb),
  radar_isaretle(text, text, text, double precision, double precision, int, int, timestamptz, text), radar_isaret_geri(text, text),
  radar_noktalari(text), egm_sonuc_yaz(text, int, int, int, int), egm_sonuc_oku(text, int, int),
  limit_duzeltmeleri(text, text, text), limit_duzelt(text, text, text, int, int, text),
  y_kod_kaydet(text, bigint, text, int, date, boolean, int, text), y_erisim(text), y_kullanicilar(text),
  y_istekler(text, bigint, bigint), y_calisan_uygulama(text, bigint, int, boolean),
  y_limitler(text), y_limit_kaydet(text, text, int), y_limit_sil(text, text)
  to anon, authenticated;
