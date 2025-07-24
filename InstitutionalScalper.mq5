//+------------------------------------------------------------------+
//|                                         InstitutionalScalper.mq5 |
//|                                    Copyright 2025, Julio Rosario |
//|                                          https://www.jrcores.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Julio Rosario"
#property link      "https://www.jrcores.com"
#property version   "1.05"
#property description "An EA for institutional scalping strategy."
#property strict

#include <Trade\Trade.mqh>

//--- Forward declaration of classes
class CLogger;
class CInstrumentManager;
class CSessionManager;
class CCompliance;
class CRiskManager;
class CSignalProvider;
class CTradeManager;

//--- Input Parameters ---

// Group: Core Strategy
input group "Strategy Parameters"
input int      InpEmaFastPeriod_M5 = 5;      // 5-Min Fast EMA Period
input int      InpEmaSlowPeriod_M5 = 20;     // 5-Min Slow EMA Period
input int      InpStochK_M1        = 5;      // 1-Min Stochastic %K
input int      InpStochD_M1        = 3;      // 1-Min Stochastic %D
input int      InpStochSlowing_M1  = 3;      // 1-Min Stochastic Slowing
input double   InpVolumeMultiplier = 1.5;    // Volume must be X times SMA
input int      InpBreakoutPoints   = 3;      // Points above/below previous bar

// Group: Instrument & Session Filters
input group "Instrument & Session Filters"
input double   InpMaxSpreadPips    = 3.0;    // Max allowed spread in pips
input double   InpMinDailyATR      = 15.0;   // Min daily ATR in pips (simplified filter)
input long     InpMinDailyVolume   = 5000000;// Min daily volume
input int      InpBrokerGmtOffset  = 3;      // Broker Server GMT Offset (e.g., GMT+3)
input int      InpEstGmtOffset     = -4;     // EST GMT Offset (e.g., EDT is -4)

// Group: Risk Management
input group "Risk & Exit Management"
input double   InpRiskPerTrade     = 0.0025; // Position Size Risk (0.25%)
input double   InpStopLossAtrMult  = 1.5;    // Stop Loss ATR (M1, 14) Multiplier
input int      InpAtrPeriod        = 14;     // ATR Period for SL and Trailing
input int      InpTimeStopSeconds  = 180;    // Max position holding time (seconds)
input double   InpTrailingStopAtrMult = 0.75; // Trailing Stop ATR Multiplier

// Group: Daily Circuit Breakers
input group "Daily Circuit Breakers"
input double   InpDrawdownThrottle = -0.015; // Halve risk at -1.5% daily drawdown
input double   InpDrawdownHalt     = -0.025; // Terminate all trades at -2.5%

//--- Global Objects ---
CTrade              trade;
CLogger             logger;
CInstrumentManager  instrumentManager;
CSessionManager     sessionManager;
CCompliance         compliance;
CRiskManager        riskManager;
CSignalProvider     signalProvider;
CTradeManager       tradeManager;

//+------------------------------------------------------------------+
//| CLogger: Handles logging of decisions and errors.                |
//+------------------------------------------------------------------+
class CLogger
{
public:
    void Log(string message)
    {
        Print(TimeCurrent(), ": ", message);
    }
};

//+------------------------------------------------------------------+
//| CInstrumentManager: Checks if a symbol meets trading criteria.   |
//+------------------------------------------------------------------+
class CInstrumentManager
{
public:
    bool IsTradable(const string symbol, const double max_spread, const double min_atr, const long min_volume)
    {
        // 1. Spread Check
        double current_spread = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / SymbolInfoDouble(symbol, SYMBOL_POINT);
        if(current_spread > max_spread)
            return false;

        // 2. ATR Check (Simplified: checks if ATR is above a minimum value)
        double atr_values[1];
        if(CopyBuffer(iATR(symbol, PERIOD_D1, 14), 0, 0, 1, atr_values) < 1) return false;
        if(atr_values[0] / SymbolInfoDouble(symbol, SYMBOL_POINT) < min_atr)
            return false;

        // 3. Volume Check
        MqlRates rates[1];
        if(CopyRates(symbol, PERIOD_D1, 0, 1, rates) < 1) return false;
        if(rates[0].tick_volume < min_volume)
            return false;

        return true;
    }
};

