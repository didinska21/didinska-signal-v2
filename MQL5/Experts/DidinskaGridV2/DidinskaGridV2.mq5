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
#include "Include\NewsAPI.mqh"
#include "Include\TelegramNotify.mqh"

//+------------------------------------------------------------------+
//| EA Inputs                                                          |
//+------------------------------------------------------------------+
input group "--- AI - 12 Slot API Key Groq (WAJIB dibaca urutannya) ---"
input string   InpApiKey_Analyst1    = "";  // Slot 1: AI Analis #1 - Trend
input string   InpApiKey_Analyst2    = "";  // Slot 2: AI Analis #2 - Momentum
input string   InpApiKey_Analyst3    = "";  // Slot 3: AI Analis #3 - Volatilitas
input string   InpApiKey_Analyst4    = "";  // Slot 4: AI Analis #4 - Volume
input string   InpApiKey_Analyst5    = "";  // Slot 5: AI Analis #5 - Support/Resistance
input string   InpApiKey_Analyst6    = "";  // Slot 6: AI Analis #6 - Smart Money Concepts
input string   InpApiKey_Analyst7    = "";  // Slot 7: AI Analis #7 - Price Action + Sesi
input string   InpApiKey_Analyst8    = "";  // Slot 8: AI Analis #8 - Multi-Timeframe
input string   InpApiKey_Analyst9    = "";  // Slot 9: AI Analis #9 - Makro XAUUSD
input string   InpApiKey_Analyst10   = "";  // Slot 10: AI Analis #10 - Risk Management
input string   InpApiKey_Summarizer  = "";  // Slot 11: AI Penyimpul (keputusan final)
input string   InpApiKey_Reserve     = "";  // Slot 12: CADANGAN UNIVERSAL (fallback semua slot di atas)

input group "--- AI - Konfigurasi Umum ---"
input bool     InpUseAIAnalysis      = true;   // Aktifkan Analisa AI (10 analis + Penyimpul)
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
input string   InpNewsAPIKey         = "";     // NewsAPI Key (free tier)
input bool     InpUseNewsFilter      = true;   // Aktifkan Filter Berita

input group "--- Telegram Notifikasi (Satu Arah) ---"
input bool     InpUseTelegramNotify  = false;  // Aktifkan Notifikasi Telegram
input string   InpTelegramBotToken   = "";     // Bot Token Telegram
input string   InpTelegramChatId     = "";     // Chat ID Telegram

input group "--- Grid Mechanics ---"
input int      InpGridDistance       = 300;    // Jarak Dasar Grid (Poin) - dikalikan grid_distance_multiplier dari AI
input int      InpGridOrders         = 2;      // Jumlah dasar pending order per sisi
input int      InpTakeProfit         = 200;    // Take Profit (Poin) - dipakai kalau AI tidak beri level spesifik
input int      InpStopLoss           = 150;    // Stop Loss (Poin) - dipakai kalau AI tidak beri level spesifik
input bool     InpDeleteOpposite     = true;   // Batalkan grid sisi lawan saat salah satu ke-trigger

input group "--- Protection & Trailing ---"
input int      InpBreakEvenTrigger   = 100;    // Pindah ke BE di (Poin)
input int      InpBreakEvenOffset    = 15;     // Poin profit yang dikunci di BE
input int      InpTrailingStart      = 140;    // Mulai trailing SL di (Poin)
input int      InpTrailingStep       = 30;     // Ukuran langkah Trailing (Poin)

input group "--- Risk Management (dari base GroqNewsGridScalper) ---"
input double   InpMaxRiskPerTrade    = 2.0;    // Risiko Maksimum per Trade (%)
input double   InpMaxDailyLossPct    = 10.0;   // Kerugian Harian Maksimum (%)
input double   InpMaxDrawdownPct     = 15.0;   // Floating Drawdown Maksimum (%)
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
CTelegramNotify   m_telegram;

