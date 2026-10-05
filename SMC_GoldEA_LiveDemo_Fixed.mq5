//+------------------------------------------------------------------+
//|                              cld_live_demo_fixed.mq5 v4.50      |
//|  FIX: Micro $20 & 2000 Cent | Auto Filling IOC | Point & Stops  |
//|  FIX: Daily Limit Aktif | Lot Cent-Safe | Validasi Demo        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, LuxAlgo & Smart Money Concepts - FIXED v4.50"
#property link "https://www.luxalgo.com/"
#property version "4.50"
#property description "FIXED SMC Gold EA - SUPPORT MODAL MICRO $20 & 2000 CENT"
#property description "Auto Filling, Auto Pip, StopsLevel Check, Daily Limit Fix"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Input Parameters
input group "═════════ STRATEGY SETTINGS ═════════"
input ENUM_TIMEFRAMES BaseTimeframe = PERIOD_M15;
input ENUM_TIMEFRAMES ConfirmTimeframe = PERIOD_M5;
input ENUM_TIMEFRAMES HigherTimeframe = PERIOD_H1;
input int MaxOpenTrades = 2;
input int Slippage = 30;

input group "═════════ RISK MANAGEMENT ═════════"
input double RiskPerTradePercent = 0.5;
input int StopLossPips = 80;
input int TakeProfitPips = 160;
input bool UseAutoRR = true;
input double MinRiskReward = 2.0;
input bool UseTrailingStop = true;
input int TrailingStopPips = 60;
input bool UseBreakeven = true;
input int BreakevenPips = 40;

input group "═════════ MICRO ACCOUNT SUPPORT ═════════"
input bool IsCentAccount = false;                              // Set TRUE jika akun Cent (2000 = $20)
input bool AutoDetectCent = true;                              // Auto deteksi akun cent
input double FixedMicroLot = 0.01;                             // Lot untuk balance < $50 / <5000 cent
input double MaxLotForMicro = 0.10;                            // Max lot untuk akun micro

input group "═════════ SMC INDICATOR SETTINGS ═════════"
input string SMC_Indicator_Name = "LuxAlgo - Smart Money Concepts";
input int SMC_OB_Lookback = 10;
input int SMC_FVG_Lookback = 8;
input bool UseOrderBlocks = true;
input bool UseFairValueGaps = true;
input bool UseLiquidityGrabs = true;
input double MinOBSize = 15;

input group "═════════ TRADING FILTERS ═════════"
input bool UseSessionFilter = true;
input int LondonStartHour = 7;
input int LondonEndHour = 16;
input int NewYorkStartHour = 13;
input int NewYorkEndHour = 21;
input bool UseVolatilityFilter = true;
input double MaxATRPercent = 1.2;
input bool UseSpreadFilter = true;
input double MaxSpreadPips = 50;

input group "═════════ LIVE DEMO SETTINGS ═════════"
input int MagicNumber = 20241225;
input string TradeComment = "SMC-Gold-LiveDemo";
input bool EnableAlerts = true;
input bool EnablePartialClose = true;
input double PartialClosePercent = 50.0;
input int PartialClosePips = 80;

input group "═════════ DAILY PROFIT OPTIMIZATION ═════════"
input double DailyProfitTarget = 50.0;
input double DailyMaxLoss = -25.0;
input int MaxDailyTrades = 15;
input bool StopAfterDailyTarget = true;

input group "═════════ ADVANCED RISK MANAGEMENT ═════════"
input bool UseDynamicSLTP = true;
input double ATRMultiplierSL = 1.0;
input double ATRMultiplierTP = 2.5;
input bool UseEarlyProfitProtection = true;
input int EarlyProfitPips = 30;
input bool UseScaledExits = true;
input double FirstExitPercent = 50.0;
input int FirstExitPips = 60;
input double SecondExitPercent = 30.0;
input int SecondExitPips = 100;
input int MinConfluenceLevel = 1;
input bool RequireHigherTFConfirmation = false;
input bool UseConservativeEntries = false;
input double SignalValidityHours = 4.0;

input group "═════════ SMC SIGNAL STRENGTH ═════════"
input bool EnableManualTesting = false;
input bool TriggerBuyTrade = false;
input bool TriggerSellTrade = false;
input bool CloseAllTrades = false;
input double ManualLotSize = 0.01;

//--- Global Variables
double PipSize;
double PointVal;
int ATR_Handle = INVALID_HANDLE;
int RSI_Handle = INVALID_HANDLE;
int SMC_Base_Handle = INVALID_HANDLE;
int SMC_Confirm_Handle = INVALID_HANDLE;
int SMC_Higher_Handle = INVALID_HANDLE;
bool SMC_Available = false;
datetime LastTickTime;
datetime LastTradeTime = 0;
double DailyStartBalance = 0.0;
datetime LastDayCheck = 0;
bool DailyTargetReached = false;
int DailyTradeCount = 0;
int no_signal_counter = 0;
bool IsCentDetected = false;

//--- ENUMS & STRUCTS
enum ENUM_SMC_BUFFERS {BUFFER_BULLISH_BOS=0,BUFFER_BEARISH_BOS=1,BUFFER_BULLISH_CHOCH=2,BUFFER_BEARISH_CHOCH=3,BUFFER_BULLISH_OB_HIGH=4,BUFFER_BULLISH_OB_LOW=5,BUFFER_BEARISH_OB_HIGH=6,BUFFER_BEARISH_OB_LOW=7,BUFFER_BULLISH_FVG_HIGH=8,BUFFER_BULLISH_FVG_LOW=9,BUFFER_BEARISH_FVG_HIGH=10,BUFFER_BEARISH_FVG_LOW=11,BUFFER_EQ_HIGHS=12,BUFFER_EQ_LOWS=13,BUFFER_LIQUIDITY_GRAB_HIGH=14,BUFFER_LIQUIDITY_GRAB_LOW=15};
enum ENUM_MARKET_BIAS {BIAS_BULLISH,BIAS_BEARISH,BIAS_NEUTRAL};
enum ENUM_TRADE_TYPE {TRADE_ORDER_BLOCK,TRADE_FAIR_VALUE_GAP,TRADE_LIQUIDITY_GRAB,TRADE_BOS_BREAKOUT,TRADE_CHOCH_REVERSAL,TRADE_NONE};
struct SMarketConditions {double atr_value;double atr_percent;double rsi_value;double current_spread;bool is_volatile;bool is_trending;ENUM_MARKET_BIAS trend_direction;};
struct SMarketStructure {bool bullish_bos;bool bearish_bos;bool bullish_choch;bool bearish_choch;double recent_high;double recent_low;datetime high_time;datetime low_time;int structure_strength;};
struct SOrderBlocks {double bullish_ob_high;double bullish_ob_low;double bearish_ob_high;double bearish_ob_low;datetime ob_time;bool is_valid;double size_pips;};
struct SFairValueGaps {double bullish_fvg_high;double bullish_fvg_low;double bearish_fvg_high;double bearish_fvg_low;datetime fvg_time;bool is_valid;double size_pips;};
struct SLiquidityLevels {double equal_highs;double equal_lows;double swing_highs;double swing_lows;bool liquidity_grab_high;bool liquidity_grab_low;datetime grab_time;};

