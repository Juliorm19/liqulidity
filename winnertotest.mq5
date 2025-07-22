//+------------------------------------------------------------------+
//|                                     KevinDavey_TrendFollower.mq5 |
//|                      Copyright 2025, Asistente AI de Google      |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Asistente AI de Google"
#property link      ""
#property version   "1.00"
#property description "EA basado en la estrategia de seguimiento de tendencia de Kevin Davey."

#include <Trade\Trade.mqh>

//--- Parámetros de Entrada
input group "EA Settings"
input long                MagicNumber          = 123456;              // Número Mágico
input string              Comment              = "KevinDavey_EA";       // Comentario para las órdenes
input int                 Slippage             = 5;                   // Deslizamiento máximo en puntos

input group "Position Sizing"
enum LotSizeMode
  {
   Fixed_Lot,          // Lote Fijo
   Risk_Percentage     // Riesgo Porcentual
  };
input LotSizeMode         LotMode              = Risk_Percentage;     // Modo de cálculo de lote
input double              FixedLotSize         = 0.01;                // Tamaño de lote fijo
input double              RiskPercentage       = 1.0;                 // Porcentaje de riesgo por operación

input group "Indicator Settings"
input int                 SlowMA_Period        = 200;                 // Período SMA Lenta
input int                 FastMA_Period        = 50;                  // Período SMA Rápida
input int                 RSI_Period           = 14;                  // Período RSI
input int                 RSI_Overbought_Level = 60;                   // Nivel de Sobrecompra RSI
input int                 RSI_Oversold_Level   = 40;                   // Nivel de Sobreventa RSI

input group "Exit Rules"
input double              RiskRewardRatio      = 2.0;                 // Relación Riesgo/Recompensa
input bool                UseTimeExit          = false;               // Habilitar/deshabilitar salida por tiempo
input int                 MaxBarsOpen          = 100;                 // Máximo de velas que una operación puede estar abierta

//--- Instancia de la clase CTrade
CTrade trade;

//--- Handles de los indicadores
int slow_ma_handle;
int fast_ma_handle;
int rsi_handle;

//--- Variables globales para el gatillo de entrada
bool buy_condition_met = false;
double trigger_candle_high = 0;
int buy_condition_bar_index = 0;

bool sell_condition_met = false;
double trigger_candle_low = 0;
int sell_condition_bar_index = 0;

//+------------------------------------------------------------------+
//| Función de inicialización del Experto                            |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Inicializar CTrade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetSlippage(Slippage);

//--- Crear handles de los indicadores
   slow_ma_handle = iMA(_Symbol, _Period, SlowMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   fast_ma_handle = iMA(_Symbol, _Period, FastMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   rsi_handle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);

//--- Verificar si los handles fueron creados correctamente
   if(slow_ma_handle == INVALID_HANDLE || fast_ma_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE)
     {
      Print("Error al crear los handles de los indicadores. Código de error: ", GetLastError());
      return(INIT_FAILED);
     }

//--- Éxito
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Función de desinicialización del Experto                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Liberar handles de los indicadores
   IndicatorRelease(slow_ma_handle);
   IndicatorRelease(fast_ma_handle);
   IndicatorRelease(rsi_handle);
  }

//+------------------------------------------------------------------+
//| Función de tick del Experto                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Usar OnBar() para lógica principal para evitar ejecuciones múltiples
  }

//+------------------------------------------------------------------+
//| Función de nueva barra                                           |
//+------------------------------------------------------------------+
void OnNewBar(const int-1)
  {
//--- Asegurarse de que no hay posiciones abiertas para este símbolo
   if(PositionsTotal() > 0)
     {
      // Lógica de salida por tiempo
      if(UseTimeExit)
        {
         CheckTimeExit();
        }
      return;
     }

//--- Obtener datos de precios e indicadores
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 0, 3, rates) < 3)
     {
      Print("No hay suficientes barras para operar.");
      return;
     }

   double slow_ma[], fast_ma[], rsi[];
   if(CopyBuffer(slow_ma_handle, 0, 0, 3, slow_ma) < 3 ||
      CopyBuffer(fast_ma_handle, 0, 0, 3, fast_ma) < 3 ||
      CopyBuffer(rsi_handle, 0, 0, 3, rsi) < 3)
     {
      Print("Error al copiar los datos de los indicadores.");
      return;
     }