//+------------------------------------------------------------------+
//| CSessionManager: Manages trading based on market sessions.       |
//+------------------------------------------------------------------+
class CSessionManager
{
public:
    bool IsTradingSessionActive(int brokerGmtOffset, int estGmtOffset)
    {
        datetime server_time = TimeCurrent();
        long time_diff_seconds = (long)(estGmtOffset - brokerGmtOffset) * 3600;
        datetime est_time = server_time + time_diff_seconds;

        MqlDateTime dt;
        TimeToStruct(est_time, dt);

        // Trading allowed between 08:30 and 16:00 EST
        if((dt.hour > 8 || (dt.hour == 8 && dt.min >= 30)) && dt.hour < 16)
        {
            return true;
        }
        return false;
    }
};

//+------------------------------------------------------------------+
//| CCompliance: Performs pre-trade compliance checks.               |
//+------------------------------------------------------------------+
class CCompliance
{
public:
    // NOTE: Sector exposure and correlation are highly complex and require external data.
    // This is a simplified placeholder for the volume check.
    bool PreTradeCheck(const string symbol, const double lot_size)
    {
        // Auto-reject if order > 5% of 1-min bar volume
        MqlRates rates_m1[1];
        if(CopyRates(symbol, PERIOD_M1, 0, 1, rates_m1) < 1) return false;

        double one_min_volume = rates_m1[0].tick_volume;
        double order_volume_approx = lot_size * SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);

        if(one_min_volume > 0 && (order_volume_approx / one_min_volume) > 0.05)
        {
            logger.Log("Compliance Block: Order size exceeds 5% of 1-min bar volume.");
            return false;
        }
        return true;
    }
};

//+------------------------------------------------------------------+
//| CRiskManager: Handles position sizing and drawdown controls.     |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
    double m_daily_starting_equity;
    int    m_last_check_day;

public:
    void Init()
    {
        m_daily_starting_equity = AccountInfoDouble(ACCOUNT_EQUITY);
        m_last_check_day = TimeCurrent() / 86400;
    }

    void CheckNewDay()
    {
        int current_day = TimeCurrent() / 86400;
        if(current_day != m_last_check_day)
        {
            m_daily_starting_equity = AccountInfoDouble(ACCOUNT_EQUITY);
            m_last_check_day = current_day;
            logger.Log("New trading day started. Daily P&L reset.");
        }
    }

    double GetDrawdownMultiplier(double throttle_level, double halt_level)
    {
        double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
        double drawdown = (current_equity / m_daily_starting_equity) - 1.0;

        if(drawdown <= halt_level)
        {
            return 0.0; // Halt trading
        }
        if(drawdown <= throttle_level)
        {
            return 0.5; // Throttle risk
        }
        return 1.0; // Normal risk
    }

    double CalculatePositionSize(double risk_percent, double stop_loss_pips)
    {
        if(stop_loss_pips <= 0) return 0.01;

        double account_equity = AccountInfoDouble(ACCOUNT_EQUITY);
        double risk_amount = account_equity * risk_percent;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

        if(tick_value <= 0 || tick_size <= 0) return 0.01;

        double sl_monetary_value_per_lot = stop_loss_pips * _Point / tick_size * tick_value;
        if(sl_monetary_value_per_lot <= 0) return 0.01;

        double position_size = risk_amount / sl_monetary_value_per_lot;

        // Normalize and clamp lot size
        double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        position_size = lot_step * floor(position_size / lot_step);
        position_size = fmax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), position_size);
        position_size = fmin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), position_size);

        return position_size;
    }
};

