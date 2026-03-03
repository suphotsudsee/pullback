//+------------------------------------------------------------------+
//|  OrderExecutor_Pullback.mq4                                      |
//|  XAUUSD Pullback Entry at M5                                  |
//|  v5.0                                                            |
//|                                                                  |
//|  Logic:                                                          |
//|   H4 = trend direction (bias)                                    |
//|   H1 = swing structure + pullback zone                          |
//|   M15 = pullback confirmation                                    |
//|   M5  = entry trigger (candle pattern)                          |
//+------------------------------------------------------------------+
#property copyright "AI XAUUSD Pullback"
#property version   "5.00"
#property strict

// Inputs
input string   ServerURL         = "http://127.0.0.1:5000";
input int      PollInterval      = 1;
input int      MagicNumber       = 55555;
input int      MaxSlippage       = 50;
input bool     EnableTrading     = true;
input bool     ReadCommandFromFile = true;
input string   CommandFileName     = "pullback_command.json";
input bool     UseCommonFiles      = false;
input bool     SyncDisplayWithSender = true;
input string   MarketDataFileName    = "pullback_market_data.json";

// ATR settings
input int      ATR_Period        = 14;
input double   SL_ATR_Multi      = 1.5;     // SL = ATR(M5)  1.5
input double   TP_ATR_Multi      = 2.0;     // TP = ATR(M5)  2.0

// Trailing stop
input bool     UseTrailingStop   = true;
input double   Trail_ATR_Multi   = 1.0;
input double   Trail_Step_Multi  = 0.3;

// XAUUSD filters
input double   MinATR_M5         = 1.5;     // ATR M5  ($1.5)
input double   MaxSpreadUSD      = 3.0;     // spread  ($3)
input bool     UseBreakEven      = true;    //  SL  breakeven  = SL
input double   BreakEvenBuffer   = 0.50;    // buffer $0.50  BE

// Risk (fixed)
const double   FIXED_LOT         = 0.01;
const int      MAX_DAILY_TRADES  = 3;
const double   MAX_LOSS_PERCENT  = 10.0;

// Runtime state
double   g_StartBalance  = 0;
int      g_DailyTrades   = 0;
datetime g_LastDay       = 0;
bool     g_DailyBlocked  = false;
string   g_LastCmdID     = "";
string   g_SLLineName    = "PB_SL_LINE";
string   g_TPLineName    = "PB_TP_LINE";

bool ReadCommandFromFileBridge(string &outJson)
{
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(UseCommonFiles) flags |= FILE_COMMON;

   int h = FileOpen(CommandFileName, flags);
   if(h == INVALID_HANDLE) return false;

   int sz = (int)FileSize(h);
   if(sz <= 0) { FileClose(h); return false; }
   outJson = FileReadString(h, sz);
   FileClose(h);
   return StringLen(outJson) > 4;
}

bool ReadMarketDataFromFileBridge(string &outJson)
{
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(UseCommonFiles) flags |= FILE_COMMON;

   int h = FileOpen(MarketDataFileName, flags);
   if(h == INVALID_HANDLE) return false;

   int sz = (int)FileSize(h);
   if(sz <= 0) { FileClose(h); return false; }
   outJson = FileReadString(h, sz);
   FileClose(h);
   return StringLen(outJson) > 8;
}

string ExtractObject(string json, string key)
{
   string token = "\"" + key + "\":";
   int p = StringFind(json, token);
   if(p < 0) return "";
   p += StringLen(token);
   while(p < StringLen(json) && StringSubstr(json, p, 1) == " ")
      p++;
   if(StringSubstr(json, p, 1) != "{") return "";

   int start = p;
   int depth = 0;
   for(int i = p; i < StringLen(json); i++) {
      string ch = StringSubstr(json, i, 1);
      if(ch == "{") depth++;
      else if(ch == "}") {
         depth--;
         if(depth == 0)
            return StringSubstr(json, start, i - start + 1);
      }
   }
   return "";
}