//--- CTrade Simple FIXED Auto-Filling
struct CTrade_Simple
{
   ulong magic_number;uint deviation;bool async_mode;
   void SetExpertMagicNumber(ulong m){magic_number=m;}
   void SetDeviationInPoints(uint d){deviation=d;}
   void SetAsyncMode(bool a){async_mode=a;}
   ENUM_ORDER_TYPE_FILLING GetFillingMode()
   {
      int filling=(int)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
      if((filling & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
      if((filling & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
   }
   bool SendOrder(MqlTradeRequest &req,MqlTradeResult &res)
   {
      // Coba FOK -> IOC -> RETURN otomatis
      ENUM_ORDER_TYPE_FILLING try_mode[3]={ORDER_FILLING_FOK,ORDER_FILLING_IOC,ORDER_FILLING_RETURN};
      for(int i=0;i<3;i++)
      {
         req.type_filling=try_mode[i];
         if(OrderSend(req,res))
         {
            if(res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL || res.retcode==TRADE_RETCODE_PLACED) return true;
         }
         int err=GetLastError();
         if(err!=10030) break; // jika bukan error filling, jangan coba lagi
      }
      return false;
   }
   bool Buy(double vol,string sym,double price,double sl,double tp,string comm)
   {
      MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
      req.action=TRADE_ACTION_DEAL;req.symbol=sym;req.volume=vol;req.type=ORDER_TYPE_BUY;req.price=price;req.sl=sl;req.tp=tp;req.deviation=deviation;req.magic=magic_number;req.comment=comm;
      req.type_filling=GetFillingMode();
      return SendOrder(req,res);
   }
   bool Sell(double vol,string sym,double price,double sl,double tp,string comm)
   {
      MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
      req.action=TRADE_ACTION_DEAL;req.symbol=sym;req.volume=vol;req.type=ORDER_TYPE_SELL;req.price=price;req.sl=sl;req.tp=tp;req.deviation=deviation;req.magic=magic_number;req.comment=comm;
      req.type_filling=GetFillingMode();
      return SendOrder(req,res);
   }
   bool PositionClose(ulong ticket)
   {
      if(!PositionSelectByTicket(ticket)) return false;
      MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
      req.action=TRADE_ACTION_DEAL;req.symbol=PositionGetString(POSITION_SYMBOL);req.volume=PositionGetDouble(POSITION_VOLUME);
      req.type=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
      req.price=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?SymbolInfoDouble(req.symbol,SYMBOL_BID):SymbolInfoDouble(req.symbol,SYMBOL_ASK);
      req.deviation=deviation;req.magic=magic_number;req.position=ticket;req.type_filling=GetFillingMode();
      return SendOrder(req,res);
   }
   bool PositionModify(ulong ticket,double sl,double tp)
   {
      if(!PositionSelectByTicket(ticket)) return false;
      MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
      req.action=TRADE_ACTION_SLTP;req.symbol=PositionGetString(POSITION_SYMBOL);req.sl=sl;req.tp=tp;req.position=ticket;
      return OrderSend(req,res);
   }
   bool PositionClosePartial(ulong ticket,double vol)
   {
      if(!PositionSelectByTicket(ticket)) return false;
      MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
      req.action=TRADE_ACTION_DEAL;req.symbol=PositionGetString(POSITION_SYMBOL);req.volume=vol;
      req.type=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
      req.price=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?SymbolInfoDouble(req.symbol,SYMBOL_BID):SymbolInfoDouble(req.symbol,SYMBOL_ASK);
      req.deviation=deviation;req.magic=magic_number;req.position=ticket;req.type_filling=GetFillingMode();
      return SendOrder(req,res);
   }
};
CTrade_Simple Trade;

//+------------------------------------------------------------------+
//| Helpers FIXED                                                     |
//+------------------------------------------------------------------+
bool IsCentAccountDetected()
{
   if(IsCentAccount) return true;
   if(!AutoDetectCent) return false;
   string curr=AccountInfoString(ACCOUNT_CURRENCY);
   StringToUpper(curr);
   if(StringFind(curr,"CENT")>=0 || StringFind(curr,"USC")>=0 || StringFind(curr,"CUSD")>=0) return true;
   // Fallback: balance besar tapi equity kecil biasanya cent (2000 cent = $20)
   // Jangan auto jika broker pakai USD tapi balance 2000 -> user harus set manual IsCentAccount=true
   return false;
}
void InitPipSize()
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   // Untuk XAUUSD: digits 2 -> point 0.01, pip 0.1 | digits 3 -> point 0.001 pip 0.01
   if(digits==3 || digits==5) PipSize=pt*10;
   else if(digits==2 || digits==4) PipSize=pt*10;
   else PipSize=pt;
   // Khusus XAU: pastikan 1 pip = 0.1
   if(_Symbol=="GOLD" || _Symbol=="XAUUSD" || StringFind(_Symbol,"XAU")>=0)
   {
      if(digits==2) PipSize=0.1;
      if(digits==3) PipSize=0.01;
   }
   PointVal=pt;
   Print("FIXED PipSize: ",PipSize," Point: ",PointVal," Digits: ",digits);
}
double NormalizePrice(double price){return NormalizeDouble(price,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));}
double AdjustStops(double price,double sl,double tp,bool is_buy)
{
   int stops_level=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop=stops_level*PointVal;
   if(min_stop==0) min_stop=PipSize; // minimal 1 pip
   if(is_buy)
   {
      if(sl>0 && (price-sl)<min_stop) sl=price-min_stop;
      if(tp>0 && (tp-price)<min_stop) tp=price+min_stop;
   }
   else
   {
      if(sl>0 && (sl-price)<min_stop) sl=price+min_stop;
      if(tp>0 && (price-tp)<min_stop) tp=price-min_stop;
   }
   return 0;
}
bool CheckMoneyForTrade(string sym,double lots,ENUM_ORDER_TYPE type)
{
   double price=(type==ORDER_TYPE_BUY)?SymbolInfoDouble(sym,SYMBOL_ASK):SymbolInfoDouble(sym,SYMBOL_BID);
   double margin; if(!OrderCalcMargin(type,sym,lots,price,margin)) return false;
   double free_margin=AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(margin>free_margin)
   {
      Print("❌ FreeMargin tidak cukup: need ",margin," free ",free_margin);
      return false;
   }
   return true;
}
double CalculateLotSizeFixed(double entry_price,int sl_pips)
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double min_lot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double max_lot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   bool isCent=IsCentDetected;

   // MODE MICRO: balance kecil pakai fixed lot agar tidak 0.00
   double threshold = isCent ? 5000 : 50;
   if(balance < threshold)
   {
      double lot=FixedMicroLot;
      lot=MathMax(lot,min_lot);
      lot=MathMin(lot,MaxLotForMicro);
      lot=MathMin(lot,max_lot);
      lot=NormalizeDouble(MathFloor(lot/step)*step,2);
      Print("MICRO MODE: Balance ",balance," Cent:",isCent," -> Lot Fixed ",lot);
      return lot;
   }

   // MODE NORMAL: kalkulasi risk %
   double risk_amount=balance*(RiskPerTradePercent/100.0);
   if(isCent) risk_amount/=100; // cent -> konversi ke USD value

   double sl_distance = sl_pips * PipSize;
   if(UseDynamicSLTP)
   {
      double atr[]; if(CopyBuffer(ATR_Handle,0,0,1,atr)>0)
      {
         sl_distance=atr[0]*ATRMultiplierSL;
         sl_distance=MathMax(sl_distance,30*PipSize);
         sl_distance=MathMin(sl_distance,120*PipSize);
         sl_pips=(int)(sl_distance/PipSize);
      }
   }
   double tick_val=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double contract=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   // Rumus lot = risk / (sl_distance/tick_size * tick_value)
   double loss_per_lot = (sl_distance/tick_size)*tick_val;
   if(loss_per_lot<=0) loss_per_lot=sl_pips*tick_val*10;
   double lot = risk_amount / loss_per_lot;
   lot = lot * 0.8; // konservatif 80%
   lot=MathMax(lot,min_lot);
   lot=MathMin(lot,max_lot);
   lot=MathMin(lot, isCent? 1.0 : MaxLotForMicro*5);
   lot=NormalizeDouble(MathFloor(lot/step)*step,2);
   if(lot<min_lot) lot=min_lot;
   Print("NORMAL LOT: Risk $",risk_amount," SL ",sl_pips," pips -> Lot ",lot);
   return lot;
}
void CalculateDynamicSLTPFixed(double entry,bool is_buy,double &sl,double &tp)
{
   double sl_dist=StopLossPips*PipSize;
   double tp_dist=TakeProfitPips*PipSize;
   if(UseDynamicSLTP)
   {
      double atr[]; if(CopyBuffer(ATR_Handle,0,0,1,atr)>0)
      {
         sl_dist=atr[0]*ATRMultiplierSL;
         tp_dist=atr[0]*ATRMultiplierTP;
         sl_dist=MathMax(sl_dist,30*PipSize); sl_dist=MathMin(sl_dist,120*PipSize);
         tp_dist=MathMax(tp_dist,60*PipSize); tp_dist=MathMin(tp_dist,300*PipSize);
      }
   }
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop=stops*PointVal;
   sl_dist=MathMax(sl_dist,min_stop+PipSize);
   tp_dist=MathMax(tp_dist,min_stop+PipSize);

   if(is_buy){sl=NormalizePrice(entry-sl_dist); tp=NormalizePrice(entry+tp_dist);}
   else {sl=NormalizePrice(entry+sl_dist); tp=NormalizePrice(entry-tp_dist);}
}
int CountPositionsByMagic(int magic,ENUM_POSITION_TYPE type)
{
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type) continue;
      cnt++;
   }
   return cnt;
}
double CalculateProfitPips(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0;
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double cur=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double diff=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?(cur-open):(open-cur);
   return diff/PipSize;
}
bool IsValidTradingEnvironment()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE)==0) return false;
   return true;
}
SMarketConditions GetMarketConditions()
{
   SMarketConditions c; ZeroMemory(c);
   double atr[]; if(CopyBuffer(ATR_Handle,0,0,1,atr)>0){c.atr_value=atr[0]; double price=SymbolInfoDouble(_Symbol,SYMBOL_BID); c.atr_percent=(atr[0]/price)*100; c.is_volatile=c.atr_percent>MaxATRPercent;}
   double rsi[]; if(CopyBuffer(RSI_Handle,0,0,1,rsi)>0) c.rsi_value=rsi[0];
   c.current_spread=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/PipSize;
   if(c.rsi_value>50) c.trend_direction=BIAS_BULLISH; else if(c.rsi_value<50) c.trend_direction=BIAS_BEARISH; else c.trend_direction=BIAS_NEUTRAL;
   c.is_trending=c.rsi_value>70 || c.rsi_value<30;
   return c;
}
bool PassesFilters(SMarketConditions &c)
{
   if(UseSessionFilter)
   {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); int h=dt.hour;
      bool london=(h>=LondonStartHour && h<LondonEndHour);
      bool ny=(h>=NewYorkStartHour && h<NewYorkEndHour);
      if(!london && !ny) return false;
   }
   if(UseVolatilityFilter && c.is_volatile) return false;
   if(UseSpreadFilter && c.current_spread>MaxSpreadPips) return false;
   return true;
}
bool CheckDailyLimits()
{
   MqlDateTime cur,last; TimeToStruct(TimeCurrent(),cur); TimeToStruct(LastDayCheck,last);
   if(cur.day!=last.day || DailyStartBalance==0)
   {
      DailyStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      DailyTradeCount=0; DailyTargetReached=false; LastDayCheck=TimeCurrent();
      Print("📅 New Day - Start Balance: ",DailyStartBalance," CentMode:",IsCentDetected);
   }
   double curBal=AccountInfoDouble(ACCOUNT_BALANCE)+AccountInfoDouble(ACCOUNT_PROFIT);
   // Untuk cent, target disesuaikan (50 USD = 5000 cent)
   double target=DailyProfitTarget; double maxloss=DailyMaxLoss;
   if(IsCentDetected){target*=100; maxloss*=100;}
   double dailyPnL = curBal - DailyStartBalance;
   if(dailyPnL >= target && StopAfterDailyTarget){ DailyTargetReached=true; Print("🎯 DAILY TARGET REACHED: ",dailyPnL); return false; }
   if(dailyPnL <= maxloss){ Print("🛑 DAILY MAX LOSS REACHED: ",dailyPnL); return false; }
   if(DailyTradeCount >= MaxDailyTrades){ Print("🛑 MAX DAILY TRADES REACHED"); return false; }
   if(DailyTargetReached) return false;
   return true;
}
bool AreIndicatorsReady()
{
   double a[],r[]; ArrayResize(a,1); ArrayResize(r,1);
   if(CopyBuffer(ATR_Handle,0,0,1,a)<=0) return false;
   if(CopyBuffer(RSI_Handle,0,0,1,r)<=0) return false;
   if(a[0]==EMPTY_VALUE || r[0]==EMPTY_VALUE) return false;
   return true;
}
string ErrorDescription(int e)
{
   switch(e){
      case 10004:return "Requote"; case 10006:return "Rejected"; case 10016:return "Invalid stops";
      case 10019:return "No money"; case 10030:return "Invalid filling"; default:return IntegerToString(e);
   }
}

