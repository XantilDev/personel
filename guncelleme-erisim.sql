-- Koridor Ortalama: erişim kontrolü (davet kodu, cihaz izni, kullanım ve kota) — Kasım 2026.
-- Çalışanlar mevcut girişleriyle devam eder; çalışan olmayanlar (misafir) yöneticinin verdiği kodla girer.
-- Yönetici her cihazı panelden engelleyebilir. Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verilere dokunmaz.

-- ---------- Davet kodları ----------
create table if not exists erisim_kod (
  id           bigint generated always as identity primary key,
  kod          text not null unique,
  ad           text not null default '',          -- kimin için (ör. "Ramazan'ın arkadaşı Ali")
  cihaz_limit  int not null default 1,
  bitis        date,                               -- boşsa süresiz
  aktif        boolean not null default true,
  gunluk_rota  int default 50,                     -- günlük Google rota+arama sınırı; boşsa sınırsız
  olusturma    timestamptz not null default now()
);
alter table erisim_kod enable row level security;
revoke all on erisim_kod from anon, authenticated;

-- Koda bağlı cihazlar
create table if not exists erisim_cihaz (
  id        bigint generated always as identity primary key,
  kod_id    bigint not null references erisim_kod(id) on delete cascade,
  cihaz_id  text not null,
  model     text,
  ilk       timestamptz not null default now(),
  son       timestamptz not null default now(),
  engelli   boolean not null default false,
  unique (kod_id, cihaz_id)
);
alter table erisim_cihaz enable row level security;
revoke all on erisim_cihaz from anon, authenticated;

-- Reddedilen denemeler (cihaz sınırı dolu, kod kapalı…): kodun başkasına verilip verilmediğini görmek için
create table if not exists erisim_red (
  id        bigint generated always as identity primary key,
  kod       text,
  kod_id    bigint references erisim_kod(id) on delete cascade,
  cihaz_id  text,
  model     text,
  neden     text,
  zaman     timestamptz not null default now()
);
alter table erisim_red enable row level security;
revoke all on erisim_red from anon, authenticated;

-- Günlük kullanım (cihaz başına; koordinat yok)
create table if not exists kullanim (
  cihaz_id   text not null,
  gun        date not null,
  kod_id     bigint references erisim_kod(id) on delete set null,
  calisan_id bigint references calisan(id) on delete set null,
  rota       int not null default 0,
  arama      int not null default 0,
  km         numeric(10,1) not null default 0,
  yolculuk   int not null default 0,
  primary key (cihaz_id, gun)
);
alter table kullanim enable row level security;
revoke all on kullanim from anon, authenticated;

-- Çalışan cihazlarını da engelleyebilmek için
alter table cihaz add column if not exists engelli boolean not null default false;

-- Bir cihazın kim adına kullandığını bulur: ('calisan', id) / ('kod', id) / ('', null) + red nedeni
create or replace function _erisim(p_token text, p_kod text, p_cihaz text, p_model text, out tur text, out ref bigint, out neden text)
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint; k erisim_kod; ec erisim_cihaz; n int;
begin
  tur := ''; ref := null; neden := null;
  if coalesce(p_cihaz, '') = '' then neden := 'cihaz_yok'; return; end if;
  if exists (select 1 from cihaz where id = p_cihaz and engelli) then neden := 'cihaz_engelli'; return; end if;
  -- Çalışan girişi
  if coalesce(p_token, '') <> '' then
    begin
      cid := _calisan(p_token);
      tur := 'calisan'; ref := cid; return;
    exception when others then
      if sqlerrm like 'Hesabın kapalı%' then neden := 'calisan_kapali'; return; end if;
      neden := 'oturum_bitti';   -- kod varsa aşağıda denenir
    end;
  end if;
  -- Davet kodu
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
  tur := 'kod'; ref := k.id; neden := null;
end $$;
revoke execute on function _erisim(text, text, text, text) from public, anon, authenticated;

