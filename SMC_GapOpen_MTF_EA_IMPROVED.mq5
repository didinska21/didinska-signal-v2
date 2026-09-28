//+------------------------------------------------------------------+
//|                                    SMC_GapOpen_MTF_EA_IMPROVED.mq5 |
//|   IMPROVEMENT: Lebih banyak trade, relaksasi filter ketat         |
//+------------------------------------------------------------------+
#property copyright "SMC Gap Open MTF EA - IMPROVED"
#property version   "2.00"
#property description "Gap-up + CHoCH/BOS + FVG/OB with relaxed filters for better trade frequency"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ENUM                                                             |
//+------------------------------------------------------------------+
enum ENUM_ZONE_MODE { ZONE_FVG_THEN_OB = 0, ZONE_FVG_ONLY = 1, ZONE_OB_ONLY = 2 };
enum ENUM_TP_MODE { TP_TODAY_EXTREME = 0, TP_PREVDAY_EXTREME = 1, TP_FIXED_RR = 2 };
enum ENUM_LOT_MODE { LOT_FIXED = 0, LOT_RISK_PERCENT = 1 };
enum ENUM_GAP_REF { GAP_VS_PREV_HIGH = 0, GAP_VS_PREV_CLOSE = 1 };

//+------------------------------------------------------------------+
//| INPUT PARAMETER - IMPROVED                                       |
//+------------------------------------------------------------------+
input group "=== 1. MULTI-TIMEFRAME ==="
input ENUM_TIMEFRAMES InpBaseTF             = PERIOD_M15;        // Ubah M5 -> M15 (lebih stabil)
input ENUM_TIMEFRAMES InpRefineTF           = PERIOD_M5;         // Ubah M1 -> M5

input group "=== 2. GAP-UP OPENING ==="
input ENUM_GAP_REF    InpGapRef             = GAP_VS_PREV_HIGH;
input double          InpMinGapPercent      = 0.02;              // RELAKSASI: 0.05 -> 0.02 (lebih banyak gap)
input int             InpTradeWindowMin     = 0;                 // BUKA: 240 -> 0 (trade sepanjang hari)

input group "=== 3. STRUKTUR & ZONA ==="
input int             InpSwingStrength      = 1;                 // RELAKSASI: 2 -> 1 (lebih peka swing)
input bool            InpTradeShort         = true;
input bool            InpTradeLong          = true;
input bool            InpShortOnBOS         = true;              // BUKA: false -> true (ambil BOS juga)
input bool            InpLongOnBOS          = true;
input ENUM_ZONE_MODE  InpZoneMode           = ZONE_FVG_THEN_OB;
input int             InpMinFVGPoints       = 5;                 // RELAKSASI: 10 -> 5 (FVG lebih kecil OK)
input int             InpMinRefineFVGPoints = 1;
input bool            InpOBBodyOnly         = false;
input int             InpZoneMaxAgeBars     = 120;               // PERLUAS: 60 -> 120 (setup lebih lama valid)
input bool            InpAllowBaseFallback  = true;

input group "=== 4. RISK MANAGEMENT ==="
input ENUM_LOT_MODE   InpLotMode            = LOT_RISK_PERCENT;
input double          InpFixedLot           = 0.10;
input double          InpRiskPercent        = 2.0;               // AGRESIF: 1.0 -> 2.0
input int             InpSLBufferPoints     = 15;                // KETAT: 30 -> 15 (risk lebih kecil)
input ENUM_TP_MODE    InpTPMode             = TP_FIXED_RR;       // UBAH: TODAY_EXTREME -> FIXED_RR (lebih konsisten)
input double          InpFixedRR            = 1.5;               // TURUN: 2.0 -> 1.5 (lebih mudah tercapai)
input double          InpMinRR              = 0.8;               // TURUN: 1.0 -> 0.8 (lebih flexible)
input int             InpMaxTradesPerDay    = 5;                 // PERLUAS: 2 -> 5
input int             InpMaxSpreadPoints    = 0;
input int             InpSlippagePoints     = 20;
input int             InpCloseHour          = -1;
input ulong           InpMagic              = 26092026;