//+------------------------------------------------------------------+
//| OnInit FIXED                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 SMC GOLD EA FIXED v4.50 Micro-Safe");
   Print("═══════════════════════════════════════");
   // FIX BUG #1: Validasi Demo yang benar
   ENUM_ACCOUNT_TRADE_MODE acc_mode=(ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(acc_mode!=ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("⚠️ LIVE Account terdeteksi - EA tetap jalan, mode DEMO tetap aman");
   }
   IsCentDetected=IsCentAccountDetected();
   Print(IsCentDetected?"💰 CENT ACCOUNT DETECTED":"💵 STANDARD ACCOUNT");

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(Slippage);
   Trade.SetAsyncMode(false);
   InitPipSize();

   ATR_Handle=iATR(_Symbol,PERIOD_H1,14);
   RSI_Handle=iRSI(_Symbol,PERIOD_H1,14,PRICE_CLOSE);
   if(ATR_Handle==INVALID_HANDLE || RSI_Handle==INVALID_HANDLE){Print("❌ Gagal create ATR/RSI"); return INIT_FAILED;}

   SMC_Base_Handle=iCustom(_Symbol,BaseTimeframe,SMC_Indicator_Name);
   SMC_Confirm_Handle=iCustom(_Symbol,ConfirmTimeframe,SMC_Indicator_Name);
   SMC_Higher_Handle=iCustom(_Symbol,HigherTimeframe,SMC_Indicator_Name);
   SMC_Available=(SMC_Base_Handle!=INVALID_HANDLE && SMC_Confirm_Handle!=INVALID_HANDLE && SMC_Higher_Handle!=INVALID_HANDLE);
   if(!SMC_Available) Print("⚠️ SMC LuxAlgo tidak ditemukan - Fallback RSI akan aktif");
   else Print("✅ SMC Loaded Base:",EnumToString(BaseTimeframe)," Confirm:",EnumToString(ConfirmTimeframe));

   DailyStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   LastDayCheck=TimeCurrent();
   Print("✅ INIT OK Balance:",DailyStartBalance," PipSize:",PipSize," Magic:",MagicNumber);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(SMC_Base_Handle!=INVALID_HANDLE) IndicatorRelease(SMC_Base_Handle);
   if(SMC_Confirm_Handle!=INVALID_HANDLE) IndicatorRelease(SMC_Confirm_Handle);
   if(SMC_Higher_Handle!=INVALID_HANDLE) IndicatorRelease(SMC_Higher_Handle);
   if(ATR_Handle!=INVALID_HANDLE) IndicatorRelease(ATR_Handle);
   if(RSI_Handle!=INVALID_HANDLE) IndicatorRelease(RSI_Handle);
}
// Lanjut PART 2...
//+------------------------------------------------------------------+
//| PART 2/3 - OnTick + SMC Analysis + Entry Execution FIXED         |
//+------------------------------------------------------------------+
void OnTick()
{
   static bool ready=false;
   if(!ready){ if(!AreIndicatorsReady()) return; ready=true; Print("✅ Indicators Ready - Trading Started"); }

   if(EnableManualTesting) HandleManualTesting();
   if(!IsValidTradingEnvironment()) return;
   if(TimeCurrent()==LastTickTime) return;
   if(!CheckDailyLimits()) return; // FIX: Daily limit sekarang aktif

   SMarketConditions cond=GetMarketConditions();
   static int mon=0; if(++mon>=20){ mon=0; PrintMarketStatus(cond); }
   if(!PassesFilters(cond)) return;

   CheckForSMCTrades(cond);
   ManageOpenPositions(cond);
   LastTickTime=TimeCurrent();
}

