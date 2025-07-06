//+------------------------------------------------------------------+
//|                                      EstrategiaLiquidezCHOCH.mq5 |
//|                                  Creado por Asistente de OpenAI  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Creado por Asistente de OpenAI"
#property link      "https://www.openai.com"
#property version   "2.2" // Versión corregida
#property description "EA basado en barrido de liquidez, CHOCH y Fibonacci."

#include <Trade\Trade.mqh>

//--- Parámetros de entrada del EA
input group           "Parámetros de Trading"
input ulong           MagicNumber = 123456;      // Número Mágico para identificar las órdenes
input double          RiskPercent = 1.0;         // Porcentaje de riesgo por operación

input group           "Ajustes de Pivots"
input int             PivotLeft = 5;             // Barras a la izquierda para el pivot
input int             PivotRight = 5;            // Barras a la derecha para el pivot

input group           "Ajustes de Tiempo"
input int             NY_Time_Offset_From_Server = -7; // Diferencia horaria: NY vs Servidor del Broker (ej. -7 para IC Markets)

//--- Instancia de la clase de trading
CTrade trade;

//--- Enumeración para el estado del Bias
enum ENUM_BIAS
{
   BIAS_NINGUNO,
   BIAS_ALCISTA,
   BIAS_BAJISTA,
   BIAS_FINALIZADO
};

//--- Variables Globales de Estado
ENUM_BIAS    g_daily_bias = BIAS_NINGUNO;
bool         g_choch_created = false;
bool         g_tp1_hit = false;
string       g_bot_status = "Iniciando...";

double       g_range_high = 0.0;
double       g_range_low = 0.0;
datetime     g_range_finalized_time = 0;

double       g_last_pivot_high = 0.0;
double       g_last_pivot_low = 0.0;
datetime     g_last_pivot_high_time = 0;
datetime     g_last_pivot_low_time = 0;

double       g_prev_pivot_high = 0.0;
double       g_prev_pivot_low = 0.0;

double       g_fibo_p1 = 0.0;
double       g_fibo_p2 = 0.0;

double       g_entry_price = 0.0;
double       g_sl_price = 0.0;
double       g_tp1_price = 0.0;
double       g_tp2_price = 0.0;

int          g_last_known_day = -1;

//+------------------------------------------------------------------+
//| Función de inicialización del experto                          |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   
   Print("EA 'EstrategiaLiquidezCHOCH' iniciado. Magic Number: ", MagicNumber);
   Print("Ajuste de tiempo NY vs Servidor: ", NY_Time_Offset_From_Server, " horas.");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Resetea las variables de estado para un nuevo día                |
//+------------------------------------------------------------------+
void ResetDailyVariables()
{
   Print("--- Nuevo Día de Trading ---");
   g_daily_bias = BIAS_NINGUNO;
   g_choch_created = false;
   g_tp1_hit = false;
   g_bot_status = "Esperando Sesión";

   g_range_high = 0.0;
   g_range_low = 0.0;
   g_range_finalized_time = 0;

   g_last_pivot_high = 0.0;
   g_last_pivot_low = 0.0;
   g_prev_pivot_high = 0.0;
   g_prev_pivot_low = 0.0;
   g_last_pivot_high_time = 0;
   g_last_pivot_low_time = 0;

   g_fibo_p1 = 0.0;
   g_fibo_p2 = 0.0;
   g_entry_price = 0.0;
   g_sl_price = 0.0;
   g_tp1_price = 0.0;
   g_tp2_price = 0.0;
}

//+------------------------------------------------------------------+
//| Obtiene la hora actual en la zona horaria de Nueva York          |
//+------------------------------------------------------------------+
MqlDateTime GetNYTime()
{
   MqlDateTime ny_time;
   long server_time = TimeCurrent() + (NY_Time_Offset_From_Server * 3600);
   TimeToStruct(server_time, ny_time);
   return ny_time;
}

