//+------------------------------------------------------------------+
//|                                          SMC_GapOpen_MTF_EA.mq5  |
//|        Gap-Up Opening -> CHoCH -> FVG/OB -> Refine -> Entry       |
//+------------------------------------------------------------------+
#property copyright "SMC Gap Open MTF EA"
#property version   "1.00"
#property description "Gap-up opening + CHoCH + FVG/OB (Base TF) + Refinement (Refine TF)"

#include <Trade\Trade.mqh>

/*
 ========================== ALUR STRATEGI ==========================
 1. HARI BARU (D1): ambil High/Low/Close KEMARIN dan Open HARI INI.
    Gap-up = Open hari ini > High (atau Close) kemarin, minimal sebesar
    InpMinGapPercent. Jika tidak ada gap-up, EA tidak mencari setup.

 2. TIAP CANDLE BASE TF (mis. M5) BARU CLOSE (analisis berat, 1x/candle):
    a. Pindai candle sejak open hari ini, cari SWING HIGH / SWING LOW.
    b. Jika ada candle CLOSE menembus swing terakhir:
         - melawan bias sebelumnya -> CHoCH (Change of Character)
         - searah bias sebelumnya  -> BOS   (Break of Structure)
       Bias awal = BULLISH (karena gap-up). Jadi tembusan pertama ke bawah
       otomatis dihitung CHoCH bearish.
    c. Di leg impulsif yang menembus struktur, cari FVG (imbalance) atau
       Order Block -> inilah "Indicator Zone".

 3. REFINE: zona Base TF dipertajam dengan mencari FVG / OB di Refine TF
    (mis. M1) yang berada di DALAM zona Base TF.

 4. TIAP TICK (ringan): jika harga pullback menyentuh zona refine -> ENTRY.
      SELL (PE): CHoCH bearish, harga naik menyentuh zona supply.
      BUY  (CE): harga turun menyentuh zona demand yang menahan harga.

 5. EXIT: SL = di luar zona refine + buffer. TP = Day Low (SELL) /
    Day High (BUY), atau RR tetap (dipilih lewat input).

 PERFORMA (tanpa lag): data tiap timeframe diambil langsung lewat
 CopyRates(simbol, TF) sehingga TIDAK bergantung pada timeframe chart.
 Analisis berat hanya jalan saat candle Base TF baru; OnTick hanya
 membandingkan harga dengan zona yang sudah tersimpan.

 CATATAN: uji dulu di Strategy Tester + akun demo sebelum live.
 ===================================================================
*/

//+------------------------------------------------------------------+
//| ENUM                                                             |
//+------------------------------------------------------------------+
enum ENUM_ZONE_MODE
  {
   ZONE_FVG_THEN_OB = 0,   // FVG dulu, jika tidak ada pakai Order Block
   ZONE_FVG_ONLY    = 1,   // Hanya FVG
   ZONE_OB_ONLY     = 2    // Hanya Order Block
  };

enum ENUM_TP_MODE
  {
   TP_TODAY_EXTREME   = 0, // Day Low/High HARI INI (berjalan)
   TP_PREVDAY_EXTREME = 1, // Low/High HARI SEBELUMNYA
   TP_FIXED_RR        = 2  // Risk:Reward tetap
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,   // Lot tetap
   LOT_RISK_PERCENT = 1    // Risiko % dari balance
  };

enum ENUM_GAP_REF
  {
   GAP_VS_PREV_HIGH  = 0,  // Open hari ini > High kemarin
   GAP_VS_PREV_CLOSE = 1   // Open hari ini > Close kemarin
  };

//+------------------------------------------------------------------+
//| INPUT PARAMETER                                                  |
//+------------------------------------------------------------------+
input group "=== 1. MULTI-TIMEFRAME ==="
input ENUM_TIMEFRAMES InpBaseTF             = PERIOD_M5;         // Base Timeframe (deteksi CHoCH, FVG, OB)
input ENUM_TIMEFRAMES InpRefineTF           = PERIOD_M1;         // Refine Timeframe (penajaman zona + trigger)

input group "=== 2. GAP-UP OPENING ==="
input ENUM_GAP_REF    InpGapRef             = GAP_VS_PREV_HIGH;  // Gap-up dihitung terhadap
input double          InpMinGapPercent      = 0.05;              // Ukuran gap minimum (% dari harga)
input int             InpTradeWindowMin     = 240;               // Jendela entry setelah open (menit, 0 = bebas)

input group "=== 3. STRUKTUR & ZONA ==="
input int             InpSwingStrength      = 2;                 // Kekuatan swing (jumlah candle kiri & kanan)
input bool            InpTradeShort         = true;              // Aktifkan SELL / PE
input bool            InpTradeLong          = true;              // Aktifkan BUY / CE
input bool            InpShortOnBOS         = false;             // SELL juga dari BOS bearish (bukan hanya CHoCH)
input bool            InpLongOnBOS          = true;              // BUY juga dari BOS bullish (gap-and-go)
input ENUM_ZONE_MODE  InpZoneMode           = ZONE_FVG_THEN_OB;  // Jenis Indicator Zone
input int             InpMinFVGPoints       = 10;                // Ukuran FVG minimum di Base TF (points)
input int             InpMinRefineFVGPoints = 1;                 // Ukuran FVG minimum di Refine TF (points)
input bool            InpOBBodyOnly         = false;             // OB = body candle saja (false = high-low penuh)
input int             InpZoneMaxAgeBars     = 60;                // Umur maks. setup (candle Base TF sejak CHoCH)
input bool            InpAllowBaseFallback  = true;              // Jika refine gagal, pakai zona Base TF