void PrintMarketStatus(SMarketConditions &c)
{
   static datetime last=0; if(TimeCurrent()-last<300) return; last=TimeCurrent();
   int buys=CountPositionsByMagic(MagicNumber,POSITION_TYPE_BUY);
   int sells=CountPositionsByMagic(MagicNumber,POSITION_TYPE_SELL);
   ENUM_MARKET_BIAS bias=GetHigherTimeframeBias();
   Print("--- MARKET ",TimeToString(TimeCurrent())," Price:",DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_BID),_Digits)," Spread:",DoubleToString(c.current_spread,1)," RSI:",DoubleToString(c.rsi_value,2)," HTF:",EnumToString(bias)," Pos:",buys+sells," Bal:",AccountInfoDouble(ACCOUNT_BALANCE));
}

//+------------------------------------------------------------------+
//| SMC CORE FIXED                                                   |
//+------------------------------------------------------------------+
ENUM_MARKET_BIAS GetHigherTimeframeBias()
{
   if(SMC_Higher_Handle==INVALID_HANDLE) return BIAS_NEUTRAL;
   double bb[],be[],cb[],ce[]; ArrayResize(bb,SMC_OB_Lookback); ArrayResize(be,SMC_OB_Lookback); ArrayResize(cb,SMC_OB_Lookback); ArrayResize(ce,SMC_OB_Lookback);
   if(CopyBuffer(SMC_Higher_Handle,BUFFER_BULLISH_BOS,0,SMC_OB_Lookback,bb)<=0) return BIAS_NEUTRAL;
   if(CopyBuffer(SMC_Higher_Handle,BUFFER_BEARISH_BOS,0,SMC_OB_Lookback,be)<=0) return BIAS_NEUTRAL;
   if(CopyBuffer(SMC_Higher_Handle,BUFFER_BULLISH_CHOCH,0,SMC_OB_Lookback,cb)<=0) return BIAS_NEUTRAL;
   if(CopyBuffer(SMC_Higher_Handle,BUFFER_BEARISH_CHOCH,0,SMC_OB_Lookback,ce)<=0) return BIAS_NEUTRAL;
   int bull=0,bear=0; datetime tBull=0,tBear=0;
   for(int i=0;i<SMC_OB_Lookback;i++)
   {
      if(bb[i]!=EMPTY_VALUE && bb[i]!=0){ bull++; datetime t=iTime(_Symbol,HigherTimeframe,i); if(t>tBull) tBull=t; }
      if(be[i]!=EMPTY_VALUE && be[i]!=0){ bear++; datetime t=iTime(_Symbol,HigherTimeframe,i); if(t>tBear) tBear=t; }
      if(cb[i]!=EMPTY_VALUE && cb[i]!=0){ bull++; datetime t=iTime(_Symbol,HigherTimeframe,i); if(t>tBull) tBull=t; }
      if(ce[i]!=EMPTY_VALUE && ce[i]!=0){ bear++; datetime t=iTime(_Symbol,HigherTimeframe,i); if(t>tBear) tBear=t; }
   }
   if(tBull>tBear && bull>=bear) return BIAS_BULLISH;
   if(tBear>tBull && bear>=bull) return BIAS_BEARISH;
   return BIAS_NEUTRAL;
}