input group "=== 5. TAMPILAN ==="
input bool            InpDraw               = true;

//+------------------------------------------------------------------+
//| STRUKTUR DATA                                                    |
//+------------------------------------------------------------------+
struct SMC_Event
  {
   bool   found;
   int    dir;
   bool   isChoch;
   int    breakIdx;
   int    swingIdx;
   int    originIdx;
   double level;
  };

struct SMC_Setup
  {
   bool     active;
   int      dir;
   bool     isChoch;
   datetime id;
   double   baseLow;
   double   baseHigh;
   double   refLow;
   double   refHigh;
   int      kind;
   int      refKind;
   int      attempts;
  };

//+------------------------------------------------------------------+
//| VARIABEL GLOBAL                                                  |
//+------------------------------------------------------------------+
CTrade       g_trade;
SMC_Setup    g_setups[10];                // IMPROVEMENT: array untuk multiple setups
int          g_setupCount = 0;

datetime     g_lastBaseBar = 0;
datetime     g_dayTime     = 0;
datetime     g_sessionOpen = 0;
datetime     g_doneIds[10];               // array untuk multiple done IDs

double       g_prevHigh    = 0.0;
double       g_prevLow     = 0.0;
double       g_prevClose   = 0.0;
double       g_dayOpen     = 0.0;
double       g_gapPct      = 0.0;
bool         g_gapUp       = false;