string TrendFromSection(string sec, double fallbackPrice)
{
   double e20  = ExtractDouble(sec, "ema20");
   double e50  = ExtractDouble(sec, "ema50");
   double e200 = ExtractDouble(sec, "ema200");

   if(e20 <= 0 || e50 <= 0 || e200 <= 0) {
      if(fallbackPrice <= 0) return "MIXED";
      return "MIXED";
   }
   if(e20 > e50 && e50 > e200) return "UP";
   if(e20 < e50 && e50 < e200) return "DOWN";
   return "MIXED";
}

void ClearCommandFileBridge()
{
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(UseCommonFiles) flags |= FILE_COMMON;
   int h = FileOpen(CommandFileName, flags);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, "{\"action\":\"none\"}\r\n");
   FileClose(h);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsTradeAllowed()) {
      Alert("Enable AutoTrading first.");
      return INIT_FAILED;
   }
   g_StartBalance = AccountBalance();
   g_LastDay      = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   EventSetTimer(PollInterval);

   double atr_m5 = iATR(NULL, PERIOD_M5, ATR_Period, 1);
   Print("Pullback EA v5 started.");
   Print("   ATR M5: $", DoubleToString(atr_m5, 2));
   Print("   SL    : $", DoubleToString(atr_m5 * SL_ATR_Multi, 2));
   Print("   TP    : $", DoubleToString(atr_m5 * TP_ATR_Multi, 2));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectDelete(0, g_SLLineName);
   ObjectDelete(0, g_TPLineName);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(!EnableTrading) return;
   CheckDailyReset();

   if(UseTrailingStop) RunTrailingStop();
   if(UseBreakEven)    RunBreakEven();

   if(!PassRiskCheck()) return;

   if(ReadCommandFromFile) {
      string fjson = "";
      if(ReadCommandFromFileBridge(fjson)) {
         if(StringFind(fjson, "\"none\"") < 0) {
            string cmdId = ExtractString(fjson, "cmd_id");
            if(StringLen(cmdId) == 0 || cmdId != g_LastCmdID) {
               if(StringLen(cmdId) > 0) g_LastCmdID = cmdId;
               ProcessCommand(fjson);
               ClearCommandFileBridge();
               return;
            }
         }
      }
   }

   // Poll AI command
   string url = ServerURL + "/get_command?magic=" + IntegerToString(MagicNumber);
   char   post[], result[];
   string resHdr, reqHdr = "Content-Type: application/json\r\n";
   ArrayResize(post, 0);

   int res = WebRequest("GET", url, reqHdr, 3000, post, result, resHdr);
   if(res != 200) return;

   string resp = CharArrayToString(result);
   if(StringLen(resp) < 5)               return;
   if(StringFind(resp, "\"none\"") >= 0) return;

   ProcessCommand(resp);
}

//+------------------------------------------------------------------+
void OnTick() { UpdateSLTPLines(); UpdateChart(); }

