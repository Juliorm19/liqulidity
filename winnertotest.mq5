//+------------------------------------------------------------------+
//|                                          KevinDaveyStrategyEA.mq5|
//|                      Creado por un Asistente AI para un Prompt   |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Creado por un Asistente AI"
#property link      "https://www.google.com"
#property version   "1.00"
#property description "Asesor Experto basado en la estrategia de seguimiento de tendencia de Kevin Davey."

#include <Trade\Trade.mqh>

//--- Enumeración para el modo de tamaño de lote
enum ENUM_LOT_SIZE_MODE
  {
   LOT_MODE_FIXED,      // Lote Fijo
   LOT_MODE_PERCENTAGE  // Riesgo Porcentual
  };

//--- Parámetros de Entrada (Inputs)
input group "Parámetros de Trading"
input long                MagicNumber          = 13579;              // Número Mágico del EA
input ENUM_LOT_SIZE_MODE  LotSizeMode          = LOT_MODE_PERCENTAGE;  // Modo de cálculo de lote
input double              FixedLotSize         = 0.01;               // Tamaño del lote si el modo es Fijo
input double              RiskPercentage       = 1.0;                // Porcentaje de riesgo por operación
input double              RiskRewardRatio      = 2.0;                // Relación Riesgo/Recompensa para el TP
input int                 Slippage             = 5;                  // Deslizamiento máximo en puntos

input group "Parámetros de Indicadores"
input int                 SlowMA_Period        = 200;                // Período de la SMA lenta
input int                 FastMA_Period        = 50;                 // Período de la SMA rápida
input int                 RSI_Period           = 14;                 // Período del RSI
input int                 RSI_Overbought_Level = 60;                 // Nivel de sobrecompra del RSI
input int                 RSI_Oversold_Level   = 40;                 // Nivel de sobreventa del RSI

input group "Parámetros de Salida y Gestión"
input int                 SwingLookbackPeriod  = 15;                 // Período para buscar Swing High/Low
input bool                UseTimeExit          = false;              // Habilitar/deshabilitar la salida por tiempo
input int                 MaxBarsOpen          = 100;                // Máximo de velas que una operación puede estar abierta
input string              Comment              = "KevinDaveyEA";     // Comentario para las órdenes

//--- Instancia de la clase CTrade para gestionar operaciones
CTrade trade;

//--- Handles de los indicadores
int h_slowMA;
int h_fastMA;
int h_rsi;

//+------------------------------------------------------------------+
//| Función de inicialización del Asesor Experto                     |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Inicializar el objeto de trading
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(Slippage);

//--- Crear handles para los indicadores
   h_slowMA = iMA(_Symbol, _Period, SlowMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   if(h_slowMA == INVALID_HANDLE)
     {
      printf("Error creando el handle de la SMA Lenta. Código de error: %d", GetLastError());
      return(INIT_FAILED);
     }

   h_fastMA = iMA(_Symbol, _Period, FastMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   if(h_fastMA == INVALID_HANDLE)
     {
      printf("Error creando el handle de la SMA Rápida. Código de error: %d", GetLastError());
      return(INIT_FAILED);
     }

   h_rsi = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
   if(h_rsi == INVALID_HANDLE)
     {
      printf("Error creando el handle del RSI. Código de error: %d", GetLastError());
      return(INIT_FAILED);
     }

//--- Éxito
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Función de desinicialización del Asesor Experto                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Liberar los handles de los indicadores
   IndicatorRelease(h_slowMA);
   IndicatorRelease(h_fastMA);
   IndicatorRelease(h_rsi);
  }

//+------------------------------------------------------------------+
//| Función de tick del Asesor Experto                               |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Usamos un manejador de nueva barra para ejecutar la lógica solo una vez por vela
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
//--- Asegurarse de que hay suficientes barras para los cálculos
   if(Bars(_Symbol, _Period) < SlowMA_Period + 5)
     {
      return;
     }

//--- Comprobar si ya hay una posición abierta por este EA en este símbolo
   if(PositionSelectByTicket(GetOpenPositionTicket()))
     {
      // Si hay una posición, gestionar la salida por tiempo si está activada
      ManageTimeExit();
      return; // No buscar nuevas entradas si ya hay una posición
     }

//--- No hay posiciones abiertas, buscar una nueva señal de entrada
   CheckForEntrySignal();
  }

//+------------------------------------------------------------------+
//| Verifica las condiciones de entrada para compra y venta          |
//+------------------------------------------------------------------+
void CheckForEntrySignal()
  {
//--- Obtener los datos de precios e indicadores necesarios
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 0, 3, rates) < 3) return; // Necesitamos 3 barras para la lógica

   double sma_slow_buffer[3];
   double sma_fast_buffer[3];
   double rsi_buffer[3];

   if(CopyBuffer(h_slowMA, 0, 0, 3, sma_slow_buffer) < 3) return;
   if(CopyBuffer(h_fastMA, 0, 0, 3, sma_fast_buffer) < 3) return;
   if(CopyBuffer(h_rsi, 0, 0, 3, rsi_buffer) < 3) return;

//--- La lógica se basa en barras completadas.
//--- rates[2] es la "vela de condición"
//--- rates[1] es la "vela de gatillo"
//--- rates[0] es la barra actual en formación