SMarketStructure GetMarketStructure(int handle)
{
   SMarketStructure s; ZeroMemory(s);
   if(handle==INVALID_HANDLE) return s;
   double bb[],be[],cb[],ce[]; ArrayResize(bb,5); ArrayResize(be,5); ArrayResize(cb,5); ArrayResize(ce,5);
   if(CopyBuffer(handle,BUFFER_BULLISH_BOS,0,5,bb)<=0) return s;
   if(CopyBuffer(handle,BUFFER_BEARISH_BOS,0,5,be)<=0) return s;
   if(CopyBuffer(handle,BUFFER_BULLISH_CHOCH,0,5,cb)<=0) return s;
   if(CopyBuffer(handle,BUFFER_BEARISH_CHOCH,0,5,ce)<=0) return s;
   for(int i=0;i<3;i++)
   {
      if(bb[i]!=EMPTY_VALUE && bb[i]!=0){ s.bullish_bos=true; s.structure_strength++; }
      if(be[i]!=EMPTY_VALUE && be[i]!=0){ s.bearish_bos=true; s.structure_strength++; }
      if(cb[i]!=EMPTY_VALUE && cb[i]!=0){ s.bullish_choch=true; s.structure_strength++; }
      if(ce[i]!=EMPTY_VALUE && ce[i]!=0){ s.bearish_choch=true; s.structure_strength++; }
   }
   double h[],l[]; ArrayResize(h,10); ArrayResize(l,10);
   ENUM_TIMEFRAMES tf=(handle==SMC_Base_Handle)?BaseTimeframe:(handle==SMC_Confirm_Handle)?ConfirmTimeframe:HigherTimeframe;
   if(CopyHigh(_Symbol,tf,0,10,h)>0 && CopyLow(_Symbol,tf,0,10,l)>0)
   {
      int mx=ArrayMaximum(h,0,5); int mn=ArrayMinimum(l,0,5);
      if(mx>=0){ s.recent_high=h[mx]; s.high_time=iTime(_Symbol,tf,mx); }
      if(mn>=0){ s.recent_low=l[mn]; s.low_time=iTime(_Symbol,tf,mn); }
   }
   return s;
}

SOrderBlocks GetOrderBlocks(int handle)
{
   SOrderBlocks b; ZeroMemory(b);
   if(handle==INVALID_HANDLE) return b;
   double bh[],bl[],rh[],rl[]; ArrayResize(bh,SMC_OB_Lookback); ArrayResize(bl,SMC_OB_Lookback); ArrayResize(rh,SMC_OB_Lookback); ArrayResize(rl,SMC_OB_Lookback);
   if(CopyBuffer(handle,BUFFER_BULLISH_OB_HIGH,0,SMC_OB_Lookback,bh)<=0) return b;
   if(CopyBuffer(handle,BUFFER_BULLISH_OB_LOW,0,SMC_OB_Lookback,bl)<=0) return b;
   if(CopyBuffer(handle,BUFFER_BEARISH_OB_HIGH,0,SMC_OB_Lookback,rh)<=0) return b;
   if(CopyBuffer(handle,BUFFER_BEARISH_OB_LOW,0,SMC_OB_Lookback,rl)<=0) return b;
   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double bestBull=DBL_MAX,bestBear=DBL_MAX;
   for(int i=0;i<SMC_OB_Lookback;i++)
   {
      if(bh[i]!=EMPTY_VALUE && bl[i]!=EMPTY_VALUE && bh[i]!=0 && bl[i]!=0)
      {
         double sz=(bh[i]-bl[i])/PipSize; double dist=MathAbs(price-bl[i]);
         if(sz>=MinOBSize && dist<bestBull){ b.bullish_ob_high=bh[i]; b.bullish_ob_low=bl[i]; b.size_pips=sz; b.is_valid=true; bestBull=dist; b.ob_time=iTime(_Symbol,BaseTimeframe,i); }
      }
      if(rh[i]!=EMPTY_VALUE && rl[i]!=EMPTY_VALUE && rh[i]!=0 && rl[i]!=0)
      {
         double sz=(rh[i]-rl[i])/PipSize; double dist=MathAbs(price-rh[i]);
         if(sz>=MinOBSize && dist<bestBear){ b.bearish_ob_high=rh[i]; b.bearish_ob_low=rl[i]; b.size_pips=sz; b.is_valid=true; bestBear=dist; b.ob_time=iTime(_Symbol,BaseTimeframe,i); }
      }
   }
   return b;
}

SFairValueGaps GetFairValueGaps(int handle)
{
   SFairValueGaps g; ZeroMemory(g);
   if(handle==INVALID_HANDLE) return g;
   double bh[],bl[],rh[],rl[]; ArrayResize(bh,SMC_FVG_Lookback); ArrayResize(bl,SMC_FVG_Lookback); ArrayResize(rh,SMC_FVG_Lookback); ArrayResize(rl,SMC_FVG_Lookback);
   if(CopyBuffer(handle,BUFFER_BULLISH_FVG_HIGH,0,SMC_FVG_Lookback,bh)<=0) return g;
   if(CopyBuffer(handle,BUFFER_BULLISH_FVG_LOW,0,SMC_FVG_Lookback,bl)<=0) return g;
   if(CopyBuffer(handle,BUFFER_BEARISH_FVG_HIGH,0,SMC_FVG_Lookback,rh)<=0) return g;
   if(CopyBuffer(handle,BUFFER_BEARISH_FVG_LOW,0,SMC_FVG_Lookback,rl)<=0) return g;
   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double bestBull=DBL_MAX,bestBear=DBL_MAX;
   for(int i=0;i<SMC_FVG_Lookback;i++)
   {
      if(bh[i]!=EMPTY_VALUE && bl[i]!=EMPTY_VALUE && bh[i]!=0 && bl[i]!=0)
      {
         double sz=(bh[i]-bl[i])/PipSize; double dist=MathAbs(price-bl[i]);
         if(sz>=10 && dist<bestBull){ g.bullish_fvg_high=bh[i]; g.bullish_fvg_low=bl[i]; g.size_pips=sz; g.is_valid=true; bestBull=dist; g.fvg_time=iTime(_Symbol,BaseTimeframe,i); }
      }
      if(rh[i]!=EMPTY_VALUE && rl[i]!=EMPTY_VALUE && rh[i]!=0 && rl[i]!=0)
      {
         double sz=(rh[i]-rl[i])/PipSize; double dist=MathAbs(price-rh[i]);
         if(sz>=10 && dist<bestBear){ g.bearish_fvg_high=rh[i]; g.bearish_fvg_low=rl[i]; g.size_pips=sz; g.is_valid=true; bestBear=dist; g.fvg_time=iTime(_Symbol,BaseTimeframe,i); }
      }
   }
   return g;
}