void UpdateSLTPLines()
{
   int bestTicket = -1;
   datetime bestOpen = 0;
   double sl = 0.0, tp = 0.0;
   int orderType = -1;

   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      if(OrderOpenTime() >= bestOpen) {
         bestOpen   = OrderOpenTime();
         bestTicket = OrderTicket();
         sl         = OrderStopLoss();
         tp         = OrderTakeProfit();
         orderType  = OrderType();
      }
   }

   if(bestTicket < 0) {
      ObjectDelete(0, g_SLLineName);
      ObjectDelete(0, g_TPLineName);
      return;
   }

   color slColor = (orderType == OP_BUY) ? clrTomato : clrAqua;
   color tpColor = (orderType == OP_BUY) ? clrLimeGreen : clrOrange;

   if(sl > 0) {
      if(ObjectFind(0, g_SLLineName) < 0)
         ObjectCreate(0, g_SLLineName, OBJ_HLINE, 0, 0, sl);
      ObjectSetDouble(0, g_SLLineName, OBJPROP_PRICE1, sl);
      ObjectSetInteger(0, g_SLLineName, OBJPROP_COLOR, slColor);
      ObjectSetInteger(0, g_SLLineName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, g_SLLineName, OBJPROP_WIDTH, 2);
      ObjectSetString(0, g_SLLineName, OBJPROP_TEXT, "SL #" + IntegerToString(bestTicket));
   } else {
      ObjectDelete(0, g_SLLineName);
   }

   if(tp > 0) {
      if(ObjectFind(0, g_TPLineName) < 0)
         ObjectCreate(0, g_TPLineName, OBJ_HLINE, 0, 0, tp);
      ObjectSetDouble(0, g_TPLineName, OBJPROP_PRICE1, tp);
      ObjectSetInteger(0, g_TPLineName, OBJPROP_COLOR, tpColor);
      ObjectSetInteger(0, g_TPLineName, OBJPROP_STYLE, STYLE_DASHDOT);
      ObjectSetInteger(0, g_TPLineName, OBJPROP_WIDTH, 2);
      ObjectSetString(0, g_TPLineName, OBJPROP_TEXT, "TP #" + IntegerToString(bestTicket));
   } else {
      ObjectDelete(0, g_TPLineName);
   }
}

//+------------------------------------------------------------------+
double GetATR_M5()
{
   return iATR(NULL, PERIOD_M5, ATR_Period, 1);
}

