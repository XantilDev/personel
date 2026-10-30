-- =====================================================================
--  AYSOFT Personel · Saha çalışma takibi
--  Supabase → SQL Editor → bu dosyanın tamamını yapıştırıp "Run".
--  Tekrar çalıştırılabilir; mevcut veriyi silmez.
--
--  Güvenlik: Tablolara doğrudan erişim kapalıdır (RLS açık, politika yok).
--  Uygulama yalnızca aşağıdaki fonksiyonları çağırır; her fonksiyon oturum
--  anahtarını kontrol eder. Ücret/ödeme bilgisi sadece yönetici fonksiyonlarından döner.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- Tablolar ----------
create table if not exists calisan (
  id            bigint generated always as identity primary key,
  ad            text not null unique,
  pin_hash      text not null,
  gunluk_ucret  numeric(12,2) not null default 0,
  aktif         boolean not null default true,
  olusturma     timestamptz not null default now()
);

create table if not exists yonetici (
  id         int primary key default 1 check (id = 1),
  sifre_hash text not null
);

create table if not exists oturum (
  token       text primary key,
  calisan_id  bigint references calisan(id) on delete cascade,
  yonetici    boolean not null default false,
  bitis       timestamptz not null
);

create table if not exists giris_deneme (
  anahtar text primary key,
  sayi    int not null default 0,
  son     timestamptz not null default now()
);

create table if not exists kayit (
  id             bigint generated always as identity primary key,
  calisan_id     bigint not null references calisan(id) on delete cascade,
  baslangic      date not null,
  bitis          date not null,
  firma          text not null default '',
  il             text not null default '',
  ilce           text not null default '',
  arkadaslar     text not null default '',
  aciklama       text not null default '',
  onay           boolean not null default false,
  onay_zamani    timestamptz,
  makine_ucreti  numeric(12,2),
  olusturma      timestamptz not null default now(),
  constraint kayit_tarih check (bitis >= baslangic and bitis - baslangic <= 92)
);
create index if not exists kayit_calisan on kayit (calisan_id, baslangic);

create table if not exists izin (
  id          bigint generated always as identity primary key,
  calisan_id  bigint not null references calisan(id) on delete cascade,
  tarih       date not null,
  pazar_izni  boolean not null default true,
  aciklama    text not null default '',
  olusturma   timestamptz not null default now(),
  unique (calisan_id, tarih)
);

create table if not exists odeme (
  id          bigint generated always as identity primary key,
  calisan_id  bigint not null references calisan(id) on delete cascade,
  tarih       date not null default current_date,
  tutar       numeric(12,2) not null,
  tur         text not null default 'Yol parası',
  aciklama    text not null default '',
  olusturma   timestamptz not null default now()
);

alter table calisan      enable row level security;
alter table yonetici     enable row level security;
alter table oturum       enable row level security;
alter table giris_deneme enable row level security;
alter table kayit        enable row level security;
alter table izin         enable row level security;
alter table odeme        enable row level security;

revoke all on calisan, yonetici, oturum, giris_deneme, kayit, izin, odeme from anon, authenticated;

-- ---------- Başlangıç çalışanları (şifre 2945) ----------
insert into calisan (ad, pin_hash, gunluk_ucret) values
  ('Ramazan Ö.', extensions.crypt('2945', extensions.gen_salt('bf')), 850),
  ('Ramazan K.', extensions.crypt('2945', extensions.gen_salt('bf')), 850),
  ('Ali Rıza',   extensions.crypt('2945', extensions.gen_salt('bf')), 850),
  ('Selman',     extensions.crypt('2945', extensions.gen_salt('bf')), 425),
  ('İrfan',      extensions.crypt('2945', extensions.gen_salt('bf')), 425)
on conflict (ad) do nothing;

-- ---------- Yardımcılar (dışarıya kapalı) ----------
-- Not: Başarısız girişte hata fırlatılmaz (fırlatılırsa deneme sayacı da geri alınırdı); {hata: ...} döner.
drop function if exists _deneme_kontrol(text);
create or replace function _kilitli(p_anahtar text) returns boolean
language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from giris_deneme where anahtar = p_anahtar and sayi >= 8 and son > now() - interval '15 minutes')
$$;