//+------------------------------------------------------------------+
//| Calcula el tamaño del lote basado en el riesgo                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry_price, double sl_price)
{
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = account_balance * (RiskPercent / 100.0);
   double sl_points = MathAbs(entry_price - sl_price) / _Point;

   if(sl_points == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tick_size == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   double value_per_point = tick_value / tick_size;
   double lot_size = risk_amount / (sl_points * value_per_point);
   
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot_size = NormalizeDouble(lot_size, 2);
   lot_size = MathFloor(lot_size / volume_step) * volume_step;

   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(lot_size < min_lot) lot_size = min_lot;
   if(lot_size > max_lot) lot_size = max_lot;

   return lot_size;
}

//+------------------------------------------------------------------+
//| Busca pivots y comprueba la condición de CHOCH                   |
//+------------------------------------------------------------------+
void FindPivotsAndCheckCHOCH()
{
   MqlRates rates[];
   int bars_to_copy = PivotLeft + PivotRight + 50;
   if(CopyRates(_Symbol, _Period, 0, bars_to_copy, rates) < bars_to_copy)
   {
      Print("No hay suficientes datos para calcular pivots.");
      return;
   }
   
   ArraySetAsSeries(rates, true);

   for(int i = PivotRight; i < bars_to_copy - PivotLeft; i++)
   {
      // CORRECCIÓN: Copiar manualmente los datos a un array de double
      double high_window[PivotLeft + PivotRight + 1];
      for(int j = 0; j < PivotLeft + PivotRight + 1; j++)
      {
         high_window[j] = rates[i - PivotRight + j].high;
      }
      
      if(rates[i].high == high_window[ArrayMaximum(high_window)])
      {
         if(rates[i].time != g_last_pivot_high_time)
         {
            g_prev_pivot_high = g_last_pivot_high;
            g_last_pivot_high = rates[i].high;
            g_last_pivot_high_time = rates[i].time;
         }
      }
      
      // CORRECCIÓN: Copiar manualmente los datos a un array de double
      double low_window[PivotLeft + PivotRight + 1];
      for(int j = 0; j < PivotLeft + PivotRight + 1; j++)
      {
         low_window[j] = rates[i - PivotRight + j].low;
      }

      if(rates[i].low == low_window[ArrayMinimum(low_window)])
      {
         if(rates[i].time != g_last_pivot_low_time)
         {
            g_prev_pivot_low = g_last_pivot_low;
            g_last_pivot_low = rates[i].low;
            g_last_pivot_low_time = rates[i].time;
         }
      }
   }

   if(g_daily_bias == BIAS_ALCISTA && g_last_pivot_high > g_prev_pivot_high && g_last_pivot_high_time > g_last_pivot_low_time && g_prev_pivot_high > 0)
   {
      g_choch_created = true;
      g_fibo_p1 = g_last_pivot_low;
      g_fibo_p2 = g_last_pivot_high;
      Print("CHOCH Alcista Creado. Fibo desde ", g_fibo_p1, " hasta ", g_fibo_p2);
   }
   else if(g_daily_bias == BIAS_BAJISTA && g_last_pivot_low < g_prev_pivot_low && g_last_pivot_low_time > g_last_pivot_high_time && g_prev_pivot_low > 0)
   {
      g_choch_created = true;
      g_fibo_p1 = g_last_pivot_high;
      g_fibo_p2 = g_last_pivot_low;
      Print("CHOCH Bajista Creado. Fibo desde ", g_fibo_p1, " hasta ", g_fibo_p2);
   }
}

//+------------------------------------------------------------------+
//| Gestiona el cierre parcial en TP1 y mueve SL a Breakeven         |
//+------------------------------------------------------------------+
void ManagePartialTakeProfit()
{
   if(g_tp1_hit || PositionSelect(_Symbol) == false) return;
   
   if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) return;

   double current_price = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double position_volume = PositionGetDouble(POSITION_VOLUME);
   double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);

   bool tp1_crossed = false;
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && current_price >= g_tp1_price)
   {
      tp1_crossed = true;
   }
   else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && current_price <= g_tp1_price)
   {
      tp1_crossed = true;
   }

   if(tp1_crossed)
   {
      double volume_to_close = NormalizeDouble(position_volume / 2.0, 2);
      if(trade.PositionClosePartial(_Symbol, volume_to_close))
      {
         Print("TP1 alcanzado. Cerrando 50% de la posición.");
         if(trade.PositionModify(_Symbol, entry_price, PositionGetDouble(POSITION_TP)))
         {
            Print("SL movido a Breakeven.");
         }
         g_tp1_hit = true;
      }
   }
}