input group "=== 4. RISK MANAGEMENT ==="
input ENUM_LOT_MODE   InpLotMode            = LOT_RISK_PERCENT;  // Mode ukuran lot
input double          InpFixedLot           = 0.10;              // Lot tetap (jika mode Lot tetap)
input double          InpRiskPercent        = 1.0;               // Risiko per trade (% balance)
input int             InpSLBufferPoints     = 30;                // Buffer SL di luar zona (points)
input ENUM_TP_MODE    InpTPMode             = TP_TODAY_EXTREME;  // Sumber Take Profit
input double          InpFixedRR            = 2.0;               // RR (jika TP = Risk:Reward tetap)
input double          InpMinRR              = 1.0;               // RR minimum, di bawah ini trade dilewati
input int             InpMaxTradesPerDay    = 2;                 // Maks. trade per hari (0 = tanpa batas)
input int             InpMaxSpreadPoints    = 0;                 // Maks. spread (points, 0 = nonaktif)
input int             InpSlippagePoints     = 20;                // Slippage maksimum (points)
input int             InpCloseHour          = -1;                // Tutup semua posisi di jam server ini (-1 = nonaktif)
input ulong           InpMagic              = 26092026;          // Magic number

input group "=== 5. TAMPILAN ==="
input bool            InpDraw               = true;              // Gambar zona/level di chart + panel status

//+------------------------------------------------------------------+
//| STRUKTUR DATA                                                    |
//+------------------------------------------------------------------+
// Satu kejadian struktur (CHoCH atau BOS) hasil pemindaian
struct SMC_Event
  {
   bool   found;       // true jika ada kejadian yang memenuhi syarat
   int    dir;         // +1 = tembus ke ATAS (bullish), -1 = tembus ke BAWAH (bearish)
   bool   isChoch;     // true = CHoCH (melawan bias), false = BOS (searah bias)
   int    breakIdx;    // index candle penembus (series: 1 = candle close terakhir)
   int    swingIdx;    // index candle swing yang ditembus
   int    originIdx;   // index candle awal leg impulsif (ekstrem sebelum tembusan)
   double level;       // harga swing yang ditembus
  };

// Setup yang sedang ditunggu (zona + arah)
struct SMC_Setup
  {
   bool     active;    // true = sedang menunggu pullback ke zona
   int      dir;       // +1 = BUY (CE), -1 = SELL (PE)
   bool     isChoch;
   datetime id;        // waktu candle penembus -> ID unik setup
   double   baseLow;   // batas bawah zona Base TF
   double   baseHigh;  // batas atas zona Base TF
   double   refLow;    // batas bawah zona refine (dipakai entry & SL)
   double   refHigh;   // batas atas zona refine
   int      kind;      // 1 = FVG, 2 = OB (zona Base TF)
   int      refKind;   // 0 = fallback zona base, 1 = FVG refine, 2 = OB refine
   int      attempts;  // jumlah percobaan kirim order yang gagal
  };

//+------------------------------------------------------------------+
//| VARIABEL GLOBAL                                                  |
//+------------------------------------------------------------------+
CTrade       g_trade;               // objek pengirim order
SMC_Setup    g_setup;               // setup aktif

datetime     g_lastBaseBar = 0;     // candle Base TF terakhir yang sudah dianalisis
datetime     g_dayTime     = 0;     // waktu open candle D1 hari ini (penanda hari)
datetime     g_sessionOpen = 0;     // waktu candle Base TF pertama hari ini
datetime     g_doneId      = 0;     // ID setup yang sudah dieksekusi / dibatalkan
int          g_refineRetry = 0;     // percobaan ulang jika data Refine TF belum siap

double       g_prevHigh    = 0.0;   // Day High kemarin
double       g_prevLow     = 0.0;   // Day Low kemarin
double       g_prevClose   = 0.0;   // Close kemarin
double       g_dayOpen     = 0.0;   // Open hari ini
double       g_gapPct      = 0.0;   // ukuran gap (%)
bool         g_gapUp       = false; // true jika hari ini gap-up yang memenuhi syarat

