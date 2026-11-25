-- Koridor Ortalama: yalnız teknik logları okuyan ayrı anahtar (ör. Claude'un sorun incelemesi için) — Kasım 2026.
-- Bu anahtarla yalnız teknik kayıtlar ve cihaz listesi okunur; maaş, ödeme, izin, çalışan kayıtlarına erişilmez, hiçbir şey değiştirilemez.
-- Anahtarın kendisi saklanmaz, yalnız SHA-256 özeti. Panelden (Uygulama › Log anahtarı) oluşturulur ve iptal edilir.
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verileri silmez.

create table if not exists log_anahtar (
  id            bigint generated always as identity primary key,
  ad            text not null default '',
  ozet          text not null unique,
  olusturma     timestamptz not null default now(),
  son_kullanim  timestamptz,
  kullanim      int not null default 0,
  aktif         boolean not null default true
);
alter table log_anahtar enable row level security;
revoke all on log_anahtar from anon, authenticated;

create or replace function _log_anahtar(p_anahtar text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  update log_anahtar set son_kullanim = now(), kullanim = kullanim + 1
   where aktif and ozet = encode(digest(coalesce(p_anahtar, ''), 'sha256'), 'hex');
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Log anahtarı geçersiz ya da iptal edilmiş.'; end if;
end $$;
revoke execute on function _log_anahtar(text) from public, anon, authenticated;

-- Teknik kayıtlar (en çok 2000 satır, en yeniden eskiye)
create or replace function log_oku(p_anahtar text, p_cihaz text default null, p_bas timestamptz default null, p_bit timestamptz default null,
  p_tur text default null, p_olay text default null, p_ara text default null, p_limit int default 500) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _log_anahtar(p_anahtar);
  return coalesce((select json_agg(json_build_object(
      'zaman', l.zaman, 'cihaz', l.cihaz_id, 'calisan', c.ad, 'model', d.model, 'surum', l.surum, 'tur', l.tur, 'olay', l.olay,
      'mesaj', l.mesaj, 'veri', l.veri, 'lat', l.lat, 'lon', l.lon, 'hiz', l.hiz) order by l.zaman desc)
    from (select * from teknik_log l
          where (p_cihaz is null or l.cihaz_id like p_cihaz || '%')
            and (p_bas is null or l.zaman >= p_bas) and (p_bit is null or l.zaman < p_bit)
            and (p_tur is null or l.tur = p_tur) and (p_olay is null or l.olay = p_olay)
            and (p_ara is null or l.mesaj ilike '%' || p_ara || '%')
          order by l.zaman desc limit least(greatest(coalesce(p_limit, 500), 1), 2000)) l
    left join cihaz d on d.id = l.cihaz_id left join calisan c on c.id = l.calisan_id), '[]'::json);
end $$;

-- Cihaz listesi (kim, model, sürüm, son görülme)
create or replace function log_cihazlar(p_anahtar text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _log_anahtar(p_anahtar);
  return coalesce((select json_agg(json_build_object('id', d.id, 'calisan', c.ad, 'model', d.model, 'android', d.android,
      'surum', d.surum, 'surum_ad', d.surum_ad, 'durum', d.durum, 'son', d.son) order by d.son desc)
    from cihaz d left join calisan c on c.id = d.calisan_id), '[]'::json);
end $$;

-- Panel: anahtar oluştur (bir kez gösterilir), listele, iptal et
create or replace function y_log_anahtar_olustur(p_token text, p_ad text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare k text := 'LOG-' || encode(gen_random_bytes(18), 'hex');
begin
  perform _yonetici(p_token);
  insert into log_anahtar (ad, ozet) values (left(coalesce(trim(p_ad), ''), 60), encode(digest(k, 'sha256'), 'hex'));
  return k;
end $$;

create or replace function y_log_anahtarlar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(json_build_object('id', id, 'ad', ad, 'olusturma', olusturma, 'son_kullanim', son_kullanim,
      'kullanim', kullanim, 'aktif', aktif) order by aktif desc, olusturma desc) from log_anahtar), '[]'::json);
end $$;

create or replace function y_log_anahtar_iptal(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  update log_anahtar set aktif = false where id = p_id;
end $$;

grant execute on function log_oku(text, text, timestamptz, timestamptz, text, text, text, int), log_cihazlar(text),
  y_log_anahtar_olustur(text, text), y_log_anahtarlar(text), y_log_anahtar_iptal(text, bigint) to anon, authenticated;