//--- El índice [1] es la última vela completa, el [0] es la actual
   double current_close = rates[1].close;
   double prev_close = rates[2].close;
   double current_slow_ma = slow_ma[1];
   double current_fast_ma = fast_ma[1];
   double current_rsi = rsi[1];

//--- Lógica de tendencia
   bool is_uptrend = current_close > current_slow_ma;
   bool is_downtrend = current_close < current_slow_ma;

//--- Resetear condiciones si la tendencia cambia
   if(!is_uptrend) buy_condition_met = false;
   if(!is_downtrend) sell_condition_met = false;

//--- Verificar condiciones de entrada
   if(is_uptrend)
     {
      CheckBuyConditions(rates, current_fast_ma, current_rsi);
      CheckBuyTrigger(rates);
     }

   if(is_downtrend)
     {
      CheckSellConditions(rates, current_fast_ma, current_rsi);
      CheckSellTrigger(rates);
     }
  }

//+------------------------------------------------------------------+
//| Verifica las condiciones iniciales para una compra               |
//+------------------------------------------------------------------+
void CheckBuyConditions(const MqlRates &rates[], double fast_ma, double rsi)
  {
   // rates[1] es la última vela cerrada
   if(rates[1].close <= fast_ma && rates[1].open > fast_ma && rsi <= RSI_Oversold_Level)
     {
      buy_condition_met = true;
      trigger_candle_high = rates[1].high;
      buy_condition_bar_index = (int)rates[1].tick_volume; // Usamos un identificador de la barra
      Print("Condición de compra cumplida. Esperando gatillo...");
     }
  }

