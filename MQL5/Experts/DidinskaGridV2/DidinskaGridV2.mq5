//+------------------------------------------------------------------+
//|                                              DidinskaGridV2.mq5   |
//|   Expert Advisor Grid Trading XAUUSD + 10 AI Analis + AI Penyimpul |
//|                         Didinska Grid V2                          |
//+------------------------------------------------------------------+
// PENJELASAN SINGKAT (bahasa sederhana):
//   EA ini adalah gabungan dari 2 project:
//     1. "Didinska Signal Bot" (Telegram + 10 AI analis Groq) -> otak
//        analisanya di-port total ke native MQL5 (tanpa Telegram/bridge
//        Python sebagai kontrol, murni EA).
//     2. "GroqNewsGridScalper" (base) -> mesin grid trading, filter
//        berita, dan circuit breaker risikonya dipakai sebagai fondasi.
//
//   Alur kerja tiap tick (OnTick):
//     1. Cek hari baru & rem darurat risiko (circuit breaker)
//     2. Cek kondisi berita (mode waspada sebelum berita besar)
//     3. Setiap InpAIAnalysisInterval detik: bangun snapshot pasar ->
//        panggil 10 AI analis -> panggil AI Penyimpul -> dapat 1
//        keputusan final (bias, level kunci, parameter grid)
//     4. Cek spread, jika terlalu lebar EA diam dulu
//     5. Kelola posisi yang sudah terbuka (trailing stop, break-even)
//     6. Kelola grid (pasang/batalkan order pending) berdasarkan
//        keputusan final AI Penyimpul yang paling baru
//     7. Tampilkan dashboard di layar chart
//
//   Notifikasi Telegram (SATU ARAH, lihat TelegramNotify.mqh) dikirim
//   lewat OnTradeTransaction() setiap ada posisi baru terbuka atau
//   posisi tertutup karena SL/TP -- terpisah total dari alur OnTick di
//   atas supaya deteksinya akurat (baca DEAL_REASON langsung dari broker,
//   bukan menebak dari pergerakan harga).
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include "Include\GroqClient.mqh"
#include "Include\MarketData.mqh"
#include "Include\Analysts.mqh"
#include "Include\AISummarizer.mqh"
#include "Include\NativeDecisionEngine.mqh"
#include "Include\NewsAPI.mqh"
#include "Include\TelegramNotify.mqh"

//+------------------------------------------------------------------+
//| Mode Analisa: AI (Groq) atau Native (tanpa API, untuk backtest)     |
//+------------------------------------------------------------------+
enum ENUM_EA_MODE
{
   MODE_AI_ON  = 0,   // Pakai 10 AI analis + AI Penyimpul (Groq, butuh internet/WebRequest)
   MODE_AI_OFF = 1    // Analisa native 9 domain teknikal, TANPA API - cocok untuk backtest
};

//+------------------------------------------------------------------+
//| EA Inputs                                                          |
//+------------------------------------------------------------------+
input group "--- Mode Analisa ---"
input ENUM_EA_MODE InpMode = MODE_AI_ON;   // AI ON = pakai Groq; AI OFF = native, tanpa API (wajib untuk backtest)

input group "--- Native Mode - Kalibrasi Sinyal (hanya berlaku saat MODE_AI_OFF) ---"
input double   InpADXTrendThreshold    = 20.0;  // ADX minimum dianggap trending (di bawah ini = ranging, WAIT paksa)
input double   InpHighConfidenceThreshold = 0.75; // Di atas ini, grid cuma pasang 1 sisi (tanpa hedge sisi lawan)

input group "--- Ambang Keyakinan (berlaku AI ON maupun AI OFF) ---"
input double   InpMinProbability       = 0.65;  // Probabilitas minimum sebelum grid boleh dibuka

input group "--- AI - 12 Slot API Key Groq (WAJIB dibaca urutannya) ---"
input string   InpApiKey_Analyst1    = "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";  // Slot 1: AI Analis #1 - Trend
input string   InpApiKey_Analyst2    = "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";  // Slot 2: AI Analis #2 - Momentum
input string   InpApiKey_Analyst3    = "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";  // Slot 3: AI Analis #3 - Volatilitas
input string   InpApiKey_Analyst4    = "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";  // Slot 4: AI Analis #4 - Volume
input string   InpApiKey_Analyst5    = "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";  // Slot 5: AI Analis #5 - Support/Resistance
input string   InpApiKey_Analyst6    = "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";  // Slot 6: AI Analis #6 - Smart Money Concepts
input string   InpApiKey_Analyst7    = "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";  // Slot 7: AI Analis #7 - Price Action + Sesi
input string   InpApiKey_Analyst8    = "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";  // Slot 8: AI Analis #8 - Multi-Timeframe
input string   InpApiKey_Analyst9    = "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";  // Slot 9: AI Analis #9 - Makro XAUUSD
input string   InpApiKey_Analyst10   = "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";  // Slot 10: AI Analis #10 - Risk Management
input string   InpApiKey_Summarizer  = "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";  // Slot 11: AI Penyimpul (keputusan final)
input string   InpApiKey_Reserve     = "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";  // Slot 12: CADANGAN UNIVERSAL (fallback semua slot di atas)

input group "--- AI - Konfigurasi Umum ---"
input string   InpGroqModel          = "openai/gpt-oss-120b"; // Model Groq
input int      InpAIAnalysisInterval = 600;    // Interval Siklus Analisa AI Penuh (detik) - default 10 menit
input int      InpAIMaxTokens        = 1500;   // Max token per panggilan AI analis (JANGAN di bawah 1000 - gpt-oss-120b butuh token utk reasoning+JSON)
input int      InpAITimeoutMs        = 30000;  // Timeout tiap panggilan API (ms)