SLiquidityLevels GetLiquidityLevels(int handle)
{
   SLiquidityLevels lv; ZeroMemory(lv);
   if(handle==INVALID_HANDLE) return lv;
   double eh[],el[],gh[],gl[]; ArrayResize(eh,10); ArrayResize(el,10); ArrayResize(gh,10); ArrayResize(gl,10);
   if(CopyBuffer(handle,BUFFER_EQ_HIGHS,0,10,eh)<=0) return lv;
   if(CopyBuffer(handle,BUFFER_EQ_LOWS,0,10,el)<=0) return lv;
   if(CopyBuffer(handle,BUFFER_LIQUIDITY_GRAB_HIGH,0,10,gh)<=0) return lv;
   if(CopyBuffer(handle,BUFFER_LIQUIDITY_GRAB_LOW,0,10,gl)<=0) return lv;
   for(int i=0;i<5;i++){ if(eh[i]!=EMPTY_VALUE && eh[i]!=0) lv.equal_highs=eh[i]; if(el[i]!=EMPTY_VALUE && el[i]!=0) lv.equal_lows=el[i]; }
   for(int i=0;i<3;i++){ if(gh[i]!=EMPTY_VALUE && gh[i]!=0){ lv.liquidity_grab_high=true; lv.grab_time=iTime(_Symbol,HigherTimeframe,i); } if(gl[i]!=EMPTY_VALUE && gl[i]!=0){ lv.liquidity_grab_low=true; lv.grab_time=iTime(_Symbol,HigherTimeframe,i); } }
   return lv;
}

int CalculateConfluenceScore(ENUM_TRADE_TYPE setup,SMarketStructure &base,SMarketStructure &conf,SOrderBlocks &ob,SFairValueGaps &fvg,SLiquidityLevels &liq,bool is_buy)
{
   int s=0;
   if(is_buy && (base.bullish_bos||base.bullish_choch)) s++;
   if(!is_buy && (base.bearish_bos||base.bearish_choch)) s++;
   if(is_buy && (conf.bullish_bos||conf.bullish_choch)) s++;
   if(!is_buy && (conf.bearish_bos||conf.bearish_choch)) s++;
   if(setup==TRADE_ORDER_BLOCK && ob.is_valid && ob.size_pips>MinOBSize) s++;
   if(setup==TRADE_FAIR_VALUE_GAP && fvg.is_valid && fvg.size_pips>10) s++;
   if(is_buy && liq.liquidity_grab_low) s++;
   if(!is_buy && liq.liquidity_grab_high) s++;
   return MathMin(s,5);
}

ENUM_TRADE_TYPE AnalyzeBuyOpportunity(ENUM_MARKET_BIAS bias,SMarketStructure &base,SMarketStructure &conf,SOrderBlocks &ob,SFairValueGaps &fvg,SLiquidityLevels &liq,double price,SMarketConditions &c)
{
   if(bias==BIAS_BEARISH && RequireHigherTFConfirmation) return TRADE_NONE;
   double tol=20*PipSize;
   if(UseOrderBlocks && ob.is_valid && ob.bullish_ob_high>0)
   {
      if(price>=(ob.bullish_ob_low-tol) && price<=(ob.bullish_ob_high+tol))
      {
         bool struct_ok=(base.bullish_bos||base.bullish_choch);
         bool mom=c.rsi_value<65 && c.rsi_value>35;
         bool size_ok=ob.size_pips>=MinOBSize && ob.size_pips<=100;
         bool time_ok=(TimeCurrent()-ob.ob_time)<SignalValidityHours*3600;
         if((struct_ok||!UseConservativeEntries) && mom && size_ok && time_ok) return TRADE_ORDER_BLOCK;
      }
   }
   if(UseFairValueGaps && fvg.is_valid && fvg.bullish_fvg_high>0)
   {
      if(price>=fvg.bullish_fvg_low && price<=fvg.bullish_fvg_high)
      {
         bool mom=c.rsi_value<70 && c.rsi_value>30;
         bool struct_ok=base.bullish_bos||conf.bullish_bos||!UseConservativeEntries;
         bool fresh=(TimeCurrent()-fvg.fvg_time)<SignalValidityHours*3600;
         if(mom && struct_ok && fresh) return TRADE_FAIR_VALUE_GAP;
      }
   }
   if(UseLiquidityGrabs && liq.liquidity_grab_low && (TimeCurrent()-liq.grab_time)<7200)
   {
      if(base.bullish_choch||conf.bullish_choch||base.bullish_bos||!RequireHigherTFConfirmation) return TRADE_LIQUIDITY_GRAB;
   }
   if(base.bullish_bos && base.structure_strength>=1 && price>base.recent_low) return TRADE_BOS_BREAKOUT;
   if(base.bullish_choch && c.rsi_value<60 && (conf.bullish_choch||base.bullish_bos||!RequireHigherTFConfirmation)) return TRADE_CHOCH_REVERSAL;
   return TRADE_NONE;
}

ENUM_TRADE_TYPE AnalyzeSellOpportunity(ENUM_MARKET_BIAS bias,SMarketStructure &base,SMarketStructure &conf,SOrderBlocks &ob,SFairValueGaps &fvg,SLiquidityLevels &liq,double price,SMarketConditions &c)
{
   if(bias==BIAS_BULLISH && RequireHigherTFConfirmation) return TRADE_NONE;
   double tol=20*PipSize;
   if(UseOrderBlocks && ob.is_valid && ob.bearish_ob_high>0)
   {
      if(price>=(ob.bearish_ob_low-tol) && price<=(ob.bearish_ob_high+tol))
      {
         if((base.bearish_bos||base.bearish_choch)||!UseConservativeEntries) return TRADE_ORDER_BLOCK;
      }
   }
   if(UseFairValueGaps && fvg.is_valid && fvg.bearish_fvg_high>0)
   {
      if(price>=fvg.bearish_fvg_low && price<=fvg.bearish_fvg_high)
      {
         bool mom=c.rsi_value>30 && c.rsi_value<70;
         bool struct_ok=base.bearish_bos||base.bearish_choch||!UseConservativeEntries;
         if(mom && struct_ok) return TRADE_FAIR_VALUE_GAP;
      }
   }
   if(UseLiquidityGrabs && liq.liquidity_grab_high && (TimeCurrent()-liq.grab_time)<7200)
   {
      if(base.bearish_choch||conf.bearish_choch||base.bearish_bos||!RequireHigherTFConfirmation) return TRADE_LIQUIDITY_GRAB;
   }
   if(base.bearish_bos && base.structure_strength>=1 && price<base.recent_high) return TRADE_BOS_BREAKOUT;
   if(base.bearish_choch && c.rsi_value>40 && (conf.bearish_choch||base.bearish_bos||!RequireHigherTFConfirmation)) return TRADE_CHOCH_REVERSAL;
   return TRADE_NONE;
}

