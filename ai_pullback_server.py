"""
ai_pullback_server.py  v5.0
XAUUSD Multi-Timeframe Pullback System

Logic:
  H4   Trend direction (Bias: Long/Short only)
  H1   Swing structure + Pullback zone identify
  M15  Pullback confirmation (momentum slowing)
  M5   Entry trigger (reversal candle pattern)

AI :
  1.  H4  Trend
  2.  H1 pullback  EMA / S&R
  3.  M15 (momentum )
  4.  M5  reversal candle

"""

import json
import os
import time
import logging
import threading
from datetime import datetime, date
from flask import Flask, request, jsonify
import requests

# 
#  CONFIG
# 
OPENAI_API_KEY     = os.getenv("OPENAI_API_KEY", "")
OPENAI_MODEL       = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
SERVER_HOST        = "0.0.0.0"
SERVER_PORT        = 5000
MT4_FILES_DIR      = os.getenv(
    "MT4_FILES_DIR",
    r"C:\Users\user\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
)
MT4_MARKET_FILE    = os.getenv("MT4_MARKET_FILE", "pullback_market_data.json")
MT4_COMMAND_FILE   = os.getenv("MT4_COMMAND_FILE", "pullback_command.json")
FILE_POLL_SEC      = float(os.getenv("FILE_POLL_SEC", "0.05"))
ORDER_ACK_TIMEOUT_SEC = int(os.getenv("ORDER_ACK_TIMEOUT_SEC", "8"))
ORDER_STATUS_RESET_SEC = int(os.getenv("ORDER_STATUS_RESET_SEC", "8"))

FIXED_LOT          = 0.01
MAX_DAILY_TRADES   = 3
MAX_LOSS_PERCENT   = 10.0
MIN_CONFIDENCE     = 75        # Minimum confidence required for MTF pullback setup
MIN_INTERVAL_SEC   = 15        # Analyze at most once every 15 seconds
AI_COOLDOWN_SEC    = 300       # Pause AI calls for 5 minutes after HTTP 429
USE_RULE_FALLBACK_ON_AI_ERROR = True
RULE_MIN_CONFIDENCE = int(os.getenv("RULE_MIN_CONFIDENCE", "72"))
RULE_ALIGN_CONFIDENCE = int(os.getenv("RULE_ALIGN_CONFIDENCE", "76"))
LATE_MAX_EMA20_ATR = float(os.getenv("LATE_MAX_EMA20_ATR", "0.5"))
LATE_MAX_CANDLE_ATR = float(os.getenv("LATE_MAX_CANDLE_ATR", "1.2"))
LATE_STOCH_BUY_MAX = float(os.getenv("LATE_STOCH_BUY_MAX", "95"))
LATE_STOCH_SELL_MIN = float(os.getenv("LATE_STOCH_SELL_MIN", "5"))
MIN_ATR_M5         = 1.5
MAX_SPREAD_USD     = 3.0

SL_ATR_MULTI       = 1.5
TP_ATR_MULTI       = 2.0
TRAIL_ATR_MULTI    = 1.0

# 
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("xauusd_pullback.log", encoding="utf-8")
    ]
)
log = logging.getLogger(__name__)
app = Flask(__name__)

last_analysis_time = 0
pending_command    = None
command_lock       = threading.Lock()
market_history     = []
trade_log          = []
ai_analysis_cache  = {}      # Latest analysis text shown on dashboard
ai_cooldown_until  = 0

_daily_date    = None
_daily_trades  = 0
_daily_blocked = False
_last_file_mtime_ns = -1
_last_file_lock_warn_ts = 0.0
order_status = {
    "stage": "idle",
    "action": "-",
    "msg": "No order yet",
    "time": "-",
    "ticket": "-",
    "source": "-",
    "ts": 0.0,
}


def set_order_status(stage: str, action: str, msg: str, ticket: str = "-", source: str = "-") -> None:
    order_status.update({
        "stage": stage,
        "action": action,
        "msg": msg,
        "time": datetime.now().strftime("%H:%M:%S"),
        "ticket": str(ticket),
        "source": source,
        "ts": time.time(),
    })


def get_effective_order_status() -> dict:
    st = dict(order_status)
    stage = str(st.get("stage", "idle"))
    ts = float(st.get("ts", 0) or 0)
    if stage in ("queued", "sent_to_ea") and ts > 0:
        age = time.time() - ts
        if age >= ORDER_ACK_TIMEOUT_SEC:
            # No callback from EA in time -> mark failed instead of hanging on QUEUED
            set_order_status(
                "failed",
                str(st.get("action", "-")),
                "No response from EA (timeout). Check MT4 login mode, AutoTrading, WebRequest whitelist.",
                ticket=str(st.get("ticket", "-")),
                source=str(st.get("source", "-")),
            )
            st = dict(order_status)
    stage = str(st.get("stage", "idle"))
    ts = float(st.get("ts", 0) or 0)
    if stage in ("filled", "failed") and ts > 0:
        if (time.time() - ts) >= ORDER_STATUS_RESET_SEC:
            set_order_status("idle", "-", "No order yet", ticket="-", source="-")
            st = dict(order_status)
    return st


def late_entry_check(data: dict, action: str) -> tuple[bool, str]:
    action = str(action or "").upper()
    if action not in ("BUY", "SELL"):
        return True, "ok"

    bid = float(data.get("bid", 0) or 0)
    m5 = (data.get("m5") or {})
    atr = float(m5.get("atr", 0) or 0)
    ema20 = float(m5.get("ema20", bid) or bid)
    stoch = float(m5.get("stoch_k", 50) or 50)
    candles = m5.get("candles", []) or []

    if atr <= 0:
        return True, "ok"

    dist_ema20 = abs(bid - ema20)
    if dist_ema20 > (LATE_MAX_EMA20_ATR * atr):
        return False, f"Too late: price extended from EMA20 ({dist_ema20:.2f} > {LATE_MAX_EMA20_ATR:.2f}xATR)"

    if candles:
        last_candle = candles[-1]
        h = float(last_candle.get("h", bid) or bid)
        l = float(last_candle.get("l", bid) or bid)
        rng = abs(h - l)
        if rng > (LATE_MAX_CANDLE_ATR * atr):
            return False, f"Too late: impulse candle too large ({rng:.2f} > {LATE_MAX_CANDLE_ATR:.2f}xATR)"

    if action == "BUY" and stoch >= LATE_STOCH_BUY_MAX:
        return False, f"Too late: Stoch too high ({stoch:.1f})"
    if action == "SELL" and stoch <= LATE_STOCH_SELL_MIN:
        return False, f"Too late: Stoch too low ({stoch:.1f})"

    return True, "ok"


