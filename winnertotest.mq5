//+------------------------------------------------------------------+
//|                                     KevinDaveyStrategyEA_v2.mq5  |
//|                      Optimizado por un Asistente AI              |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Optimizado por un Asistente AI"
#property link      "https://www.google.com"
#property version   "2.00"
#property description "Versión optimizada del EA de Kevin Davey con filtros de horario, volatilidad (ATR) y trailing stop."

#include <Trade\Trade.mqh>

//--- Enumeraciones para modos de configuración
enum ENUM_LOT_SIZE_MODE
  {
   LOT_MODE_FIXED,      // Lote Fijo
   LOT_MODE_PERCENTAGE  // Riesgo Porcentual
  };

enum ENUM_EXIT_STRATEGY_MODE
  {
   EXIT_FIXED_TP_RR,      // Take Profit fijo por Ratio R/R
   EXIT_TRAILING_STOP_ATR // Trailing Stop basado en ATR
  };

//--- Parámetros de Entrada (Inputs)
input group "Gestión de Riesgo y Magia"
input long                MagicNumber          = 13580;              // Número Mágico del EA
input ENUM_LOT_SIZE_MODE  LotSizeMode          = LOT_MODE_PERCENTAGE;  // Modo de cálculo de lote
input double              FixedLotSize         = 0.01;               // Tamaño del lote si el modo es Fijo
input double              RiskPercentage       = 1.0;                // Porcentaje de riesgo por operación
input int                 Slippage             = 5;                  // Deslizamiento máximo en puntos
input string              Comment              = "KevinDaveyEA_v2";  // Comentario para las órdenes

input group "Filtros de Horario y Día"
input bool                UseTimeFilter        = true;               // Habilitar filtro de horario?
input int                 Session1_Start_Hour  = 8;                  // Hora de inicio de la sesión 1 (0-23)
input int                 Session1_End_Hour    = 11;                 // Hora de fin de la sesión 1 (0-23)
input int                 Session2_Start_Hour  = 14;                 // Hora de inicio de la sesión 2 (0-23)
input int                 Session2_End_Hour    = 18;                 // Hora de fin de la sesión 2 (0-23)
input bool                TradeOnMonday        = true;               // Operar los Lunes?
input bool                TradeOnTuesday       = true;               // Operar los Martes?
input bool                TradeOnWednesday     = true;               // Operar los Miércoles?
input bool                TradeOnThursday      = true;               // Operar los Jueves?
input bool                TradeOnFriday        = true;               // Operar los Viernes?

input group "Filtros de Estrategia (Optimización)"
input bool                UseAtrFilter         = true;               // Habilitar filtro de volatilidad ATR?
input int                 ATR_Period           = 14;                 // Período del ATR
input double              MinAtrValuePips      = 10.0;               // Volatilidad mínima en pips para operar

input group "Parámetros de Indicadores"
input int                 SlowMA_Period        = 200;                // Período de la SMA lenta
input int                 FastMA_Period        = 50;                 // Período de la SMA rápida
input int                 RSI_Period           = 14;                 // Período del RSI
input int                 RSI_Overbought_Level = 60;                 // Nivel de sobrecompra del RSI
input int                 RSI_Oversold_Level   = 40;                 // Nivel de sobreventa del RSI
input int                 SwingLookbackPeriod  = 15;                 // Período para buscar Swing High/Low

input group "Estrategia de Salida"
input ENUM_EXIT_STRATEGY_MODE ExitStrategyMode = EXIT_TRAILING_STOP_ATR; // Modo de estrategia de salida
input double              RiskRewardRatio      = 2.0;                // Ratio R/R (si se usa TP Fijo)
input double              TrailingStopAtrMultiplier = 2.5;           // Múltiplo de ATR para el Trailing Stop

//--- Instancia de la clase CTrade
CTrade trade;

//--- Handles de los indicadores
int h_slowMA;
int h_fastMA;
int h_rsi;
int h_atr;

//+------------------------------------------------------------------+
//| Función de inicialización del Asesor Experto                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(Slippage);

   h_slowMA = iMA(_Symbol, _Period, SlowMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   h_fastMA = iMA(_Symbol, _Period, FastMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   h_rsi = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
   h_atr = iATR(_Symbol, _Period, ATR_Period);

   if(h_slowMA==INVALID_HANDLE || h_fastMA==INVALID_HANDLE || h_rsi==INVALID_HANDLE || h_atr==INVALID_HANDLE)
     {
      printf("Error creando handles de indicadores. Código: %d", GetLastError());
      return(INIT_FAILED);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Función de desinicialización del Asesor Experto                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(h_slowMA);
   IndicatorRelease(h_fastMA);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_atr);
  }

//+------------------------------------------------------------------+
//| Función de tick del Asesor Experto                               |
//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime lastBarTime = 0;
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(lastBarTime != currentBarTime)
     {
      lastBarTime = currentBarTime;
      OnNewBar();
     }
  }