//+------------------------------------------------------------------+
//| CSignalProvider: Identifies trading signals.                     |
//+------------------------------------------------------------------+
class CSignalProvider
{
private:
    double m_stop_loss_pips;

public:
    int GetSignal()
    {
        m_stop_loss_pips = 0;

        // 1. 5-Min Trend Filter
        double ema_fast_m5[2], ema_slow_m5[2];
        if(CopyBuffer(iMA(_Symbol, PERIOD_M5, InpEmaFastPeriod_M5, 0, MODE_EMA, PRICE_CLOSE), 0, 0, 2, ema_fast_m5) < 2) return 0;
        if(CopyBuffer(iMA(_Symbol, PERIOD_M5, InpEmaSlowPeriod_M5, 0, MODE_EMA, PRICE_CLOSE), 0, 0, 2, ema_slow_m5) < 2) return 0;
        bool is_bullish_trend = ema_fast_m5[1] > ema_slow_m5[1];
        bool is_bearish_trend = ema_fast_m5[1] < ema_slow_m5[1];

        // 2. 1-Min Scalp Trigger
        double stoch_main[2], stoch_signal[2];
        if(CopyBuffer(iStochastic(_Symbol, PERIOD_M1, InpStochK_M1, InpStochD_M1, InpStochSlowing_M1, MODE_SMA, STO_LOWHIGH), 0, 0, 2, stoch_main) < 2) return 0;
        if(CopyBuffer(iStochastic(_Symbol, PERIOD_M1, InpStochK_M1, InpStochD_M1, InpStochSlowing_M1, MODE_SMA, STO_LOWHIGH), 1, 0, 2, stoch_signal) < 2) return 0;

        MqlRates rates_m1[2];
        if(CopyRates(_Symbol, PERIOD_M1, 0, 2, rates_m1) < 2) return 0;

        double sma_vol_values[1];
        if(CopyBuffer(iMA(_Symbol, PERIOD_M1, 20, 0, MODE_SMA, TICKET_VOLUME), 0, 0, 1, sma_vol_values) < 1) return 0;
        double sma_vol = sma_vol_values[0];

        double atr_val[1];
        if(CopyBuffer(iATR(_Symbol, PERIOD_M1, InpAtrPeriod), 0, 0, 1, atr_val) < 1) return 0;
        m_stop_loss_pips = (atr_val[0] * InpStopLossAtrMult) / _Point;

        // --- Long Signal Logic ---
        bool stoch_crossover = stoch_main[1] < 20 && stoch_main[0] > 20;
        bool volume_spike = rates_m1[1].tick_volume > InpVolumeMultiplier * sma_vol;
        bool breakout_high = rates_m1[1].close > rates_m1[0].high + InpBreakoutPoints * _Point;

        if(is_bullish_trend && stoch_crossover && volume_spike && breakout_high)
        {
            return 1; // BUY
        }

        // --- Short Signal Logic ---
        bool stoch_crossunder = stoch_main[1] > 80 && stoch_main[0] < 80;
        bool breakout_low = rates_m1[1].close < rates_m1[0].low - InpBreakoutPoints * _Point;

        if(is_bearish_trend && stoch_crossunder && volume_spike && breakout_low)
        {
            return -1; // SELL
        }

        return 0; // No Signal
    }

    double GetStopLossPips() { return m_stop_loss_pips; }
};