create or replace function _deneme_hata(p_anahtar text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into giris_deneme (anahtar, sayi, son) values (p_anahtar, 1, now())
  on conflict (anahtar) do update
    set sayi = case when giris_deneme.son < now() - interval '15 minutes' then 1 else giris_deneme.sayi + 1 end,
        son = now();
end $$;

create or replace function _oturum(p_token text) returns oturum
language plpgsql security definer set search_path = public, extensions as $$
declare o oturum;
begin
  select * into o from oturum where token = p_token and bitis > now();
  if not found then
    raise exception 'Oturum süresi doldu, tekrar giriş yap.';
  end if;
  return o;
end $$;

create or replace function _calisan(p_token text) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare o oturum;
begin
  o := _oturum(p_token);
  if o.calisan_id is null then raise exception 'Bu işlem çalışan girişi ister.'; end if;
  if not exists (select 1 from calisan where id = o.calisan_id and aktif) then
    raise exception 'Hesabın kapalı. Yöneticine başvur.';
  end if;
  return o.calisan_id;
end $$;

create or replace function _yonetici(p_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare o oturum;
begin
  o := _oturum(p_token);
  if not o.yonetici then raise exception 'Bu işlem için yönetici girişi gerekir.'; end if;
end $$;

-- Bir çalışanın kazandığı pazarlar ve FIFO ile hangi izinde kullanıldığı
create or replace function _pazarlar(p_calisan bigint)
returns table (pazar date, kullanildi date, firma text, il text)
language sql security definer set search_path = public, extensions as $$
  with kazanilan as (
    select d::date as pazar, min(k.firma) as firma, min(k.il) as il,
           row_number() over (order by d::date) as sira
    from kayit k, generate_series(k.baslangic, k.bitis, interval '1 day') d
    where k.calisan_id = p_calisan and extract(isodow from d) = 7
    group by d::date
  ),
  kullanilan as (
    select tarih, row_number() over (order by tarih) as sira
    from izin where calisan_id = p_calisan and pazar_izni
  )
  select k.pazar, u.tarih, k.firma, k.il
  from kazanilan k left join kullanilan u on u.sira = k.sira
  order by k.pazar
$$;

-- ---------- Herkese açık ----------
create or replace function calisan_adlari() returns setof text
language sql security definer set search_path = public, extensions as $$
  select ad from calisan where aktif order by ad
$$;

create or replace function giris(p_ad text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare c calisan; t text; k text := 'c:' || lower(coalesce(p_ad, ''));
begin
  if _kilitli(k) then
    return json_build_object('hata', 'Çok fazla hatalı deneme. 15 dakika sonra tekrar dene.');
  end if;
  select * into c from calisan where ad = p_ad and aktif;
  if not found or c.pin_hash <> crypt(coalesce(p_pin, ''), c.pin_hash) then
    perform _deneme_hata(k);
    return json_build_object('hata', 'Ad veya şifre yanlış.');
  end if;
  delete from giris_deneme where anahtar = k;
  delete from oturum where bitis < now();
  t := encode(gen_random_bytes(24), 'hex');
  insert into oturum (token, calisan_id, bitis) values (t, c.id, now() + interval '90 days');
  return json_build_object('token', t, 'ad', c.ad);
end $$;

create or replace function cikis(p_token text) returns void
language sql security definer set search_path = public, extensions as $$
  delete from oturum where token = p_token
$$;

create or replace function yonetici_kurulu() returns boolean
language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from yonetici)
$$;

create or replace function yonetici_kurulum(p_sifre text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t text;
begin
  if exists (select 1 from yonetici) then raise exception 'Yönetici şifresi zaten belirlenmiş.'; end if;
  if length(coalesce(p_sifre, '')) < 8 then raise exception 'Şifre en az 8 karakter olmalı.'; end if;
  insert into yonetici (id, sifre_hash) values (1, crypt(p_sifre, gen_salt('bf')));
  t := encode(gen_random_bytes(24), 'hex');
  insert into oturum (token, yonetici, bitis) values (t, true, now() + interval '12 hours');
  return json_build_object('token', t);
end $$;

create or replace function yonetici_giris(p_sifre text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare h text; t text;
begin
  if _kilitli('yonetici') then
    return json_build_object('hata', 'Çok fazla hatalı deneme. 15 dakika sonra tekrar dene.');
  end if;
  select sifre_hash into h from yonetici where id = 1;
  if h is null or h <> crypt(coalesce(p_sifre, ''), h) then
    perform _deneme_hata('yonetici');
    return json_build_object('hata', 'Şifre yanlış.');
  end if;
  delete from giris_deneme where anahtar = 'yonetici';
  t := encode(gen_random_bytes(24), 'hex');
  insert into oturum (token, yonetici, bitis) values (t, true, now() + interval '12 hours');
  return json_build_object('token', t);
end $$;

-- ---------- Çalışan (ücret ve onay bilgisi dönmez) ----------
create or replace function kayitlarim(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
      'id', id, 'baslangic', baslangic, 'bitis', bitis, 'firma', firma, 'il', il, 'ilce', ilce,
      'arkadaslar', arkadaslar, 'aciklama', aciklama, 'olusturma', olusturma
    ) order by baslangic desc, id desc)
    from kayit where calisan_id = cid), '[]'::json);
end $$;

create or replace function kayit_ekle(p_token text, p_baslangic date, p_bitis date, p_firma text, p_il text,
                                      p_ilce text, p_arkadaslar text, p_aciklama text) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token); yeni bigint;