const string PFX = "SMCGAP_";       // awalan nama objek di chart

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(PeriodSeconds(InpRefineTF) >= PeriodSeconds(InpBaseTF))
     {
      Print("[SMC-GAP] ERROR: Refine TF harus LEBIH KECIL dari Base TF (contoh: Base M5, Refine M1).");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpSwingStrength < 1)
     {
      Print("[SMC-GAP] ERROR: Kekuatan swing minimal 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpLotMode == LOT_RISK_PERCENT && InpRiskPercent <= 0.0)
     {
      Print("[SMC-GAP] ERROR: Risiko % harus lebih besar dari 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpLotMode == LOT_FIXED && InpFixedLot <= 0.0)
     {
      Print("[SMC-GAP] ERROR: Lot tetap harus lebih besar dari 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ResetSetup(g_setup);
   g_lastBaseBar = 0;
   g_dayTime     = 0;
   g_sessionOpen = 0;
   g_doneId      = 0;
   g_refineRetry = 0;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("[SMC-GAP] PERINGATAN: tombol Algo Trading di terminal belum aktif.");

   PrintFormat("[SMC-GAP] Siap. Symbol=%s | Base TF=%s | Refine TF=%s",
               _Symbol, EnumToString(InpBaseTF), EnumToString(InpRefineTF));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
   Comment("");
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- (a) Keluar paksa di jam tertentu (opsional)
   if(InpCloseHour >= 0)
      ManageTimeExit();

   //--- (b) Ganti hari -> setup kemarin otomatis tidak berlaku
   if(g_setup.active && iTime(_Symbol, PERIOD_D1, 0) != g_dayTime)
      g_setup.active = false;

   //--- (c) ANALISIS BERAT: hanya 1x setiap candle Base TF baru (event-driven, tanpa lag)
   const datetime curBar = iTime(_Symbol, InpBaseTF, 0);
   if(curBar == 0)
      return;
   if(curBar != g_lastBaseBar)
     {
      if(UpdateSetup())            // true  = data lengkap, analisis selesai
         g_lastBaseBar = curBar;   // false = data belum siap -> diulang di tick berikutnya
     }

   //--- (d) TRIGGER ENTRY: dicek tiap tick, tapi hanya membandingkan harga dengan zona tersimpan
   if(g_setup.active)
      CheckEntry();
  }

//+------------------------------------------------------------------+
//| UpdateDailyLevels                                                |
//| Ambil High/Low/Close kemarin & Open hari ini, lalu tentukan      |
//| apakah hari ini GAP-UP. Dijalankan sekali per hari baru.         |
//+------------------------------------------------------------------+
bool UpdateDailyLevels()
  {
   const datetime dayTime = iTime(_Symbol, PERIOD_D1, 0);
   if(dayTime == 0)
      return false;                        // data D1 belum siap
   if(dayTime == g_dayTime)
      return true;                         // hari yang sama -> level sudah dihitung

   //--- Hari baru: ambil High/Low/Close KEMARIN dan Open HARI INI
   const double pH = iHigh (_Symbol, PERIOD_D1, 1);
   const double pL = iLow  (_Symbol, PERIOD_D1, 1);
   const double pC = iClose(_Symbol, PERIOD_D1, 1);
   const double o  = iOpen (_Symbol, PERIOD_D1, 0);
   if(pH <= 0.0 || pL <= 0.0 || pC <= 0.0 || o <= 0.0)
      return false;                        // data D1 belum lengkap

   g_dayTime   = dayTime;
   g_prevHigh  = pH;
   g_prevLow   = pL;
   g_prevClose = pC;
   g_dayOpen   = o;

   //--- DETEKSI GAP-UP:
   //    harga pembukaan hari ini harus di atas High (atau Close) kemarin,
   //    dan ukuran gap minimal InpMinGapPercent (% dari harga referensi).
   const double ref = (InpGapRef == GAP_VS_PREV_HIGH) ? pH : pC;
   g_gapPct = (o - ref) / ref * 100.0;
   g_gapUp  = (o > ref && g_gapPct >= InpMinGapPercent);

   //--- Reset state hari baru
   ResetSetup(g_setup);
   g_doneId      = 0;
   g_sessionOpen = 0;
   g_refineRetry = 0;

   ObjectsDeleteAll(0, PFX);
   SmcDrawLevel("PDH", pH, clrDodgerBlue, "High kemarin");
   SmcDrawLevel("PDL", pL, clrOrange,     "Low kemarin");

   PrintFormat("[SMC-GAP] Hari baru %s | High kemarin=%s Low kemarin=%s Close kemarin=%s | Open=%s | Gap=%.3f%% -> %s",
               TimeToString(dayTime, TIME_DATE),
               DoubleToString(pH, _Digits), DoubleToString(pL, _Digits), DoubleToString(pC, _Digits),
               DoubleToString(o, _Digits), g_gapPct, (g_gapUp ? "GAP-UP" : "tidak ada gap-up"));
   return true;
  }

//+------------------------------------------------------------------+
//| UpdateSetup                                                      |
//| Analisis utama: struktur -> zona Base TF -> refine -> setup.     |
//| Return false hanya jika DATA belum siap (akan diulang di tick    |
//| berikutnya). Return true = analisis selesai (ada/tidak ada setup)|
//+------------------------------------------------------------------+
bool UpdateSetup()
  {
   if(!UpdateDailyLevels())
      return false;

   if(!g_gapUp)
     {
      ResetSetup(g_setup);
      UpdatePanel("Tidak ada gap-up hari ini. EA menunggu hari berikutnya.");
      return true;
     }

   //--- (1) Ambil data Base TF.
   //    Urutan SERIES: [0] = candle berjalan, [1] = candle close terakhir,
   //    index makin besar = makin lama. Jumlah candle disesuaikan dengan
   //    lama hari berjalan, jadi tetap cukup untuk M1 maupun M15.
   const long secsToday = (long)(TimeCurrent() - g_dayTime);
   int want = (int)(secsToday / PeriodSeconds(InpBaseTF)) + 3 * InpSwingStrength + 20;
   want = MathMax(60, MathMin(want, 5000));

   MqlRates rb[];
   ArraySetAsSeries(rb, true);
   const int got = CopyRates(_Symbol, InpBaseTF, 0, want, rb);
   if(got < 30)
      return false;                        // data belum siap -> coba lagi di tick berikutnya

   //--- (2) Cari index candle Base TF PERTAMA hari ini (= candle "opening")
   int openIdx = -1;
   for(int i = 0; i < got; i++)
     {
      if(rb[i].time < g_dayTime)
         break;
      openIdx = i;
     }
   if(openIdx < 0)
      return false;
   g_sessionOpen = rb[openIdx].time;

   //--- (3) Deteksi struktur: CHoCH / BOS terakhir sejak open
   SMC_Event ev;
   if(!ScanStructure(rb, got, openIdx, ev))
     {
      ResetSetup(g_setup);
      UpdatePanel("Gap-up terdeteksi. Menunggu CHoCH...");
      return true;
     }

   //--- (4) Setup kadaluarsa?
   if(ev.breakIdx > InpZoneMaxAgeBars)
     {
      ResetSetup(g_setup);
      UpdatePanel("Setup terakhir kadaluarsa. Menunggu struktur baru...");
      return true;
     }

   //--- (5) Cari INDICATOR ZONE di Base TF (FVG / Order Block)
   double bLow = 0.0, bHigh = 0.0;
   int    kind = 0, iOld = 0, iNew = 0;
   if(!FindBaseZone(rb, got, ev, bLow, bHigh, kind, iOld, iNew))
     {
      ResetSetup(g_setup);
      UpdatePanel("Struktur berubah, tetapi FVG/OB yang valid belum ditemukan.");
      return true;
     }

   //--- (6) INVALIDASI: setelah tembusan, jika ada candle CLOSE menembus sisi
   //    jauh zona (di atas zona SELL / di bawah zona BUY), zona dianggap gagal.
   for(int k = ev.breakIdx - 1; k >= 1; k--)
     {
      if((ev.dir < 0 && rb[k].close > bHigh) || (ev.dir > 0 && rb[k].close < bLow))
        {
         ResetSetup(g_setup);
         UpdatePanel("Zona gagal (ada candle close menembus zona). Menunggu struktur baru...");
         return true;
        }
     }

   //--- (7) REFINE ke timeframe kecil.
   //    Jendela waktu = candle-candle Base TF yang membentuk zona.
   const datetime tFrom = rb[iOld].time;
   const datetime tTo   = rb[iNew].time + PeriodSeconds(InpBaseTF) - 1;
   double rLow = bLow, rHigh = bHigh;
   int    refKind = 0;
   const int rr = RefineZone(ev.dir, bLow, bHigh, tFrom, tTo, rLow, rHigh, refKind);
   if(rr < 0 && g_refineRetry < 5)
     {
      g_refineRetry++;
      return false;                        // data Refine TF belum siap -> ulangi di tick berikutnya
     }
   g_refineRetry = 0;
   if(rr <= 0)
     {
      if(!InpAllowBaseFallback)
        {
         ResetSetup(g_setup);
         UpdatePanel("Refine tidak menemukan blok, fallback zona Base dimatikan.");
         return true;
        }
      rLow    = bLow;                      // fallback: pakai zona Base TF apa adanya
      rHigh   = bHigh;
      refKind = 0;
     }

   //--- (8) Simpan setup
   SMC_Setup cand;
   ResetSetup(cand);
   cand.active   = true;
   cand.dir      = ev.dir;
   cand.isChoch  = ev.isChoch;
   cand.id       = rb[ev.breakIdx].time;
   cand.baseLow  = bLow;
   cand.baseHigh = bHigh;
   cand.refLow   = rLow;
   cand.refHigh  = rHigh;
   cand.kind     = kind;
   cand.refKind  = refKind;
   cand.attempts = (cand.id == g_setup.id) ? g_setup.attempts : 0;

   if(cand.id == g_doneId)                   cand.active = false;   // sudah dieksekusi / dibatalkan
   if(cand.dir < 0 && !InpTradeShort)        cand.active = false;
   if(cand.dir > 0 && !InpTradeLong)         cand.active = false;

   const bool isNew = (cand.id != g_setup.id);
   g_setup = cand;

   if(isNew)
      PrintFormat("[SMC-GAP] %s %s @ %s | level %s | zona base (%s) %s - %s | zona refine (%s) %s - %s",
                  (ev.isChoch ? "CHoCH" : "BOS"), (ev.dir < 0 ? "BEARISH" : "BULLISH"),
                  TimeToString(cand.id, TIME_DATE | TIME_MINUTES),
                  DoubleToString(ev.level, _Digits),
                  (kind == 1 ? "FVG" : "OB"),
                  DoubleToString(bLow, _Digits), DoubleToString(bHigh, _Digits),
                  RefineName(refKind),
                  DoubleToString(rLow, _Digits), DoubleToString(rHigh, _Digits));

   DrawSetup(ev, cand, rb[ev.swingIdx].time, rb[ev.breakIdx].time, tFrom);

   string st = StringFormat("%s %s | zona refine %s - %s | ",
                            (ev.isChoch ? "CHoCH" : "BOS"), (ev.dir < 0 ? "bearish" : "bullish"),
                            DoubleToString(rLow, _Digits), DoubleToString(rHigh, _Digits));
   st += (cand.active ? "MENUNGGU pullback ke zona" : "tidak aktif (sudah dieksekusi / arah dimatikan)");
   UpdatePanel(st);
   return true;
  }

//+------------------------------------------------------------------+
//| ScanStructure                                                    |
//| Memindai candle Base TF dari "opening" hari ini sampai candle    |
//| close terakhir (urutan waktu: LAMA -> BARU) dan mengembalikan    |
//| kejadian CHoCH/BOS TERAKHIR yang memenuhi syarat.                |
//|                                                                  |
//| CARA MESIN MENDETEKSI CHoCH:                                     |
//|  1. SWING HIGH = candle yang high-nya lebih tinggi dari N candle |
//|     di kiri dan N candle di kanannya (fractal). SWING LOW =      |
//|     kebalikannya. Swing baru dianggap sah setelah N candle di    |
//|     kanannya selesai -> tidak repaint.                           |
//|  2. Bias awal = BULLISH (karena gap-up).                         |
//|  3. Jika ada candle CLOSE < swing low terakhir (yang belum       |
//|     pernah ditembus):                                            |
//|        bias sebelumnya bullish -> CHoCH BEARISH                  |
//|        bias sebelumnya bearish -> BOS bearish (lanjutan tren)    |
//|     Jika CLOSE > swing high terakhir: kebalikannya.              |
//|  4. Setelah tembusan, bias berubah searah tembusan.              |
//|  5. Yang dipakai adalah kejadian TERAKHIR (paling baru).         |
//+------------------------------------------------------------------+
bool ScanStructure(const MqlRates &r[], const int total, const int openIdx, SMC_Event &ev)
  {
   ev.found     = false;
   ev.dir       = 0;
   ev.isChoch   = false;
   ev.breakIdx  = -1;
   ev.swingIdx  = -1;
   ev.originIdx = -1;
   ev.level     = 0.0;

   const int N = InpSwingStrength;

   double shPrice = 0.0, slPrice = 0.0;    // harga swing high / swing low terakhir
   int    shIdx = -1,    slIdx = -1;       // index candle swing tsb
   bool   shBroken = true, slBroken = true;// true = belum ada swing / sudah ditembus
   int    trend = +1;                      // bias awal: bullish (karena gap-up)

   // Iterasi kronologis: dari candle opening (index besar) menuju candle close terakhir (index 1)
   for(int i = openIdx; i >= 1; i--)
     {
      const double cl = r[i].close;

      //--- (1) Cek tembusan struktur memakai swing yang SUDAH terkonfirmasi sebelumnya
      if(shIdx >= 0 && !shBroken && cl > shPrice)
        {
         // Close menembus swing high terakhir -> tembusan BULLISH
         const bool choch = (trend < 0);   // sebelumnya bearish lalu tembus ke atas = CHoCH
         shBroken = true;
         trend    = +1;
         if(choch || InpLongOnBOS)
           {
            // origin leg = candle dengan LOW terendah antara swing yang ditembus dan candle penembus
            int    org = i;
            double ll  = r[i].low;
            for(int k = i; k <= shIdx; k++)
               if(r[k].low <= ll)
                 {
                  ll  = r[k].low;
                  org = k;
                 }
            ev.found     = true;
            ev.dir       = +1;
            ev.isChoch   = choch;
            ev.breakIdx  = i;
            ev.swingIdx  = shIdx;
            ev.originIdx = org;
            ev.level     = shPrice;
           }
        }
      else if(slIdx >= 0 && !slBroken && cl < slPrice)
        {
         // Close menembus swing low terakhir -> tembusan BEARISH
         const bool choch = (trend > 0);   // sebelumnya bullish lalu tembus ke bawah = CHoCH
         slBroken = true;
         trend    = -1;
         if(choch || InpShortOnBOS)
           {
            // origin leg = candle dengan HIGH tertinggi antara swing yang ditembus dan candle penembus
            int    org = i;
            double hh  = r[i].high;
            for(int k = i; k <= slIdx; k++)
               if(r[k].high >= hh)
                 {
                  hh  = r[k].high;
                  org = k;
                 }
            ev.found     = true;
            ev.dir       = -1;
            ev.isChoch   = choch;
            ev.breakIdx  = i;
            ev.swingIdx  = slIdx;
            ev.originIdx = org;
            ev.level     = slPrice;
           }
        }

      //--- (2) Konfirmasi swing baru: kandidat berada N candle di belakang candle i
      //    (sudah punya N candle penutup di sisi kanannya). Hanya swing sejak opening.
      const int j = i + N;
      if(j <= openIdx && (j + N) < total)
        {
         bool isSH = true, isSL = true;
         for(int k = 1; k <= N; k++)
           {
            // sisi kanan (lebih baru) harus STRICT lebih rendah/tinggi; sisi kiri (lebih lama) boleh sama
            if(r[j].high <= r[j - k].high || r[j].high < r[j + k].high)
               isSH = false;
            if(r[j].low  >= r[j - k].low  || r[j].low  > r[j + k].low)
               isSL = false;
           }
         if(isSH)
           {
            shPrice  = r[j].high;
            shIdx    = j;
            shBroken = false;
           }
         if(isSL)
           {
            slPrice  = r[j].low;
            slIdx    = j;
            slBroken = false;
           }
        }
     }
   return ev.found;
  }

//+------------------------------------------------------------------+
//| FindBaseZone                                                     |
//| Cari INDICATOR ZONE (FVG / Order Block) pada leg impulsif yang   |
//| menembus struktur (dari origin sampai candle penembus).          |
//|                                                                  |
//| CARA MESIN MENDETEKSI FVG (Fair Value Gap) - 3 candle:           |
//|   a = candle lama, b = candle tengah (impuls), c = candle baru   |
//|   FVG BEARISH: LOW candle a  >  HIGH candle c -> ada celah       |
//|                zona = [HIGH c ... LOW a]                         |
//|   FVG BULLISH: HIGH candle a <  LOW candle c  -> ada celah       |
//|                zona = [HIGH a ... LOW c]                         |
//|   Jika ada beberapa FVG, dipilih yang TERBESAR (displacement).   |
//|                                                                  |
//| CARA MESIN MENDETEKSI ORDER BLOCK:                               |
//|   SELL: candle BULLISH terakhir sebelum candle penembus (harga   |
//|         kemudian turun impulsif).                                |
//|   BUY : candle BEARISH terakhir sebelum candle penembus.         |
//|                                                                  |
//| Output: zLow/zHigh, kind (1=FVG, 2=OB), serta index candle       |
//| terlama (iOld) & terbaru (iNew) penyusun zona (untuk refine).    |
//+------------------------------------------------------------------+
bool FindBaseZone(const MqlRates &r[], const int total, const SMC_Event &ev,
                  double &zLow, double &zHigh, int &kind, int &iOld, int &iNew)
  {
   //--- (A) Cari FVG terbesar pada leg impulsif
   const double minFvg = InpMinFVGPoints * _Point;
   bool   fvgFound = false;
   double fvgLow = 0.0, fvgHigh = 0.0, fvgSize = 0.0;
   int    fvgOld = 0, fvgNew = 0;

   const int mMin = MathMax(2, ev.breakIdx);   // c = m-1 harus candle yang sudah close (>= 1)
   const int mMax = ev.originIdx - 1;          // a = m+1 tidak melewati candle origin
   for(int m = mMin; m <= mMax; m++)
     {
      const int a = m + 1;                     // candle terlama
      const int c = m - 1;                     // candle terbaru
      if(a >= total)
         break;

      double lo = 0.0, hi = 0.0;
      if(ev.dir < 0)                           // FVG bearish: low[a] > high[c]
        {
         if(!(r[a].low > r[c].high))
            continue;
         lo = r[c].high;
         hi = r[a].low;
        }
      else                                     // FVG bullish: high[a] < low[c]
        {
         if(!(r[a].high < r[c].low))
            continue;
         lo = r[a].high;
         hi = r[c].low;
        }

      const double gapSize = hi - lo;
      if(gapSize < minFvg)
         continue;
      if(gapSize > fvgSize)                    // ambil yang terbesar; jika sama, yang lebih baru
        {
         fvgFound = true;
         fvgSize  = gapSize;
         fvgLow   = lo;
         fvgHigh  = hi;
         fvgOld   = a;
         fvgNew   = c;
        }
     }

   //--- (B) Cari Order Block: candle berlawanan arah terakhir sebelum candle penembus
   bool   obFound = false;
   double obLow = 0.0, obHigh = 0.0;
   int    obIdx = -1;
   for(int k = ev.breakIdx + 1; k <= ev.originIdx; k++)
     {
      if(k >= total)
         break;
      const bool opposite = (ev.dir < 0) ? (r[k].close > r[k].open)    // SELL: candle bullish
                                         : (r[k].close < r[k].open);   // BUY : candle bearish
      if(opposite)
        {
         obIdx = k;
         break;
        }
     }
   if(obIdx < 0 && ev.originIdx >= 0 && ev.originIdx < total)
      obIdx = ev.originIdx;                    // fallback: candle origin leg
   if(obIdx >= 0)
     {
      obFound = true;
      if(InpOBBodyOnly)
        {
         obLow  = MathMin(r[obIdx].open, r[obIdx].close);
         obHigh = MathMax(r[obIdx].open, r[obIdx].close);
        }
      else
        {
         obLow  = r[obIdx].low;
         obHigh = r[obIdx].high;
        }
     }

   //--- (C) Pilih zona sesuai mode input
   bool useFvg = false;
   if(InpZoneMode == ZONE_FVG_ONLY)
      useFvg = true;
   else if(InpZoneMode == ZONE_OB_ONLY)
      useFvg = false;
   else
      useFvg = fvgFound;                       // FVG dulu, kalau tidak ada -> OB

   if(useFvg)
     {
      if(!fvgFound)
         return false;
      zLow  = fvgLow;
      zHigh = fvgHigh;
      kind  = 1;
      iOld  = fvgOld;
      iNew  = fvgNew;
     }
   else
     {
      if(!obFound)
         return false;
      zLow  = obLow;
      zHigh = obHigh;
      kind  = 2;
      iOld  = obIdx;
      iNew  = obIdx;
     }
   return (zHigh > zLow);
  }

//+------------------------------------------------------------------+
//| RefineZone                                                       |
//| Pertajam zona Base TF dengan FVG / OB di Refine TF (mis. M1).    |
//| Hanya blok yang beririsan dengan zona Base yang dipakai, lalu    |
//| dipotong agar tetap berada di dalam zona Base.                   |
//| Return: 1 = ketemu, 0 = tidak ada blok, -1 = data belum siap.    |
//+------------------------------------------------------------------+
int RefineZone(const int dir, const double bLow, const double bHigh,
               const datetime tFrom, const datetime tTo,
               double &rLow, double &rHigh, int &refKind)
  {
   refKind = 0;

   MqlRates m[];
   ArraySetAsSeries(m, true);
   const int n = CopyRates(_Symbol, InpRefineTF, tFrom, tTo, m);   // candle Refine TF di dalam jendela waktu
   if(n < 1)
      return -1;

   //--- (1) FVG di Refine TF (aturan sama dengan Base TF) yang beririsan dengan zona Base
   const double minFvg = InpMinRefineFVGPoints * _Point;
   bool   found = false;
   double bestSize = 0.0, bestLow = 0.0, bestHigh = 0.0;
   for(int mm = 1; mm <= n - 2; mm++)
     {
      const int a = mm + 1;                    // lebih lama
      const int c = mm - 1;                    // lebih baru
      double lo = 0.0, hi = 0.0;
      if(dir < 0)                              // FVG bearish
        {
         if(!(m[a].low > m[c].high))
            continue;
         lo = m[c].high;
         hi = m[a].low;
        }
      else                                     // FVG bullish
        {
         if(!(m[a].high < m[c].low))
            continue;
         lo = m[a].high;
         hi = m[c].low;
        }
      lo = MathMax(lo, bLow);                  // potong agar tetap di dalam zona Base
      hi = MathMin(hi, bHigh);
      const double sz = hi - lo;
      if(sz <= 0.0 || sz < minFvg)
         continue;
      if(sz > bestSize)
        {
         found    = true;
         bestSize = sz;
         bestLow  = lo;
         bestHigh = hi;
        }
     }
   if(found)
     {
      rLow    = bestLow;
      rHigh   = bestHigh;
      refKind = 1;
      return 1;
     }

   //--- (2) Tidak ada FVG -> cari Order Block di Refine TF
   //    (index 0 = candle terbaru dalam jendela, mundur ke masa lalu)
   for(int k = 0; k < n; k++)
     {
      const bool opposite = (dir < 0) ? (m[k].close > m[k].open)     // SELL: candle bullish
                                      : (m[k].close < m[k].open);    // BUY : candle bearish
      if(!opposite)
         continue;
      double lo = InpOBBodyOnly ? MathMin(m[k].open, m[k].close) : m[k].low;
      double hi = InpOBBodyOnly ? MathMax(m[k].open, m[k].close) : m[k].high;
      lo = MathMax(lo, bLow);
      hi = MathMin(hi, bHigh);
      if(hi - lo <= 0.0)
         continue;                             // tidak beririsan dengan zona Base
      rLow    = lo;
      rHigh   = hi;
      refKind = 2;
      return 1;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| RefineName                                                       |
//+------------------------------------------------------------------+
string RefineName(const int refKind)
  {
   if(refKind == 1)
      return "FVG refine";
   if(refKind == 2)
      return "OB refine";
   return "fallback zona base";
  }

//+------------------------------------------------------------------+
//| CheckEntry                                                       |
//| Dipanggil tiap tick. Murah: hanya membandingkan harga dengan     |
//| zona refine yang sudah tersimpan.                                |
//+------------------------------------------------------------------+
void CheckEntry()
  {
   if(g_setup.id == g_doneId)
     {
      g_setup.active = false;
      return;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   const double buf = InpSLBufferPoints * _Point;
   double entry = 0.0, sl = 0.0;

   //--- (1) TRIGGER: harga pullback menyentuh zona refine
   if(g_setup.dir < 0)                         // SELL (PE): pullback NAIK ke zona supply
     {
      if(bid < g_setup.refLow)
         return;                               // belum menyentuh zona
      entry = bid;
      sl    = g_setup.refHigh + buf;           // SL tepat di atas zona + buffer
      if(entry >= sl)
        {
         KillSetup("harga sudah menembus zona hingga melewati level SL");
         return;
        }
     }
   else                                        // BUY (CE): pullback TURUN ke zona demand
     {
      if(ask > g_setup.refHigh)
         return;                               // belum menyentuh zona
      entry = ask;
      sl    = g_setup.refLow - buf;            // SL tepat di bawah zona - buffer
      if(entry <= sl)
        {
         KillSetup("harga sudah menembus zona hingga melewati level SL");
         return;
        }
     }

   //--- (2) Filter waktu, spread, posisi berjalan
   if(!EntryTimeAllowed())
      return;
   if(InpMaxSpreadPoints > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints)
      return;
   if(HasOpenPosition())
      return;

   //--- (3) Hitung SL / TP / RR
   sl = NormPrice(sl);
   const double tp     = CalcTP(g_setup.dir, entry, sl, ask - bid);
   const double risk   = MathAbs(entry - sl);
   const double reward = (g_setup.dir < 0) ? (entry - tp) : (tp - entry);
   if(risk <= 0.0 || reward <= 0.0)
      return;                                  // TP berada di sisi yang salah / terlalu dekat
   if(reward / risk < InpMinRR)
      return;                                  // RR kurang

   //--- jarak minimum SL/TP menurut broker (stops level)
   const double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(g_setup.dir < 0)
     {
      if(sl - ask < minDist || ask - tp < minDist)
         return;
     }
   else
     {
      if(bid - sl < minDist || tp - bid < minDist)
         return;
     }

   //--- (4) Batas trade harian
   if(InpMaxTradesPerDay > 0 && CountTradesToday() >= InpMaxTradesPerDay)
     {
      KillSetup("batas trade harian tercapai");
      return;
     }

   //--- (5) Lot & margin
   const double lot = CalcLot(g_setup.dir, entry, sl);
   if(lot <= 0.0)
      return;
   const ENUM_ORDER_TYPE ot = (g_setup.dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin = 0.0;
   if(OrderCalcMargin(ot, _Symbol, lot, entry, margin) && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      Print("[SMC-GAP] Margin bebas tidak cukup untuk lot ", DoubleToString(lot, 2));
      return;
     }

   //--- (6) Kirim order
   const string cmt = StringFormat("SMCGAP %s %s", (g_setup.isChoch ? "CHoCH" : "BOS"),
                                   (g_setup.dir < 0 ? "SELL" : "BUY"));
   bool sent = false;
   if(g_setup.dir < 0)
      sent = g_trade.Sell(lot, _Symbol, bid, sl, tp, cmt);
   else
      sent = g_trade.Buy(lot, _Symbol, ask, sl, tp, cmt);

   const uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      PrintFormat("[SMC-GAP] %s dieksekusi | lot=%s entry=%s SL=%s TP=%s RR=%.2f",
                  (g_setup.dir < 0 ? "SELL" : "BUY"), DoubleToString(lot, 2),
                  DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
                  DoubleToString(tp, _Digits), reward / risk);
      g_doneId       = g_setup.id;           // 1 setup = maksimal 1 trade
      g_setup.active = false;
     }
   else
     {
      g_setup.attempts++;
      PrintFormat("[SMC-GAP] Order gagal (retcode %u: %s). Percobaan ke-%d",
                  rc, g_trade.ResultRetcodeDescription(), g_setup.attempts);
      if(g_setup.attempts >= 3)
         KillSetup("gagal kirim order 3x");
     }
  }

//+------------------------------------------------------------------+
//| CalcTP                                                           |
//| TP di level likuiditas: Day Low (SELL) / Day High (BUY).         |
//| Catatan: posisi SELL ditutup saat harga ASK menyentuh TP, maka   |
//| untuk SELL ditambah spread agar TP tercapai saat harga chart     |
//| (bid) menyentuh Day Low.                                         |
//+------------------------------------------------------------------+
double CalcTP(const int dir, const double entry, const double sl, const double spread)
  {
   double tp = 0.0;
   if(InpTPMode == TP_TODAY_EXTREME)
     {
      // Day Low / Day High HARI INI (berjalan sampai saat ini)
      if(dir < 0)
         tp = iLow(_Symbol, PERIOD_D1, 0) + spread;
      else
         tp = iHigh(_Symbol, PERIOD_D1, 0);
     }
   else if(InpTPMode == TP_PREVDAY_EXTREME)
     {
      // Low / High HARI SEBELUMNYA. Catatan: pada gap-up, High kemarin ada DI BAWAH
      // harga, jadi untuk BUY mode ini biasanya tidak valid (trade akan dilewati).
      if(dir < 0)
         tp = g_prevLow + spread;
      else
         tp = g_prevHigh;
     }
   else
     {
      // Risk:Reward tetap
      const double risk = MathAbs(entry - sl);
      if(dir < 0)
         tp = entry - risk * InpFixedRR;
      else
         tp = entry + risk * InpFixedRR;
     }
   return NormPrice(tp);
  }

//+------------------------------------------------------------------+
//| CalcLot                                                          |
//| Lot tetap, atau lot dari risiko % balance dan jarak SL.          |
//| Jika lot hasil hitungan < lot minimum broker, dipakai lot min    |
//| (risiko akan sedikit lebih besar dari yang diminta).             |
//+------------------------------------------------------------------+
double CalcLot(const int dir, const double entry, const double sl)
  {
   double lot = InpFixedLot;

   if(InpLotMode == LOT_RISK_PERCENT)
     {
      const double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      double loss1 = 0.0;                      // rugi untuk 1 lot jika SL kena (bernilai negatif)
      const ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, loss1) && loss1 < 0.0)
         lot = riskMoney / MathAbs(loss1);
      else
        {
         // fallback memakai tick value
         const double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         const double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         const double dist = MathAbs(entry - sl);
         if(tv > 0.0 && ts > 0.0 && dist > 0.0)
            lot = riskMoney / (dist / ts * tv);
        }
     }

   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0.0)
      lot = MathFloor(lot / step + 1e-9) * step;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   int volDigits = 2;
   if(step > 0.0)
      volDigits = (int)MathMax(0.0, MathRound(-MathLog10(step)));
   return NormalizeDouble(lot, volDigits);
  }

//+------------------------------------------------------------------+
//| NormPrice: bulatkan harga ke tick size simbol                    |
//+------------------------------------------------------------------+
double NormPrice(const double price)
  {
   const double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0.0)
      return NormalizeDouble(MathRound(price / ts) * ts, _Digits);
   return NormalizeDouble(price, _Digits);
  }

//+------------------------------------------------------------------+
//| HasOpenPosition: ada posisi EA ini di simbol ini?                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| CountTradesToday: jumlah entry EA ini hari ini (dari history)    |
//+------------------------------------------------------------------+
int CountTradesToday()
  {
   const datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(!HistorySelect(dayStart, TimeCurrent() + 60))
      return 0;

   int cnt = 0;
   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| EntryTimeAllowed: jendela entry & batas jam                      |
//+------------------------------------------------------------------+
bool EntryTimeAllowed()
  {
   const datetime now = TimeCurrent();

   if(InpTradeWindowMin > 0)
     {
      const datetime openT = (g_sessionOpen > 0) ? g_sessionOpen : g_dayTime;
      if(now > openT + (datetime)((long)InpTradeWindowMin * 60))
         return false;                         // jendela setelah open sudah lewat
     }

   if(InpCloseHour >= 0)
     {
      MqlDateTime dt;
      TimeToStruct(now, dt);
      if(dt.hour >= InpCloseHour)
         return false;                         // sudah lewat jam tutup paksa
     }
   return true;
  }

//+------------------------------------------------------------------+
//| ManageTimeExit / CloseAllByMagic: tutup paksa di jam tertentu    |
//+------------------------------------------------------------------+
void ManageTimeExit()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour >= InpCloseHour)
      CloseAllByMagic();
  }

void CloseAllByMagic()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      g_trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| ResetSetup / KillSetup                                           |
//+------------------------------------------------------------------+
void ResetSetup(SMC_Setup &s)
  {
   s.active   = false;
   s.dir      = 0;
   s.isChoch  = false;
   s.id       = 0;
   s.baseLow  = 0.0;
   s.baseHigh = 0.0;
   s.refLow   = 0.0;
   s.refHigh  = 0.0;
   s.kind     = 0;
   s.refKind  = 0;
   s.attempts = 0;
  }

void KillSetup(const string reason)
  {
   PrintFormat("[SMC-GAP] Setup %s dibatalkan: %s",
               TimeToString(g_setup.id, TIME_DATE | TIME_MINUTES), reason);
   g_doneId       = g_setup.id;
   g_setup.active = false;
  }

//+------------------------------------------------------------------+
//| GAMBAR DI CHART (membantu melihat cara EA membaca struktur)      |
//+------------------------------------------------------------------+
void DrawSetup(const SMC_Event &ev, const SMC_Setup &s,
               const datetime tSwing, const datetime tBreak, const datetime tZoneStart)
  {
   if(!InpDraw)
      return;

   const string   tag   = IntegerToString((long)s.id);
   const datetime tEnd  = TimeCurrent() + (datetime)((long)PeriodSeconds(InpBaseTF) * 12);
   const color    cBase = (s.dir < 0) ? C'120,45,45' : C'35,95,65';
   const color    cRef  = (s.dir < 0) ? clrRed : clrLime;

   string lbl = (ev.isChoch ? "CHoCH" : "BOS");
   lbl += (ev.dir > 0 ? " bullish" : " bearish");

   // garis dari swing yang ditembus sampai candle penembus + label
   SmcDrawSeg ("LVL_" + tag, tSwing, ev.level, tBreak, ev.level, clrGold);
   SmcDrawText("TXT_" + tag, tBreak, ev.level, lbl, clrGold);
   // zona Base TF (redup) dan zona refine (terang) - sampai beberapa candle ke kanan
   SmcDrawRect("BASE_" + tag, tZoneStart, s.baseLow, tEnd, s.baseHigh, cBase);
   SmcDrawRect("REF_"  + tag, tZoneStart, s.refLow,  tEnd, s.refHigh,  cRef);
  }

void UpdatePanel(const string status)
  {
   if(!InpDraw)
      return;
   string s = "=== SMC Gap-Open MTF EA ===\n";
   s += StringFormat("Base TF: %s | Refine TF: %s\n", EnumToString(InpBaseTF), EnumToString(InpRefineTF));
   s += StringFormat("High kemarin: %s | Low kemarin: %s | Close kemarin: %s\n",
                     DoubleToString(g_prevHigh, _Digits), DoubleToString(g_prevLow, _Digits),
                     DoubleToString(g_prevClose, _Digits));
   s += StringFormat("Open hari ini: %s | Gap: %.3f%% | Gap-up: %s\n",
                     DoubleToString(g_dayOpen, _Digits), g_gapPct, (g_gapUp ? "YA" : "TIDAK"));
   s += "Status: " + status;
   Comment(s);
  }

void SmcDrawLevel(const string name, const double price, const color clr, const string txt)
  {
   if(!InpDraw)
      return;
   const string n = PFX + name;
   ObjectDelete(0, n);
   if(!ObjectCreate(0, n, OBJ_HLINE, 0, 0, price))
      return;
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
  }

void SmcDrawRect(const string name, const datetime t1, const double p1,
                 const datetime t2, const double p2, const color clr)
  {
   if(!InpDraw)
      return;
   const string n = PFX + name;
   ObjectDelete(0, n);
   if(!ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
      return;
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_FILL, true);
   ObjectSetInteger(0, n, OBJPROP_BACK, true);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
  }

void SmcDrawSeg(const string name, const datetime t1, const double p1,
                const datetime t2, const double p2, const color clr)
  {
   if(!InpDraw)
      return;
   const string n = PFX + name;
   ObjectDelete(0, n);
   if(!ObjectCreate(0, n, OBJ_TREND, 0, t1, p1, t2, p2))
      return;
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
  }

void SmcDrawText(const string name, const datetime t, const double price,
                 const string txt, const color clr)
  {
   if(!InpDraw)
      return;
   const string n = PFX + name;
   ObjectDelete(0, n);
   if(!ObjectCreate(0, n, OBJ_TEXT, 0, t, price))
      return;
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
  }
//+------------------------------------------------------------------+
