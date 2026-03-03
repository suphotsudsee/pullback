//+------------------------------------------------------------------+
//|  DataSender_MTF.mq4                                              |
//|  Multi-Timeframe Data Sender for XAUUSD Pullback               |
//|  Sends H4, H1, M15, and M5 data to local AI server            |
//|  v5.0                                                            |
//+------------------------------------------------------------------+
#property copyright "AI XAUUSD Pullback System"
#property version   "5.00"
#property strict

input string   ServerURL     = "http://127.0.0.1:5000";
input int      SendInterval  = 3;    // Send every 3 seconds
input int      CandleCount   = 30;   // Candle count per timeframe

double   g_StartBalance = 0;
datetime g_LastDay      = 0;
string   g_ServerURL    = "";
string   g_AltServerURL = "";

string NormalizeBaseURL(string url)
{
   StringReplace(url, " ", "");
   StringReplace(url, "\t", "");
   StringReplace(url, "\r", "");
   StringReplace(url, "\n", "");
   StringReplace(url, "\"", "");
   StringReplace(url, "'", "");
   while(StringLen(url) > 0 && StringGetChar(url, StringLen(url)-1) == '/')
      url = StringSubstr(url, 0, StringLen(url)-1);
   return url;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(Symbol(), "XAU") < 0 && StringFind(Symbol(), "GOLD") < 0)
      Print("Warning: This EA is designed for XAUUSD.");

   g_StartBalance = AccountBalance();
   g_LastDay      = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   g_ServerURL = NormalizeBaseURL(ServerURL);
   g_AltServerURL = g_ServerURL;
   if(StringFind(g_AltServerURL, "127.0.0.1") >= 0)
      StringReplace(g_AltServerURL, "127.0.0.1", "localhost");
   else if(StringFind(g_AltServerURL, "localhost") >= 0)
      StringReplace(g_AltServerURL, "localhost", "127.0.0.1");

   EventSetTimer(SendInterval);

   Print("MTF DataSender v5 started.");
   Print("   Timeframes: H4, H1, M15, M5");
   Print("   Strategy  : Pullback Entry");
   Print("   ServerURL : ", g_ServerURL);
   if(g_AltServerURL != g_ServerURL) Print("   AltURL    : ", g_AltServerURL);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
void OnTimer()
{
   CheckDailyReset();
   string json = BuildMTFJSON();

   char   post[], result[];
   string resHdr, reqHdr = "Content-Type: application/json\r\n";
   ArrayResize(post, StringToCharArray(json, post, 0, WHOLE_ARRAY, CP_UTF8) - 1);

   ResetLastError();
   string endpoint = g_ServerURL + "/market_data";
   int res = WebRequest("POST", endpoint, reqHdr, 8000, post, result, resHdr);
   if(res == 200) {
      string resp = CharArrayToString(result);
      if(StringFind(resp, "\"none\"") < 0 && StringFind(resp, "\"action\"") >= 0)
         Print("AI CMD: ", resp);
   } else {
      int err = GetLastError();
      string respErr = CharArrayToString(result);
      PrintFormat("WebRequest failed | HTTP=%d | LastError=%d | URL=%s | Resp=%s",
                  res, err, endpoint, respErr);

      // Fallback: some terminals reject one host format (127.0.0.1/localhost).
      if(res == -1 && err == 5200 && g_AltServerURL != g_ServerURL) {
         endpoint = g_AltServerURL + "/market_data";
         ResetLastError();
         res = WebRequest("POST", endpoint, reqHdr, 8000, post, result, resHdr);
         if(res == 200) {
            Print("WebRequest fallback success via ", endpoint);
         } else {
            err = GetLastError();
            respErr = CharArrayToString(result);
            PrintFormat("WebRequest fallback failed | HTTP=%d | LastError=%d | URL=%s | Resp=%s",
                        res, err, endpoint, respErr);
         }
      }

      if(res == -1)
         Print("Hint: MT4 > Tools > Options > Expert Advisors > Allow WebRequest for listed URL: ", g_ServerURL);
   }
}
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today > g_LastDay) {
      g_StartBalance = AccountBalance();
      g_LastDay      = today;
      Print("New day reset. StartBal=", g_StartBalance);
   }
}