//+------------------------------------------------------------------+
//| Función de tick del experto                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime ny_time = GetNYTime();
   
   if(g_last_known_day != ny_time.day)
   {
      ResetDailyVariables();
      g_last_known_day = ny_time.day;
   }
   
   MqlRates rates[1];
   if(CopyRates(_Symbol, _Period, 0, 1, rates) < 1) return;
   double latest_high = rates[0].high;
   double latest_low = rates[0].low;

   if(ny_time.hour >= 2 && (ny_time.hour < 7 || (ny_time.hour == 7 && ny_time.min <= 15)))
   {
      g_bot_status = "Definiendo Rango";
      if(g_range_high == 0.0 || latest_high > g_range_high) g_range_high = latest_high;
      if(g_range_low == 0.0 || latest_low < g_range_low) g_range_low = latest_low;
   }
   else if(g_range_high > 0 && g_range_finalized_time == 0)
   {
      g_range_finalized_time = TimeCurrent();
      Print("Rango definido: High=", g_range_high, ", Low=", g_range_low);
   }

   bool in_killzone = (ny_time.hour > 7 || (ny_time.hour == 7 && ny_time.min >= 45)) && ny_time.hour < 11;

   if(ny_time.hour >= 11 && g_daily_bias != BIAS_FINALIZADO)
   {
      if(PositionsTotal() == 0)
      {
         g_bot_status = "Sesión Finalizada";
         g_daily_bias = BIAS_FINALIZADO;
         trade.OrderDelete(0, true);
         Print("Fin de sesión. Setup del día cancelado.");
      }
   }

   if(in_killzone && g_daily_bias != BIAS_FINALIZADO && g_range_high > 0)
   {
      if(g_daily_bias == BIAS_NINGUNO)
      {
         g_bot_status = "Esperando Bias";
         if(latest_high > g_range_high)
         {
            g_daily_bias = BIAS_BAJISTA;
            g_bot_status = "Bias: Bajista";
            Print("Toma de liquidez en el HIGH. Bias del día: BAJISTA");
         }
         else if(latest_low < g_range_low)
         {
            g_daily_bias = BIAS_ALCISTA;
            g_bot_status = "Bias: Alcista";
            Print("Toma de liquidez en el LOW. Bias del día: ALCISTA");
         }
      }

      if((g_daily_bias == BIAS_ALCISTA || g_daily_bias == BIAS_BAJISTA) && !g_choch_created)
      {
         FindPivotsAndCheckCHOCH();
      }

      if(g_choch_created && g_entry_price == 0.0)
      {
         g_bot_status = "Esperando Retroceso";
         double fibo_range = MathAbs(g_fibo_p2 - g_fibo_p1);
         
         if(g_daily_bias == BIAS_ALCISTA)
         {
            g_entry_price = g_fibo_p1 + fibo_range * 0.618;
            g_sl_price = g_fibo_p1;
            g_tp1_price = g_fibo_p2 + fibo_range * 0.27;
            g_tp2_price = g_fibo_p2 + fibo_range * 0.64;
         }
         else if(g_daily_bias == BIAS_BAJISTA)
         {
            g_entry_price = g_fibo_p1 - fibo_range * 0.618;
            g_sl_price = g_fibo_p1;
            g_tp1_price = g_fibo_p2 - fibo_range * 0.27;
            g_tp2_price = g_fibo_p2 - fibo_range * 0.64;
         }
         
         Print("Niveles calculados: Entrada=", g_entry_price, ", SL=", g_sl_price, ", TP1=", g_tp1_price, ", TP2=", g_tp2_price);
         
         double lot = CalculateLotSize(g_entry_price, g_sl_price);
         if(lot > 0)
         {
            if(g_daily_bias == BIAS_ALCISTA)
            {
               trade.BuyLimit(lot, g_entry_price, _Symbol, g_sl_price, g_tp2_price, ORDER_TIME_GTC, 0, "BOT Liquidez");
            }
            else if(g_daily_bias == BIAS_BAJISTA)
            {
               trade.SellLimit(lot, g_entry_price, _Symbol, g_sl_price, g_tp2_price, ORDER_TIME_GTC, 0, "BOT Liquidez");
            }
            g_bot_status = "Orden Pendiente";
            g_daily_bias = BIAS_FINALIZADO;
         }
      }
   }
   
   if(PositionsTotal() > 0)
   {
      ManagePartialTakeProfit();
   }
}
//+------------------------------------------------------------------+