input group "--- Market Data - Simbol Referensi & Sesi ---"
input ENUM_TIMEFRAMES InpWorkingTF   = PERIOD_M15; // Timeframe kerja utama
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H4;  // Timeframe lebih tinggi (MTF alignment)
input string   InpMacroProxySymbol   = "EURUSD";   // Symbol proksi korelasi dolar (kalau DXY tidak tersedia)
input string   InpDxySymbol          = "";         // Symbol Dollar Index broker (kosongkan kalau tidak ada)
input int      InpBrokerGmtOffset    = 2;          // Offset GMT waktu server broker (jam), untuk deteksi sesi

input group "--- Berita (News Filter) ---"
input string   InpNewsAPIKey         = "c8b07645703f4600ae3eef9de207a0cd";     // NewsAPI Key (free tier)
input bool     InpUseNewsFilter      = true;   // Aktifkan Filter Berita

input group "--- Telegram Notifikasi (Satu Arah) ---"
input bool     InpUseTelegramNotify  = true;   // Aktifkan Notifikasi Telegram
input string   InpTelegramBotToken   = "8559391123:AAEPaMcT2Mw9IWHsI6-TplUNyBIwgGC_w48";     // Bot Token Telegram
input string   InpTelegramChatId     = "5747803355";     // Chat ID Telegram

input group "--- Grid Mechanics ---"
input int      InpGridDistance       = 300;    // Jarak Dasar Grid (Poin) - dikalikan grid_distance_multiplier dari AI
input int      InpGridOrders         = 2;      // Jumlah dasar pending order per sisi
input int      InpTakeProfit         = 200;    // Take Profit (Poin) - FALLBACK saja, dipakai kalau AI belum pernah selesai analisa; setelahnya jarak TP diambil dari ATR asli (lihat GetEffectiveTPDistance)
input int      InpStopLoss           = 150;    // Stop Loss (Poin) - FALLBACK saja, dipakai kalau AI belum pernah selesai analisa; setelahnya jarak SL diambil dari ATR asli (lihat GetEffectiveSLDistance)
input bool     InpDeleteOpposite     = true;   // Batalkan grid sisi lawan saat salah satu ke-trigger

input group "--- Protection & Trailing (berbasis ATR, bukan poin fixed) ---"
input double   InpBreakEvenTriggerATR = 1.0;   // Pindah ke BE saat profit >= (x ATR)
input double   InpBreakEvenOffsetATR  = 0.2;   // Profit yang dikunci di BE (x ATR)
input double   InpTrailingStartATR    = 2.0;   // Mulai trailing SL saat profit >= (x ATR)
input double   InpTrailingStepATR     = 0.5;   // Ukuran langkah Trailing (x ATR)

input group "--- Risk Management (dari base GroqNewsGridScalper) ---"
input double   InpMaxRiskPerTrade    = 1.0;    // Risiko per "nyawa"/order (%) - akun dibagi ~100 unit, risk:reward 1:2 lewat ATR (lihat suggested_sl/tp_distance)
input double   InpMaxDailyLossPct    = 10.0;   // Kerugian Harian Maksimum (%)
input double   InpMaxDrawdownPct     = 15.0;   // Floating Drawdown Maksimum (%)
input double   InpMaxDrawdownFromPeakPct = 20.0; // Drawdown Maksimum dari PUNCAK Equity Tertinggi (%) - halt PERMANEN, tidak auto-reset harian
input int      InpMaxSpread          = 35;     // Spread Maksimum yang diizinkan (Poin)
input bool     InpDynamicPositionSizing = true; // Gunakan Position Sizing dari AI
input ulong    InpMagicNumber        = 990022; // Magic Number EA

//+------------------------------------------------------------------+
//| Global Engine Variables                                            |
//+------------------------------------------------------------------+
CTrade            m_trade;
CPositionInfo     m_position;
COrderInfo        m_order;
CAccountInfo      m_account;
CNewsAPI          m_news_api;

CGroqClient       m_groq_client;
CMarketDataEngine m_market_engine;
CAnalystEngine    *m_analyst_engine;
CAISummarizer     *m_ai_summarizer;
CNativeDecisionEngine m_native_engine;
CTelegramNotify   m_telegram;

// State variables
double            m_start_day_balance;
double            m_peak_equity = 0.0;
bool              m_peak_drawdown_halted = false; // TIDAK di-reset harian, cuma lewat restart EA
int               m_current_day = -1;
bool              m_system_halted = false;
bool              m_news_caution = false;
datetime          m_last_ai_analysis = 0;
bool              m_grid_needs_refresh = false;

// Cache hasil siklus AI paling baru
SMarketSnapshot   m_last_snapshot;
SAnalystOpinion   m_last_opinions[];
SFinalDecision    m_last_decision;
bool              m_has_decision = false;