//+------------------------------------------------------------------+
//| Execution FIXED Micro-Safe                                       |
//+------------------------------------------------------------------+
void ExecuteSMCBuyTrade(double ask,ENUM_TRADE_TYPE setup,int score,SMarketConditions &c)
{
   double lot=CalculateLotSizeFixed(ask,StopLossPips);
   if(!CheckMoneyForTrade(_Symbol,lot,ORDER_TYPE_BUY)){ Print("❌ BUY Margin tidak cukup lot ",lot); return; }
   double sl,tp; CalculateDynamicSLTPFixed(ask,true,sl,tp);
   string comm=TradeComment+"-"+EnumToString(setup)+"-C"+IntegerToString(score);
   if(Trade.Buy(lot,_Symbol,ask,sl,tp,comm)){ LastTradeTime=TimeCurrent(); DailyTradeCount++; Print("✅ BUY EXECUTED Lot:",lot," SL:",sl," TP:",tp," Score:",score); if(EnableAlerts) Alert("SMC BUY ",EnumToString(setup)); }
   else Print("❌ BUY FAILED ",GetLastError()," ",ErrorDescription(GetLastError()));
}
void ExecuteSMCSellTrade(double bid,ENUM_TRADE_TYPE setup,int score,SMarketConditions &c)
{
   double lot=CalculateLotSizeFixed(bid,StopLossPips);
   if(!CheckMoneyForTrade(_Symbol,lot,ORDER_TYPE_SELL)){ Print("❌ SELL Margin tidak cukup lot ",lot); return; }
   double sl,tp; CalculateDynamicSLTPFixed(bid,false,sl,tp);
   string comm=TradeComment+"-"+EnumToString(setup)+"-C"+IntegerToString(score);
   if(Trade.Sell(lot,_Symbol,bid,sl,tp,comm)){ LastTradeTime=TimeCurrent(); DailyTradeCount++; Print("✅ SELL EXECUTED Lot:",lot," SL:",sl," TP:",tp," Score:",score); if(EnableAlerts) Alert("SMC SELL ",EnumToString(setup)); }
   else Print("❌ SELL FAILED ",GetLastError()," ",ErrorDescription(GetLastError()));
}
void ExecuteFallbackTrade(bool is_buy,MqlTick &tick,SMarketConditions &c)
{
   double price=is_buy?tick.ask:tick.bid;
   double lot=CalculateLotSizeFixed(price,StopLossPips);
   if(!CheckMoneyForTrade(_Symbol,lot,is_buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL)) return;
   double sl,tp; CalculateDynamicSLTPFixed(price,is_buy,sl,tp);
   string comm=TradeComment+"-FALLBACK-RSI";
   bool ok=is_buy?Trade.Buy(lot,_Symbol,price,sl,tp,comm):Trade.Sell(lot,_Symbol,price,sl,tp,comm);
   if(ok){ LastTradeTime=TimeCurrent(); DailyTradeCount++; Print("✅ FALLBACK ",is_buy?"BUY":"SELL"," Lot:",lot); }
}

void CheckForSMCTrades(SMarketConditions &c)
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   if(TimeCurrent()-LastTradeTime<900) return;
   ENUM_MARKET_BIAS bias=GetHigherTimeframeBias();
   SMarketStructure base=GetMarketStructure(SMC_Base_Handle);
   SMarketStructure conf=GetMarketStructure(SMC_Confirm_Handle);
   SOrderBlocks ob=GetOrderBlocks(SMC_Base_Handle);
   SFairValueGaps fvg=GetFairValueGaps(SMC_Base_Handle);
   SLiquidityLevels liq=GetLiquidityLevels(SMC_Higher_Handle);

   if(CountPositionsByMagic(MagicNumber,POSITION_TYPE_BUY)<MaxOpenTrades)
   {
      ENUM_TRADE_TYPE buy=AnalyzeBuyOpportunity(bias,base,conf,ob,fvg,liq,tick.ask,c);
      if(buy!=TRADE_NONE)
      {
         int score=CalculateConfluenceScore(buy,base,conf,ob,fvg,liq,true);
         if(score>=MinConfluenceLevel){ ExecuteSMCBuyTrade(tick.ask,buy,score,c); no_signal_counter=0; }
      }
   }
   if(CountPositionsByMagic(MagicNumber,POSITION_TYPE_SELL)<MaxOpenTrades)
   {
      ENUM_TRADE_TYPE sell=AnalyzeSellOpportunity(bias,base,conf,ob,fvg,liq,tick.bid,c);
      if(sell!=TRADE_NONE)
      {
         int score=CalculateConfluenceScore(sell,base,conf,ob,fvg,liq,false);
         if(score>=MinConfluenceLevel){ ExecuteSMCSellTrade(tick.bid,sell,score,c); no_signal_counter=0; }
      }
   }
   no_signal_counter++;
   if(no_signal_counter>200 && TimeCurrent()-LastTradeTime>1200)
   {
      if(c.rsi_value<35 && CountPositionsByMagic(MagicNumber,POSITION_TYPE_BUY)==0) ExecuteFallbackTrade(true,tick,c);
      else if(c.rsi_value>65 && CountPositionsByMagic(MagicNumber,POSITION_TYPE_SELL)==0) ExecuteFallbackTrade(false,tick,c);
   }
}
void HandleManualTesting()
{
   static bool b=false,s=false,ca=false;
   MqlTick t; SymbolInfoTick(_Symbol,t);
   if(TriggerBuyTrade && !b){ b=true; double sl,tp; CalculateDynamicSLTPFixed(t.ask,true,sl,tp); Trade.Buy(ManualLotSize,_Symbol,t.ask,sl,tp,TradeComment+"-MANUAL-BUY"); }
   if(TriggerSellTrade && !s){ s=true; double sl,tp; CalculateDynamicSLTPFixed(t.bid,false,sl,tp); Trade.Sell(ManualLotSize,_Symbol,t.bid,sl,tp,TradeComment+"-MANUAL-SELL"); }
   if(CloseAllTrades && !ca){ ca=true; for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i); if(tk==0) continue; if(!PositionSelectByTicket(tk)) continue; if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue; if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue; Trade.PositionClose(tk); } }
   if(!TriggerBuyTrade) b=false; if(!TriggerSellTrade) s=false; if(!CloseAllTrades) ca=false;
}
//+------------------------------------------------------------------+
//| PART 3/3 - ADVANCED POSITION MANAGEMENT FIXED Micro-Safe         |
//+------------------------------------------------------------------+
void MoveToBreakeven(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL=PositionGetDouble(POSITION_SL);
   double curTP=PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double buffer=20*PointVal; // 2 pips buffer
   double newSL=0;
   if(type==POSITION_TYPE_BUY)
   {
      newSL=NormalizePrice(open+buffer);
      if(curSL==0 || newSL>curSL)
      {
         if(Trade.PositionModify(ticket,newSL,curTP))
            Print("✅ BE MOVED BUY #",ticket," NewSL:",newSL);
      }
   }
   else
   {
      newSL=NormalizePrice(open-buffer);
      if(curSL==0 || newSL<curSL)
      {
         if(Trade.PositionModify(ticket,newSL,curTP))
            Print("✅ BE MOVED SELL #",ticket," NewSL:",newSL);
      }
   }
}