//+------------------------------------------------------------------+
//| CTradeManager: Handles order execution and management.           |
//+------------------------------------------------------------------+
class CTradeManager
{
public:
    bool OpenPosition(int signal_type, double lot_size, double sl_pips)
    {
        if(lot_size <= 0) return false;

        double sl_price = 0;
        double tp1_price = 0;
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if(signal_type == 1) // Buy
        {
            sl_price = ask - sl_pips * _Point;
            tp1_price = ask + sl_pips * _Point; // 1R Target
            if(!trade.Buy(lot_size, _Symbol, ask, sl_price, 0, "InstScalp_Buy"))
            {
                logger.Log("Buy order failed: " + IntegerToString(trade.ResultCode()));
                return false;
            }
        }
        else if(signal_type == -1) // Sell
        {
            sl_price = bid + sl_pips * _Point;
            tp1_price = bid - sl_pips * _Point; // 1R Target
            if(!trade.Sell(lot_size, _Symbol, bid, sl_price, 0, "InstScalp_Sell"))
            {
                logger.Log("Sell order failed: " + IntegerToString(trade.ResultCode()));
                return false;
            }
        }
        else
        {
            return false;
        }

        // Store TP levels in the position comment for management
        ulong ticket = trade.ResultDeal();
        if(PositionSelectByTicket(ticket))
        {
            string comment = PositionGetString(POSITION_COMMENT) + "|TP1:" + DoubleToString(tp1_price, _Digits);
            PositionModify(ticket, PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), comment);
        }
        logger.Log("Position opened: Ticket " + (string)ticket + ", Lots: " + (string)lot_size);
        return true;
    }

    void ManageOpenPositions()
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(!PositionSelect(i)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

            // 1. Time Stop
            long time_held = TimeCurrent() - (long)PositionGetInteger(POSITION_TIME);
            if(time_held > InpTimeStopSeconds)
            {
                trade.PositionClose(PositionGetTicket());
                logger.Log("Position " + (string)PositionGetTicket() + " closed due to Time Stop.");
                continue;
            }

            // 2. Profit Target Management (Simplified)
            // A full implementation would track partial closes. This is a basic example.
            // For a real system, you'd need to manage state more robustly.
        }
    }

    void TerminateAllTrades()
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(PositionSelect(i))
            {
                trade.PositionClose(PositionGetTicket());
            }
        }
        logger.Log("CIRCUIT BREAKER: All positions terminated due to max daily drawdown.");
    }
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    logger.Log("Initializing Institutional Scalper EA...");
    trade.SetExpertMagicNumber(12345);
    trade.SetTypeFillingBySymbol(_Symbol);
    riskManager.Init();
    EventSetTimer(1); // Timer for periodic checks (e.g., time stops)
    logger.Log("Initialization complete.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    logger.Log("EA Deinitialized. Reason: " + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| Expert tick function (main logic loop)                           |
//+------------------------------------------------------------------+
void OnTick()
{
    // Use OnNewBar to prevent over-trading
    static datetime last_bar_time;
    datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, PERIOD_M1, SERIES_LASTBAR_DATE);
    if(current_bar_time == last_bar_time)
    {
        return; // Not a new M1 bar, do nothing
    }
    last_bar_time = current_bar_time;

    // --- Pre-Trade Checks ---
    
    // 1. Check trading session
    if(!sessionManager.IsTradingSessionActive(InpBrokerGmtOffset, InpEstGmtOffset))
        return;

    // 2. Check if instrument is tradable
    if(!instrumentManager.IsTradable(_Symbol, InpMaxSpreadPips, InpMinDailyATR, InpMinDailyVolume))
        return;

    // 3. Check daily drawdown circuit breaker
    riskManager.CheckNewDay();
    double drawdown_multiplier = riskManager.GetDrawdownMultiplier(InpDrawdownThrottle, InpDrawdownHalt);
    if(drawdown_multiplier == 0.0)
    {
        tradeManager.TerminateAllTrades();
        return; // Halt all new trading activity
    }

    // --- Signal Generation & Execution ---

    // 4. Check for existing positions on this symbol
    if(PositionSelect(_Symbol))
        return; // Don't open a new trade if one already exists

    // 5. Get trading signal
    int signal = signalProvider.GetSignal();
    if(signal == 0)
        return;

    // 6. Calculate position size
    double sl_pips = signalProvider.GetStopLossPips();
    double lot_size = riskManager.CalculatePositionSize(InpRiskPerTrade, sl_pips);
    lot_size *= drawdown_multiplier; // Apply drawdown throttle

    // 7. Final compliance check
    if(!compliance.PreTradeCheck(_Symbol, lot_size))
        return;

    // 8. Execute Trade
    tradeManager.OpenPosition(signal, lot_size, sl_pips);
}

//+------------------------------------------------------------------+
//| Timer function for managing open trades                          |
//+------------------------------------------------------------------+
void OnTimer()
{
    tradeManager.ManageOpenPositions();
}
//+------------------------------------------------------------------+