//+------------------------------------------------------------------+
//| Verifica el gatillo de entrada para una compra                   |
//+------------------------------------------------------------------+
void CheckBuyTrigger(const MqlRates &rates[])
  {
   if(buy_condition_met && rates[1].close > trigger_candle_high)
     {
      double stop_loss = CalculateStopLoss(true);
      if(stop_loss == 0) return;

      double lot_size = CalculateLotSize(stop_loss, rates[1].close);
      if(lot_size <= 0) return;

      double take_profit = CalculateTakeProfit(rates[1].close, stop_loss, true);

      if(trade.Buy(lot_size, _Symbol, rates[1].close, stop_loss, take_profit, Comment))
        {
         Print("Orden de compra ejecutada: ", trade.ResultDeal());
        }
      else
        {
         Print("Error al ejecutar orden de compra: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        }
      buy_condition_met = false; // Resetear
     }
  }

//+------------------------------------------------------------------+
//| Verifica las condiciones iniciales para una venta                |
//+------------------------------------------------------------------+
void CheckSellConditions(const MqlRates &rates[], double fast_ma, double rsi)
  {
   if(rates[1].close >= fast_ma && rates[1].open < fast_ma && rsi >= RSI_Overbought_Level)
     {
      sell_condition_met = true;
      trigger_candle_low = rates[1].low;
      sell_condition_bar_index = (int)rates[1].tick_volume;
      Print("Condición de venta cumplida. Esperando gatillo...");
     }
  }

//+------------------------------------------------------------------+
//| Verifica el gatillo de entrada para una venta                    |
//+------------------------------------------------------------------+
void CheckSellTrigger(const MqlRates &rates[])
  {
   if(sell_condition_met && rates[1].close < trigger_candle_low)
     {
      double stop_loss = CalculateStopLoss(false);
      if(stop_loss == 0) return;

      double lot_size = CalculateLotSize(stop_loss, rates[1].close);
      if(lot_size <= 0) return;

      double take_profit = CalculateTakeProfit(rates[1].close, stop_loss, false);

      if(trade.Sell(lot_size, _Symbol, rates[1].close, stop_loss, take_profit, Comment))
        {
         Print("Orden de venta ejecutada: ", trade.ResultDeal());
        }
      else
        {
         Print("Error al ejecutar orden de venta: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        }
      sell_condition_met = false; // Resetear
     }
  }


//+------------------------------------------------------------------+
//| Calcula el tamaño del lote                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_price, double entry_price)
  {
   if(LotMode == Fixed_Lot)
     {
      return(FixedLotSize);
     }

   // Cálculo basado en el riesgo porcentual
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = account_balance * (RiskPercentage / 100.0);
   double sl_pips = MathAbs(entry_price - sl_price);
   
   // Si el SL es 0, no podemos calcular el lote
   if(sl_pips == 0)
   {
    Print("Distancia de Stop Loss es cero. No se puede calcular el tamaño del lote.");
    return 0.0;
   }

   // Obtener el valor del tick y el tamaño del tick
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0 || tick_size <= 0)
   {
      Print("Valores de símbolo inválidos para el cálculo del lote (Tick Value/Tick Size).");
      return 0.0;
   }
   
   double lot_size = (risk_amount / sl_pips) * tick_size / tick_value;

   // Normalizar y verificar límites del lote
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot_size = MathFloor(lot_size / lot_step) * lot_step;

   if(lot_size < min_lot) lot_size = min_lot;
   if(lot_size > max_lot) lot_size = max_lot;

   return(lot_size);
  }

//+------------------------------------------------------------------+
//| Calcula el precio del Stop Loss                                  |
//+------------------------------------------------------------------+
double CalculateStopLoss(bool is_buy)
  {
   MqlRates rates[];
   // Buscar el último swing low/high en las últimas 50 velas
   if(CopyRates(_Symbol, _Period, 0, 50, rates) < 50)
     {
      Print("No hay suficientes barras para calcular el SL.");
      return 0.0;
     }

   if(is_buy) // Para compra, buscar el último swing low
     {
      double swing_low = rates[1].low;
      for(int i = 2; i < 50; i++)
        {
         // Simple swing low: una vela con un mínimo más bajo que las velas adyacentes
         if(rates[i].low < rates[i-1].low && rates[i].low < rates[i+1].low)
           {
            swing_low = rates[i].low;
            break;
           }
        }
      return(swing_low - _Point * 10); // Añadir un pequeño buffer
     }
   else // Para venta, buscar el último swing high
     {
      double swing_high = rates[1].high;
      for(int i = 2; i < 50; i++)
        {
         // Simple swing high: una vela con un máximo más alto que las velas adyacentes
         if(rates[i].high > rates[i-1].high && rates[i].high > rates[i+1].high)
           {
            swing_high = rates[i].high;
            break;
           }
        }
      return(swing_high + _Point * 10); // Añadir un pequeño buffer
     }
  }

//+------------------------------------------------------------------+
//| Calcula el precio del Take Profit                                |
//+------------------------------------------------------------------+
double CalculateTakeProfit(double entry_price, double sl_price, bool is_buy)
  {
   if(RiskRewardRatio <= 0)
     {
      return 0.0; // TP no se usa
     }

   double risk_distance = MathAbs(entry_price - sl_price);

   if(is_buy)
     {
      return(entry_price + risk_distance * RiskRewardRatio);
     }
   else
     {
      return(entry_price - risk_distance * RiskRewardRatio);
     }
  }

//+------------------------------------------------------------------+
//| Cierra la posición si ha estado abierta demasiado tiempo         |
//+------------------------------------------------------------------+
void CheckTimeExit()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionSelect(_Symbol))
        {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            long open_time = PositionGetInteger(POSITION_TIME);
            MqlDateTime open_dt;
            TimeToStruct(open_time, open_dt);

            MqlRates rates[];
            if(CopyRates(_Symbol, _Period, 0, MaxBarsOpen + 1, rates) > MaxBarsOpen)
              {
               long bars_open = Bars(_Symbol, _Period, open_time, TimeCurrent());
               if(bars_open >= MaxBarsOpen)
                 {
                  if(trade.PositionClose(_Symbol))
                    {
                     Print("Posición cerrada por tiempo. Abierta por ", bars_open, " barras.");
                    }
                  else
                    {
                     Print("Error al cerrar posición por tiempo: ", trade.ResultRetcodeDescription());
                    }
                 }
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
