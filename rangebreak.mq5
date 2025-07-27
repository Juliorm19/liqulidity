//+------------------------------------------------------------------+
//|                                               RangeBreakout_EA.mq5 |
//|                                  Copyright 2025, Nombre del Autor |
//|                                             https://www.google.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Nombre del Autor"
#property link      "https://www.google.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Parámetros de Entrada Configurables por el Usuario
input group "Gestión de Riesgo"
input double RiskPercent = 1.0; // Porcentaje de la cuenta a arriesgar por operación (1.0 = 1%)
input double RiskRewardRatio = 0.0; // Ratio Riesgo/Beneficio (ej: 2.0 para 1:2). 0.0 para usar el rango.

input group "Configuración del Rango"
input string StartTime = "02:00"; // Hora de inicio del rango (formato HH:MM)
input string EndTime = "09:29";   // Hora de finalización del rango (formato HH:MM)

input group "Identificación de Operaciones"
input int MagicNumber = 12345; // Número mágico para identificar las operaciones del EA

//--- Variables Globales
double rangeHigh = 0.0;
double rangeLow = 0.0;
datetime rangeDate; // Para asegurar que el rango se calcula solo una vez al día

//--- Objeto para operaciones de trading
CTrade trade;

//+------------------------------------------------------------------+
//| Función de inicialización del Asesor Experto                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Inicializar el objeto de trading
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   
   //--- Mensaje de inicio
   Print("RangeBreakout_EA inicializado. Símbolo: ", _Symbol, ", Riesgo: ", RiskPercent, "%");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Función que se ejecuta en cada tick del mercado                  |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Obtener la hora actual del servidor y convertirla a la estructura MqlDateTime
   MqlDateTime serverTimeStruct;
   TimeCurrent(serverTimeStruct);

   //--- Manejo de la diferencia horaria con Nueva York (aproximación EST/EDT)
   //--- Nueva York es UTC-5 (EST) o UTC-4 (EDT). Esta es una parte compleja.
   //--- Una solución robusta requiere una librería o un manejo detallado de las fechas de cambio de horario.
   //--- Para este ejemplo, usaremos un offset simple que puede necesitar ajuste manual.
   //--- Asumimos que el servidor está en UTC. El usuario debe verificar el offset de su bróker.
   long ny_time_offset_seconds = -4 * 3600; // Asumiendo EDT (UTC-4)
   long ny_time = TimeCurrent() + ny_time_offset_seconds;
   MqlDateTime nyTimeStruct;
   TimeToStruct(ny_time, nyTimeStruct);

   //--- Comprobar si es un nuevo día para resetear el rango
   if(nyTimeStruct.day != TimeToStruct(rangeDate, nyTimeStruct).day)
   {
      rangeHigh = 0.0;
      rangeLow = 0.0;
   }

   //--- 1. Definición del Rango de Operaciones
   //--- Si estamos dentro del horario y el rango aún no ha sido definido
   if(IsTimeInRange(nyTimeStruct, StartTime, EndTime) && rangeHigh == 0.0)
   {
      if(CalculateRange())
      {
         rangeDate = TimeCurrent(); // Marcar la fecha en que se calculó el rango
         Print("Rango definido para ", TimeToString(rangeDate, TIME_DATE), ": High=", DoubleToString(rangeHigh, _Digits), ", Low=", DoubleToString(rangeLow, _Digits));
      }
   }

   //--- 2. Monitoreo de Ruptura de Rango
   //--- Si estamos fuera del horario del rango y el rango ha sido definido
   if(!IsTimeInRange(nyTimeStruct, StartTime, EndTime) && rangeHigh > 0.0)
   {
      //--- Verificar si ya hay una operación abierta por este EA
      if(IsTradeOpen())
         return;

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      //--- Condición de Venta (Sell)
      if(ask >= rangeHigh)
      {
         ExecuteTrade(ORDER_TYPE_SELL);
      }
      //--- Condición de Compra (Buy)
      else if(bid <= rangeLow)
      {
         ExecuteTrade(ORDER_TYPE_BUY);
      }
   }
}