//--- Verificar condiciones de COMPRA
   bool isUptrend = rates[2].close > sma_slow_buffer[2];
   bool isRetracement = rates[2].low <= sma_fast_buffer[2];
   bool isOversold = rsi_buffer[2] <= RSI_Oversold_Level;
   bool isTriggerCandleBullish = rates[1].close > rates[1].open;
   bool isTriggerFired = rates[1].close > rates[2].high;

   if(isUptrend && isRetracement && isOversold && isTriggerCandleBullish && isTriggerFired)
     {
      //--- Condiciones de compra cumplidas, proceder a abrir la orden
      double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double stop_loss = FindSwingLow(SwingLookbackPeriod);
      if(stop_loss == 0) return; // No se pudo encontrar un SL válido

      double risk_pips = (entry_price - stop_loss) / _Point;
      if(risk_pips <= 0) return; // Riesgo inválido

      double take_profit = entry_price + (risk_pips * RiskRewardRatio * _Point);
      double lot_size = CalculateLotSize(stop_loss, entry_price);

      if(lot_size > 0)
        {
         trade.Buy(lot_size, _Symbol, entry_price, stop_loss, take_profit, Comment);
        }
      return; // Salir después de intentar abrir una orden
     }

//--- Verificar condiciones de VENTA
   bool isDowntrend = rates[2].close < sma_slow_buffer[2];
   bool isPullback = rates[2].high >= sma_fast_buffer[2];
   bool isOverbought = rsi_buffer[2] >= RSI_Overbought_Level;
   bool isTriggerCandleBearish = rates[1].close < rates[1].open;
   bool isSellTriggerFired = rates[1].close < rates[2].low;

   if(isDowntrend && isPullback && isOverbought && isTriggerCandleBearish && isSellTriggerFired)
     {
      //--- Condiciones de venta cumplidas, proceder a abrir la orden
      double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double stop_loss = FindSwingHigh(SwingLookbackPeriod);
      if(stop_loss == 0) return; // No se pudo encontrar un SL válido

      double risk_pips = (stop_loss - entry_price) / _Point;
      if(risk_pips <= 0) return; // Riesgo inválido

      double take_profit = entry_price - (risk_pips * RiskRewardRatio * _Point);
      double lot_size = CalculateLotSize(stop_loss, entry_price);

      if(lot_size > 0)
        {
         trade.Sell(lot_size, _Symbol, entry_price, stop_loss, take_profit, Comment);
        }
      return; // Salir después de intentar abrir una orden
     }
  }

//+------------------------------------------------------------------+
//| Calcula el tamaño del lote basado en el modo seleccionado        |
//+------------------------------------------------------------------+
double CalculateLotSize(double stop_loss_price, double entry_price)
  {
   if(LotSizeMode == LOT_MODE_FIXED)
     {
      return(FixedLotSize);
     }

   //--- Cálculo por Riesgo Porcentual
   double lot_size = 0.0;
   double account_balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = account_balance * (RiskPercentage / 100.0);
   double risk_per_lot = 0.0;
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_size == 0 || tick_value == 0) return 0.0;

   double points_at_risk = MathAbs(entry_price - stop_loss_price);
   risk_per_lot = points_at_risk / tick_size * tick_value;

   if(risk_per_lot > 0)
     {
      lot_size = risk_amount / risk_per_lot;
     }

   //--- Normalizar el tamaño del lote
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot_size = MathFloor(lot_size / volume_step) * volume_step;

   //--- Validar contra los límites de volumen
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
   if(CopyRates(_Symbol, _Period, 1, lookback_period, rates) < lookback_period)
     {
      return 0.0; // No hay suficientes datos
     }

   double swing_low = rates[0].low;
   for(int i = 1; i < lookback_period; i++)
     {
      if(rates[i].low < swing_low)
        {
         swing_low = rates[i].low;
        }
     }
   return swing_low;
  }

//+------------------------------------------------------------------+
//| Encuentra el máximo más alto (swing high) en un período          |
//+------------------------------------------------------------------+
double FindSwingHigh(int lookback_period)
  {
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, lookback_period, rates) < lookback_period)
     {
      return 0.0; // No hay suficientes datos
     }

   double swing_high = rates[0].high;
   for(int i = 1; i < lookback_period; i++)
     {
      if(rates[i].high > swing_high)
        {
         swing_high = rates[i].high;
        }
     }
   return swing_high;
  }

//+------------------------------------------------------------------+
//| Gestiona la salida por tiempo si está activada                   |
//+------------------------------------------------------------------+
void ManageTimeExit()
  {
   if(!UseTimeExit) return;

   long position_ticket = GetOpenPositionTicket();
   if(position_ticket > 0)
     {
      ulong position_open_time = PositionGetInteger(POSITION_TIME);
      long position_open_bar = iBarShift(_Symbol, _Period, (datetime)position_open_time);
      long current_bar = iBarShift(_Symbol, _Period, TimeCurrent());

      if(position_open_bar - current_bar >= MaxBarsOpen)
        {
         // Cerrar la posición
         trade.PositionClose(position_ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Obtiene el ticket de la primera posición abierta por este EA     |
//+------------------------------------------------------------------+
long GetOpenPositionTicket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol)
        {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            return PositionGetInteger(POSITION_TICKET);
           }
        }
     }
   return 0;
  }
//+------------------------------------------------------------------+