// Dashboard
string            m_dashboard_status = "INITIALIZING";

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);

   // --- Susun array 12 API key sesuai urutan slot (lihat GroqClient.mqh) ---
   string api_keys[12];
   api_keys[0] = InpApiKey_Analyst1;
   api_keys[1] = InpApiKey_Analyst2;
   api_keys[2] = InpApiKey_Analyst3;
   api_keys[3] = InpApiKey_Analyst4;
   api_keys[4] = InpApiKey_Analyst5;
   api_keys[5] = InpApiKey_Analyst6;
   api_keys[6] = InpApiKey_Analyst7;
   api_keys[7] = InpApiKey_Analyst8;
   api_keys[8] = InpApiKey_Analyst9;
   api_keys[9] = InpApiKey_Analyst10;
   api_keys[10] = InpApiKey_Summarizer;
   api_keys[11] = InpApiKey_Reserve;

   m_groq_client.Initialize(api_keys, InpGroqModel, InpAIMaxTokens, 0.3, InpAITimeoutMs);

   m_analyst_engine = new CAnalystEngine(GetPointer(m_groq_client));
   m_ai_summarizer  = new CAISummarizer(GetPointer(m_groq_client));

   m_market_engine.Configure(_Symbol, InpWorkingTF, InpHigherTF,
                              InpMacroProxySymbol, InpDxySymbol, InpBrokerGmtOffset);

   if(InpUseNewsFilter)
   {
      m_news_api.Initialize(InpNewsAPIKey);
   }

   m_telegram.Initialize(InpTelegramBotToken, InpTelegramChatId, InpUseTelegramNotify);

   m_start_day_balance = m_account.Balance();
   m_peak_equity = m_account.Balance();
   m_peak_drawdown_halted = false;
   m_system_halted = false;
   m_news_caution = false;
   m_has_decision = false;

   // CATATAN: m_last_decision adalah variabel GLOBAL, MQL5 otomatis
   // menzero-kannya saat program dimuat -- tidak perlu ZeroMemory() (yang
   // lagipula tidak aman untuk struct berisi field string, lihat catatan
   // fix di MarketData.mqh). Assignment di bawah ini cukup untuk memberi
   // nilai default yang eksplisit & aman sebelum siklus AI pertama selesai.
   m_last_decision.bias = FINAL_BIAS_WAIT;

   Print("Didinska Grid V2 Initialized");
   Print("Mode: ", (InpMode == MODE_AI_ON) ? "AI ON (10 analis Groq + Penyimpul)" : "AI OFF (Native, tanpa API - siap backtest)");
   Print("News Filter: ", InpUseNewsFilter ? "ENABLED" : "DISABLED");
   Print("Telegram Notify: ", InpUseTelegramNotify ? "ENABLED" : "DISABLED");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(CheckPointer(m_analyst_engine) == POINTER_DYNAMIC) delete m_analyst_engine;
   if(CheckPointer(m_ai_summarizer)  == POINTER_DYNAMIC) delete m_ai_summarizer;

   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Manajemen waktu & rem darurat risiko
   ManageDayReset();
   if(CheckRiskCircuitBreaker()) return;

   // 2. Cek kondisi berita
   if(InpUseNewsFilter)
   {
      CheckNewsConditions();
   }

   // 3. Siklus analisa penuh, berkala (cabang AI ON/OFF ditangani di dalamnya)
   if(ShouldRunAIAnalysis())
   {
      RunFullAIAnalysisCycle();
   }

   // 4. Cek spread
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread)
   {
      RefreshDashboard("SPREAD CAUTION - IDLE");
      return;
   }

   // 5. Mode waspada berita - tetap izinkan trading tapi dengan volume dikurangi
   //    (pengurangan ukuran lot ditangani di GetSmartLotSize())
   if(m_news_caution)
   {
      RefreshDashboard("NEWS CAUTION - REDUCED ACTIVITY");
   }

   // 6. Kelola posisi terbuka & grid
   ProcessActiveTrades();
   ManageGridStructure();

   // 7. Dashboard
   RefreshDashboard(m_dashboard_status);
}

//+------------------------------------------------------------------+
//| Deteksi event trading untuk notifikasi Telegram (SATU ARAH)        |
//+------------------------------------------------------------------+
// PENJELASAN: dipanggil otomatis oleh terminal MT5 setiap ada perubahan
// transaksi (order baru, deal baru, dll). Dipisah dari OnTick() karena
// ini cara PALING AKURAT mendeteksi kenapa sebuah posisi tertutup --
// DEAL_REASON dari broker memberi tahu persis apakah itu SL, TP, atau
// manual close, jauh lebih akurat daripada menebak dari harga di OnTick().
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(!InpUseTelegramNotify) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   // PENJELASAN FIX: trans.deal SUDAH berisi ticket deal yang PERSIS baru
   // terjadi -- dipakai langsung lewat HistoryDealSelect(), BUKAN menebak
   // "deal terakhir di histori" lewat index. Menebak index berisiko salah
   // ambil deal kalau 2 transaksi (misal 2 grid ke-trigger) terjadi nyaris
   // bersamaan di tick yang sama.
   ulong deal_ticket = trans.deal;
   if(deal_ticket == 0) return;
   if(!HistoryDealSelect(deal_ticket)) return;

   long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   if(deal_magic != (long)InpMagicNumber) return;

   string deal_symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   if(deal_symbol != _Symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);

   // --- Posisi BARU terbuka (entry ke pasar, termasuk grid yang ke-trigger) ---
   if(entry == DEAL_ENTRY_IN)
   {
      ulong position_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      if(!m_position.SelectByTicket(position_id)) return;

      bool is_buy = (m_position.PositionType() == POSITION_TYPE_BUY);
      m_telegram.NotifyOrderFilled(_Symbol, is_buy, m_position.PriceOpen(),
                                    m_position.Volume(), m_position.StopLoss(), m_position.TakeProfit());
      return;
   }

   // --- Posisi DITUTUP (cek alasan: SL atau TP) ---
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
      double close_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
      double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) +
                       HistoryDealGetDouble(deal_ticket, DEAL_SWAP) +
                       HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

      if(reason == DEAL_REASON_SL)
      {
         m_telegram.NotifyStopLossHit(_Symbol, close_price, profit);
      }
      else if(reason == DEAL_REASON_TP)
      {
         m_telegram.NotifyTakeProfitHit(_Symbol, close_price, profit);
      }
      // Selain SL/TP (misal close manual atau circuit breaker) -> sengaja
      // TIDAK dinotifikasi, sesuai kesepakatan awal (hanya 3 event ini).
   }
}