def write_command_file(cmd: dict) -> None:
    try:
        os.makedirs(MT4_FILES_DIR, exist_ok=True)
        path = os.path.join(MT4_FILES_DIR, MT4_COMMAND_FILE)
        payload = dict(cmd)
        payload.setdefault("cmd_id", str(int(time.time() * 1000)))
        with open(path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
        log.info(f"Command file updated: {path} | action={payload.get('action')}")
    except Exception as e:
        log.error(f"Command file write error: {e}")


# 
def check_daily_reset():
    global _daily_date, _daily_trades, _daily_blocked
    today = date.today()
    if _daily_date != today:
        if _daily_date:
            log.info(f"New day reset (previous trades: {_daily_trades})")
        _daily_date, _daily_trades, _daily_blocked = today, 0, False


# 
#  RISK GUARD
# 
def risk_check(data: dict) -> tuple[bool, str]:
    global _daily_blocked
    check_daily_reset()
    acc      = data.get("account", {})
    loss_pct = float(acc.get("loss_pct", 0) or 0)
    trades   = int(acc.get("daily_trades", _daily_trades) or 0)
    spread   = float(data.get("spread_usd", 0) or 0)
    atr_m5   = float((data.get("m5") or {}).get("atr", 0) or 0)

    if loss_pct >= MAX_LOSS_PERCENT:
        _daily_blocked = True
        return False, f"Daily loss limit reached: {loss_pct:.2f}%"
    if _daily_blocked:
        return False, "Trading blocked"
    if trades >= MAX_DAILY_TRADES:
        return False, f"Max daily trades reached: {MAX_DAILY_TRADES}"
    if atr_m5 < MIN_ATR_M5:
        return False, f"ATR M5 too low: ${atr_m5:.2f}"
    if spread > MAX_SPREAD_USD:
        return False, f"Spread too high: ${spread:.2f}"
    return True, "ok"


def process_market_data(data: dict, source: str = "http") -> None:
    global last_analysis_time
    m5 = data.get("m5", {})
    log.info(
        f"[{source}] {data.get('bid','?')} | "
        f"ATR_M5=${float(m5.get('atr',0) or 0):.2f} | "
        f"RSI_M5={m5.get('rsi','?')} | "
        f"Spread=${float(data.get('spread_usd',0) or 0):.2f}"
    )

    market_history.append(data)
    if len(market_history) > 30:
        market_history.pop(0)

    now = time.time()
    if now - last_analysis_time >= MIN_INTERVAL_SEC:
        last_analysis_time = now
        t = threading.Thread(target=analyze_pullback, args=(data,), daemon=True)
        t.start()


def build_rule_based_command(data: dict) -> dict:
    bid = float(data.get("bid", 0) or 0)
    h4 = data.get("h4", {}) or {}
    h1 = data.get("h1", {}) or {}
    m15 = data.get("m15", {}) or {}
    m5 = data.get("m5", {}) or {}

    def tf_trend(tf_data: dict) -> str:
        e20 = float(tf_data.get("ema20", bid) or bid)
        e50 = float(tf_data.get("ema50", bid) or bid)
        e200 = float(tf_data.get("ema200", bid) or bid)
        if e20 > e50 > e200:
            return "UP"
        if e20 < e50 < e200:
            return "DOWN"
        return "MIXED"

    h4_t = tf_trend(h4)
    h1_t = tf_trend(h1)
    m15_t = tf_trend(m15)
    m5_t = tf_trend(m5)

    m5_rsi = float(m5.get("rsi", 50) or 50)
    m5_stoch = float(m5.get("stoch_k", 50) or 50)
    m5_macd_m = float(m5.get("macd_m", 0) or 0)
    m5_macd_s = float(m5.get("macd_s", 0) or 0)
    m5_close = float(m5.get("last_close", bid) or bid)
    m5_prev = float(m5.get("prev_close", bid) or bid)
    m5_ema20 = float(m5.get("ema20", bid) or bid)

    buy_score = 0
    sell_score = 0
    if m5_close > m5_prev:
        buy_score += 1
    if m5_close > m5_ema20:
        buy_score += 1
    if m5_rsi >= 48:
        buy_score += 1
    if m5_stoch >= 45:
        buy_score += 1
    if m5_macd_m >= m5_macd_s:
        buy_score += 1

    if m5_close < m5_prev:
        sell_score += 1
    if m5_close < m5_ema20:
        sell_score += 1
    if m5_rsi <= 52:
        sell_score += 1
    if m5_stoch <= 55:
        sell_score += 1
    if m5_macd_m <= m5_macd_s:
        sell_score += 1

    up_align = h4_t == "UP" and h1_t == "UP" and m15_t != "DOWN"
    down_align = h4_t == "DOWN" and h1_t == "DOWN" and m15_t != "UP"

    cmd = {
        "action": "none",
        "setup": "RULE_FALLBACK",
        "h4_bias": "BULLISH" if h4_t == "UP" else ("BEARISH" if h4_t == "DOWN" else "NEUTRAL"),
        "h1_zone": f"H1={h1_t} M15={m15_t}",
        "m5_signal": f"RSI={m5_rsi:.1f} Stoch={m5_stoch:.1f} MACD={m5_macd_m:.4f}/{m5_macd_s:.4f} scoreB={buy_score}/5 scoreS={sell_score}/5",
        "confidence": 55,
        "reason": "No aligned rule-based setup"
    }

    if up_align and buy_score >= 4:
        cmd["action"] = "BUY"
        cmd["confidence"] = RULE_ALIGN_CONFIDENCE
        cmd["reason"] = f"H4/H1 uptrend alignment with M5 bullish score {buy_score}/5"
    elif down_align and sell_score >= 4:
        cmd["action"] = "SELL"
        cmd["confidence"] = RULE_ALIGN_CONFIDENCE
        cmd["reason"] = f"H4/H1 downtrend alignment with M5 bearish score {sell_score}/5"
    elif h4_t == "UP" and buy_score == 5 and h1_t != "DOWN":
        cmd["action"] = "BUY"
        cmd["confidence"] = RULE_MIN_CONFIDENCE
        cmd["reason"] = "Strong M5 bullish trigger with higher-timeframe support"
    elif h4_t == "DOWN" and sell_score == 5 and h1_t != "UP":
        cmd["action"] = "SELL"
        cmd["confidence"] = RULE_MIN_CONFIDENCE
        cmd["reason"] = "Strong M5 bearish trigger with higher-timeframe support"

    return cmd


def queue_command_if_valid(cmd: dict, data: dict, source: str) -> None:
    global pending_command
    if not cmd:
        return

    action = str(cmd.get("action", "none")).upper()
    confidence = int(cmd.get("confidence", 0) or 0)
    if action not in ("BUY", "SELL", "CLOSE") or confidence < MIN_CONFIDENCE:
        return

    if source != "MANUAL" and action in ("BUY", "SELL"):
        ok_timing, timing_msg = late_entry_check(data, action)
        if not ok_timing:
            set_order_status("failed", action, timing_msg, ticket=cmd.get("cmd_id", "-"), source=source)
            log.info(f"{source} skipped ({action}): {timing_msg}")
            return

    open_pos = int((data.get("account", {}) or {}).get("open_pos", 0) or 0)
    if action in ("BUY", "SELL") and open_pos >= MAX_DAILY_TRADES:
        return

    cmd["action"] = action
    cmd["lots"] = FIXED_LOT
    cmd["cmd_id"] = str(int(time.time() * 1000))
    with command_lock:
        pending_command = cmd
    write_command_file(cmd)
    set_order_status("queued", action, f"{source} queued and waiting EA", ticket=cmd["cmd_id"], source=source)
    log.info(f"{source} command queued: {cmd}")


def watch_mt4_file() -> None:
    global _last_file_mtime_ns, _last_file_lock_warn_ts
    file_path = os.path.join(MT4_FILES_DIR, MT4_MARKET_FILE)
    log.info(f"FileBridge watch: {file_path}")

    while True:
        try:
            if not os.path.exists(file_path):
                time.sleep(FILE_POLL_SEC)
                continue

            stat = os.stat(file_path)
            if stat.st_mtime_ns == _last_file_mtime_ns:
                time.sleep(FILE_POLL_SEC)
                continue

            _last_file_mtime_ns = stat.st_mtime_ns
            raw = ""
            # MT4 may hold the file lock briefly while writing.
            for _ in range(3):
                try:
                    with open(file_path, "r", encoding="utf-8-sig") as f:
                        raw = f.read().strip()
                    break
                except PermissionError:
                    time.sleep(0.02)
            if not raw:
                time.sleep(FILE_POLL_SEC)
                continue

            data = json.loads(raw)
            if isinstance(data, dict):
                process_market_data(data, source="file")
            else:
                log.warning("FileBridge ignored non-object JSON payload")
        except json.JSONDecodeError:
            # EA อาจกำลังเขียนไฟล์อยู่ จึงรอรอบถัดไป
            time.sleep(FILE_POLL_SEC)
            continue
        except PermissionError:
            now = time.time()
            if now - _last_file_lock_warn_ts >= 5:
                _last_file_lock_warn_ts = now
                log.warning("FileBridge: market data file is locked by MT4, retrying...")
            time.sleep(FILE_POLL_SEC)
            continue
        except Exception as e:
            log.error(f"FileBridge error: {e}")

        time.sleep(FILE_POLL_SEC)


# 
#  ENDPOINTS
# 
@app.route("/market_data", methods=["POST"])
def receive_market_data():
    global pending_command
    data = request.get_json(force=True, silent=True)
    if not data:
        return jsonify({"status": "error"}), 400

    process_market_data(data, source="http")

    with command_lock:
        if pending_command:
            cmd = pending_command
            pending_command = None
            log.info(f"Dispatch command: {cmd}")
            return jsonify(cmd)

    return jsonify({"status": "ok", "action": "none"})


@app.route("/order_result", methods=["POST"])
def receive_order_result():
    global _daily_trades
    data = request.get_json(force=True, silent=True)
    log.info(f" Order: {json.dumps(data, ensure_ascii=False)}")
    if data:
        action = str(data.get("type", "-")).upper()
        source = str(data.get("source", "-"))
        ticket = data.get("ticket", "-")
        if data.get("success"):
            set_order_status("filled", action, "Order filled", ticket=ticket, source=source)
        else:
            err = str(data.get("error", "") or "Order failed")
            set_order_status("failed", action, err, ticket=ticket, source=source)

    if data and data.get("success"):
        check_daily_reset()
        _daily_trades += 1
        trade_log.append({
            "time": datetime.now().isoformat(),
            "ticket": data.get("ticket"),
            "type": data.get("type"),
        })
    return jsonify({"status": "received"})


# 
#  ENDPOINT: EA poll 
# 
@app.route("/get_command", methods=["GET"])
def get_command():
    global pending_command
    with command_lock:
        if pending_command:
            cmd = pending_command
            pending_command = None
            log.info(f" EA : {cmd}")
            set_order_status("sent_to_ea", str(cmd.get("action", "-")).upper(), "EA polled command", ticket=cmd.get("cmd_id", "-"), source="AI")
            return jsonify(cmd)
    return jsonify({"action": "none"})


@app.route("/order_status", methods=["GET"])
def get_order_status():
    return jsonify(get_effective_order_status())


# 
#  ENDPOINT: Manual Order  Dashboard
# 
@app.route("/manual_order", methods=["POST"])
def manual_order():
    global pending_command
    data = request.get_json(force=True, silent=True)
    if not data:
        set_order_status("failed", "-", "Invalid manual order JSON", source="MANUAL")
        return jsonify({"status": "error", "msg": "invalid JSON"}), 400

    action = str(data.get("action", "")).upper()
    if action not in ("BUY", "SELL", "CLOSE"):
        set_order_status("failed", action or "-", "Manual action must be BUY/SELL/CLOSE", source="MANUAL")
        return jsonify({"status": "error", "msg": "action must be BUY/SELL/CLOSE"}), 400

    check_daily_reset()

    # Manual BUY/SELL still passes risk checks
    last_data = market_history[-1] if market_history else {}
    if action in ("BUY", "SELL"):
        allowed, reason = risk_check(last_data)
        if not allowed:
            log.warning(f"Manual {action} blocked: {reason}")
            set_order_status("failed", action, reason, source="MANUAL")
            return jsonify({"status": "blocked", "msg": reason}), 403

    cmd = {
        "action":        action,
        "lots":          FIXED_LOT,
        "reason":        "Manual Order",
        "setup":         "MANUAL",
        "close_ticket":  int(data.get("close_ticket", 0)),
        "confidence":    100,
    }

    cmd["cmd_id"] = str(int(time.time() * 1000))
    with command_lock:
        pending_command = cmd
    write_command_file(cmd)
    set_order_status("queued", action, "Queued and waiting EA", ticket=cmd["cmd_id"], source="MANUAL")

    log.info(f"Manual {action} queued, waiting for EA poll")
    return jsonify({"status": "queued", "action": action})


# 
#  PULLBACK ANALYSIS
# 
def analyze_pullback(data: dict):
    global ai_analysis_cache, ai_cooldown_until

    allowed, reason = risk_check(data)
    if not allowed:
        log.info(f"Blocked: {reason}")
        ai_analysis_cache["block_reason"] = reason
        return

    now = time.time()
    if now < ai_cooldown_until:
        wait_sec = int(ai_cooldown_until - now)
        msg = f"OpenAI cooldown active ({wait_sec}s left) after rate limit"
        log.warning(msg)
        if USE_RULE_FALLBACK_ON_AI_ERROR:
            fallback_cmd = build_rule_based_command(data)
            ai_analysis_cache = {
                "time": datetime.now().strftime("%H:%M:%S"),
                "response": json.dumps(fallback_cmd, ensure_ascii=False),
                "block_reason": msg
            }
            queue_command_if_valid(fallback_cmd, data, source="RuleFallback")
        else:
            ai_analysis_cache["block_reason"] = msg
        return

    try:
        prompt   = build_pullback_prompt(data)
        log.info("Analyzing MTF pullback...")
        response = call_openai(prompt)
        log.info(f"AI response:\n{response}")

        # Save latest analysis for dashboard
        ai_analysis_cache = {
            "time": datetime.now().strftime("%H:%M:%S"),
            "response": response,
            "block_reason": ""
        }

        cmd = parse_response(response, data)
        queue_command_if_valid(cmd, data, source="AI")

    except requests.HTTPError as e:
        status = e.response.status_code if e.response is not None else None
        if status == 429:
            ai_cooldown_until = time.time() + AI_COOLDOWN_SEC
            msg = f"OpenAI 429 rate limit. Cooldown {AI_COOLDOWN_SEC}s"
            log.warning(msg)
            if USE_RULE_FALLBACK_ON_AI_ERROR:
                fallback_cmd = build_rule_based_command(data)
                ai_analysis_cache = {
                    "time": datetime.now().strftime("%H:%M:%S"),
                    "response": json.dumps(fallback_cmd, ensure_ascii=False),
                    "block_reason": msg
                }
                queue_command_if_valid(fallback_cmd, data, source="RuleFallback")
            else:
                ai_analysis_cache["block_reason"] = msg
            return
        log.error(f" OpenAI HTTP error: {e}")
        if USE_RULE_FALLBACK_ON_AI_ERROR:
            fallback_cmd = build_rule_based_command(data)
            ai_analysis_cache = {
                "time": datetime.now().strftime("%H:%M:%S"),
                "response": json.dumps(fallback_cmd, ensure_ascii=False),
                "block_reason": "OpenAI HTTP error -> rule fallback"
            }
            queue_command_if_valid(fallback_cmd, data, source="RuleFallback")
    except Exception as e:
        log.error(f" Error: {e}")
        if USE_RULE_FALLBACK_ON_AI_ERROR:
            fallback_cmd = build_rule_based_command(data)
            ai_analysis_cache = {
                "time": datetime.now().strftime("%H:%M:%S"),
                "response": json.dumps(fallback_cmd, ensure_ascii=False),
                "block_reason": "OpenAI error -> rule fallback"
            }
            queue_command_if_valid(fallback_cmd, data, source="RuleFallback")


# 
#  PULLBACK PROMPT
# 
def build_pullback_prompt(data: dict) -> str:
    bid     = float(data.get("bid", 0) or 0)
    ask     = float(data.get("ask", 0) or 0)
    spread  = float(data.get("spread_usd", 0) or 0)
    acc     = data.get("account", {})
    h4      = data.get("h4",  {})
    h1      = data.get("h1",  {})
    m15     = data.get("m15", {})
    m5      = data.get("m5",  {})
    orders  = data.get("orders", [])

    def tf_summary(tf_data: dict, name: str) -> str:
        ema20 = float(tf_data.get("ema20", bid) or bid)
        ema50 = float(tf_data.get("ema50", bid) or bid)
        ema200 = float(tf_data.get("ema200", bid) or bid)
        rsi = float(tf_data.get("rsi", 50) or 50)
        atr = float(tf_data.get("atr", 0) or 0)
        macd_m = float(tf_data.get("macd_m", 0) or 0)
        macd_s = float(tf_data.get("macd_s", 0) or 0)
        stoch = float(tf_data.get("stoch_k", 50) or 50)
        s_high = float(tf_data.get("swing_high", bid) or bid)
        s_low = float(tf_data.get("swing_low", bid) or bid)
        lc = float(tf_data.get("last_close", bid) or bid)

        trend = (
            "UPTREND" if ema20 > ema50 > ema200 else
            "DOWNTREND" if ema20 < ema50 < ema200 else
            "MIXED"
        )

        dist_ema20 = round(bid - ema20, 2)
        dist_ema50 = round(bid - ema50, 2)
        candles = tf_data.get("candles", [])[-5:]
        candle_str = " | ".join(str(c.get("c", "?")) for c in candles) if candles else "n/a"

        return f"""
[{name}] {trend}
EMA20={ema20:.2f} EMA50={ema50:.2f} EMA200={ema200:.2f}
Price vs EMA20: {'+' if dist_ema20 >= 0 else ''}{dist_ema20:.2f} | vs EMA50: {'+' if dist_ema50 >= 0 else ''}{dist_ema50:.2f}
RSI={rsi:.0f} Stoch={stoch:.0f} ATR=${atr:.2f}
MACD={macd_m:.4f} Signal={macd_s:.4f} ({'Bullish' if macd_m > macd_s else 'Bearish'})
Swing High={s_high:.2f} Swing Low={s_low:.2f} Last Close={lc:.2f}
Recent closes: {candle_str}"""

    atr_m5  = float(m5.get("atr", 0) or 0)
    sl_usd  = round(atr_m5 * SL_ATR_MULTI, 2)
    tp_usd  = round(atr_m5 * TP_ATR_MULTI, 2)
    sl_buy  = round(bid - sl_usd, 2)
    tp_buy  = round(bid + tp_usd, 2)
    sl_sell = round(bid + sl_usd, 2)
    tp_sell = round(bid - tp_usd, 2)

    loss_pct  = float(acc.get("loss_pct", 0) or 0)
    trades_left = MAX_DAILY_TRADES - int(acc.get("daily_trades", 0) or 0)
    orders_str = json.dumps(orders, ensure_ascii=False) if orders else "none"

    # H4 EMA alignment for major bias
    h4_ema20 = float(h4.get("ema20", bid) or bid)
    h4_ema50 = float(h4.get("ema50", bid) or bid)
    h4_ema200= float(h4.get("ema200", bid) or bid)
    h4_bias  = ("BULLISH" if h4_ema20 > h4_ema50 > h4_ema200 else
                "BEARISH" if h4_ema20 < h4_ema50 < h4_ema200 else "NEUTRAL")

    return f"""You are an XAUUSD multi-timeframe pullback analyst.

PRICE
Bid=${bid:.2f} Ask=${ask:.2f} Spread=${spread:.2f} Time={data.get('time','')}

H4 BIAS: {h4_bias}
{tf_summary(h4, "H4")}

H1 SWING STRUCTURE
{tf_summary(h1, "H1")}

M15 CONFIRMATION
{tf_summary(m15, "M15")}

M5 ENTRY TRIGGER
{tf_summary(m5, "M5")}

SL/TP FROM ATR(M5)
ATR M5=${atr_m5:.2f}
BUY:  entry={bid:.2f} sl={sl_buy:.2f} tp={tp_buy:.2f}
SELL: entry={bid:.2f} sl={sl_sell:.2f} tp={tp_sell:.2f}
Risk:Reward=1:{TP_ATR_MULTI/SL_ATR_MULTI:.1f}

RISK STATUS
Loss today={loss_pct:.2f}% / {MAX_LOSS_PERCENT}%
Trades left today={trades_left}
Open orders={orders_str}

RULES
- Trade only if all timeframes align.
- If no clean setup, return action=none.
- Confidence must be >= {MIN_CONFIDENCE} to allow trade.

Respond with JSON only:
{{
  "action": "BUY" | "SELL" | "none",
  "setup": "short setup name",
  "h4_bias": "BULLISH/BEARISH/NEUTRAL",
  "h1_zone": "pullback zone description",
  "m5_signal": "entry trigger summary",
  "confidence": 0-100,
  "reason": "short rationale"
}}"""


# 
def call_openai(prompt: str) -> str:
    if not OPENAI_API_KEY or OPENAI_API_KEY == "YOUR_OPENAI_API_KEY":
        raise RuntimeError("OPENAI_API_KEY is not set")

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {OPENAI_API_KEY}"
    }
    body = {
        "model": OPENAI_MODEL,
        "temperature": 0.2,
        "max_tokens": 500,
        "messages": [
            {
                "role": "system",
                "content": "You are a precise trading analysis assistant. Reply with JSON only."
            },
            {"role": "user", "content": prompt}
        ]
    }
    r = requests.post("https://api.openai.com/v1/chat/completions",
                      headers=headers, json=body, timeout=30)
    if r.status_code >= 400:
        msg = r.text[:800]
        raise requests.HTTPError(f"OpenAI HTTP {r.status_code}: {msg}", response=r)
    r.raise_for_status()
    data = r.json()
    content = (data.get("choices") or [{}])[0].get("message", {}).get("content", "")
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(item.get("text", ""))
        return "\n".join(parts).strip()
    return str(content).strip()