-- Uygulama: açılışta ve 6 saatte bir "bu cihaz kullanabilir mi?"
create or replace function erisim_kontrol(p_token text, p_kod text, p_cihaz text, p_model text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e record; k erisim_kod; bugun int := 0;
begin
  select * into e from _erisim(p_token, p_kod, p_cihaz, p_model);
  if e.tur = '' then
    return json_build_object('izin', false, 'neden', e.neden);
  end if;
  if e.tur = 'kod' then
    select * into k from erisim_kod where id = e.ref;
    select coalesce(rota + arama, 0) into bugun from kullanim where cihaz_id = p_cihaz and gun = current_date;
    return json_build_object('izin', true, 'tur', 'kod', 'ad', k.ad, 'bitis', k.bitis, 'gunluk', k.gunluk_rota, 'bugun', coalesce(bugun, 0));
  end if;
  return json_build_object('izin', true, 'tur', 'calisan');
end $$;

-- Uygulama: kullanım sayaçları (Google rota/arama sayısı, km, yolculuk). Döner: bugünkü toplam ve sınır.
create or replace function kullanim_ekle(p_token text, p_kod text, p_cihaz text, p_rota int, p_arama int, p_km numeric, p_yolculuk int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e record; sinir int; tot int;
begin
  select * into e from _erisim(p_token, p_kod, p_cihaz, null);
  if e.tur = '' then raise exception 'Erişim yok (%)', e.neden; end if;
  insert into kullanim (cihaz_id, gun, kod_id, calisan_id, rota, arama, km, yolculuk)
  values (p_cihaz, current_date, case when e.tur = 'kod' then e.ref end, case when e.tur = 'calisan' then e.ref end,
          greatest(coalesce(p_rota, 0), 0), greatest(coalesce(p_arama, 0), 0), greatest(coalesce(p_km, 0), 0), greatest(coalesce(p_yolculuk, 0), 0))
  on conflict (cihaz_id, gun) do update set rota = kullanim.rota + excluded.rota, arama = kullanim.arama + excluded.arama,
    km = kullanim.km + excluded.km, yolculuk = kullanim.yolculuk + excluded.yolculuk,
    kod_id = coalesce(excluded.kod_id, kullanim.kod_id), calisan_id = coalesce(excluded.calisan_id, kullanim.calisan_id)
  returning rota + arama into tot;
  if e.tur = 'kod' then select gunluk_rota into sinir from erisim_kod where id = e.ref; end if;
  return json_build_object('bugun', tot, 'sinir', sinir);
end $$;

-- ---------- Panel ----------
create or replace function y_erisim(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return json_build_object(
    'kodlar', coalesce((select json_agg(json_build_object(
        'id', k.id, 'kod', k.kod, 'ad', k.ad, 'cihaz_limit', k.cihaz_limit, 'bitis', k.bitis, 'aktif', k.aktif,
        'gunluk_rota', k.gunluk_rota, 'olusturma', k.olusturma,
        'cihazlar', coalesce((select json_agg(json_build_object('id', c.id, 'cihaz_id', c.cihaz_id, 'model', c.model, 'ilk', c.ilk, 'son', c.son,
              'engelli', c.engelli,
              'km30', (select coalesce(sum(u.km), 0) from kullanim u where u.cihaz_id = c.cihaz_id and u.gun > current_date - 30),
              'yolculuk30', (select coalesce(sum(u.yolculuk), 0) from kullanim u where u.cihaz_id = c.cihaz_id and u.gun > current_date - 30),
              'google30', (select coalesce(sum(u.rota + u.arama), 0) from kullanim u where u.cihaz_id = c.cihaz_id and u.gun > current_date - 30),
              'google_bugun', (select coalesce(sum(u.rota + u.arama), 0) from kullanim u where u.cihaz_id = c.cihaz_id and u.gun = current_date))
            order by c.son desc) from erisim_cihaz c where c.kod_id = k.id), '[]'::json),
        'red', coalesce((select json_agg(json_build_object('model', r.model, 'neden', r.neden, 'zaman', r.zaman) order by r.zaman desc)
            from (select * from erisim_red r where r.kod_id = k.id order by r.zaman desc limit 10) r), '[]'::json))
      order by k.aktif desc, k.olusturma desc) from erisim_kod k), '[]'::json),
    -- Çalışan cihazlarının kullanımı (son 30 gün)
    'calisanlar', coalesce((select json_agg(x order by x.google30 desc) from (
        select d.id as cihaz_id, c.ad, d.model, d.son, d.engelli,
          (select coalesce(sum(u.km), 0) from kullanim u where u.cihaz_id = d.id and u.gun > current_date - 30) km30,
          (select coalesce(sum(u.rota + u.arama), 0) from kullanim u where u.cihaz_id = d.id and u.gun > current_date - 30) google30
        from cihaz d left join calisan c on c.id = d.calisan_id) x), '[]'::json),
    'bilinmeyen_kod', coalesce((select json_agg(json_build_object('kod', r.kod, 'model', r.model, 'zaman', r.zaman) order by r.zaman desc)
        from (select * from erisim_red where kod_id is null order by zaman desc limit 10) r), '[]'::json));
end $$;

create or replace function y_kod_kaydet(p_token text, p_id bigint, p_ad text, p_limit int, p_bitis date, p_aktif boolean, p_gunluk int) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare yeni text; i int := 0;
begin
  perform _yonetici(p_token);
  if p_id is null then
    loop
      -- Karışmayan harf ve rakamlar (0/O, 1/I yok)
      yeni := 'AYM-' || (select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 5));
      exit when not exists (select 1 from erisim_kod where kod = yeni);
      i := i + 1; if i > 20 then raise exception 'Kod üretilemedi'; end if;
    end loop;
    insert into erisim_kod (kod, ad, cihaz_limit, bitis, aktif, gunluk_rota)
    values (yeni, left(coalesce(trim(p_ad), ''), 80), greatest(coalesce(p_limit, 1), 1), p_bitis, coalesce(p_aktif, true), p_gunluk);
    return yeni;
  end if;
  update erisim_kod set ad = left(coalesce(trim(p_ad), ''), 80), cihaz_limit = greatest(coalesce(p_limit, 1), 1), bitis = p_bitis,
    aktif = coalesce(p_aktif, true), gunluk_rota = p_gunluk where id = p_id returning kod into yeni;
  return yeni;
end $$;

create or replace function y_kod_sil(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  delete from erisim_kod where id = p_id;
end $$;

-- Koda bağlı bir cihazı engelle / aç (engelli cihaz sınırdan düşer; kod başka bir cihaza verilebilir)
create or replace function y_erisim_cihaz(p_token text, p_id bigint, p_engelli boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  update erisim_cihaz set engelli = coalesce(p_engelli, true) where id = p_id;
end $$;

-- Herhangi bir cihazı (çalışan cihazı dahil) engelle / aç
create or replace function y_cihaz_engelle(p_token text, p_cihaz text, p_engelli boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  insert into cihaz (id, engelli) values (p_cihaz, coalesce(p_engelli, true))
  on conflict (id) do update set engelli = excluded.engelli;
end $$;

-- Cihaz listesi: engel bilgisi de gelsin
create or replace function y_cihazlar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object(
      'id', d.id, 'calisan', c.ad, 'model', d.model, 'android', d.android, 'surum', d.surum, 'surum_ad', d.surum_ad,
      'durum', d.durum, 'lat', d.lat, 'lon', d.lon, 'ilk', d.ilk, 'son', d.son, 'engelli', d.engelli,
      'cevrimici', d.son > now() - interval '3 minutes',
      'hata_24s', (select count(*) from teknik_log l where l.cihaz_id = d.id and l.tur in ('hata', 'cokme') and l.zaman > now() - interval '24 hours'),
      'log_24s', (select count(*) from teknik_log l where l.cihaz_id = d.id and l.zaman > now() - interval '24 hours'))
      order by d.son desc)
    from cihaz d left join calisan c on c.id = d.calisan_id), '[]'::json);
end $$;

grant execute on function erisim_kontrol(text, text, text, text), kullanim_ekle(text, text, text, int, int, numeric, int),
  y_erisim(text), y_kod_kaydet(text, bigint, text, int, date, boolean, int), y_kod_sil(text, bigint),
  y_erisim_cihaz(text, bigint, boolean), y_cihaz_engelle(text, text, boolean), y_cihazlar(text)
  to anon, authenticated;