//+------------------------------------------------------------------+
//| Jalankan siklus penuh: snapshot -> 10 analis -> Penyimpul           |
//+------------------------------------------------------------------+
void RunFullAIAnalysisCycle()
{
   m_last_snapshot = m_market_engine.BuildSnapshot();

   if(InpMode == MODE_AI_ON)
   {
      Print("=== Memulai siklus analisa AI penuh (MODE: AI ON) ===");
      m_analyst_engine.AnalyzeAll(m_last_snapshot, m_last_opinions);
      m_last_decision = m_ai_summarizer.Summarize(m_last_opinions, m_last_snapshot);
   }
   else // MODE_AI_OFF
   {
      // PENJELASAN: TIDAK ADA panggilan WebRequest sama sekali di jalur ini
      // -- cocok dipakai di Strategy Tester (yang memblokir WebRequest
      // total) maupun kapan pun user tidak mau bergantung API eksternal.
      // m_last_opinions dikosongkan karena tidak ada AI analis yang
      // dipanggil (dashboard akan menampilkan "Mode: Native" alih-alih
      // jumlah analis sepakat/gagal).
      Print("=== Memulai siklus analisa native (MODE: AI OFF, tanpa API) ===");
      ArrayResize(m_last_opinions, 0);
      m_last_decision = m_native_engine.Decide(m_last_snapshot, (double)InpMaxSpread, InpADXTrendThreshold);
   }

   m_has_decision  = true;
   m_last_ai_analysis = TimeCurrent();

   // PENJELASAN FIX (refresh paksa): setiap siklus AI Penyimpul selesai
   // dengan keputusan baru, tandai grid perlu di-refresh. Kalau saat ini
   // masih ada pending order LAMA yang belum ke-trigger (grid basi dari
   // siklus sebelumnya), ManageGridStructure() akan membatalkannya dan
   // membangun ulang dengan bias/parameter terbaru -- supaya grid selalu
   // representasikan opini AI paling baru, bukan opini yang sudah usang.
   // Posisi yang SUDAH live (ke-trigger) tidak diutak-atik oleh ini.
   m_grid_needs_refresh = true;

   string bias_text = (m_last_decision.bias == FINAL_BIAS_BUY) ? "BUY" :
                       (m_last_decision.bias == FINAL_BIAS_SELL) ? "SELL" : "WAIT";
   string engine_label = (InpMode == MODE_AI_ON) ? "AI Penyimpul" : "Native Engine";
   string total_label  = (InpMode == MODE_AI_ON) ? "/10" : "/9";

   m_dashboard_status = engine_label + ": " + bias_text +
                        " (Prob: " + DoubleToString(m_last_decision.probability * 100, 0) + "%" +
                        (m_last_decision.used_builtin_fallback ? ", FALLBACK NATIVE" : "") + ")";

   Print("Keputusan Final [", engine_label, "]: ", bias_text,
         " | Probabilitas=", DoubleToString(m_last_decision.probability, 2),
         " | Sepakat=", m_last_decision.analysts_agreed, total_label,
         (InpMode == MODE_AI_ON) ? (" | Gagal=" + IntegerToString(m_last_decision.analysts_failed) + "/10") : "",
         (m_last_decision.used_builtin_fallback ? " | [FALLBACK NATIVE DIPAKAI]" : ""));
   Print("Alasan: ", m_last_decision.reasoning);
}

//+------------------------------------------------------------------+
//| Kapan siklus AI penuh berikutnya harus dijalankan?                  |
//+------------------------------------------------------------------+
bool ShouldRunAIAnalysis()
{
   int elapsed = (int)(TimeCurrent() - m_last_ai_analysis);
   return elapsed >= InpAIAnalysisInterval;
}

//+------------------------------------------------------------------+
//| Cek kondisi berita dan sesuaikan mode waspada                       |
//+------------------------------------------------------------------+
void CheckNewsConditions()
{
   if(m_news_api.IsHighImpactNewsImminent(_Symbol, 30))
   {
      if(!m_news_caution) Print("NEWS ALERT: berita high-impact akan rilis - masuk mode waspada");
      m_news_caution = true;
   }
   else if(m_news_api.IsHighImpactNewsImminent(_Symbol, 60))
   {
      m_news_caution = true;
   }
   else
   {
      m_news_caution = false;
   }
}

//+------------------------------------------------------------------+
//| Kelola struktur grid berdasarkan keputusan final AI Penyimpul       |
//+------------------------------------------------------------------+
void ManageGridStructure()
{
   int live_positions = 0;
   int standing_orders = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber &&
         m_position.Symbol() == _Symbol)
      {
         live_positions++;
      }
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i) && m_order.Magic() == InpMagicNumber &&
         m_order.Symbol() == _Symbol)
      {
         standing_orders++;
      }
   }

   bool allow_new_trades = ShouldAllowNewTrades();

   // REFRESH PAKSA: ada keputusan AI baru sejak grid pending terakhir
   // dipasang, dan belum ada posisi live (semua order masih menunggu
   // di-trigger) -> batalkan dulu, biar tick berikutnya bangun grid baru
   // dengan bias/parameter dari keputusan AI paling baru. Posisi yang
   // SUDAH live tidak disentuh sama sekali oleh logika ini.
   if(live_positions == 0 && standing_orders > 0 && m_grid_needs_refresh)
   {
      PurgeAllPending();
      m_grid_needs_refresh = false;
      Print("ManageGridStructure: grid lama dibatalkan untuk refresh paksa (keputusan AI baru tersedia).");
      return; // tunggu 1 tick lagi supaya OrdersTotal() sudah ter-update sebelum bangun grid baru
   }

   if(live_positions > 0 && InpDeleteOpposite && standing_orders > 0)
   {
      CancelOppositeGridSide();
   }

   if(live_positions == 0 && standing_orders == 0 && allow_new_trades)
   {
      BuildSmartGrid();
      m_grid_needs_refresh = false;
   }

   if(live_positions == 0 && standing_orders > 0 && !allow_new_trades)
   {
      PurgeAllPending();
   }
}