//+------------------------------------------------------------------+
//| Lógica principal que se ejecuta en cada nueva barra              |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   if(Bars(_Symbol, _Period) < SlowMA_Period + 5) return;

   long open_position_ticket = GetOpenPositionTicket();
   if(open_position_ticket > 0)
     {
      ManageExits(open_position_ticket);
      return;
     }

   if(!IsTradingAllowed()) return;

   CheckForEntrySignal();
  }

//+------------------------------------------------------------------+
//| Verifica si el trading está permitido por horario y día          |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
  {
   if(!UseTimeFilter) return true;

   MqlDateTime dt;
   TimeCurrent(dt); // Obtiene la hora del servidor

   // Verificar día de la semana
   bool isDayAllowed = false;
   switch(dt.day_of_week)
     {
      case 1: isDayAllowed = TradeOnMonday;    break; // Monday
      case 2: isDayAllowed = TradeOnTuesday;   break; // Tuesday
      case 3: isDayAllowed = TradeOnWednesday; break; // Wednesday
      case 4: isDayAllowed = TradeOnThursday;  break; // Thursday
      case 5: isDayAllowed = TradeOnFriday;    break; // Friday
     }
   if(!isDayAllowed) return false;

   // Verificar hora
   bool isTimeAllowed = false;
   if(dt.hour >= Session1_Start_Hour && dt.hour < Session1_End_Hour) isTimeAllowed = true;
   if(dt.hour >= Session2_Start_Hour && dt.hour < Session2_End_Hour) isTimeAllowed = true;

   return isTimeAllowed;
  }

//+------------------------------------------------------------------+
//| Verifica las condiciones de entrada para compra y venta          |
//+------------------------------------------------------------------+
void CheckForEntrySignal()
  {
//--- Filtro de Volatilidad ATR
   if(UseAtrFilter)
     {
      double atr_buffer[1];
      if(CopyBuffer(h_atr, 0, 1, 1, atr_buffer) < 1) return;
      if(atr_buffer[0] / _Point < MinAtrValuePips) return; // Salir si la volatilidad es muy baja
     }

   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 0, 3, rates) < 3) return;

   double sma_slow_buffer[3], sma_fast_buffer[3], rsi_buffer[3];
   if(CopyBuffer(h_slowMA, 0, 0, 3, sma_slow_buffer)<3 || CopyBuffer(h_fastMA, 0, 0, 3, sma_fast_buffer)<3 || CopyBuffer(h_rsi, 0, 0, 3, rsi_buffer)<3) return;

   //--- Condiciones de COMPRA (en la vela completada anterior, índice 2)
   bool isUptrend = rates[2].close > sma_slow_buffer[2];
   bool isRetracement = rates[2].low <= sma_fast_buffer[2];
   bool isOversold = rsi_buffer[2] <= RSI_Oversold_Level;
   bool isTriggerCandleBullish = rates[1].close > rates[1].open;
   bool isTriggerFired = rates[1].close > rates[2].high;

   if(isUptrend && isRetracement && isOversold && isTriggerCandleBullish && isTriggerFired)
     {
      double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double stop_loss = FindSwingLow(SwingLookbackPeriod);
      if(stop_loss == 0 || stop_loss >= entry_price) return;

      double take_profit = 0.0;
      if(ExitStrategyMode == EXIT_FIXED_TP_RR)
        {
         double risk_pips = (entry_price - stop_loss) / _Point;
         take_profit = entry_price + (risk_pips * RiskRewardRatio * _Point);
        }

      double lot_size = CalculateLotSize(stop_loss, entry_price);
      if(lot_size > 0) trade.Buy(lot_size, _Symbol, entry_price, stop_loss, take_profit, Comment);
      return;
     }

   //--- Condiciones de VENTA (en la vela completada anterior, índice 2)
   bool isDowntrend = rates[2].close < sma_slow_buffer[2];
   bool isPullback = rates[2].high >= sma_fast_buffer[2];
   bool isOverbought = rsi_buffer[2] >= RSI_Overbought_Level;
   bool isTriggerCandleBearish = rates[1].close < rates[1].open;
   bool isSellTriggerFired = rates[1].close < rates[2].low;

   if(isDowntrend && isPullback && isOverbought && isTriggerCandleBearish && isSellTriggerFired)
     {
      double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double stop_loss = FindSwingHigh(SwingLookbackPeriod);
      if(stop_loss == 0 || stop_loss <= entry_price) return;

      double take_profit = 0.0;
      if(ExitStrategyMode == EXIT_FIXED_TP_RR)
        {
         double risk_pips = (stop_loss - entry_price) / _Point;
         take_profit = entry_price - (risk_pips * RiskRewardRatio * _Point);
        }

      double lot_size = CalculateLotSize(stop_loss, entry_price);
      if(lot_size > 0) trade.Sell(lot_size, _Symbol, entry_price, stop_loss, take_profit, Comment);
      return;
     }
  }