def parse_response(text: str, data: dict) -> dict:
    s = text.find("{"); e = text.rfind("}") + 1
    if s < 0 or e <= 0:
        return {"action": "none"}
    try:
        cmd = json.loads(text[s:e])
    except:
        return {"action": "none"}

    action     = str(cmd.get("action", "none")).upper()
    confidence = int(cmd.get("confidence", 0))

    if confidence < MIN_CONFIDENCE:
        log.info(f" Confidence {confidence}% < {MIN_CONFIDENCE}%")
        return {"action": "none"}

    open_pos = data.get("account", {}).get("open_pos", 0)
    if action in ("BUY", "SELL") and int(open_pos or 0) >= MAX_DAILY_TRADES:
        return {"action": "none"}

    cmd["action"] = action
    cmd["lots"]   = FIXED_LOT
    return cmd


# 
#  DASHBOARD  MTF Pullback Edition
# 
@app.route("/", methods=["GET"])
def dashboard():
    check_daily_reset()
    last = market_history[-1] if market_history else {}
    acc  = last.get("account", {})
    h4   = last.get("h4",  {})
    h1   = last.get("h1",  {})
    m15  = last.get("m15", {})
    m5   = last.get("m5",  {})

    def rsi_color(v):
        v = float(v or 50)
        return "#ef4444" if v > 65 else ("#10b981" if v < 35 else "#94a3b8")

    def trend_html(tf_data):
        e20 = float(tf_data.get("ema20", 0) or 0)
        e50 = float(tf_data.get("ema50", 0) or 0)
        e200= float(tf_data.get("ema200",0) or 0)
        if e20 > e50 > e200: return "<span style='color:#10b981'> UP</span>"
        if e20 < e50 < e200: return "<span style='color:#ef4444'> DOWN</span>"
        return "<span style='color:#f59e0b'> MIXED</span>"

    bid      = float(last.get("bid", 0) or 0)
    spread   = float(last.get("spread_usd", 0) or 0)
    loss_pct = float(acc.get("loss_pct", 0) or 0)
    dt       = int(acc.get("daily_trades", _daily_trades) or 0)
    tl       = max(0, MAX_DAILY_TRADES - dt)
    atr_m5   = float(m5.get("atr", 0) or 0)
    sc       = "#ef4444" if _daily_blocked else ("#f59e0b" if loss_pct>7 else "#10b981")

    # AI analysis cache
    ai_time  = ai_analysis_cache.get("time", "-")
    ai_resp  = ai_analysis_cache.get("response", "Waiting for analysis...")
    ai_block = ai_analysis_cache.get("block_reason", "")

    # Parse cached JSON fields if available
    ai_action = "-"; ai_setup = "-"; ai_conf = "-"; ai_reason = "-"; ai_signal = "-"
    try:
        raw = ai_resp
        s = raw.find("{"); e = raw.rfind("}") + 1
        if s >= 0 and e > 0:
            d = json.loads(raw[s:e])
            ai_action = d.get("action", "-")
            ai_setup  = d.get("setup",  "-")
            ai_conf   = str(d.get("confidence", "-"))
            ai_reason = d.get("reason", "-")
            ai_signal = d.get("m5_signal", "-")
    except:
        pass

    action_color = {"BUY":"#10b981","SELL":"#ef4444"}.get(ai_action, "#94a3b8")

    current_status = get_effective_order_status()
    stg = str(current_status.get("stage", "idle"))
    status_color = {
        "idle": "#64748b",
        "queued": "#f59e0b",
        "sent_to_ea": "#38bdf8",
        "filled": "#10b981",
        "failed": "#ef4444",
    }.get(stg, "#64748b")
    status_title = {
        "idle": "IDLE",
        "queued": "QUEUED",
        "sent_to_ea": "SENT TO EA",
        "filled": "FILLED",
        "failed": "FAILED",
    }.get(stg, stg.upper())

    rows = ""
    for t in reversed(trade_log[-6:]):
        c = "#10b981" if t['type']=="BUY" else "#ef4444"
        src = t.get("source", "AI")
        src_color = "#fbbf24" if src == "MANUAL" else "#64748b"
        rows += f"<tr><td>{t['time'][:19]}</td><td style='color:{c}'>{t['type']}</td><td>#{t['ticket']}</td><td style='color:{src_color}'>{src}</td></tr>"

    blocked_msg = "Daily loss exceeded 10%" if _daily_blocked else ai_block
    blocked_html = f"<div class='alert'>{blocked_msg}</div>" if (_daily_blocked or ai_block) else ""

    return f"""<!DOCTYPE html><html><head>
<meta http-equiv="refresh" content="1">
<title>XAUUSD Pullback AI</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:'Courier New',monospace;background:#080c10;color:#cbd5e1;padding:20px}}
h1{{color:#fbbf24;font-size:19px;letter-spacing:3px;margin-bottom:4px}}
.sub{{color:#475569;font-size:11px;margin-bottom:18px}}
.g3{{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:10px}}
.g2{{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:10px}}
.card{{background:#0f172a;border:1px solid #1e293b;border-radius:8px;padding:14px}}
.card h3{{color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:1px;margin-bottom:8px}}
.val{{font-size:20px;font-weight:700;color:#f1f5f9}}
.sub2{{font-size:11px;color:#64748b;margin-top:3px}}
.bar-bg{{background:#1e293b;border-radius:3px;height:5px;margin-top:7px}}
.bar{{height:5px;border-radius:3px}}
.alert{{background:#450a0a;border:1px solid #dc2626;border-radius:8px;
        padding:10px;color:#fca5a5;margin-bottom:10px;text-align:center}}
.tf-grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:10px}}
.tf-card{{background:#0f172a;border:1px solid #1e293b;border-radius:8px;padding:12px}}
.tf-label{{font-size:11px;color:#fbbf24;font-weight:bold;margin-bottom:6px}}
.tf-row{{font-size:11px;color:#64748b;margin:2px 0}}
.ai-card{{background:#0f172a;border:1px solid #334155;border-radius:8px;padding:16px;margin-bottom:10px}}
.ai-card h3{{color:#38bdf8;font-size:11px;margin-bottom:10px}}
.ai-action{{font-size:28px;font-weight:900;color:{action_color};margin-bottom:6px}}
table{{width:100%;border-collapse:collapse;font-size:11px}}
th{{color:#475569;text-align:left;padding:5px 8px;border-bottom:1px solid #1e293b}}
td{{padding:5px 8px;border-bottom:1px solid #0f172a}}
</style></head><body>

<h1>XAUUSD PULLBACK AI v5</h1>
<div class="sub">Multi-Timeframe: H4 -> H1 -> M15 -> M5 Entry | refresh every 3s</div>

{blocked_html}

<div class="card" style="margin-bottom:10px;border-color:{status_color}">
  <h3>Order Status</h3>
  <div class="val" style="color:{status_color}">{status_title}</div>
  <div class="sub2">Action: <b>{current_status.get('action','-')}</b> | Source: <b>{current_status.get('source','-')}</b></div>
  <div class="sub2">Ticket/Cmd: <b>{current_status.get('ticket','-')}</b> | Time: <b>{current_status.get('time','-')}</b></div>
  <div class="sub2" style="color:#cbd5e1">{current_status.get('msg','-')}</div>
</div>

<div class="g3">
  <div class="card">
    <h3> Price</h3>
    <div class="val" style="color:#fbbf24">${bid:,.2f}</div>
    <div class="sub2">Spread ${spread:.2f} {'OK' if spread<=MAX_SPREAD_USD else 'HIGH'}</div>
    <div class="sub2" style="color:#334155">{last.get('time','')}</div>
  </div>
  <div class="card">
    <h3> Loss / Day</h3>
    <div class="val" style="color:{sc}">{loss_pct:.2f}%</div>
    <div class="sub2">Limit {MAX_LOSS_PERCENT}% | Remaining {MAX_LOSS_PERCENT-loss_pct:.2f}%</div>
    <div class="bar-bg"><div class="bar" style="width:{min(int(loss_pct*10),100)}%;background:{sc}"></div></div>
  </div>
  <div class="card">
    <h3> Trades Today</h3>
    <div class="val">{dt}<span style="font-size:13px;color:#475569">/{MAX_DAILY_TRADES}</span></div>
    <div class="sub2"><b style="color:#10b981">{tl}</b> trades left | Lot 0.01</div>
    <div class="bar-bg"><div class="bar" style="width:{min(dt*34,100)}%;background:#3b82f6"></div></div>
  </div>
  <div class="card">
    <h3> ATR M5</h3>
    <div class="val" style="color:#a78bfa">${atr_m5:.2f}</div>
    <div class="sub2">SL ${atr_m5*SL_ATR_MULTI:.2f} | TP ${atr_m5*TP_ATR_MULTI:.2f}</div>
    <div class="sub2">{'Trade allowed' if atr_m5>=MIN_ATR_M5 else 'Sideways / low volatility'}</div>
  </div>
</div>

<div class="tf-grid">
  <div class="tf-card" style="border-color:#1e3a5f">
    <div class="tf-label">H4  BIAS</div>
    <div style="margin-bottom:4px">{trend_html(h4)}</div>
    <div class="tf-row">RSI <span style="color:{rsi_color(h4.get('rsi',50))}">{h4.get('rsi','-')}</span></div>
    <div class="tf-row">EMA20 {h4.get('ema20','-')}</div>
    <div class="tf-row">EMA200 {h4.get('ema200','-')}</div>
    <div class="tf-row">ATR ${float(h4.get('atr',0) or 0):.2f}</div>
  </div>
  <div class="tf-card" style="border-color:#14532d">
    <div class="tf-label">H1  SWING ZONE</div>
    <div style="margin-bottom:4px">{trend_html(h1)}</div>
    <div class="tf-row">RSI <span style="color:{rsi_color(h1.get('rsi',50))}">{h1.get('rsi','-')}</span></div>
    <div class="tf-row">SwHigh {h1.get('swing_high','-')}</div>
    <div class="tf-row">SwLow  {h1.get('swing_low','-')}</div>
    <div class="tf-row">EMA50  {h1.get('ema50','-')}</div>
  </div>
  <div class="tf-card" style="border-color:#451a03">
    <div class="tf-label">M15  CONFIRM</div>
    <div style="margin-bottom:4px">{trend_html(m15)}</div>
    <div class="tf-row">RSI <span style="color:{rsi_color(m15.get('rsi',50))}">{m15.get('rsi','-')}</span></div>
    <div class="tf-row">Stoch {m15.get('stoch_k','-')}</div>
    <div class="tf-row">MACD {m15.get('macd_m','-')}</div>
    <div class="tf-row">ATR ${float(m15.get('atr',0) or 0):.2f}</div>
  </div>
  <div class="tf-card" style="border-color:#581c87">
    <div class="tf-label">M5  ENTRY </div>
    <div style="margin-bottom:4px">{trend_html(m5)}</div>
    <div class="tf-row">RSI <span style="color:{rsi_color(m5.get('rsi',50))}">{m5.get('rsi','-')}</span></div>
    <div class="tf-row">Stoch {m5.get('stoch_k','-')}</div>
    <div class="tf-row">Signal: <b>{ai_signal}</b></div>
    <div class="tf-row">ATR ${atr_m5:.2f}</div>
  </div>
</div>

<div class="ai-card">
  <h3> AI ANALYSIS  [{ai_time}]</h3>
  <div class="g2">
    <div>
      <div class="ai-action">{ai_action}</div>
      <div style="font-size:12px;color:#64748b">Setup: {ai_setup}</div>
      <div style="font-size:12px;color:#64748b">Signal: {ai_signal}</div>
      <div style="font-size:12px;margin-top:6px">Confidence: <b style="color:#fbbf24">{ai_conf}%</b></div>
    </div>
    <div style="font-size:12px;color:#94a3b8;padding-top:4px">
      <b style="color:#cbd5e1">Reason:</b><br>{ai_reason}
    </div>
  </div>
</div>

<!--  MANUAL ORDER PANEL  -->
<div id="manual-panel" style="background:#0f172a;border:2px solid #334155;border-radius:10px;padding:18px;margin-bottom:10px">
  <h3 style="color:#f1f5f9;font-size:13px;margin-bottom:4px"> MANUAL ORDER</h3>
  <p style="font-size:11px;color:#475569;margin-bottom:14px">
    SL = ATR M5 x {SL_ATR_MULTI} = <b style="color:#ef4444">${atr_m5*SL_ATR_MULTI:.2f}</b> &nbsp;|&nbsp;
    TP = ATR M5 x {TP_ATR_MULTI} = <b style="color:#10b981">${atr_m5*TP_ATR_MULTI:.2f}</b> &nbsp;|&nbsp;
    Lot = <b style="color:#fbbf24">0.01</b>
  </p>

  <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px">

    <!-- BUY -->
    <button id="btn-buy" onclick="sendManual('BUY')"
      style="background:#065f46;border:2px solid #10b981;border-radius:10px;
             padding:16px 8px;cursor:pointer;transition:all .15s">
      <div style="font-size:22px;font-weight:900;color:#10b981"> BUY</div>
      <div style="font-size:11px;color:#6ee7b7;margin-top:4px">@ ${bid:.2f}</div>
      <div style="font-size:11px;color:#6ee7b7">SL ${atr_m5*SL_ATR_MULTI:.2f} below</div>
      <div style="font-size:11px;color:#6ee7b7">TP ${atr_m5*TP_ATR_MULTI:.2f} above</div>
    </button>

    <!-- SELL -->
    <button id="btn-sell" onclick="sendManual('SELL')"
      style="background:#7f1d1d;border:2px solid #ef4444;border-radius:10px;
             padding:16px 8px;cursor:pointer;transition:all .15s">
      <div style="font-size:22px;font-weight:900;color:#ef4444"> SELL</div>
      <div style="font-size:11px;color:#fca5a5;margin-top:4px">@ ${bid:.2f}</div>
      <div style="font-size:11px;color:#fca5a5">SL ${atr_m5*SL_ATR_MULTI:.2f} above</div>
      <div style="font-size:11px;color:#fca5a5">TP ${atr_m5*TP_ATR_MULTI:.2f} below</div>
    </button>

    <!-- CLOSE ALL -->
    <button id="btn-close" onclick="sendManual('CLOSE')"
      style="background:#1c1f26;border:2px solid #64748b;border-radius:10px;
             padding:16px 8px;cursor:pointer;transition:all .15s">
      <div style="font-size:22px;font-weight:900;color:#94a3b8"> CLOSE</div>
      <div style="font-size:11px;color:#64748b;margin-top:4px">ALL positions</div>
      <div style="font-size:11px;color:#64748b">Close all orders</div>
      <div style="font-size:11px;color:#64748b">&nbsp;</div>
    </button>

  </div>

  <!-- Status message -->
  <div id="order-status" style="margin-top:12px;padding:10px;border-radius:6px;
       font-size:12px;font-weight:bold;display:none;text-align:center"></div>

  <!-- Risk warning -->
  <div style="margin-top:10px;font-size:10px;color:#374151;text-align:center">
    Manual orders still follow risk rules: Loss <= {MAX_LOSS_PERCENT}% | <= {MAX_DAILY_TRADES} trades/day
  </div>
</div>

<div class="card">
  <h3>Trade History Today</h3>
  <table>
    <tr><th>Time</th><th>Type</th><th>Ticket</th><th>Source</th></tr>
    {rows if rows else "<tr><td colspan='4' style='color:#334155;text-align:center;padding:12px'>No trades yet today</td></tr>"}
  </table>
</div>
<p style="margin-top:8px;color:#1e293b;font-size:10px">Auto refresh 1s</p>

<script>
async function sendManual(action) {{
  const status = document.getElementById('order-status');

  // Disable buttons while request is in-flight
  ['buy','sell','close'].forEach(b => {{
    document.getElementById('btn-' + b).disabled = true;
    document.getElementById('btn-' + b).style.opacity = '0.5';
  }});

  status.style.display = 'block';
  status.style.background = '#1e293b';
  status.style.color = '#94a3b8';
  status.textContent = 'Sending ' + action + ' to MT4...';

  try {{
    const res = await fetch('/manual_order', {{
      method: 'POST',
      headers: {{'Content-Type': 'application/json'}},
      body: JSON.stringify({{
        action: action,
        close_ticket: 0
      }})
    }});
    const data = await res.json();

    if (res.ok && data.status === 'queued') {{
      status.style.background = '#064e3b';
      status.style.color = '#6ee7b7';
      status.textContent = action + ' queued. Waiting EA result...';
      waitOrderResult(action);
    }} else if (res.status === 403) {{
      status.style.background = '#450a0a';
      status.style.color = '#fca5a5';
      status.textContent = data.msg || 'Blocked by risk limits';
    }} else {{
      status.style.background = '#451a03';
      status.style.color = '#fed7aa';
      status.textContent = 'Error: ' + (data.msg || 'Unknown error');
    }}
  }} catch(e) {{
    status.style.background = '#450a0a';
    status.style.color = '#fca5a5';
    status.textContent = 'Server error: ' + e.message;
  }}

  // Re-enable buttons quickly for rapid retries
  setTimeout(() => {{
    ['buy','sell','close'].forEach(b => {{
      document.getElementById('btn-' + b).disabled = false;
      document.getElementById('btn-' + b).style.opacity = '1';
    }});
  }}, 1200);
}}

async function waitOrderResult(expectedAction) {{
  const status = document.getElementById('order-status');
  const start = Date.now();
  const timeoutMs = 30000;
  while (Date.now() - start < timeoutMs) {{
    try {{
      const r = await fetch('/order_status');
      const s = await r.json();
      const stage = (s.stage || '').toLowerCase();
      const act = (s.action || '').toUpperCase();

      if (act && act !== '-' && act !== expectedAction) {{
        await new Promise(x => setTimeout(x, 250));
        continue;
      }}

      if (stage === 'filled') {{
        status.style.background = '#064e3b';
        status.style.color = '#6ee7b7';
        status.textContent = 'FILLED | ' + s.action + ' | ticket ' + s.ticket + ' | ' + s.msg;
        return;
      }}
      if (stage === 'failed') {{
        status.style.background = '#450a0a';
        status.style.color = '#fca5a5';
        status.textContent = 'FAILED | ' + s.action + ' | ' + s.msg;
        return;
      }}
      if (stage === 'sent_to_ea') {{
        status.style.background = '#0c4a6e';
        status.style.color = '#7dd3fc';
        status.textContent = 'SENT TO EA | ' + s.action + ' | waiting broker response...';
      }}
    }} catch (e) {{}}
    await new Promise(x => setTimeout(x, 250));
  }}
  status.style.background = '#451a03';
  status.style.color = '#fed7aa';
  status.textContent = 'Timeout waiting order result. Check MT4 Experts/Journal.';
}}

// Hover effects
document.querySelectorAll('button').forEach(btn => {{
  btn.addEventListener('mouseenter', () => btn.style.transform = 'scale(1.03)');
  btn.addEventListener('mouseleave', () => btn.style.transform = 'scale(1)');
}});
</script>
</body></html>"""


# 
if __name__ == "__main__":
    log.info("XAUUSD Pullback AI Server v5")
    log.info(f"   URL    : http://{SERVER_HOST}:{SERVER_PORT}")
    log.info("   Logic  : H4 -> H1 -> M15 -> M5 Pullback Entry")
    log.info(f"   Conf   : >= {MIN_CONFIDENCE}%  |  Interval: {MIN_INTERVAL_SEC}s")
    log.info(f"   SL=ATR x {SL_ATR_MULTI} | TP=ATR x {TP_ATR_MULTI}")
    log.info(f"   File   : {os.path.join(MT4_FILES_DIR, MT4_MARKET_FILE)}")
    watcher = threading.Thread(target=watch_mt4_file, daemon=True)
    watcher.start()
    app.run(host=SERVER_HOST, port=SERVER_PORT, debug=False)
