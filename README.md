# AYSOFT Personel

Saha çalışma kayıtları, pazar mesaisi izin hakları ve yönetici hesap paneli.

- Çalışan girişi: `https://personel.aysoftbilisim.com/`
- Yönetici paneli: `https://personel.aysoftbilisim.com/#yonetici`
- Veritabanı: Supabase. Kurulum betiği `kurulum.sql` (SQL Editor'da çalıştırılır; tekrar çalıştırılabilir).

Tablolara doğrudan erişim kapalıdır; uygulama yalnızca oturum anahtarı kontrol eden fonksiyonları çağırır.
`config.js` içindeki anahtar herkese açık (publishable) anahtardır. `service_role` / `secret` anahtar bu depoya asla eklenmez.