//+------------------------------------------------------------------+
//  BUILD JSON: send all timeframe payloads
//+------------------------------------------------------------------+
string BuildMTFJSON()
{
   double equity   = AccountEquity();
   double lossPct  = (g_StartBalance > 0)
                     ? (g_StartBalance - equity) / g_StartBalance * 100.0 : 0;

   string s = "{";
   s += "\"symbol\":\""    + Symbol() + "\",";
   s += "\"time\":\""      + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"bid\":"         + DoubleToString(Bid, Digits) + ",";
   s += "\"ask\":"         + DoubleToString(Ask, Digits) + ",";
   s += "\"spread_usd\":"  + DoubleToString(Ask-Bid, Digits) + ",";

   // Account
   s += "\"account\":{";
   s += "\"balance\":"       + DoubleToString(AccountBalance(), 2) + ",";
   s += "\"equity\":"        + DoubleToString(equity,           2) + ",";
   s += "\"free_margin\":"   + DoubleToString(AccountFreeMargin(), 2) + ",";
   s += "\"open_pos\":"      + IntegerToString(OrdersTotal()) + ",";
   s += "\"start_balance\":" + DoubleToString(g_StartBalance, 2) + ",";
   s += "\"loss_pct\":"      + DoubleToString(lossPct, 2) + ",";
   s += "\"daily_trades\":"  + IntegerToString(CountDailyTrades());
   s += "},";

   //  H4 Data 
   s += "\"h4\":" + BuildTFData(PERIOD_H4) + ",";

   //  H1 Data 
   s += "\"h1\":" + BuildTFData(PERIOD_H1) + ",";

   //  M15 Data 
   s += "\"m15\":" + BuildTFData(PERIOD_M15) + ",";

   //  M5 Data (Entry TF  ) 
   s += "\"m5\":" + BuildTFData(PERIOD_M5) + ",";

   // Open Orders
   s += "\"orders\":[";
   bool first = true;
   for(int j = 0; j < OrdersTotal(); j++) {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!first) s += ",";
      first = false;
      double pnl_pts = 0;
      if(OrderType()==OP_BUY)  pnl_pts = (Bid - OrderOpenPrice()) / Point;
      if(OrderType()==OP_SELL) pnl_pts = (OrderOpenPrice() - Ask) / Point;
      s += "{\"ticket\":"       + IntegerToString(OrderTicket());
      s += ",\"type\":"         + IntegerToString(OrderType());
      s += ",\"lots\":"         + DoubleToString(OrderLots(), 2);
      s += ",\"open_price\":"   + DoubleToString(OrderOpenPrice(), Digits);
      s += ",\"sl\":"           + DoubleToString(OrderStopLoss(),  Digits);
      s += ",\"tp\":"           + DoubleToString(OrderTakeProfit(),Digits);
      s += ",\"profit_usd\":"   + DoubleToString(OrderProfit(), 2);
      s += ",\"profit_pts\":"   + DoubleToString(pnl_pts, 0) + "}";
   }
   s += "]";
   s += "}";
   return s;
}