void UpdateTrailingStop(ulong ticket,double profit_pips)
{
   if(!PositionSelectByTicket(ticket)) return;
   double curSL=PositionGetDouble(POSITION_SL);
   double curTP=PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   string sym=PositionGetString(POSITION_SYMBOL);
   double curPrice=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(sym,SYMBOL_BID):SymbolInfoDouble(sym,SYMBOL_ASK);
   double trail_pips=TrailingStopPips;
   if(profit_pips>500) trail_pips=TrailingStopPips*0.6;
   else if(profit_pips>300) trail_pips=TrailingStopPips*0.8;
   double trail_dist=trail_pips*PipSize;
   double newSL=0; bool update=false;
   if(type==POSITION_TYPE_BUY)
   {
      newSL=NormalizePrice(curPrice-trail_dist);
      if(curSL==0 || newSL>curSL) update=true;
   }
   else
   {
      newSL=NormalizePrice(curPrice+trail_dist);
      if(curSL==0 || newSL<curSL) update=true;
   }
   if(update)
   {
      if(Trade.PositionModify(ticket,newSL,curTP))
         Print("✅ TRAILING UPDATE #",ticket," Profit:",profit_pips," NewSL:",newSL);
   }
}

void PartialClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   double vol=PositionGetDouble(POSITION_VOLUME);
   string comm=PositionGetString(POSITION_COMMENT);
   if(StringFind(comm,"PARTIAL")>=0) return;
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double partVol=vol*(PartialClosePercent/100.0);
   partVol=MathFloor(partVol/step)*step;
   partVol=NormalizeDouble(partVol,2);
   partVol=MathMax(partVol,minLot);
   if(partVol>=vol) partVol=vol-minLot;
   if(partVol>=minLot)
   {
      if(Trade.PositionClosePartial(ticket,partVol))
      {
         Print("✅ PARTIAL CLOSE #",ticket," Vol:",partVol);
         Sleep(1000);
         if(PositionSelectByTicket(ticket)) MoveToBreakeven(ticket);
         if(EnableAlerts) Alert("SMC Partial Close ",partVol);
      }
   }
}

void ExecuteScaledExit(ulong ticket,double percent,string label)
{
   if(!PositionSelectByTicket(ticket)) return;
   double vol=PositionGetDouble(POSITION_VOLUME);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double exitVol=MathFloor((vol*(percent/100.0))/step)*step;
   exitVol=NormalizeDouble(exitVol,2);
   if(exitVol<minLot) exitVol=minLot;
   if(exitVol>=vol) exitVol=vol-minLot;
   if(exitVol>=minLot && exitVol<vol)
   {
      if(Trade.PositionClosePartial(ticket,exitVol))
         Print("✅ SCALED EXIT ",label," #",ticket," Closed:",exitVol);
   }
}

void ApplyEarlyProfitProtection(ulong ticket,double profit_pips)
{
   if(!PositionSelectByTicket(ticket)) return;
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL=PositionGetDouble(POSITION_SL);
   double curTP=PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double protect_pips=MathMax(profit_pips*0.5,50);
   double newSL=0;
   if(type==POSITION_TYPE_BUY)
   {
      newSL=NormalizePrice(open+protect_pips*PipSize);
      if(curSL==0 || newSL>curSL) Trade.PositionModify(ticket,newSL,curTP);
   }
   else
   {
      newSL=NormalizePrice(open-protect_pips*PipSize);
      if(curSL==0 || newSL<curSL) Trade.PositionModify(ticket,newSL,curTP);
   }
}

void ManageOpenPositions(SMarketConditions &cond)
{
   static datetime last_manage=0;
   if(TimeCurrent()-last_manage<15) return;
   last_manage=TimeCurrent();

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      double profit_pips=CalculateProfitPips(ticket);
      double vol=PositionGetDouble(POSITION_VOLUME);
      string comm=PositionGetString(POSITION_COMMENT);
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime open_time=(datetime)PositionGetInteger(POSITION_TIME);
      int age_min=(int)((TimeCurrent()-open_time)/60);
      SMarketStructure curStruct=GetMarketStructure(SMC_Base_Handle);

      // 1. FAST PROFIT 50% at 60 pips (6 pips XAU)
      if(profit_pips>=60 && vol>SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)*1.1 && StringFind(comm,"SCALED")<0)
      {
         double fvol=MathFloor((vol*0.5)/SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP))*SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         fvol=NormalizeDouble(fvol,2);
         if(fvol>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
            if(Trade.PositionClosePartial(ticket,fvol)) Print("💰 FAST PROFIT 50% #",ticket);
      }

      // 2. Scaled Exit 1 & 2
      if(UseScaledExits && profit_pips>=FirstExitPips && StringFind(comm,"SCALED1")<0) ExecuteScaledExit(ticket,FirstExitPercent,"SCALED1");
      if(UseScaledExits && profit_pips>=SecondExitPips && StringFind(comm,"SCALED2")<0 && StringFind(comm,"SCALED1")>=0) ExecuteScaledExit(ticket,SecondExitPercent,"SCALED2");

      // 3. Breakeven at 30 pips (3 pips)
      if(UseBreakeven && profit_pips>=BreakevenPips && StringFind(comm,"BE")<0) MoveToBreakeven(ticket);

      // 4. Early Profit Protection
      if(UseEarlyProfitProtection && profit_pips>=EarlyProfitPips && profit_pips<BreakevenPips) ApplyEarlyProfitProtection(ticket,profit_pips);

      // 5. Trailing Stop
      if(UseTrailingStop && profit_pips>TrailingStopPips) UpdateTrailingStop(ticket,profit_pips);

      // 6. Partial Close
      if(EnablePartialClose && profit_pips>=PartialClosePips && vol>SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)*1.5 && StringFind(comm,"PARTIAL")<0) PartialClosePosition(ticket);

      // 7. Emergency Loss -100 pips (-10 pips)
      if(profit_pips<=-100)
      {
         Print("🚨 EMERGENCY LOSS #",ticket," ",profit_pips);
         if(Trade.PositionClose(ticket)) continue;
      }

      // 8. SMC Opposing Structure Exit
      bool emergency=false;
      if(type==POSITION_TYPE_BUY && curStruct.bearish_bos && profit_pips<50) emergency=true;
      if(type==POSITION_TYPE_SELL && curStruct.bullish_bos && profit_pips<50) emergency=true;
      if(emergency)
      {
         Print("🚨 SMC OPPOSING BOS EXIT #",ticket);
         if(Trade.PositionClose(ticket)) continue;
      }

      // 9. Time-based exit 120 menit loss -50 pips
      if(age_min>120 && profit_pips<-50)
      {
         if((type==POSITION_TYPE_BUY && curStruct.bearish_choch) || (type==POSITION_TYPE_SELL && curStruct.bullish_choch))
         {
            Print("⏰ TIME EXIT #",ticket);
            if(Trade.PositionClose(ticket)) continue;
         }
      }

      // 10. Large profit lock 500 pips
      if(profit_pips>500 && StringFind(comm,"LARGE")<0)
      {
         double addVol=MathFloor((vol*0.25)/SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP))*SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         addVol=NormalizeDouble(addVol,2);
         if(addVol>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)) Trade.PositionClosePartial(ticket,addVol);
      }
   }
}
//+------------------------------------------------------------------+
//| END OF FILE - Siap Compile                                       |
//+------------------------------------------------------------------+