//+------------------------------------------------------------------+
//| Apakah boleh membuka grid baru saat ini?                            |
//+------------------------------------------------------------------+
bool ShouldAllowNewTrades()
{
   if(m_system_halted) return false;
   if(!m_has_decision) return false; // belum ada siklus AI yang selesai sama sekali

   // Bias WAIT dari AI Penyimpul -> jangan buka grid baru
   if(m_last_decision.bias == FINAL_BIAS_WAIT) return false;

   // Probabilitas terlalu rendah -> terlalu tidak yakin untuk dibuka
   // (PENJELASAN FIX: naik dari 0.5 -> InpMinProbability default 0.65.
   // 50% itu nyaris lempar koin -- terlalu longgar untuk mengizinkan grid
   // beneran dibuka, terutama di mode Native yang tidak sekuat AI reasoning.)
   if(m_last_decision.probability < InpMinProbability) return false;

   // Mode waspada berita + keyakinan juga tidak tinggi -> lebih baik tunggu
   if(m_news_caution && m_last_decision.probability < (InpMinProbability + 0.10)) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Jarak SL/TP efektif (dalam satuan HARGA, bukan poin)                 |
//+------------------------------------------------------------------+
// PENJELASAN FIX PENTING: InpStopLoss/InpTakeProfit ("poin") itu warisan
// dari base yang dirancang generic -- untuk forex biasa 1 poin = 0.0001,
// tapi untuk XAUUSD 1 poin biasanya = 0.01. Kalau dipaksa pakai poin fixed
// (150/200), jaraknya jadi cuma $1.50/$2.00 -- JAUH lebih sempit dari
// volatilitas normal gold, dan itu menyebabkan GetSmartLotSize() menghitung
// lot RAKSASA (2.5+ lot untuk akun $2000-an) supaya "risiko tetap konsisten"
// meski stopnya nyaris nol -- ujungnya order ditolak broker (margin tidak
// cukup / SL terlalu dekat).
//
// FIX: pakai suggested_sl_distance/suggested_tp_distance dari snapshot
// (dihitung dari ATR asli XAUUSD di MarketData.mqh, otomatis mengikuti
// skala harga & volatilitas symbol apa pun) sebagai sumber UTAMA. Input
// poin cuma dipakai sebagai fallback kalau belum ada siklus AI yang
// selesai sama sekali (snapshot masih kosong).
double GetEffectiveSLDistance()
{
   if(m_has_decision && m_last_snapshot.suggested_sl_distance > 0)
      return m_last_snapshot.suggested_sl_distance;

   return InpStopLoss * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double GetEffectiveTPDistance()
{
   if(m_has_decision && m_last_snapshot.suggested_tp_distance > 0)
      return m_last_snapshot.suggested_tp_distance;

   return InpTakeProfit * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
//| Bangun grid dengan parameter dari keputusan final AI Penyimpul      |
//+------------------------------------------------------------------+
void BuildSmartGrid()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double sl_distance = GetEffectiveSLDistance();
   double tp_distance = GetEffectiveTPDistance();

   // Jarak grid dasar dikalikan grid_distance_multiplier dari AI Penyimpul
   // (0.5 = lebih rapat karena AI yakin & volatilitas rendah,
   //  2.0 = lebih lebar karena AI kurang yakin / volatilitas tinggi)
   int adjusted_grid_distance = (int)(InpGridDistance * m_last_decision.grid_distance_multiplier);

   // Bobot buy/sell dari keputusan (1-5) dikombinasikan dengan jumlah dasar.
   // PENJELASAN FIX (revisi setelah backtest): kalau keyakinan SANGAT tinggi
   // (>=InpHighConfidenceThreshold), sisi lawan TIDAK dipasang lot penuh
   // (jadi tidak menggerus profit dari retrace kecil sebelum breakout
   // lanjut) -- TAPI tetap dipasang 1 order LOT MINIMUM sebagai "asuransi
   // murah". Backtest menunjukkan risiko nyata: kalau tren tiba-tiba
   // BERBALIK persis setelah periode keyakinan tinggi, grid tanpa hedge
   // sama sekali (0 order) babak belur tanpa cushion apa pun. 1 lot minimum
   // costnya nyaris nol tapi kasih early-cushion di skenario ekor seperti
   // itu. Sisi lawan dapat lot PENUH cuma saat keyakinan SEDANG (di bawah
   // ambang tinggi) -- itu situasi benar-benar tidak yakin arahnya.
   int buy_orders  = InpGridOrders;
   int sell_orders = InpGridOrders;
   bool buy_side_is_minimal_hedge  = false;
   bool sell_side_is_minimal_hedge = false;

   if(m_last_decision.bias == FINAL_BIAS_BUY)
   {
      buy_orders  = InpGridOrders + m_last_decision.buy_weight - 1;
      if(m_last_decision.probability >= InpHighConfidenceThreshold)
      {
         sell_orders = 1;
         sell_side_is_minimal_hedge = true;
      }
      else
      {
         sell_orders = MathMax(1, InpGridOrders - 1);
      }
   }
   else if(m_last_decision.bias == FINAL_BIAS_SELL)
   {
      sell_orders = InpGridOrders + m_last_decision.sell_weight - 1;
      if(m_last_decision.probability >= InpHighConfidenceThreshold)
      {
         buy_orders = 1;
         buy_side_is_minimal_hedge = true;
      }
      else
      {
         buy_orders = MathMax(1, InpGridOrders - 1);
      }
   }

   // PENJELASAN FIX: total layer dihitung DULU, baru diserahkan ke
   // GetSmartLotSize() -- supaya cap margin 25% dibagi rata ke SEMUA
   // layer yang akan dipasang di siklus ini. Kalau tidak, cap dihitung
   // seolah cuma ada 1 order, padahal bisa sampai 6-7 layer sekaligus
   // -- margin kumulatif bisa jauh melebihi 25% kalau semua ke-trigger.
   int total_layers = buy_orders + sell_orders;
   double lot_size  = GetSmartLotSize(total_layers);
   double min_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double buy_lot  = buy_side_is_minimal_hedge  ? min_lot : lot_size;
   double sell_lot = sell_side_is_minimal_hedge ? min_lot : lot_size;

   // Deploy Buy Stops
   for(int i = 1; i <= buy_orders; i++)
   {
      double target_buy = ask + (adjusted_grid_distance * i * point);
      double buy_tp = target_buy + tp_distance;
      double buy_sl = target_buy - sl_distance;

      m_trade.BuyStop(buy_lot, target_buy, _Symbol, buy_sl, buy_tp);
   }

   // Deploy Sell Stops
   for(int i = 1; i <= sell_orders; i++)
   {
      double target_sell = bid - (adjusted_grid_distance * i * point);
      double sell_tp = target_sell - tp_distance;
      double sell_sl = target_sell + sl_distance;

      m_trade.SellStop(sell_lot, target_sell, _Symbol, sell_sl, sell_tp);
   }

   Print("BuildSmartGrid: Buy=", buy_orders, " (lot ", buy_lot, buy_side_is_minimal_hedge ? " HEDGE-MIN" : "", ")",
         " Sell=", sell_orders, " (lot ", sell_lot, sell_side_is_minimal_hedge ? " HEDGE-MIN" : "", ")",
         " Jarak=", adjusted_grid_distance, " poin (multiplier ", m_last_decision.grid_distance_multiplier, "x)",
         " SL_dist=", DoubleToString(sl_distance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
         " TP_dist=", DoubleToString(tp_distance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
         " (", total_layers, " layer total)");
}

//+------------------------------------------------------------------+
//| Hitung lot size (dari base: dinamis berbasis risk %)                |
//+------------------------------------------------------------------+
// total_layers: jumlah TOTAL pending order (buy+sell) yang akan dipasang
// di siklus grid ini -- dipakai untuk membagi rata cap margin, supaya
// margin KUMULATIF (kalau semua layer ke-trigger) tetap aman, bukan
// cuma margin 1 order saja yang dicek.
double GetSmartLotSize(const int total_layers = 1)
{
   double base_lot = 0.01;

   if(!InpDynamicPositionSizing)
      return base_lot;

   double account_balance = m_account.Balance();
   double stop_loss_distance = GetEffectiveSLDistance();

   double risk_amount = account_balance * (InpMaxRiskPerTrade / 100.0);

   // Kurangi risiko kalau AI Penyimpul kurang yakin (probability rendah = lebih hati-hati)
   double confidence_factor = m_has_decision ? m_last_decision.probability : 0.5;
   double adjusted_risk = risk_amount * (0.5 + confidence_factor * 0.5); // rentang 50%-100% dari risk_amount

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value == 0 || tick_size == 0 || stop_loss_distance == 0)
      return 0.01;

   double sl_ticks = stop_loss_distance / tick_size;
   double lot_size = adjusted_risk / (sl_ticks * tick_value);

   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot_step > 0)
      lot_size = MathFloor(lot_size / lot_step) * lot_step;

   lot_size = MathMax(min_lot, MathMin(max_lot, lot_size));

   // Kurangi lagi saat mode waspada berita
   if(m_news_caution)
      lot_size *= 0.5;

   lot_size = MathMax(min_lot, lot_size);
   lot_size = NormalizeDouble(lot_size, 2);

   // PENGAMAN TAMBAHAN: verifikasi margin RIIL ke broker (bukan cuma
   // andalkan formula risk% di atas). Cap 25% dari free margin dibagi
   // rata ke SEMUA layer (total_layers) yang akan dipasang di siklus
   // ini -- supaya kalau SEMUA layer ke-trigger bersamaan, margin
   // KUMULATIF tetap <=25% free margin, bukan meleset berkali-lipat.
   double required_margin = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot_size, SymbolInfoDouble(_Symbol, SYMBOL_ASK), required_margin))
   {
      double free_margin = m_account.FreeMargin();
      int    safe_layer_count = MathMax(1, total_layers);
      double max_affordable_margin = (free_margin * 0.25) / safe_layer_count;

      if(required_margin > max_affordable_margin && required_margin > 0)
      {
         double scale_factor = max_affordable_margin / required_margin;
         lot_size = lot_size * scale_factor;

         if(lot_step > 0)
            lot_size = MathFloor(lot_size / lot_step) * lot_step;

         lot_size = MathMax(min_lot, lot_size);
         lot_size = NormalizeDouble(lot_size, 2);

         Print("GetSmartLotSize: lot dikecilkan dari perhitungan awal karena margin tidak cukup ",
               "(dibagi ", safe_layer_count, " layer). Free margin=", DoubleToString(free_margin, 2),
               " Lot disesuaikan=", lot_size);
      }
   }

   return lot_size;
}