//+------------------------------------------------------------------+
//  BREAK-EVEN: move SL to entry +/- buffer once price reaches 1R
//+------------------------------------------------------------------+
void RunBreakEven()
{
   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber)           continue;
      if(OrderSymbol() != Symbol())                   continue;

      double openPrice = OrderOpenPrice();
      double curSL     = OrderStopLoss();
      double curTP     = OrderTakeProfit();
      double slDist    = MathAbs(openPrice - curSL);
      double beTarget  = openPrice + BreakEvenBuffer;

      if(OrderType() == OP_BUY) {
         //  Bid  openPrice + slDist (= reward  risk)
         if(Bid >= openPrice + slDist && curSL < beTarget) {
            double newSL = NormalizeDouble(beTarget, Digits);
            if(OrderModify(OrderTicket(), openPrice, newSL, curTP, 0, clrYellow))
               Print(" BreakEven BUY #", OrderTicket(),
                     " SL  ", DoubleToString(newSL,2));
         }
      }
      else if(OrderType() == OP_SELL) {
         double beTargetSell = openPrice - BreakEvenBuffer;
         if(Ask <= openPrice - slDist && (curSL == 0 || curSL > beTargetSell)) {
            double newSL = NormalizeDouble(beTargetSell, Digits);
            if(OrderModify(OrderTicket(), openPrice, newSL, curTP, 0, clrYellow))
               Print(" BreakEven SELL #", OrderTicket(),
                     " SL  ", DoubleToString(newSL,2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//  TRAILING STOP
//+------------------------------------------------------------------+
void RunTrailingStop()
{
   double atr = GetATR_M5();
   if(atr <= 0) return;

   double trailDist = NormalizeDouble(atr * Trail_ATR_Multi,  Digits);
   double trailStep = NormalizeDouble(atr * Trail_Step_Multi, Digits);

   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber)           continue;
      if(OrderSymbol() != Symbol())                   continue;

      double curSL     = OrderStopLoss();
      double openPrice = OrderOpenPrice();
      double curTP     = OrderTakeProfit();

      if(OrderType() == OP_BUY) {
         double newSL = NormalizeDouble(Bid - trailDist, Digits);
         if(newSL > curSL + trailStep) {
            if(OrderModify(OrderTicket(), openPrice, newSL, curTP, 0, clrAqua))
               Print(" Trail BUY #", OrderTicket(),
                     " SL: ", DoubleToString(curSL,2), "", DoubleToString(newSL,2));
         }
      }
      else if(OrderType() == OP_SELL) {
         double newSL = NormalizeDouble(Ask + trailDist, Digits);
         if(curSL == 0 || newSL < curSL - trailStep) {
            if(OrderModify(OrderTicket(), openPrice, newSL, curTP, 0, clrOrange))
               Print(" Trail SELL #", OrderTicket(),
                     " SL: ", DoubleToString(curSL,2), "", DoubleToString(newSL,2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//  RISK CHECK
//+------------------------------------------------------------------+
bool PassRiskCheck()
{
   double lossPct = (g_StartBalance > 0)
                    ? (g_StartBalance - AccountEquity()) / g_StartBalance * 100.0 : 0;

   if(lossPct >= MAX_LOSS_PERCENT) {
      if(!g_DailyBlocked) {
         g_DailyBlocked = true;
         Alert("  ", DoubleToString(lossPct,2), "%  ", MAX_LOSS_PERCENT, "%");
         Print("BLOCKED");
      }
      return false;
   }
   if(g_DailyBlocked)                 return false;
   if(g_DailyTrades >= MAX_DAILY_TRADES) {
      Print("Max daily trades reached (3).");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today > g_LastDay) {
      Print("New day reset (previous trades: ", g_DailyTrades, ").");
      g_DailyTrades  = 0;
      g_DailyBlocked = false;
      g_LastDay      = today;
      g_StartBalance = AccountBalance();
   }
}

//+------------------------------------------------------------------+
//  PROCESS COMMAND
//+------------------------------------------------------------------+
void ProcessCommand(string json)
{
   string action = ExtractString(json, "action");
   string reason = ExtractString(json, "reason");
   string setup  = ExtractString(json, "setup");
   if(StringLen(action) == 0) {
      Print("Command parse failed: action is empty | json=", json);
      return;
   }
   bool   isManual = (setup == "MANUAL");

   string prefix = isManual ? "MANUAL" : "AI Pullback";
   Print(prefix, ": ", action, " | Setup=", setup, " | ", reason);

   if(action == "BUY")        ExecuteBuy(reason, setup, isManual);
   else if(action == "SELL")  ExecuteSell(reason, setup, isManual);
   else if(action == "CLOSE") ExecuteClose(json);
}

//+------------------------------------------------------------------+
//  EXECUTE BUY  (AI Pullback  Manual)
//+------------------------------------------------------------------+
void ExecuteBuy(string reason, string setup, bool isManual = false)
{
   double atr = GetATR_M5();

   // Manual order:  ATR filter  warn
   if(!isManual && atr < MinATR_M5) {
      Print(" ATR M5=$", DoubleToString(atr,2), "    (AI)");
      return;
   }
   // Spread filter:  manual  AI   manual 
   double spreadUSD = Ask - Bid;
   if(spreadUSD > MaxSpreadUSD) {
      if(!isManual) {
         Print(" Spread $", DoubleToString(spreadUSD,2), "    (AI)");
         return;
      }
      Print(" Manual BUY: Spread $", DoubleToString(spreadUSD,2), "  ");
   }

   RefreshRates();
   double price = Ask;
   double sl    = NormalizeDouble(price - atr * SL_ATR_Multi, Digits);
   double tp    = NormalizeDouble(price + atr * TP_ATR_Multi, Digits);

   //  StopLevel
   double stopLv = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(price - sl < stopLv) sl = NormalizeDouble(price - stopLv * 1.5, Digits);
   if(tp - price < stopLv) tp = NormalizeDouble(price + stopLv * 1.5, Digits);

   string tag = isManual ? "MANUAL-BUY" : "AI-PB-BUY [" + setup + "]";
   Print(" BUY", (isManual?" [MANUAL]":""), " | Entry=", DoubleToString(price,2),
         " | SL=", DoubleToString(sl,2), " ($", DoubleToString(price-sl,2), ")",
         " | TP=", DoubleToString(tp,2), " ($", DoubleToString(tp-price,2), ")",
         " | ATR=$", DoubleToString(atr,2));

   int ticket = OrderSend(Symbol(), OP_BUY, FIXED_LOT, price,
                          MaxSlippage, sl, tp,
                          tag + ": " + reason,
                          MagicNumber, 0, clrGreen);

   if(ticket > 0) {
      g_DailyTrades++;
      Print(" BUY #", ticket, (isManual?" [MANUAL]":""),
            " |  ", g_DailyTrades, "/", MAX_DAILY_TRADES);
      SendResult(ticket, "BUY", true, "", isManual ? "MANUAL" : "AI");
   } else {
      Print("BUY failed: ", GetErrMsg());
      SendResult(0, "BUY", false, GetErrMsg(), isManual ? "MANUAL" : "AI");
   }
}

//+------------------------------------------------------------------+
//  EXECUTE SELL  (AI Pullback  Manual)
//+------------------------------------------------------------------+
void ExecuteSell(string reason, string setup, bool isManual = false)
{
   double atr = GetATR_M5();

   if(!isManual && atr < MinATR_M5) {
      Print(" ATR M5=$", DoubleToString(atr,2), "    (AI)");
      return;
   }
   double spreadUSD = Ask - Bid;
   if(spreadUSD > MaxSpreadUSD) {
      if(!isManual) {
         Print(" Spread $", DoubleToString(spreadUSD,2), "    (AI)");
         return;
      }
      Print(" Manual SELL: Spread $", DoubleToString(spreadUSD,2), "  ");
   }

   RefreshRates();
   double price = Bid;
   double sl    = NormalizeDouble(price + atr * SL_ATR_Multi, Digits);
   double tp    = NormalizeDouble(price - atr * TP_ATR_Multi, Digits);

   double stopLv = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(sl - price < stopLv) sl = NormalizeDouble(price + stopLv * 1.5, Digits);
   if(price - tp < stopLv) tp = NormalizeDouble(price - stopLv * 1.5, Digits);

   string tag = isManual ? "MANUAL-SELL" : "AI-PB-SELL [" + setup + "]";
   Print(" SELL", (isManual?" [MANUAL]":""), " | Entry=", DoubleToString(price,2),
         " | SL=", DoubleToString(sl,2), " ($", DoubleToString(sl-price,2), ")",
         " | TP=", DoubleToString(tp,2), " ($", DoubleToString(price-tp,2), ")",
         " | ATR=$", DoubleToString(atr,2));

   int ticket = OrderSend(Symbol(), OP_SELL, FIXED_LOT, price,
                          MaxSlippage, sl, tp,
                          tag + ": " + reason,
                          MagicNumber, 0, clrRed);

   if(ticket > 0) {
      g_DailyTrades++;
      Print(" SELL #", ticket, (isManual?" [MANUAL]":""),
            " |  ", g_DailyTrades, "/", MAX_DAILY_TRADES);
      SendResult(ticket, "SELL", true, "", isManual ? "MANUAL" : "AI");
   } else {
      Print("SELL failed: ", GetErrMsg());
      SendResult(0, "SELL", false, GetErrMsg(), isManual ? "MANUAL" : "AI");
   }
}

//+------------------------------------------------------------------+
void ExecuteClose(string json)
{
   int t = (int)ExtractDouble(json, "close_ticket");
   if(t > 0) CloseSingle(t);
   else       CloseAll();
}

void CloseSingle(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;
   RefreshRates();
   bool ok = (OrderType()==OP_BUY)
             ? OrderClose(ticket, OrderLots(), Bid, MaxSlippage, clrYellow)
             : OrderClose(ticket, OrderLots(), Ask, MaxSlippage, clrYellow);
   Print(ok ? "Closed #" : "Close failed #", ticket);
}

void CloseAll()
{
   for(int i = OrdersTotal()-1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() == MagicNumber) CloseSingle(OrderTicket());
   }
}

//+------------------------------------------------------------------+
//  CHART DISPLAY
//+------------------------------------------------------------------+
void UpdateChart()
{
   double atr_h4  = iATR(NULL, PERIOD_H4, 14, 1);
   double atr_h1  = iATR(NULL, PERIOD_H1, 14, 1);
   double atr_m15 = iATR(NULL, PERIOD_M15,14, 1);
   double atr_m5  = iATR(NULL, PERIOD_M5, 14, 1);

   double rsi_h4  = iRSI(NULL, PERIOD_H4, 14, PRICE_CLOSE, 0);
   double rsi_h1  = iRSI(NULL, PERIOD_H1, 14, PRICE_CLOSE, 0);
   double rsi_m15 = iRSI(NULL, PERIOD_M15,14, PRICE_CLOSE, 0);
   double rsi_m5  = iRSI(NULL, PERIOD_M5, 14, PRICE_CLOSE, 0);

   double ema_h4  = iMA(NULL, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema_h1  = iMA(NULL, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE, 0);

   double lossPct = (g_StartBalance > 0)
                    ? (g_StartBalance - AccountEquity()) / g_StartBalance * 100.0 : 0;

   string h4Trend = (Bid > ema_h4) ? "UP" : "DOWN";
   string h1Trend = (Bid > ema_h1) ? "UP" : "DOWN";
   double dispBid = Bid;
   double dispAsk = Ask;
   double spread  = Ask - Bid;

   if(SyncDisplayWithSender) {
      string snap = "";
      if(ReadMarketDataFromFileBridge(snap)) {
         double b = ExtractDouble(snap, "bid");
         double a = ExtractDouble(snap, "ask");
         double s = ExtractDouble(snap, "spread_usd");
         if(b > 0) dispBid = b;
         if(a > 0) dispAsk = a;
         if(s > 0) spread = s;

         string h4 = ExtractObject(snap, "h4");
         string h1 = ExtractObject(snap, "h1");
         string m15= ExtractObject(snap, "m15");
         string m5 = ExtractObject(snap, "m5");

         if(StringLen(h4) > 0) {
            double v = ExtractDouble(h4, "atr"); if(v > 0) atr_h4 = v;
            v = ExtractDouble(h4, "rsi"); if(v > 0) rsi_h4 = v;
            h4Trend = TrendFromSection(h4, dispBid);
         }
         if(StringLen(h1) > 0) {
            double v = ExtractDouble(h1, "atr"); if(v > 0) atr_h1 = v;
            v = ExtractDouble(h1, "rsi"); if(v > 0) rsi_h1 = v;
            h1Trend = TrendFromSection(h1, dispBid);
         }
         if(StringLen(m15) > 0) {
            double v = ExtractDouble(m15, "atr"); if(v > 0) atr_m15 = v;
            v = ExtractDouble(m15, "rsi"); if(v > 0) rsi_m15 = v;
         }
         if(StringLen(m5) > 0) {
            double v = ExtractDouble(m5, "atr"); if(v > 0) atr_m5 = v;
            v = ExtractDouble(m5, "rsi"); if(v > 0) rsi_m5 = v;
         }
      }
   }

   string status;
   if(g_DailyBlocked)                    status = "BLOCKED";
   else if(g_DailyTrades >= MAX_DAILY_TRADES) status = "MAX DAILY TRADES REACHED";
   else if(atr_m5 < MinATR_M5)           status = "ATR M5 TOO LOW";
   else if(Ask - Bid > MaxSpreadUSD)      status = "SPREAD TOO HIGH";
   else                                   status = "WATCHING FOR PULLBACK";

   Comment(
      "XAUUSD Pullback AI v5\n",
      "Price : $", DoubleToString(dispBid,2), " / $", DoubleToString(dispAsk,2), "\n",
      "Spread: $", DoubleToString(spread,2), "\n",
      "\n",
      "TIMEFRAME ANALYSIS\n",
      "H4  : ", h4Trend, "  RSI=", DoubleToString(rsi_h4,0),  "  ATR=$", DoubleToString(atr_h4,2), "\n",
      "H1  : ", h1Trend, "  RSI=", DoubleToString(rsi_h1,0),  "  ATR=$", DoubleToString(atr_h1,2), "\n",
      "M15 : RSI=",         DoubleToString(rsi_m15,0),         "  ATR=$", DoubleToString(atr_m15,2), "\n",
      "M5  : RSI=",         DoubleToString(rsi_m5,0),          "  ATR=$", DoubleToString(atr_m5,2), " [ENTRY]\n",
      "\n",
      "SL  : $", DoubleToString(atr_m5*SL_ATR_Multi,2), " (ATR M5 x ", SL_ATR_Multi, ")\n",
      "TP  : $", DoubleToString(atr_m5*TP_ATR_Multi,2), " (ATR M5 x ", TP_ATR_Multi, ")\n",
      "Trail: $", DoubleToString(atr_m5*Trail_ATR_Multi,2), "\n",
      "\n",
      "Loss: ", DoubleToString(lossPct,2), "%/", MAX_LOSS_PERCENT, "%\n",
      "Trades Today: ", g_DailyTrades, "/", MAX_DAILY_TRADES, "\n",
      "\n",
      status
   );
}

//+------------------------------------------------------------------+
void SendResult(int ticket, string tp, bool ok, string err, string source = "AI")
{
   string json = "{\"ticket\":" + IntegerToString(ticket);
   json += ",\"type\":\"" + tp + "\"";
   json += ",\"success\":" + (ok?"true":"false");
   json += ",\"error\":\"" + err + "\"";
   json += ",\"source\":\"" + source + "\"";
   json += ",\"time\":\"" + TimeToString(TimeCurrent()) + "\"}";

   char   post[], result[];
   string resHdr, reqHdr = "Content-Type: application/json\r\n";
   ArrayResize(post, StringToCharArray(json, post, 0, WHOLE_ARRAY, CP_UTF8) - 1);
   WebRequest("POST", ServerURL + "/order_result", reqHdr, 3000, post, result, resHdr);
}

string ExtractString(string json, string key)
{
   string s = "\"" + key + "\"";
   int p = StringFind(json, s); if(p<0) return "";
   p += StringLen(s);
   while(p < StringLen(json) && StringSubstr(json,p,1) == " ") p++;
   if(p >= StringLen(json) || StringSubstr(json,p,1) != ":") return "";
   p++;
   while(p < StringLen(json) && StringSubstr(json,p,1) == " ") p++;
   if(p >= StringLen(json) || StringSubstr(json,p,1) != "\"") return "";
   p++;
   int e = StringFind(json,"\"",p);
   return(e<0)?"":StringSubstr(json,p,e-p);
}

double ExtractDouble(string json, string key)
{
   string s = "\"" + key + "\"";
   int p = StringFind(json, s); if(p<0) return 0;
   p += StringLen(s);
   while(p < StringLen(json) && StringSubstr(json,p,1) == " ") p++;
   if(p >= StringLen(json) || StringSubstr(json,p,1) != ":") return 0;
   p++;
   while(p < StringLen(json) && StringSubstr(json,p,1) == " ") p++;
   string val = "";
   for(int i=p;i<StringLen(json);i++){
      string ch=StringSubstr(json,i,1);
      if(ch==","||ch=="}"||ch==" ")break;
      val+=ch;
   }
   return StringToDouble(val);
}

string GetErrMsg()
{
   int c = GetLastError();
   if(c==129) return "Invalid price";
   if(c==130) return "Invalid stops";
   if(c==131) return "Invalid volume";
   if(c==132) return "Market closed";
   if(c==134) return "Not enough money";
   if(c==138) return "Requote";
   return "Err#"+IntegerToString(c);
}