const string PFX = "SMCGAP_";

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(PeriodSeconds(InpRefineTF) >= PeriodSeconds(InpBaseTF))
     {
      Print("[SMC-GAP] ERROR: Refine TF harus LEBIH KECIL dari Base TF.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ArrayInitialize(g_doneIds, 0);
   g_setupCount = 0;
   g_lastBaseBar = 0;
   g_dayTime = 0;

   PrintFormat("[SMC-GAP] IMPROVED v2.0 | Base=%s | Refine=%s | MaxTrades=%d",
               EnumToString(InpBaseTF), EnumToString(InpRefineTF), InpMaxTradesPerDay);
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
   if(g_setupCount > 0 && iTime(_Symbol, PERIOD_D1, 0) != g_dayTime)
     {
      g_setupCount = 0;                    // Reset setups setiap hari baru
      ArrayInitialize(g_doneIds, 0);
     }

   const datetime curBar = iTime(_Symbol, InpBaseTF, 0);
   if(curBar == 0)
      return;
      
   if(curBar != g_lastBaseBar)
     {
      if(UpdateSetups())
         g_lastBaseBar = curBar;
     }

   for(int i = 0; i < g_setupCount; i++)
      if(g_setups[i].active)
         CheckEntry(i);
  }

//+------------------------------------------------------------------+
//| UpdateDailyLevels                                                |
//+------------------------------------------------------------------+
bool UpdateDailyLevels()
  {
   const datetime dayTime = iTime(_Symbol, PERIOD_D1, 0);
   if(dayTime == 0)
      return false;
   if(dayTime == g_dayTime)
      return true;

   const double pH = iHigh(_Symbol, PERIOD_D1, 1);
   const double pL = iLow(_Symbol, PERIOD_D1, 1);
   const double pC = iClose(_Symbol, PERIOD_D1, 1);
   const double o  = iOpen(_Symbol, PERIOD_D1, 0);
   if(pH <= 0.0 || pL <= 0.0 || pC <= 0.0 || o <= 0.0)
      return false;

   g_dayTime   = dayTime;
   g_prevHigh  = pH;
   g_prevLow   = pL;
   g_prevClose = pC;
   g_dayOpen   = o;

   const double ref = (InpGapRef == GAP_VS_PREV_HIGH) ? pH : pC;
   g_gapPct = (o - ref) / ref * 100.0;
   g_gapUp  = (o > ref && g_gapPct >= InpMinGapPercent);

   if(g_gapUp)
     {
      g_setupCount = 0;
      ArrayInitialize(g_doneIds, 0);
      ObjectsDeleteAll(0, PFX);
      PrintFormat("[SMC-GAP] GAP-UP %.3f%% | Open=%s High=%s", g_gapPct, 
                  DoubleToString(o, _Digits), DoubleToString(pH, _Digits));
     }
   return true;
  }

//+------------------------------------------------------------------+
//| UpdateSetups - IMPROVED: Cari MULTIPLE setups (tidak hanya 1)   |
//+------------------------------------------------------------------+
bool UpdateSetups()
  {
   if(!UpdateDailyLevels())
      return false;

   if(!g_gapUp)
     {
      Comment("Tidak ada gap-up hari ini.");
      return true;
     }

   const long secsToday = (long)(TimeCurrent() - g_dayTime);
   int want = (int)(secsToday / PeriodSeconds(InpBaseTF)) + 50;
   want = MathMax(60, MathMin(want, 5000));

   MqlRates rb[];
   ArraySetAsSeries(rb, true);
   const int got = CopyRates(_Symbol, InpBaseTF, 0, want, rb);
   if(got < 30)
      return false;

   int openIdx = -1;
   for(int i = 0; i < got; i++)
     {
      if(rb[i].time < g_dayTime)
         break;
      openIdx = i;
     }
   if(openIdx < 0)
      return false;

   //--- IMPROVEMENT: Scan MULTIPLE structures (tidak hanya yang terakhir)
   SMC_Event events[5];
   int eventCount = ScanStructureMultiple(rb, got, openIdx, events);
   
   //--- Process setiap event yang belum dalam doneIds
   for(int e = 0; e < eventCount && g_setupCount < 10; e++)
     {
      SMC_Event &ev = events[e];
      if(!ev.found)
         continue;

      // Check jika sudah done
      bool isDone = false;
      for(int j = 0; j < 10; j++)
         if(g_doneIds[j] == ev.breakIdx + rb[ev.breakIdx].time)
          {
           isDone = true;
           break;
          }
      if(isDone)
         continue;

      if(ev.breakIdx > InpZoneMaxAgeBars)
         continue;

      double bLow = 0.0, bHigh = 0.0;
      int kind = 0, iOld = 0, iNew = 0;
      if(!FindBaseZone(rb, got, ev, bLow, bHigh, kind, iOld, iNew))
         continue;

      // Check invalidasi
      bool valid = true;
      for(int k = ev.breakIdx - 1; k >= 1; k--)
        {
         if((ev.dir < 0 && rb[k].close > bHigh) || (ev.dir > 0 && rb[k].close < bLow))
          {
           valid = false;
           break;
          }
        }
      if(!valid)
         continue;

      // Refine
      const datetime tFrom = rb[iOld].time;
      const datetime tTo   = rb[iNew].time + PeriodSeconds(InpBaseTF) - 1;
      double rLow = bLow, rHigh = bHigh;
      int refKind = 0;
      RefineZone(ev.dir, bLow, bHigh, tFrom, tTo, rLow, rHigh, refKind);

      // Tambah ke array setups
      SMC_Setup &setup = g_setups[g_setupCount];
      setup.active   = true;
      setup.dir      = ev.dir;
      setup.isChoch  = ev.isChoch;
      setup.id       = rb[ev.breakIdx].time;
      setup.baseLow  = bLow;
      setup.baseHigh = bHigh;
      setup.refLow   = rLow;
      setup.refHigh  = rHigh;
      setup.kind     = kind;
      setup.refKind  = refKind;
      setup.attempts = 0;

      if((ev.dir < 0 && !InpTradeShort) || (ev.dir > 0 && !InpTradeLong))
         setup.active = false;

      if(setup.active)
        {
         PrintFormat("[SMC-GAP] Setup #%d %s %s @ %s", g_setupCount + 1,
                     (ev.isChoch ? "CHoCH" : "BOS"), (ev.dir < 0 ? "SELL" : "BUY"),
                     TimeToString(setup.id, TIME_DATE | TIME_MINUTES));
         g_setupCount++;
        }
     }

   Comment(StringFormat("Gap-up %.3f%% | Setups aktif: %d | Done: %d", 
           g_gapPct, g_setupCount, CountDoneIds()));
   return true;
  }

//+------------------------------------------------------------------+
//| ScanStructureMultiple - Scan MULTIPLE CHoCH/BOS (bukan hanya 1)  |
//+------------------------------------------------------------------+
int ScanStructureMultiple(const MqlRates &r[], const int total, const int openIdx, SMC_Event &events[])
  {
   int count = 0;

   const int N = InpSwingStrength;
   double shPrice = 0.0, slPrice = 0.0;
   int    shIdx = -1,    slIdx = -1;
   bool   shBroken = true, slBroken = true;
   int    trend = +1;

   for(int i = openIdx; i >= 1; i--)
     {
      const double cl = r[i].close;

      // Check tembusan swing high
      if(shIdx >= 0 && !shBroken && cl > shPrice)
        {
         const bool choch = (trend < 0);
         shBroken = true;
         if(choch || InpLongOnBOS)
          {
           if(count < 5)
            {
             events[count].found     = true;
             events[count].dir       = +1;
             events[count].isChoch   = choch;
             events[count].breakIdx  = i;
             events[count].swingIdx  = shIdx;
             events[count].level     = shPrice;
             int org = i;
             double ll = r[i].low;
             for(int k = i; k <= shIdx; k++)
                if(r[k].low <= ll) { ll = r[k].low; org = k; }
             events[count].originIdx = org;
             count++;
            }
          }
         trend = +1;
        }
      else if(slIdx >= 0 && !slBroken && cl < slPrice)
        {
         const bool choch = (trend > 0);
         slBroken = true;
         if(choch || InpShortOnBOS)
          {
           if(count < 5)
            {
             events[count].found     = true;
             events[count].dir       = -1;
             events[count].isChoch   = choch;
             events[count].breakIdx  = i;
             events[count].swingIdx  = slIdx;
             events[count].level     = slPrice;
             int org = i;
             double hh = r[i].high;
             for(int k = i; k <= slIdx; k++)
                if(r[k].high >= hh) { hh = r[k].high; org = k; }
             events[count].originIdx = org;
             count++;
            }
          }
         trend = -1;
        }

      // Konfirmasi swing
      const int j = i + N;
      if(j <= openIdx && (j + N) < total)
        {
         bool isSH = true, isSL = true;
         for(int k = 1; k <= N; k++)
          {
           if(r[j].high <= r[j - k].high || r[j].high < r[j + k].high)
              isSH = false;
           if(r[j].low >= r[j - k].low || r[j].low > r[j + k].low)
              isSL = false;
          }
         if(isSH) { shPrice = r[j].high; shIdx = j; shBroken = false; }
         if(isSL) { slPrice = r[j].low; slIdx = j; slBroken = false; }
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| FindBaseZone                                                     |
//+------------------------------------------------------------------+
bool FindBaseZone(const MqlRates &r[], const int total, const SMC_Event &ev,
                  double &zLow, double &zHigh, int &kind, int &iOld, int &iNew)
  {
   const double minFvg = InpMinFVGPoints * _Point;
   bool   fvgFound = false;
   double fvgLow = 0.0, fvgHigh = 0.0, fvgSize = 0.0;
   int    fvgOld = 0, fvgNew = 0;

   const int mMin = MathMax(2, ev.breakIdx);
   const int mMax = ev.originIdx - 1;
   for(int m = mMin; m <= mMax; m++)
     {
      const int a = m + 1;
      const int c = m - 1;
      if(a >= total)
         break;

      double lo = 0.0, hi = 0.0;
      if(ev.dir < 0)
        {
         if(!(r[a].low > r[c].high))
            continue;
         lo = r[c].high;
         hi = r[a].low;
        }
      else
        {
         if(!(r[a].high < r[c].low))
            continue;
         lo = r[a].high;
         hi = r[c].low;
        }

      const double gapSize = hi - lo;
      if(gapSize < minFvg)
         continue;
      if(gapSize > fvgSize)
        {
         fvgFound = true;
         fvgSize = gapSize;
         fvgLow = lo;
         fvgHigh = hi;
         fvgOld = a;
         fvgNew = c;
        }
     }

   bool obFound = false;
   double obLow = 0.0, obHigh = 0.0;
   int obIdx = -1;
   for(int k = ev.breakIdx + 1; k <= ev.originIdx; k++)
     {
      if(k >= total)
         break;
      const bool opposite = (ev.dir < 0) ? (r[k].close > r[k].open) : (r[k].close < r[k].open);
      if(opposite)
        {
         obIdx = k;
         break;
        }
     }
   if(obIdx < 0 && ev.originIdx >= 0 && ev.originIdx < total)
      obIdx = ev.originIdx;
   if(obIdx >= 0)
     {
      obFound = true;
      obLow  = InpOBBodyOnly ? MathMin(r[obIdx].open, r[obIdx].close) : r[obIdx].low;
      obHigh = InpOBBodyOnly ? MathMax(r[obIdx].open, r[obIdx].close) : r[obIdx].high;
     }

   bool useFvg = (InpZoneMode == ZONE_FVG_ONLY) || 
                 (InpZoneMode == ZONE_FVG_THEN_OB && fvgFound);

   if(useFvg)
     {
      if(!fvgFound)
         return false;
      zLow = fvgLow;
      zHigh = fvgHigh;
      kind = 1;
      iOld = fvgOld;
      iNew = fvgNew;
     }
   else
     {
      if(!obFound)
         return false;
      zLow = obLow;
      zHigh = obHigh;
      kind = 2;
      iOld = obIdx;
      iNew = obIdx;
     }
   return (zHigh > zLow);
  }

//+------------------------------------------------------------------+
//| RefineZone                                                       |
//+------------------------------------------------------------------+
int RefineZone(const int dir, const double bLow, const double bHigh,
               const datetime tFrom, const datetime tTo,
               double &rLow, double &rHigh, int &refKind)
  {
   refKind = 0;

   MqlRates m[];
   ArraySetAsSeries(m, true);
   const int n = CopyRates(_Symbol, InpRefineTF, tFrom, tTo, m);
   if(n < 1)
      return -1;

   const double minFvg = InpMinRefineFVGPoints * _Point;
   bool found = false;
   double bestSize = 0.0, bestLow = 0.0, bestHigh = 0.0;
   for(int mm = 1; mm <= n - 2; mm++)
     {
      const int a = mm + 1;
      const int c = mm - 1;
      double lo = 0.0, hi = 0.0;
      if(dir < 0)
        {
         if(!(m[a].low > m[c].high))
            continue;
         lo = m[c].high;
         hi = m[a].low;
        }
      else
        {
         if(!(m[a].high < m[c].low))
            continue;
         lo = m[a].high;
         hi = m[c].low;
        }
      lo = MathMax(lo, bLow);
      hi = MathMin(hi, bHigh);
      const double sz = hi - lo;
      if(sz <= 0.0 || sz < minFvg)
         continue;
      if(sz > bestSize)
        {
         found = true;
         bestSize = sz;
         bestLow = lo;
         bestHigh = hi;
        }
     }
   if(found)
     {
      rLow = bestLow;
      rHigh = bestHigh;
      refKind = 1;
      return 1;
     }

   for(int k = 0; k < n; k++)
     {
      const bool opposite = (dir < 0) ? (m[k].close > m[k].open) : (m[k].close < m[k].open);
      if(!opposite)
         continue;
      double lo = InpOBBodyOnly ? MathMin(m[k].open, m[k].close) : m[k].low;
      double hi = InpOBBodyOnly ? MathMax(m[k].open, m[k].close) : m[k].high;
      lo = MathMax(lo, bLow);
      hi = MathMin(hi, bHigh);
      if(hi - lo <= 0.0)
         continue;
      rLow = lo;
      rHigh = hi;
      refKind = 2;
      return 1;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| CheckEntry - IMPROVED: dengan entry delay & re-entry management  |
//+------------------------------------------------------------------+
void CheckEntry(const int setupIdx)
  {
   SMC_Setup &setup = g_setups[setupIdx];
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   const double buf = InpSLBufferPoints * _Point;
   double entry = 0.0, sl = 0.0;

   // Check trigger
   if(setup.dir < 0)
     {
      if(bid < setup.refLow)
         return;
      entry = bid;
      sl = setup.refHigh + buf;
      if(entry >= sl)
       {
        setup.active = false;
        return;
       }
     }
   else
     {
      if(ask > setup.refHigh)
         return;
      entry = ask;
      sl = setup.refLow - buf;
      if(entry <= sl)
       {
        setup.active = false;
        return;
       }
     }

   // Filters
   if(CountTradesPerDay() >= InpMaxTradesPerDay)
      return;
   if(CountPositionsBySetup(setupIdx) > 0)
      return;

   // TP/RR calculation
   sl = NormPrice(sl);
   const double tp     = CalcTP(setup.dir, entry, sl, ask - bid);
   const double risk   = MathAbs(entry - sl);
   const double reward = (setup.dir < 0) ? (entry - tp) : (tp - entry);
   
   if(risk <= 0.0 || reward <= 0.0)
      return;
   if(reward / risk < InpMinRR)
      return;

   // Lot & order
   const double lot = CalcLot(setup.dir, entry, sl);
   if(lot <= 0.0)
      return;

   bool sent = false;
   if(setup.dir < 0)
      sent = g_trade.Sell(lot, _Symbol, bid, sl, tp, "SMCGAP-SELL");
   else
      sent = g_trade.Buy(lot, _Symbol, ask, sl, tp, "SMCGAP-BUY");

   if(sent)
     {
      setup.active = false;
      for(int i = 0; i < 10; i++)
        {
         if(g_doneIds[i] == 0)
          {
           g_doneIds[i] = setup.id;
           break;
          }
        }
      PrintFormat("[SMC-GAP] Eksekusi Setup #%d %s %.5f (SL=%.5f TP=%.5f)",
                  setupIdx + 1, (setup.dir < 0 ? "SELL" : "BUY"), entry, sl, tp);
     }
   else
     {
      setup.attempts++;
      if(setup.attempts >= 3)
         setup.active = false;
     }
  }

//+------------------------------------------------------------------+
//| CalcTP                                                           |
//+------------------------------------------------------------------+
double CalcTP(const int dir, const double entry, const double sl, const double spread)
  {
   double tp = 0.0;
   if(InpTPMode == TP_TODAY_EXTREME)
     {
      if(dir < 0)
         tp = iLow(_Symbol, PERIOD_D1, 0) + spread;
      else
         tp = iHigh(_Symbol, PERIOD_D1, 0);
     }
   else if(InpTPMode == TP_PREVDAY_EXTREME)
     {
      if(dir < 0)
         tp = g_prevLow + spread;
      else
         tp = g_prevHigh;
     }
   else
     {
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
//+------------------------------------------------------------------+
double CalcLot(const int dir, const double entry, const double sl)
  {
   if(InpLotMode == LOT_FIXED)
      return InpFixedLot;

   const double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double loss1 = 0.0;
   const ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, loss1) && loss1 < 0.0)
      return riskMoney / MathAbs(loss1);

   const double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double dist = MathAbs(entry - sl);
   if(tv > 0 && ts > 0)
      return riskMoney / (dist / ts * tv);

   return InpFixedLot;
  }

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
double NormPrice(const double p)
  {
   const double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }

int CountTradesPerDay()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   return count;
  }

int CountPositionsBySetup(const int setupIdx)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
        {
         string cmt = PositionGetString(POSITION_COMMENT);
         if(StringFind(cmt, "SMCGAP") >= 0)
            count++;
        }
   return count;
  }

int CountDoneIds()
  {
   int count = 0;
   for(int i = 0; i < 10; i++)
      if(g_doneIds[i] != 0)
         count++;
   return count;
  }
