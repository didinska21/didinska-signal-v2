# Didinska Grid V2

Expert Advisor MetaTrader 5 untuk **XAUUSD (Emas)** yang menggabungkan strategi **grid trading** dengan **10 AI analis spesialis + 1 AI Penyimpul** (Groq) sebagai penentu arah dan parameter grid, dilengkapi filter berita ekonomi dan notifikasi Telegram satu arah.

Proyek ini adalah **versi 2 (V2)** — hasil kombinasi dari:
- **Didinska Signal Bot** — sistem analisa 10 AI spesialis + AI Penyimpul yang sebelumnya berjalan di Telegram bot (Cloudflare Workers).
- **GroqNewsGridScalper** — fondasi mesin grid trading, filter berita, dan circuit breaker risiko.

V2 mem-port seluruh logika analisa AI menjadi **native MQL5** (tanpa Telegram bot sebagai kontrol, tanpa bridge Python) — EA berjalan mandiri di dalam MetaTrader 5, dengan notifikasi Telegram sebagai fitur satu arah opsional.

---

## Fitur Utama

- **10 AI Analis Spesialis** (masing-masing dengan slot API key terpisah): Trend, Momentum, Volatilitas, Volume, Support & Resistance, Smart Money Concepts, Price Action Native + Sesi Trading, Multi-Timeframe Alignment, Konteks Makro XAUUSD, Risk Management.
- **AI Penyimpul** — merangkum 10 opini menjadi satu keputusan final (bias arah, level kunci, probabilitas, parameter grid) dengan bobot berdasarkan confidence tiap analis, bukan sekadar voting.
- **Fallback native tanpa AI** — kalau AI Penyimpul gagal total, sistem otomatis memakai voting berbobot dari opini analis yang berhasil (dibatasi konservatif), supaya EA tidak berhenti analisa hanya karena satu titik kegagalan API.
- **Skema 12 API Key** — 10 untuk analis, 1 untuk Penyimpul, 1 cadangan universal yang otomatis dipakai kalau slot mana pun kena rate limit.
- **Grid Trading Adaptif** — jarak dan bobot buy/sell grid disesuaikan otomatis oleh keputusan AI Penyimpul (`grid_distance_multiplier`, `buy_weight`, `sell_weight`).
- **Filter Berita** — mode waspada otomatis sebelum rilis berita berdampak tinggi (NewsAPI.org + kalender ekonomi ForexFactory).
- **Circuit Breaker Risiko** — auto-close semua posisi kalau kerugian harian atau floating drawdown melewati batas.
- **Notifikasi Telegram Satu Arah** — hanya untuk 3 event: order terisi, kena Stop Loss, kena Take Profit. Tidak ada kontrol balik dari Telegram ke EA.

---

## Struktur Folder

```
DidinskaGridV2/
└── MQL5/
    └── Experts/
        └── DidinskaGridV2/
            ├── DidinskaGridV2.mq5      # EA utama (orkestrasi, grid, circuit breaker)
            └── Include/
                ├── GroqClient.mqh      # Lapisan komunikasi Groq API + skema 12 key
                ├── MarketData.mqh      # Pengumpul data pasar native (indikator, S/R, SMC, sesi)
                ├── Analysts.mqh        # 10 AI analis spesialis
                ├── AISummarizer.mqh    # AI Penyimpul + fallback native
                ├── NewsAPI.mqh         # Filter berita & kalender ekonomi
                └── TelegramNotify.mqh  # Notifikasi Telegram satu arah
```

---

## Instalasi

1. Buka folder data terminal MT5: **File → Open Data Folder**.
2. Salin seluruh isi `MQL5/Experts/DidinskaGridV2/` (termasuk folder `Include/`) ke `MQL5/Experts/DidinskaGridV2/` di folder data tersebut.
3. Buka **MetaEditor** (`F4` dari MT5), buka `DidinskaGridV2.mq5`, lalu **Compile** (`F7`).
4. Di MT5: **Tools → Options → Expert Advisors → Allow WebRequest for listed URL**, tambahkan domain berikut:
   - `https://api.groq.com`
   - `https://newsapi.org`
   - `https://nfs.faireconomy.media`
   - `https://api.telegram.org` (kalau notifikasi Telegram diaktifkan)
5. Attach EA ke chart **XAUUSD** dan isi parameter input (lihat bagian di bawah).

---

## Parameter Input Penting

### API Key Groq (12 slot)
| Input | Slot | Keterangan |
|---|---|---|
| `InpApiKey_Analyst1` .. `InpApiKey_Analyst10` | 0-9 | Satu key per AI analis |
| `InpApiKey_Summarizer` | 10 | Key khusus AI Penyimpul |
| `InpApiKey_Reserve` | 11 | Cadangan universal — dipakai otomatis kalau slot mana pun kena rate limit |

> Semua key didapat gratis dari [console.groq.com](https://console.groq.com). Kalau ada slot kosong, sistem tetap jalan tapi analis/Penyimpul terkait akan langsung memakai key cadangan (slot 12) setiap kali dipanggil.

### Konfigurasi Lain yang Wajib Disesuaikan per Broker
| Input | Keterangan |
|---|---|
| `InpMacroProxySymbol` | Nama symbol EURUSD **persis** sesuai broker (cek suffix, misal `EURUSD` vs `EURUSDm`) |
| `InpDxySymbol` | Nama symbol Dollar Index broker (kosongkan kalau tidak tersedia — otomatis fallback ke korelasi EURUSD) |
| `InpBrokerGmtOffset` | Offset GMT waktu server broker (jam) — dipakai untuk deteksi sesi trading Asia/London/NY |
| `InpNewsAPIKey` | API key gratis dari [newsapi.org](https://newsapi.org) |
| `InpTelegramBotToken`, `InpTelegramChatId` | Diisi kalau `InpUseTelegramNotify = true` |

### Parameter Strategi
| Input | Default | Keterangan |
|---|---|---|
| `InpAIAnalysisInterval` | 600 (detik) | Interval siklus analisa AI penuh (10 analis + Penyimpul) |
| `InpGridDistance` | 300 (poin) | Jarak dasar grid, dikalikan `grid_distance_multiplier` dari AI |
| `InpGridOrders` | 2 | Jumlah dasar pending order per sisi |
| `InpMaxDailyLossPct` / `InpMaxDrawdownPct` | 10% / 15% | Ambang circuit breaker |
| `InpMaxRiskPerTrade` | 2% | Risiko dasar per trade, disesuaikan otomatis oleh probabilitas keputusan AI |

---

## Cara Kerja Singkat

1. **Setiap `InpAIAnalysisInterval` detik**: EA membangun snapshot pasar native (indikator, S/R, SMC, sesi, korelasi makro) → memanggil 10 AI analis → AI Penyimpul merangkum jadi satu keputusan (bias, probabilitas, level kunci, parameter grid).
2. **Setiap tick**: circuit breaker & filter berita dicek lebih dulu, lalu posisi terbuka dikelola (trailing/break-even), lalu grid disusun ulang berdasarkan keputusan AI paling baru (kalau belum ada posisi/order aktif).
3. **Setiap ada order terisi atau posisi tertutup karena SL/TP**: notifikasi dikirim ke Telegram (kalau diaktifkan) lewat `OnTradeTransaction`, terpisah dari alur analisa di atas.

---

## Disclaimer

EA ini adalah alat bantu analisa dan eksekusi otomatis, **bukan jaminan profit**. Trading forex/emas mengandung risiko kehilangan modal. Selalu uji di akun demo terlebih dahulu sebelum menggunakan akun real, dan sesuaikan parameter risiko dengan toleransi kamu sendiri.
