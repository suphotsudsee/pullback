//+------------------------------------------------------------------+
//|  DataSender_MTF.mq4                                              |
//|  Multi-Timeframe Data Sender สำหรับ XAUUSD Pullback             |
//|  ส่งข้อมูล H4, H1, M15, M5 พร้อมกัน                            |
//|  v5.0                                                            |
//+------------------------------------------------------------------+
#property copyright "AI XAUUSD Pullback System"
#property version   "5.00"
#property strict

input string   ServerURL     = "http://127.0.0.1:5000";
input string   FallbackURL1  = "http://localhost:5000";
input string   FallbackURL2  = "";
input string   FallbackURL3  = "";
input int      SendInterval  = 1;    // ส่งทุก 1 วินาที
input int      CandleCount   = 30;   // candle ต่อ timeframe
input bool     EnableFallback = true;
input bool     UseMagicFilter  = true;
input int      MagicFilter     = 55555;
input bool     WriteToFileBridge = true;                 // เขียน JSON ลง MQL4\Files
input string   OutputFileName    = "pullback_market_data.json";
input bool     UseCommonFiles    = true;                 // true = เขียนที่ Terminal\Common\Files
input bool     SendToServer      = false;                // ปิด WebRequest ถ้าใช้โหมดไฟล์อย่างเดียว

double   g_StartBalance = 0;
datetime g_LastDay      = 0;
string   g_ServerURL    = "";
string   g_WhitelistURL = "";
string   g_ServerList[4];
string   g_WhitelistList[4];
int      g_ServerCount  = 0;
int      g_ServerIndex  = 0;

bool PassTradeFilter()
{
   if(OrderSymbol() != Symbol()) return false;
   if(UseMagicFilter && OrderMagicNumber() != MagicFilter) return false;
   int type = OrderType();
   if(type != OP_BUY && type != OP_SELL) return false;
   return true;
}

bool WriteJSONToFile(string json)
{
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(UseCommonFiles) flags |= FILE_COMMON;

   int handle = FileOpen(OutputFileName, flags);
   if(handle == INVALID_HANDLE) {
      int err = GetLastError();
      Print("❌ เขียนไฟล์ไม่สำเร็จ: ", OutputFileName, " | Err=", err);
      return false;
   }

   FileWriteString(handle, json);
   FileWriteString(handle, "\r\n");
   FileClose(handle);
   return true;
}

string NormalizeServerURL(string url)
{
   while(StringLen(url) > 0 && StringSubstr(url, StringLen(url)-1, 1) == "/")
      url = StringSubstr(url, 0, StringLen(url)-1);
   return url;
}

string ExtractWhitelistBase(string url)
{
   int p = StringFind(url, "://");
   if(p < 0) return url;

   int hostStart = p + 3;
   int slash     = StringFind(url, "/", hostStart);
   if(slash > 0) return StringSubstr(url, 0, slash);
   return url;
}

bool URLExists(string url)
{
   for(int i=0; i<g_ServerCount; i++)
      if(g_ServerList[i] == url) return true;
   return false;
}

void AddServerCandidate(string url)
{
   string n = NormalizeServerURL(url);
   if(StringLen(n) == 0) return;
   if(URLExists(n)) return;
   if(g_ServerCount >= ArraySize(g_ServerList)) return;

   g_ServerList[g_ServerCount] = n;
   g_WhitelistList[g_ServerCount] = ExtractWhitelistBase(n);
   g_ServerCount++;
}

void ActivateServer(int idx)
{
   if(idx < 0 || idx >= g_ServerCount) return;
   g_ServerIndex  = idx;
   g_ServerURL    = g_ServerList[idx];
   g_WhitelistURL = g_WhitelistList[idx];
}