//+------------------------------------------------------------------+
//| Calcula el High y Low del rango horario especificado             |
//+------------------------------------------------------------------+
bool CalculateRange()
{
   //--- Convertir horas de inicio y fin a datetime para el día actual
   datetime from_time = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " " + StartTime);
   datetime to_time = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " " + EndTime);

   //--- Copiar las barras del período de tiempo especificado
   MqlRates rates[];
   int bars_copied = CopyRates(_Symbol, PERIOD_M1, from_time, to_time, rates);

   if(bars_copied <= 0)
   {
      Print("Error al copiar el historial de precios para el rango. Código de error: ", GetLastError());
      return false;
   }

   //--- Encontrar el máximo y mínimo en las barras copiadas
   rangeHigh = rates[0].high;
   rangeLow = rates[0].low;

   for(int i = 1; i < bars_copied; i++)
   {
      if(rates[i].high > rangeHigh)
         rangeHigh = rates[i].high;
      if(rates[i].low < rangeLow)
         rangeLow = rates[i].low;
   }
   
   //--- Asegurarse de que el rango es válido
   if(rangeHigh > 0 && rangeLow > 0 && rangeHigh > rangeLow)
   {
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Ejecuta una operación de compra o venta                          |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType)
{
   //--- 3. Lógica de Entrada a las Operaciones
   double entry_price = 0;
   double stop_loss = 0;
   double take_profit = 0;
   double range_in_points = (rangeHigh - rangeLow);

   //--- Calcular Stop Loss
   double sl_distance = range_in_points / 2.0;
   if(sl_distance == 0)
   {
      Print("La distancia del Stop Loss es cero. No se puede abrir la operación.");
      return;
   }

   //--- Calcular Lotaje Dinámico
   double lot_size = CalculateLotSize(sl_distance);
   if(lot_size <= 0)
   {
      Print("El tamaño del lote calculado es inválido: ", lot_size);
      return;
   }

   if(orderType == ORDER_TYPE_BUY)
   {
      entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      stop_loss = entry_price - sl_distance;
      
      //--- Calcular Take Profit
      if(RiskRewardRatio > 0)
      {
         take_profit = entry_price + (sl_distance * RiskRewardRatio);
      }
      else
      {
         take_profit = rangeHigh;
      }
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      stop_loss = entry_price + sl_distance;
      
      //--- Calcular Take Profit
      if(RiskRewardRatio > 0)
      {
         take_profit = entry_price - (sl_distance * RiskRewardRatio);
      }
      else
      {
         take_profit = rangeLow;
      }
   }

   //--- Enviar la orden
   trade.PositionOpen(_Symbol, orderType, lot_size, entry_price, stop_loss, take_profit, "RangeBreakout_EA");
   
   //--- Resetear el rango para no abrir más operaciones hoy
   rangeHigh = 0.0;
   rangeLow = 0.0;
}

//+------------------------------------------------------------------+
//| Calcula el tamaño del lote basado en el riesgo por operación     |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance_price)
{
   //--- 4. Gestión del Lote (Lotaje)
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = account_balance * (RiskPercent / 100.0);
   
   //--- Obtener información del símbolo
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tick_size == 0 || sl_distance_price == 0)
   {
      Print("Tick size o distancia de SL es cero, no se puede calcular el lotaje.");
      return 0.0;
   }

   //--- Calcular el valor monetario de la pérdida por lote
   double loss_per_lot = (sl_distance_price / tick_size) * tick_value;

   if(loss_per_lot == 0)
   {
      Print("La pérdida por lote es cero, no se puede calcular el lotaje.");
      return 0.0;
   }

   //--- Calcular el tamaño del lote
   double lot_size = risk_amount / loss_per_lot;

   //--- Normalizar el tamaño del lote
   lot_size = floor(lot_size / lot_step) * lot_step;

   //--- Verificar contra los límites del bróker
   if(lot_size < min_lot)
      lot_size = min_lot;
   if(lot_size > max_lot)
      lot_size = max_lot;
      
   return lot_size;
}

//+------------------------------------------------------------------+
//| Verifica si ya existe una operación abierta por este EA          |
//+------------------------------------------------------------------+
bool IsTradeOpen()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         return true; // Se encontró una posición abierta
      }
   }
   return false; // No hay posiciones abiertas
}

//+------------------------------------------------------------------+
//| Verifica si la hora actual está dentro de un rango               |
//+------------------------------------------------------------------+
bool IsTimeInRange(const MqlDateTime &timeStruct, string startTimeStr, string endTimeStr)
{
   int current_minutes = timeStruct.hour * 60 + timeStruct.min;
   
   int start_hour, start_min, end_hour, end_min;
   sscanf(startTimeStr, "%d:%d", &start_hour, &start_min);
   sscanf(endTimeStr, "%d:%d", &end_hour, &end_min);
   
   int start_total_minutes = start_hour * 60 + start_min;
   int end_total_minutes = end_hour * 60 + end_min;

   return (current_minutes >= start_total_minutes && current_minutes <= end_total_minutes);
}
//+------------------------------------------------------------------+