//+------------------------------------------------------------------+
//| Gestiona las salidas de una posición abierta                     |
//+------------------------------------------------------------------+
void ManageExits(long ticket)
  {
   if(ExitStrategyMode == EXIT_TRAILING_STOP_ATR)
     {
      ManageTrailingStop(ticket);
     }
   // La gestión de salida por tiempo se mantiene igual
   ManageTimeExit(ticket);
  }

//+------------------------------------------------------------------+
//| Gestiona el Trailing Stop basado en ATR                          |
//+------------------------------------------------------------------+
void ManageTrailingStop(long ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;

   double atr_buffer[1];
   if(CopyBuffer(h_atr, 0, 1, 1, atr_buffer) < 1) return;
   double trail_distance = atr_buffer[0] * TrailingStopAtrMultiplier;

   double current_sl = PositionGetDouble(POSITION_SL);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   long type = PositionGetInteger(POSITION_TYPE);

   if(type == POSITION_TYPE_BUY)
     {
      double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double new_sl = current_price - trail_distance;
      // Mover el SL solo si es más alto que el SL actual y asegura algo de ganancia
      if(new_sl > current_sl && new_sl > open_price)
        {
         trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
        }
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double new_sl = current_price + trail_distance;
      // Mover el SL solo si es más bajo que el SL actual y asegura algo de ganancia
      if(new_sl < current_sl && new_sl < open_price)
        {
         trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
        }
     }
  }

//+------------------------------------------------------------------+
//| Gestiona la salida por tiempo si está activada                   |
//+------------------------------------------------------------------+
void ManageTimeExit(long ticket)
  {
   if(!UseTimeExit) return;
   if(!PositionSelectByTicket(ticket)) return;

   ulong position_open_time = PositionGetInteger(POSITION_TIME);
   long position_open_bar = iBarShift(_Symbol, _Period, (datetime)position_open_time);
   long current_bar = iBarShift(_Symbol, _Period, TimeCurrent());

   if(position_open_bar - current_bar >= MaxBarsOpen)
     {
      trade.PositionClose(ticket);
     }
  }

//--- Las funciones de ayuda (CalculateLotSize, FindSwingLow/High, GetOpenPositionTicket) permanecen sin cambios ---
//--- (Se omiten por brevedad, pero deben estar presentes en el archivo final. Pega el código completo) ---

//+------------------------------------------------------------------+
//| Calcula el tamaño del lote basado en el modo seleccionado        |
//+------------------------------------------------------------------+
double CalculateLotSize(double stop_loss_price, double entry_price)
  {
   if(LotSizeMode == LOT_MODE_FIXED) return(FixedLotSize);
   double lot_size = 0.0;
   double account_balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = account_balance * (RiskPercentage / 100.0);
   double risk_per_lot = 0.0;
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size == 0 || tick_value == 0) return 0.0;
   double points_at_risk = MathAbs(entry_price - stop_loss_price);
   risk_per_lot = points_at_risk / tick_size * tick_value;
   if(risk_per_lot > 0) lot_size = risk_amount / risk_per_lot;
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot_size = MathFloor(lot_size / volume_step) * volume_step;
   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot_size < min_volume) lot_size = min_volume;
   if(lot_size > max_volume) lot_size = max_volume;
   return(lot_size);
  }
//+------------------------------------------------------------------+
//| Encuentra el mínimo más bajo (swing low) en un período           |
//+------------------------------------------------------------------+
double FindSwingLow(int lookback_period)
  {
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, lookback_period, rates) < lookback_period) return 0.0;
   double swing_low = rates[0].low;
   for(int i = 1; i < lookback_period; i++)
     {
      if(rates[i].low < swing_low) swing_low = rates[i].low;
     }
   return swing_low;
  }
//+------------------------------------------------------------------+
//| Encuentra el máximo más alto (swing high) en un período          |
//+------------------------------------------------------------------+
double FindSwingHigh(int lookback_period)
  {
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, lookback_period, rates) < lookback_period) return 0.0;
   double swing_high = rates[0].high;
   for(int i = 1; i < lookback_period; i++)
     {
      if(rates[i].high > swing_high) swing_high = rates[i].high;
     }
   return swing_high;
  }
//+------------------------------------------------------------------+
//| Obtiene el ticket de la primera posición abierta por este EA     |
//+------------------------------------------------------------------+
long GetOpenPositionTicket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
         return PositionGetInteger(POSITION_TICKET);
        }
     }
   return 0;
  }
//+------------------------------------------------------------------+