bool SwitchToNextServer()
{
   if(g_ServerCount <= 1) return false;
   int old = g_ServerIndex;
   int next = (g_ServerIndex + 1) % g_ServerCount;
   if(next == old) return false;
   ActivateServer(next);
   Print("↪️ Fallback ไป URL ถัดไป: ", g_ServerURL, " (Whitelist: ", g_WhitelistURL, ")");
   return true;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(Symbol(), "XAU") < 0 && StringFind(Symbol(), "GOLD") < 0)
      Print("⚠️ Warning: ออกแบบสำหรับ XAUUSD");

   g_ServerCount = 0;
   AddServerCandidate(ServerURL);
   AddServerCandidate(FallbackURL1);
   AddServerCandidate(FallbackURL2);
   AddServerCandidate(FallbackURL3);
   if(g_ServerCount == 0) AddServerCandidate("http://127.0.0.1:5000");
   ActivateServer(0);

   g_StartBalance = AccountBalance();
   g_LastDay      = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   EventSetTimer(SendInterval);

   Print("✅ MTF DataSender v5 เริ่มทำงาน");
   Print("   Timeframes: H4, H1, M15, M5");
   Print("   Strategy  : Pullback Entry");
   if(WriteToFileBridge) {
      string basePath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\";
      if(UseCommonFiles) basePath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\";
      Print("   FileBridge: ", basePath, OutputFileName);
   }
   if(SendToServer) {
      Print("   Server    : ", g_ServerURL, " (Whitelist: ", g_WhitelistURL, ")");
      if(g_ServerCount > 1) {
         Print("   Fallbacks : ", g_ServerCount, " URLs");
         for(int i=0; i<g_ServerCount; i++)
            Print("      [", i, "] ", g_ServerList[i], " (Whitelist: ", g_WhitelistList[i], ")");
      }
   }
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
void OnTimer()
{
   CheckDailyReset();
   string json = BuildMTFJSON();

   if(WriteToFileBridge) {
      static bool g_fileOk = false;
      bool ok = WriteJSONToFile(json);
      if(ok && !g_fileOk) {
         g_fileOk = true;
         Print("🎉 File bridge พร้อมใช้งาน: ", OutputFileName);
      }
   }

   if(!SendToServer) return;

   char   post[], result[];
   string resHdr, reqHdr = "Content-Type: application/json\r\n";
   ArrayResize(post, StringToCharArray(json, post, 0, WHOLE_ARRAY, CP_UTF8) - 1);

   int res = -1;
   int err = 0;
   string endpoint = "";
   int attempts = (EnableFallback ? g_ServerCount : 1);
   if(attempts < 1) attempts = 1;

   for(int a=0; a<attempts; a++)
   {
      endpoint = g_ServerURL + "/market_data";
      ResetLastError();
      res = WebRequest("POST", endpoint, reqHdr, 8000, post, result, resHdr);
      err = GetLastError();
      if(res == 200) break;

      if(!EnableFallback || a >= attempts-1) break;
      if(!SwitchToNextServer()) break;
   }

   if(res == 200) {
      static bool g_ok = false;
      if(!g_ok) { g_ok=true; Print("🎉 เชื่อมต่อ Server สำเร็จ! URL=", g_ServerURL); }
      string resp = CharArrayToString(result);
      if(StringFind(resp, "\"none\"") < 0 && StringFind(resp, "\"action\"") >= 0)
         Print("📨 AI CMD: ", resp);
      return;
   }

   static datetime g_lastWarn = 0;
   if(TimeCurrent() - g_lastWarn < 15) return;
   g_lastWarn = TimeCurrent();

   string cause="", fix="";
   if(err==5200){ cause="URL ไม่อยู่ใน MT4 Whitelist";
                  fix="Tools > Options > Expert Advisors > Allow WebRequest > Add: "+g_WhitelistURL+" > OK > รีสตาร์ท MT4"; }
   else if(err==5001){ cause="Python server ไม่รัน";
                       fix="รัน: python ai_pullback_server.py"; }
   else if(err==5004){ cause="Connection Refused";
                       fix="ตรวจ Firewall / ตรวจ port 5000"; }
   else { cause="Unknown"; fix="LastErr="+IntegerToString(err); }

   Print("❌ WebRequest ล้มเหลว | HTTP=",res," Err=",err," | ",cause," | URL=",endpoint);
   Print("   วิธีแก้: ",fix);
}

//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today > g_LastDay) {
      g_StartBalance = AccountBalance();
      g_LastDay      = today;
      Print("🌅 วันใหม่ StartBal=", g_StartBalance);
   }
}

//+------------------------------------------------------------------+
//  BUILD JSON — ส่งข้อมูลทุก Timeframe
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

   // ── H4 Data ──
   s += "\"h4\":" + BuildTFData(PERIOD_H4) + ",";

   // ── H1 Data ──
   s += "\"h1\":" + BuildTFData(PERIOD_H1) + ",";

   // ── M15 Data ──
   s += "\"m15\":" + BuildTFData(PERIOD_M15) + ",";

   // ── M5 Data (Entry TF — ส่งมากกว่าพิเศษ) ──
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

   // Indicators สำหรับ TF นี้
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

   // Swing High/Low (5 แท่งล่าสุด)
   double swingHigh = High[iHighest(NULL, tf, MODE_HIGH, 10, 1)];
   double swingLow  = Low[iLowest(NULL,  tf, MODE_LOW,  10, 1)];

   // Close ล่าสุด
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
      if(!PassTradeFilter()) continue;
      if(StringToTime(TimeToString(OrderCloseTime(), TIME_DATE)) == today) cnt++;
   }
   for(int j = 0; j < OrdersTotal(); j++) {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!PassTradeFilter()) continue;
      if(StringToTime(TimeToString(OrderOpenTime(), TIME_DATE)) == today) cnt++;
   }
   return cnt;
}