begin
  if p_baslangic is null or p_bitis is null then raise exception 'Tarihleri seç.'; end if;
  if p_bitis < p_baslangic then raise exception 'Bitiş tarihi başlangıçtan önce olamaz.'; end if;
  if p_bitis - p_baslangic > 92 then raise exception 'Bir kayıt en fazla 3 ayı kapsayabilir.'; end if;
  if coalesce(trim(p_firma), '') = '' and coalesce(trim(p_aciklama), '') = '' then
    raise exception 'Firma ya da açıklama yaz.';
  end if;
  insert into kayit (calisan_id, baslangic, bitis, firma, il, ilce, arkadaslar, aciklama)
  values (cid, p_baslangic, p_bitis, left(trim(coalesce(p_firma, '')), 120), left(trim(coalesce(p_il, '')), 40),
          left(trim(coalesce(p_ilce, '')), 60), left(trim(coalesce(p_arkadaslar, '')), 300), left(trim(coalesce(p_aciklama, '')), 2000))
  returning id into yeni;
  return yeni;
end $$;

create or replace function kayit_sil(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
begin
  delete from kayit where id = p_id and calisan_id = cid and not onay;
  if not found then raise exception 'Bu kayıt silinemiyor. Düzeltme için yöneticine başvur.'; end if;
end $$;

create or replace function pazar_durumum(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
begin
  return json_build_object(
    'pazarlar', coalesce((select json_agg(json_build_object('pazar', pazar, 'kullanildi', kullanildi, 'firma', firma, 'il', il) order by pazar)
                          from _pazarlar(cid)), '[]'::json),
    'kalan', (select count(*) from _pazarlar(cid) where kullanildi is null),
    'izinler', coalesce((select json_agg(json_build_object('id', id, 'tarih', tarih, 'pazar_izni', pazar_izni, 'aciklama', aciklama) order by tarih desc)
                         from izin where calisan_id = cid), '[]'::json)
  );
end $$;

create or replace function izin_ekle(p_token text, p_tarih date, p_pazar_izni boolean, p_aciklama text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
begin
  if p_tarih is null then raise exception 'Tarih seç.'; end if;
  if exists (select 1 from izin where calisan_id = cid and tarih = p_tarih) then
    raise exception 'Bu güne zaten izin girilmiş.';
  end if;
  if p_pazar_izni and (select count(*) from _pazarlar(cid) where kullanildi is null) < 1 then
    raise exception 'Kullanılabilir pazar iznin yok.';
  end if;
  insert into izin (calisan_id, tarih, pazar_izni, aciklama)
  values (cid, p_tarih, coalesce(p_pazar_izni, false), left(trim(coalesce(p_aciklama, '')), 300));
end $$;

create or replace function izin_sil(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cid bigint := _calisan(p_token);
begin
  delete from izin where id = p_id and calisan_id = cid;
end $$;

-- ---------- Yönetici ----------
create or replace function y_kayitlar(p_token text, p_durum text, p_calisan bigint, p_bas date, p_bit date) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((
    select json_agg(json_build_object(
      'id', k.id, 'calisan_id', k.calisan_id, 'calisan', c.ad, 'baslangic', k.baslangic, 'bitis', k.bitis,
      'gun', k.bitis - k.baslangic + 1,
      'firma', k.firma, 'il', k.il, 'ilce', k.ilce, 'arkadaslar', k.arkadaslar, 'aciklama', k.aciklama,
      'onay', k.onay, 'makine_ucreti', k.makine_ucreti, 'olusturma', k.olusturma
    ) order by k.baslangic desc, k.id desc)
    from kayit k join calisan c on c.id = k.calisan_id
    where (p_durum is null or p_durum = 'hepsi' or (p_durum = 'bekleyen' and not k.onay) or (p_durum = 'onayli' and k.onay))
      and (p_calisan is null or k.calisan_id = p_calisan)
      and (p_bas is null or k.bitis >= p_bas)
      and (p_bit is null or k.baslangic <= p_bit)
  ), '[]'::json);
end $$;

create or replace function y_onayla(p_token text, p_id bigint, p_onay boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  update kayit set onay = p_onay, onay_zamani = case when p_onay then now() end where id = p_id;
end $$;

create or replace function y_kayit_sil(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  delete from kayit where id = p_id;
end $$;

create or replace function y_makine_ucreti(p_token text, p_id bigint, p_tutar numeric) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  update kayit set makine_ucreti = p_tutar where id = p_id;
end $$;

create or replace function y_calisanlar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('id', id, 'ad', ad, 'gunluk_ucret', gunluk_ucret, 'aktif', aktif) order by ad) from calisan), '[]'::json);
end $$;

create or replace function y_calisan_kaydet(p_token text, p_id bigint, p_ad text, p_gunluk numeric, p_aktif boolean, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  if coalesce(trim(p_ad), '') = '' then raise exception 'Ad boş olamaz.'; end if;
  if p_id is null then
    insert into calisan (ad, pin_hash, gunluk_ucret, aktif)
    values (trim(p_ad), crypt(coalesce(nullif(p_pin, ''), '2945'), gen_salt('bf')), coalesce(p_gunluk, 0), coalesce(p_aktif, true));
  else
    update calisan set ad = trim(p_ad), gunluk_ucret = coalesce(p_gunluk, gunluk_ucret), aktif = coalesce(p_aktif, aktif),
      pin_hash = case when coalesce(p_pin, '') <> '' then crypt(p_pin, gen_salt('bf')) else pin_hash end
    where id = p_id;
    if coalesce(p_aktif, true) = false then delete from oturum where calisan_id = p_id; end if;
  end if;
end $$;

create or replace function y_odemeler(p_token text, p_calisan bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('id', o.id, 'calisan_id', o.calisan_id, 'calisan', c.ad, 'tarih', o.tarih,
                    'tutar', o.tutar, 'tur', o.tur, 'aciklama', o.aciklama) order by o.tarih desc, o.id desc)
                   from odeme o join calisan c on c.id = o.calisan_id
                   where p_calisan is null or o.calisan_id = p_calisan), '[]'::json);
end $$;

create or replace function y_odeme_ekle(p_token text, p_calisan bigint, p_tarih date, p_tutar numeric, p_tur text, p_aciklama text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  if p_tutar is null or p_tutar = 0 then raise exception 'Tutar gir.'; end if;
  insert into odeme (calisan_id, tarih, tutar, tur, aciklama)
  values (p_calisan, coalesce(p_tarih, current_date), p_tutar, coalesce(nullif(trim(p_tur), ''), 'Yol parası'), coalesce(trim(p_aciklama), ''));
end $$;

create or replace function y_odeme_sil(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  delete from odeme where id = p_id;
end $$;

create or replace function y_izinler(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('id', i.id, 'calisan', c.ad, 'tarih', i.tarih, 'pazar_izni', i.pazar_izni, 'aciklama', i.aciklama)
                    order by i.tarih desc) from izin i join calisan c on c.id = i.calisan_id), '[]'::json);
end $$;

-- Dönem hesabı: onaylı kayıtlardaki farklı günler × günlük ücret + makine ücretleri − ödemeler
create or replace function y_hesap(p_token text, p_bas date, p_bit date) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare b date := coalesce(p_bas, '2000-01-01'); e date := coalesce(p_bit, '2100-01-01');
begin
  perform _yonetici(p_token);
  return coalesce((
    select json_agg(r order by r.ad) from (
      select c.id, c.ad, c.gunluk_ucret, c.aktif,
        (select count(distinct d::date) from kayit k, generate_series(greatest(k.baslangic, b), least(k.bitis, e), interval '1 day') d
          where k.calisan_id = c.id and k.onay) as gun,
        (select count(distinct d::date) from kayit k, generate_series(greatest(k.baslangic, b), least(k.bitis, e), interval '1 day') d
          where k.calisan_id = c.id and not k.onay) as bekleyen_gun,
        coalesce((select sum(makine_ucreti) from kayit k where k.calisan_id = c.id and k.onay and k.baslangic between b and e), 0) as makine,
        coalesce((select sum(tutar) from odeme o where o.calisan_id = c.id and o.tarih between b and e), 0) as odenen,
        (select count(*) from _pazarlar(c.id)) as pazar_kazanilan,
        (select count(*) from _pazarlar(c.id) where kullanildi is null) as pazar_kalan
      from calisan c
    ) r), '[]'::json);
end $$;

-- Yönetici: çalışan bazında pazar izni özeti ve ayrıntısı
create or replace function y_pazar_ozet(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(r order by r.aktif desc, r.ad) from (
    select c.id, c.ad, c.aktif,
      (select count(*) from _pazarlar(c.id)) as kazanilan,
      (select count(*) from _pazarlar(c.id) where kullanildi is not null) as kullanilan,
      (select count(*) from _pazarlar(c.id) where kullanildi is null) as kalan,
      (select count(*) from izin i where i.calisan_id = c.id and i.pazar_izni) as pazar_izni_girilen,
      (select count(*) from izin i where i.calisan_id = c.id and not i.pazar_izni) as normal_izin
    from calisan c) r), '[]'::json);
end $$;

create or replace function y_pazar_durumu(p_token text, p_calisan bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return json_build_object(
    'pazarlar', coalesce((select json_agg(json_build_object('pazar', pazar, 'kullanildi', kullanildi, 'firma', firma, 'il', il) order by pazar)
                          from _pazarlar(p_calisan)), '[]'::json),
    'kalan', (select count(*) from _pazarlar(p_calisan) where kullanildi is null),
    'izinler', coalesce((select json_agg(json_build_object('id', id, 'tarih', tarih, 'pazar_izni', pazar_izni, 'aciklama', aciklama) order by tarih desc)
                         from izin where calisan_id = p_calisan), '[]'::json)
  );
end $$;

-- ---------- Yetkiler ----------
revoke execute on function _kilitli(text), _deneme_hata(text), _oturum(text), _calisan(text), _yonetici(text), _pazarlar(bigint)
  from public, anon, authenticated;

grant execute on function
  calisan_adlari(), giris(text, text), cikis(text), yonetici_kurulu(), yonetici_kurulum(text), yonetici_giris(text),
  kayitlarim(text), kayit_ekle(text, date, date, text, text, text, text, text), kayit_sil(text, bigint),
  pazar_durumum(text), izin_ekle(text, date, boolean, text), izin_sil(text, bigint),
  y_kayitlar(text, text, bigint, date, date), y_onayla(text, bigint, boolean), y_kayit_sil(text, bigint),
  y_makine_ucreti(text, bigint, numeric), y_calisanlar(text), y_calisan_kaydet(text, bigint, text, numeric, boolean, text),
  y_odemeler(text, bigint), y_odeme_ekle(text, bigint, date, numeric, text, text), y_odeme_sil(text, bigint),
  y_izinler(text), y_hesap(text, date, date), y_pazar_ozet(text), y_pazar_durumu(text, bigint)
to anon, authenticated;