// State variables
double            m_start_day_balance;
int               m_current_day = -1;
bool              m_system_halted = false;
bool              m_news_caution = false;
datetime          m_last_ai_analysis = 0;

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
   Print("AI Analysis: ", InpUseAIAnalysis ? "ENABLED" : "DISABLED");
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

   // 3. Siklus analisa AI penuh (10 analis + Penyimpul), berkala
   if(InpUseAIAnalysis && ShouldRunAIAnalysis())
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
   Print("=== Memulai siklus analisa AI penuh ===");

   m_last_snapshot = m_market_engine.BuildSnapshot();
   m_analyst_engine.AnalyzeAll(m_last_snapshot, m_last_opinions);
   m_last_decision = m_ai_summarizer.Summarize(m_last_opinions, m_last_snapshot);
   m_has_decision  = true;
   m_last_ai_analysis = TimeCurrent();

   string bias_text = (m_last_decision.bias == FINAL_BIAS_BUY) ? "BUY" :
                       (m_last_decision.bias == FINAL_BIAS_SELL) ? "SELL" : "WAIT";

   m_dashboard_status = "AI Penyimpul: " + bias_text +
                        " (Prob: " + DoubleToString(m_last_decision.probability * 100, 0) + "%" +
                        (m_last_decision.used_builtin_fallback ? ", FALLBACK NATIVE" : "") + ")";

   Print("Keputusan Final: ", bias_text,
         " | Probabilitas=", DoubleToString(m_last_decision.probability, 2),
         " | Analis Sepakat=", m_last_decision.analysts_agreed, "/10",
         " | Analis Gagal=", m_last_decision.analysts_failed, "/10",
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

   if(live_positions > 0 && InpDeleteOpposite && standing_orders > 0)
   {
      CancelOppositeGridSide();
   }

   if(live_positions == 0 && standing_orders == 0 && allow_new_trades)
   {
      BuildSmartGrid();
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
   if(m_last_decision.probability < 0.5) return false;

   // Mode waspada berita + keyakinan AI juga tidak tinggi -> lebih baik tunggu
   if(m_news_caution && m_last_decision.probability < 0.65) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Bangun grid dengan parameter dari keputusan final AI Penyimpul      |
//+------------------------------------------------------------------+
void BuildSmartGrid()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double lot_size = GetSmartLotSize();

   // Jarak grid dasar dikalikan grid_distance_multiplier dari AI Penyimpul
   // (0.5 = lebih rapat karena AI yakin & volatilitas rendah,
   //  2.0 = lebih lebar karena AI kurang yakin / volatilitas tinggi)
   int adjusted_grid_distance = (int)(InpGridDistance * m_last_decision.grid_distance_multiplier);

   // Bobot buy/sell dari AI Penyimpul (1-5) dikombinasikan dengan jumlah dasar
   int buy_orders  = InpGridOrders;
   int sell_orders = InpGridOrders;

   if(m_last_decision.bias == FINAL_BIAS_BUY)
   {
      buy_orders  = InpGridOrders + m_last_decision.buy_weight - 1;
      sell_orders = MathMax(1, InpGridOrders - 1);
   }
   else if(m_last_decision.bias == FINAL_BIAS_SELL)
   {
      sell_orders = InpGridOrders + m_last_decision.sell_weight - 1;
      buy_orders  = MathMax(1, InpGridOrders - 1);
   }

   // Deploy Buy Stops
   for(int i = 1; i <= buy_orders; i++)
   {
      double target_buy = ask + (adjusted_grid_distance * i * point);
      double buy_tp = target_buy + (InpTakeProfit * point);
      double buy_sl = target_buy - (InpStopLoss * point);

      m_trade.BuyStop(lot_size, target_buy, _Symbol, buy_sl, buy_tp);
   }

   // Deploy Sell Stops
   for(int i = 1; i <= sell_orders; i++)
   {
      double target_sell = bid - (adjusted_grid_distance * i * point);
      double sell_tp = target_sell - (InpTakeProfit * point);
      double sell_sl = target_sell + (InpStopLoss * point);

      m_trade.SellStop(lot_size, target_sell, _Symbol, sell_sl, sell_tp);
   }

   Print("BuildSmartGrid: Buy=", buy_orders, " Sell=", sell_orders,
         " Jarak=", adjusted_grid_distance, " poin (multiplier ", m_last_decision.grid_distance_multiplier, "x)",
         " Lot=", lot_size);
}

//+------------------------------------------------------------------+
//| Hitung lot size (dari base: dinamis berbasis risk %)                |
//+------------------------------------------------------------------+
double GetSmartLotSize()
{
   double base_lot = 0.01;

   if(!InpDynamicPositionSizing)
      return base_lot;

   double account_balance = m_account.Balance();
   double stop_loss_distance = InpStopLoss * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

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

   return NormalizeDouble(lot_size, 2);
}

//+------------------------------------------------------------------+
//| Proses posisi terbuka: trailing stop & break-even (dari base)       |
//+------------------------------------------------------------------+
void ProcessActiveTrades()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

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
            double trajectory = (current_tick - base_entry) / point;

            if(trajectory >= InpBreakEvenTrigger && current_sl < base_entry)
            {
               m_trade.PositionModify(m_position.Ticket(),
                                       base_entry + (InpBreakEvenOffset * point),
                                       m_position.TakeProfit());
               continue;
            }

            if(trajectory >= InpTrailingStart)
            {
               double calculated_trailing = current_tick - (InpTrailingStep * point);
               if(calculated_trailing > current_sl)
               {
                  m_trade.PositionModify(m_position.Ticket(), calculated_trailing, m_position.TakeProfit());
               }
            }
         }
         else if(m_position.PositionType() == POSITION_TYPE_SELL)
         {
            double trajectory = (base_entry - current_tick) / point;

            if(trajectory >= InpBreakEvenTrigger && (current_sl > base_entry || current_sl == 0))
            {
               m_trade.PositionModify(m_position.Ticket(),
                                       base_entry - (InpBreakEvenOffset * point),
                                       m_position.TakeProfit());
               continue;
            }

            if(trajectory >= InpTrailingStart)
            {
               double calculated_trailing = current_tick + (InpTrailingStep * point);
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
//| Circuit breaker risiko harian/drawdown (dari base)                   |
//+------------------------------------------------------------------+
bool CheckRiskCircuitBreaker()
{
   if(m_system_halted) return true;

   double account_equity  = m_account.Equity();
   double account_balance = m_account.Balance();

   double daily_loss_evaluation = ((m_start_day_balance - account_equity) / m_start_day_balance) * 100;
   double drawdown_evaluation   = ((account_balance - account_equity) / account_balance) * 100;

   if(daily_loss_evaluation >= InpMaxDailyLossPct || drawdown_evaluation >= InpMaxDrawdownPct)
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

      Print("CRITICAL: Risk circuit breaker triggered!");
      Print("Daily Loss: ", DoubleToString(daily_loss_evaluation, 2), "%");
      Print("Drawdown: ", DoubleToString(drawdown_evaluation, 2), "%");

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

   string ai_status = "DISABLED";
   if(InpUseAIAnalysis && m_has_decision)
   {
      string bias_text = (m_last_decision.bias == FINAL_BIAS_BUY) ? "BUY" :
                          (m_last_decision.bias == FINAL_BIAS_SELL) ? "SELL" : "WAIT";
      ai_status = bias_text + " | Prob: " + DoubleToString(m_last_decision.probability * 100, 0) + "%";
      ai_status += " | Sepakat: " + IntegerToString(m_last_decision.analysts_agreed) + "/10";
      ai_status += " | Gagal: " + IntegerToString(m_last_decision.analysts_failed) + "/10";
      if(m_last_decision.used_builtin_fallback) ai_status += " | [FALLBACK]";
   }

   string news_status = InpUseNewsFilter ? (m_news_caution ? "CAUTION" : "CLEAR") : "DISABLED";

   int next_analysis_in = InpUseAIAnalysis ?
      MathMax(0, InpAIAnalysisInterval - (int)(TimeCurrent() - m_last_ai_analysis)) : 0;

   string ui = "========================================\n";
   ui += " DIDINSKA GRID V2 - 10 AI + PENYIMPUL\n";
   ui += "========================================\n";
   ui += " Engine     : " + engine_msg + "\n";
   ui += " Balance    : " + DoubleToString(m_account.Balance(), 2) + " USD\n";
   ui += " Equity     : " + DoubleToString(m_account.Equity(), 2) + " USD\n";
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