//+------------------------------------------------------------------+
//  BUILD SINGLE TIMEFRAME DATA
//+------------------------------------------------------------------+
string BuildTFData(int tf)
{
   int bars = CandleCount;

   // Indicators  TF 
   double ema20  = iMA(NULL, tf, 20,  0, MODE_EMA, PRICE_CLOSE, 0);
   double ema50  = iMA(NULL, tf, 50,  0, MODE_EMA, PRICE_CLOSE, 0);
   double ema200 = iMA(NULL, tf, 200, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi    = iRSI(NULL, tf, 14, PRICE_CLOSE, 0);
   double atr    = iATR(NULL, tf, 14, 1);
   double macdM  = iMACD(NULL, tf, 12, 26, 9, PRICE_CLOSE, MODE_MAIN,   0);
   double macdS  = iMACD(NULL, tf, 12, 26, 9, PRICE_CLOSE, MODE_SIGNAL, 0);
   double bbU    = iBands(NULL, tf, 20, 2, 0, PRICE_CLOSE, MODE_UPPER, 0);
   double bbM    = iBands(NULL, tf, 20, 2, 0, PRICE_CLOSE, MODE_MAIN,  0);
   double bbL    = iBands(NULL, tf, 20, 2, 0, PRICE_CLOSE, MODE_LOWER, 0);
   double stochK = iStochastic(NULL, tf, 5, 3, 3, MODE_SMA, 0, MODE_MAIN,   0);
   double stochD = iStochastic(NULL, tf, 5, 3, 3, MODE_SMA, 0, MODE_SIGNAL, 0);

   // Swing High/Low (5 )
   double swingHigh = High[iHighest(NULL, tf, MODE_HIGH, 10, 1)];
   double swingLow  = Low[iLowest(NULL,  tf, MODE_LOW,  10, 1)];

   // Close 
   double lastClose = iClose(NULL, tf, 1);
   double prevClose = iClose(NULL, tf, 2);

   string s = "{";
   s += "\"ema20\":"     + DoubleToString(ema20,  Digits) + ",";
   s += "\"ema50\":"     + DoubleToString(ema50,  Digits) + ",";
   s += "\"ema200\":"    + DoubleToString(ema200, Digits) + ",";
   s += "\"rsi\":"       + DoubleToString(rsi,    2) + ",";
   s += "\"atr\":"       + DoubleToString(atr,    Digits) + ",";
   s += "\"macd_m\":"    + DoubleToString(macdM,  4) + ",";
   s += "\"macd_s\":"    + DoubleToString(macdS,  4) + ",";
   s += "\"bb_upper\":"  + DoubleToString(bbU,    Digits) + ",";
   s += "\"bb_mid\":"    + DoubleToString(bbM,    Digits) + ",";
   s += "\"bb_lower\":"  + DoubleToString(bbL,    Digits) + ",";
   s += "\"stoch_k\":"   + DoubleToString(stochK, 2) + ",";
   s += "\"stoch_d\":"   + DoubleToString(stochD, 2) + ",";
   s += "\"swing_high\":" + DoubleToString(swingHigh, Digits) + ",";
   s += "\"swing_low\":"  + DoubleToString(swingLow,  Digits) + ",";
   s += "\"last_close\":" + DoubleToString(lastClose,  Digits) + ",";
   s += "\"prev_close\":" + DoubleToString(prevClose,  Digits) + ",";

   // Candles
   s += "\"candles\":[";
   for(int i = bars-1; i >= 0; i--) {
      if(i < bars-1) s += ",";
      double o = iOpen(NULL,tf,i), h = iHigh(NULL,tf,i);
      double l = iLow(NULL,tf,i),  c = iClose(NULL,tf,i);
      bool bullish = c >= o;
      s += "{\"t\":\"" + TimeToString(iTime(NULL,tf,i), TIME_DATE|TIME_MINUTES) + "\"";
      s += ",\"o\":"  + DoubleToString(o, Digits);
      s += ",\"h\":"  + DoubleToString(h, Digits);
      s += ",\"l\":"  + DoubleToString(l, Digits);
      s += ",\"c\":"  + DoubleToString(c, Digits);
      s += ",\"bull\":" + (bullish ? "1" : "0");
      s += ",\"range\":" + DoubleToString(h-l, Digits) + "}";
   }
   s += "]}";
   return s;
}

//+------------------------------------------------------------------+
int CountDailyTrades()
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int cnt = 0;
   for(int i = OrdersHistoryTotal()-1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(StringToTime(TimeToString(OrderCloseTime(), TIME_DATE)) == today) cnt++;
   }
   for(int j = 0; j < OrdersTotal(); j++) {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
      if(StringToTime(TimeToString(OrderOpenTime(), TIME_DATE)) == today) cnt++;
   }
   return cnt;
}