//+------------------------------------------------------------------+
//| Ambil ATR "segar" untuk trailing/BE (dihitung tiap tick, BUKAN     |
//| dari snapshot 10-menitan -- supaya trailing tetap responsif kalau  |
//| volatilitas berubah cepat di antara 2 siklus AI)                   |
//+------------------------------------------------------------------+
double GetLiveATR()
{
   int handle = iATR(_Symbol, InpWorkingTF, 14);
   if(handle == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   double atr = 0.0;
   if(CopyBuffer(handle, 0, 0, 1, buf) > 0) atr = buf[0];

   IndicatorRelease(handle);
   return atr;
}

//+------------------------------------------------------------------+
//| Proses posisi terbuka: trailing stop & break-even BERBASIS ATR      |
//+------------------------------------------------------------------+
// PENJELASAN FIX: sebelumnya BE/trailing pakai poin fixed (100/140/30
// poin) yang warisan asumsi forex biasa -- untuk XAUUSD itu cuma
// $1-1.40, jauh di bawah noise normal gold, sehingga posisi ke-BE lalu
// ke-stop sebelum sempat lari ke TP (~3x ATR). Sekarang semua dihitung
// relatif terhadap ATR, konsisten dengan skala SL/TP yang sudah benar.
void ProcessActiveTrades()
{
   double atr = GetLiveATR();
   if(atr <= 0) return; // data ATR belum siap, jangan modifikasi apa pun dulu

   double be_trigger_distance  = InpBreakEvenTriggerATR * atr;
   double be_offset_distance   = InpBreakEvenOffsetATR  * atr;
   double trailing_start_dist  = InpTrailingStartATR    * atr;
   double trailing_step_dist   = InpTrailingStepATR     * atr;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber &&
         m_position.Symbol() == _Symbol)
      {
         double current_tick = (m_position.PositionType() == POSITION_TYPE_BUY) ?
                                SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                                SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double base_entry = m_position.PriceOpen();
         double current_sl = m_position.StopLoss();

         if(m_position.PositionType() == POSITION_TYPE_BUY)
         {
            double profit_distance = current_tick - base_entry;

            if(profit_distance >= be_trigger_distance && current_sl < base_entry)
            {
               m_trade.PositionModify(m_position.Ticket(),
                                       base_entry + be_offset_distance,
                                       m_position.TakeProfit());
               continue;
            }

            if(profit_distance >= trailing_start_dist)
            {
               double calculated_trailing = current_tick - trailing_step_dist;
               if(calculated_trailing > current_sl)
               {
                  m_trade.PositionModify(m_position.Ticket(), calculated_trailing, m_position.TakeProfit());
               }
            }
         }
         else if(m_position.PositionType() == POSITION_TYPE_SELL)
         {
            double profit_distance = base_entry - current_tick;

            if(profit_distance >= be_trigger_distance && (current_sl > base_entry || current_sl == 0))
            {
               m_trade.PositionModify(m_position.Ticket(),
                                       base_entry - be_offset_distance,
                                       m_position.TakeProfit());
               continue;
            }

            if(profit_distance >= trailing_start_dist)
            {
               double calculated_trailing = current_tick + trailing_step_dist;
               if(calculated_trailing < current_sl || current_sl == 0)
               {
                  m_trade.PositionModify(m_position.Ticket(), calculated_trailing, m_position.TakeProfit());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Batalkan grid sisi lawan setelah salah satu sisi ke-trigger          |
//+------------------------------------------------------------------+
void CancelOppositeGridSide()
{
   ENUM_POSITION_TYPE active_trend = POSITION_TYPE_BUY;
   bool track = false;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber &&
         m_position.Symbol() == _Symbol)
      {
         active_trend = m_position.PositionType();
         track = true;
         break;
      }
   }

   if(!track) return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i) && m_order.Magic() == InpMagicNumber &&
         m_order.Symbol() == _Symbol)
      {
         if(active_trend == POSITION_TYPE_BUY && m_order.OrderType() == ORDER_TYPE_SELL_STOP)
            m_trade.OrderDelete(m_order.Ticket());

         if(active_trend == POSITION_TYPE_SELL && m_order.OrderType() == ORDER_TYPE_BUY_STOP)
            m_trade.OrderDelete(m_order.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| Hapus semua pending order milik EA ini                              |
//+------------------------------------------------------------------+
void PurgeAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i) && m_order.Magic() == InpMagicNumber &&
         m_order.Symbol() == _Symbol)
      {
         m_trade.OrderDelete(m_order.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| Circuit breaker risiko harian/drawdown/PUNCAK EQUITY                 |
//+------------------------------------------------------------------+
bool CheckRiskCircuitBreaker()
{
   if(m_system_halted) return true;

   double account_equity  = m_account.Equity();
   double account_balance = m_account.Balance();

   // Update puncak equity tertinggi yang PERNAH dicapai (high-water mark)
   if(account_equity > m_peak_equity) m_peak_equity = account_equity;

   double daily_loss_evaluation = ((m_start_day_balance - account_equity) / m_start_day_balance) * 100;
   double drawdown_evaluation   = ((account_balance - account_equity) / account_balance) * 100;
   double drawdown_from_peak    = (m_peak_equity > 0) ?
                                   ((m_peak_equity - account_equity) / m_peak_equity) * 100 : 0.0;

   // PENJELASAN FIX: drawdown_from_peak menangkap penurunan BERTAHAP lintas
   // hari/minggu yang tidak pernah terdeteksi oleh daily_loss_evaluation
   // (yang reset tiap hari baru, jadi buta terhadap "rugi sedikit tiap hari
   // selama berminggu-minggu"). Ini HALT PERMANEN -- tidak di-reset otomatis
   // oleh ManageDayReset() seperti circuit breaker harian, karena penurunan
   // dari puncak sebesar ini adalah sinyal masalah STRUKTURAL (bukan cuma
   // "hari sial"), butuh keputusan sadar user (restart EA) untuk lanjut lagi.
   bool peak_drawdown_triggered = (drawdown_from_peak >= InpMaxDrawdownFromPeakPct);

   if(daily_loss_evaluation >= InpMaxDailyLossPct || drawdown_evaluation >= InpMaxDrawdownPct ||
      peak_drawdown_triggered)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
         {
            m_trade.PositionClose(m_position.Ticket());
         }
      }

      PurgeAllPending();
      m_system_halted = true;

      if(peak_drawdown_triggered)
      {
         m_peak_drawdown_halted = true;
         Print("CRITICAL: PEAK DRAWDOWN circuit breaker triggered! HALT PERMANEN (butuh restart EA untuk lanjut).");
         Print("Puncak Equity: ", DoubleToString(m_peak_equity, 2),
               " | Equity Sekarang: ", DoubleToString(account_equity, 2),
               " | Drawdown dari Puncak: ", DoubleToString(drawdown_from_peak, 2), "%");
      }
      else
      {
         Print("CRITICAL: Risk circuit breaker HARIAN triggered! (auto-resume besok)");
         Print("Daily Loss: ", DoubleToString(daily_loss_evaluation, 2), "%");
         Print("Drawdown: ", DoubleToString(drawdown_evaluation, 2), "%");
      }

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Reset harian                                                        |
//+------------------------------------------------------------------+
void ManageDayReset()
{
   MqlDateTime current_time;
   TimeCurrent(current_time);

   if(current_time.day_of_year != m_current_day)
   {
      m_current_day = current_time.day_of_year;
      m_start_day_balance = m_account.Balance();

      // PENTING: halt akibat PEAK DRAWDOWN sengaja TIDAK di-reset di sini --
      // cuma halt HARIAN biasa yang auto-resume besok paginya. Peak drawdown
      // halt cuma hilang lewat restart EA (lihat OnInit).
      if(!m_peak_drawdown_halted)
         m_system_halted = false;

      m_news_caution = false;

      Print("New trading day started. Balance: ", DoubleToString(m_start_day_balance, 2));
   }
}

//+------------------------------------------------------------------+
//| Dashboard                                                            |
//+------------------------------------------------------------------+
void RefreshDashboard(string engine_msg)
{
   double profit_tracking = m_account.Equity() - m_start_day_balance;

   string ai_status = "";
   if(m_has_decision)
   {
      string bias_text = (m_last_decision.bias == FINAL_BIAS_BUY) ? "BUY" :
                          (m_last_decision.bias == FINAL_BIAS_SELL) ? "SELL" : "WAIT";
      ai_status = bias_text + " | Prob: " + DoubleToString(m_last_decision.probability * 100, 0) + "%";

      if(InpMode == MODE_AI_ON)
      {
         ai_status += " | Sepakat: " + IntegerToString(m_last_decision.analysts_agreed) + "/10";
         ai_status += " | Gagal: " + IntegerToString(m_last_decision.analysts_failed) + "/10";
         if(m_last_decision.used_builtin_fallback) ai_status += " | [FALLBACK]";
      }
      else
      {
         ai_status += " | Domain searah: " + IntegerToString(m_last_decision.analysts_agreed) + "/9";
      }
   }
   else
   {
      ai_status = "Menunggu siklus pertama...";
   }

   string news_status = InpUseNewsFilter ? (m_news_caution ? "CAUTION" : "CLEAR") : "DISABLED";

   int next_analysis_in = MathMax(0, InpAIAnalysisInterval - (int)(TimeCurrent() - m_last_ai_analysis));

   string ui = "========================================\n";
   ui += " DIDINSKA GRID V2 - " + string((InpMode == MODE_AI_ON) ? "AI ON (10 AI+Penyimpul)" : "AI OFF (Native)") + "\n";
   ui += "========================================\n";
   ui += " Engine     : " + engine_msg + "\n";
   if(m_peak_drawdown_halted)
      ui += " *** HALT PERMANEN (Peak Drawdown) - restart EA untuk lanjut ***\n";
   ui += " Balance    : " + DoubleToString(m_account.Balance(), 2) + " USD\n";
   ui += " Equity     : " + DoubleToString(m_account.Equity(), 2) + " USD\n";
   ui += " Peak Equity: " + DoubleToString(m_peak_equity, 2) + " USD\n";
   ui += " P/L Today  : " + DoubleToString(profit_tracking, 2) + " USD\n";
   ui += " Spread     : " + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts\n";
   ui += "----------------------------------------\n";
   ui += " AI Status  : " + ai_status + "\n";
   ui += " Next Cycle : " + IntegerToString(next_analysis_in) + " detik lagi\n";
   ui += " News       : " + news_status + "\n";
   ui += " Telegram   : " + (InpUseTelegramNotify ? "ON" : "OFF") + "\n";
   ui += "========================================\n";

   Comment(ui);
}
