//+------------------------------------------------------------------+
//|                                   EstrategiaLiquidezNY_v1.2.mq5 |
//|                                  Creado para el usuario de GPT |
//|                                             https://chat.openai.com |
//+------------------------------------------------------------------+
#property copyright "Creado para el usuario de GPT"
#property link      "https://chat.openai.com"
#property version   "1.2" // Versión con correcciones de compilador

#include <Trade\Trade.mqh>

//--- Inputs del Usuario
input group "Configuración de Tiempo (Hora de Nueva York)"
input string   InpSessionStart      = "02:00"; // Inicio del rango de Asia
input string   InpSessionEnd        = "07:15"; // Fin del rango de Asia
input string   InpTradingStart      = "07:45"; // Inicio de la ventana de trading
input string   InpTradingEnd        = "11:00"; // Fin de la ventana de trading
input int      InpNYTimeOffset      = -5;      // Desplazamiento horario de NY respecto a GMT (ej. -5 para EST, -4 para EDT)

input group "Gestión de Riesgo"
input double   InpRiskPercent       = 1.0;     // Porcentaje de riesgo por operación
input ulong    InpMagicNumber       = 12345;   // Número Mágico para las operaciones

input group "Parámetros de Estructura (ZigZag)"
input int      InpZigZagDepth       = 12;
input int      InpZigZagDeviation   = 5;
input int      InpZigZagBackstep    = 3;

input group "Configuración de Fibonacci"
input double   InpFiboEntryLevel    = 61.8;    // Nivel de entrada de Fibonacci
input double   InpFiboSLLevel       = 100.0;   // Nivel de Stop Loss de Fibonacci
input double   InpFiboTP1Level      = -27.0;   // Nivel de Take Profit 1
input double   InpFiboTP2Level      = -64.0;   // Nivel de Take Profit 2

input group "Visualización"
input color    InpSessionLineColor  = clrGray;
input color    InpPivotLabelColor   = clrWhite;
input ENUM_BASE_CORNER InpPanelCorner = CORNER_TOP_LEFT;


//--- Enumeraciones para estados y dirección
enum ENUM_STATE
{
    STATE_WAIT_SESSION,      // 1. Esperando que se forme el rango de Asia
    STATE_WAIT_BIAS,         // 2. Esperando la toma de liquidez para definir el BIAS
    STATE_WAIT_BOS,          // 3. Esperando un Break of Structure (BOS)
    STATE_WAIT_CHOCH,        // 4. Esperando un Change of Character (CHOCH)
    STATE_WAIT_RETRACEMENT,  // 5. Esperando el retroceso a Fibonacci
    STATE_TRADE_MANAGEMENT,  // 6. Orden colocada, gestionando la operación
    STATE_DAY_END            // Fin del día, esperando al siguiente
};

enum ENUM_BIAS
{
    BIAS_NONE,
    BIAS_BULLISH, // Toma de liquidez por debajo -> Dirección alcista
    BIAS_BEARISH  // Toma de liquidez por encima -> Dirección bajista
};

//--- Variables Globales
CTrade      trade;
ENUM_STATE  g_currentState = STATE_WAIT_SESSION;
ENUM_BIAS   g_bias = BIAS_NONE;
int         g_zigzag_handle;

// Variables de la sesión
datetime    g_session_start_time;
datetime    g_session_end_time;
double      g_session_high;
double      g_session_low;
bool        g_session_marked = false;

// Variables de la estructura
double      g_pivots[5]; // Almacenará los últimos 5 pivots de precio
datetime    g_pivot_times[5]; // Almacenará los tiempos de los últimos 5 pivots

// Variables de Fibonacci y orden
double      g_fibo_anchor_1;
double      g_fibo_anchor_2;
long        g_pending_order_ticket = 0;

// Panel de estado
string      g_panel_name = "StatusPanel";
string      g_label_name = "StatusLabel";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Inicializar objeto de trading
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetTypeFillingBySymbol(_Symbol);

    //--- Obtener handle del indicador ZigZag
    g_zigzag_handle = iZigZag(_Symbol, _Period, InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);
    if(g_zigzag_handle == INVALID_HANDLE)
    {
        printf("Error al crear el handle del indicador ZigZag");
        return(INIT_FAILED);
    }

    //--- Crear panel de estado
    CreateStatusPanel();
    UpdateStatusPanel("Iniciando...");

    //--- Resetear variables diarias al inicio
    ResetDailyVariables();
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Limpiar objetos del gráfico
    ObjectDelete(0, g_panel_name);
    ObjectDelete(0, g_label_name);
    ObjectsDeleteAll(0, "Session_");
    ObjectsDeleteAll(0, "Pivot_");
    ObjectsDeleteAll(0, "FiboEntry_");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Solo ejecutar en una nueva barra para eficiencia
    static datetime last_bar_time = 0;
    long current_bar_time_long;
    if(!SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_TIME, current_bar_time_long)) return;
    datetime current_bar_time = (datetime)current_bar_time_long;

    if(last_bar_time == current_bar_time)
        return;
    last_bar_time = current_bar_time;

    //--- Obtener hora actual de NY
    datetime ny_time = GetNYTime(TimeCurrent());
    MqlDateTime dt_ny;
    TimeToStruct(ny_time, dt_ny);
    
    //--- Resetear al inicio de un nuevo día (antes de la sesión)
    if(dt_ny.hour == 0 && dt_ny.min == 0 && g_currentState != STATE_WAIT_SESSION)
    {
        ResetDailyVariables();
    }

    //--- Máquina de estados
    switch(g_currentState)
    {
        case STATE_WAIT_SESSION:
            HandleStateWaitSession(ny_time);
            break;
        case STATE_WAIT_BIAS:
            HandleStateWaitBias(ny_time);
            break;
        case STATE_WAIT_BOS:
            HandleStateWaitBos(ny_time);
            break;
        case STATE_WAIT_CHOCH:
            HandleStateWaitChoch(ny_time);
            break;
        case STATE_WAIT_RETRACEMENT:
            HandleStateWaitRetracement(ny_time);
            break;
        case STATE_TRADE_MANAGEMENT:
            HandleStateTradeManagement(ny_time);
            break;
        case STATE_DAY_END:
            // No hacer nada hasta el reseteo del día siguiente
            break;
    }
}

//+------------------------------------------------------------------+
//| 1. Maneja la espera y marcado de la sesión de Asia               |
//+------------------------------------------------------------------+
void HandleStateWaitSession(datetime ny_time)
{
    UpdateStatusPanel("Waiting Session Range");
    
    if(g_session_marked) return;

    // Si ya pasó la hora de fin de sesión, la marcamos
    if(ny_time >= StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpSessionEnd))
    {
        datetime session_start_server_time = GetServerTimeFromNY(StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpSessionStart));
        datetime session_end_server_time = GetServerTimeFromNY(StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpSessionEnd));

        int start_bar = iBarShift(_Symbol, _Period, session_start_server_time);
        int end_bar = iBarShift(_Symbol, _Period, session_end_server_time);

        if(start_bar < 0 || end_bar < 0) return;

        double highs[], lows[];
        CopyHigh(_Symbol, _Period, end_bar, start_bar - end_bar + 1, highs);
        CopyLow(_Symbol, _Period, end_bar, start_bar - end_bar + 1, lows);

        g_session_high = highs[ArrayMaximum(highs)];
        g_session_low = lows[ArrayMinimum(lows)];
        
        // Dibujar líneas en el gráfico
        DrawLine("Session_High", session_start_server_time, g_session_high, TimeCurrent() + 3600*12, g_session_high, InpSessionLineColor, STYLE_DOT);
        DrawLine("Session_Low", session_start_server_time, g_session_low, TimeCurrent() + 3600*12, g_session_low, InpSessionLineColor, STYLE_DOT);
        
        g_session_marked = true;
        g_currentState = STATE_WAIT_BIAS;
        printf("Sesión marcada. High: %f, Low: %f", g_session_high, g_session_low);
    }
}

//+------------------------------------------------------------------+
//| 2. Espera la toma de liquidez para definir el BIAS               |
//+------------------------------------------------------------------+
void HandleStateWaitBias(datetime ny_time)
{
    UpdateStatusPanel("Waiting Bias");

    // Verificar si estamos dentro de la ventana de trading
    if(ny_time < StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpTradingStart)) return;
    
    // Si se pasa la ventana de trading, fin del día
    if(ny_time > StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpTradingEnd))
    {
        g_currentState = STATE_DAY_END;
        UpdateStatusPanel("Trading Window Closed");
        return;
    }

    MqlRates current_bar[1];
    if(CopyRates(_Symbol, _Period, 0, 1, current_bar) < 1) return;

    // Toma de liquidez por encima -> BIAS BAJISTA
    if(current_bar[0].high > g_session_high)
    {
        g_bias = BIAS_BEARISH;
        g_currentState = STATE_WAIT_BOS;
        printf("Liquidez tomada por encima. BIAS: BAJISTA");
    }
    // Toma de liquidez por debajo -> BIAS ALCISTA
    else if(current_bar[0].low < g_session_low)
    {
        g_bias = BIAS_BULLISH;
        g_currentState = STATE_WAIT_BOS;
        printf("Liquidez tomada por debajo. BIAS: ALCISTA");
    }
}

//+------------------------------------------------------------------+
//| 3. Espera un Break of Structure (BOS)                            |
//+------------------------------------------------------------------+
void HandleStateWaitBos(datetime ny_time)
{
    UpdateStatusPanel("Bias: " + EnumToString(g_bias) + " | Waiting BOS");

    if(ny_time > StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpTradingEnd))
    {
        g_currentState = STATE_DAY_END;
        UpdateStatusPanel("Trading Window Closed");
        return;
    }

    if(FindPivots(4))
    {
        // BIAS ALCISTA: Buscamos un BOS alcista (un Higher High)
        // Secuencia: Low -> High -> Higher High
        if(g_bias == BIAS_BULLISH && g_pivots[0] > g_pivots[2] && g_pivots[1] < g_pivots[3])
        {
            CreatePivotLabel(g_pivot_times[3], g_pivots[3], "L");
            CreatePivotLabel(g_pivot_times[2], g_pivots[2], "H");
            CreatePivotLabel(g_pivot_times[1], g_pivots[1], "L"); // Este es el low que no debe romperse
            CreatePivotLabel(g_pivot_times[0], g_pivots[0], "HH");
            g_currentState = STATE_WAIT_CHOCH;
            printf("BOS Alcista detectado. Esperando CHOCH Bajista.");
        }
        // BIAS BAJISTA: Buscamos un BOS bajista (un Lower Low)
        // Secuencia: High -> Low -> Lower Low
        else if(g_bias == BIAS_BEARISH && g_pivots[0] < g_pivots[2] && g_pivots[1] > g_pivots[3])
        {
            CreatePivotLabel(g_pivot_times[3], g_pivots[3], "H");
            CreatePivotLabel(g_pivot_times[2], g_pivots[2], "L");
            CreatePivotLabel(g_pivot_times[1], g_pivots[1], "H"); // Este es el high que no debe romperse
            CreatePivotLabel(g_pivot_times[0], g_pivots[0], "LL");
            g_currentState = STATE_WAIT_CHOCH;
            printf("BOS Bajista detectado. Esperando CHOCH Alcista.");
        }
    }
}

//+------------------------------------------------------------------+
//| 4. Espera un Change of Character (CHOCH)                         |
//+------------------------------------------------------------------+
void HandleStateWaitChoch(datetime ny_time)
{
    UpdateStatusPanel("BOS Created | Waiting CHOCH");

    if(ny_time > StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpTradingEnd))
    {
        g_currentState = STATE_DAY_END;
        UpdateStatusPanel("Trading Window Closed");
        return;
    }

    if(FindPivots(5)) // Necesitamos un pivot más para el CHOCH
    {
        // Después de un BOS Alcista (L-H-HH), buscamos un CHOCH Bajista (un Low más bajo que el último Low)
        if(g_bias == BIAS_BULLISH && g_pivots[0] < g_pivots[2]) // g_pivots[2] es el último Low (el punto 'L' antes del 'HH')
        {
            // El CHOCH es bajista, pero la entrada será alcista (es un retroceso)
            // La secuencia es: L(3) -> H(2) -> HH(1) -> LL(0) (CHOCH)
            // El Fibo se traza desde el inicio del movimiento que rompió (HH) hasta el nuevo low (LL)
            g_fibo_anchor_1 = g_pivots[1]; // El HH
            g_fibo_anchor_2 = g_pivots[0]; // El nuevo LL
            CreatePivotLabel(g_pivot_times[0], g_pivots[0], "LL");
            g_currentState = STATE_WAIT_RETRACEMENT;
            printf("CHOCH Bajista detectado. Preparando entrada ALCISTA.");
        }
        // Después de un BOS Bajista (H-L-LL), buscamos un CHOCH Alcista (un High más alto que el último High)
        else if(g_bias == BIAS_BEARISH && g_pivots[0] > g_pivots[2]) // g_pivots[2] es el último High (el punto 'H' antes del 'LL')
        {
            // El CHOCH es alcista, pero la entrada será bajista
            // La secuencia es: H(3) -> L(2) -> LL(1) -> HH(0) (CHOCH)
            // El Fibo se traza desde el inicio del movimiento que rompió (LL) hasta el nuevo high (HH)
            g_fibo_anchor_1 = g_pivots[1]; // El LL
            g_fibo_anchor_2 = g_pivots[0]; // El nuevo HH
            CreatePivotLabel(g_pivot_times[0], g_pivots[0], "HH");
            g_currentState = STATE_WAIT_RETRACEMENT;
            printf("CHOCH Alcista detectado. Preparando entrada BAJISTA.");
        }
    }
}

//+------------------------------------------------------------------+
//| 5. Espera el retroceso a Fibonacci y coloca la orden             |
//+------------------------------------------------------------------+
void HandleStateWaitRetracement(datetime ny_time)
{
    UpdateStatusPanel("CHOCH Created | Waiting Retracement");

    if(ny_time > StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpTradingEnd))
    {
        g_currentState = STATE_DAY_END;
        UpdateStatusPanel("Trading Window Closed");
        return;
    }

    // Calcular niveles de Fibo
    double range = MathAbs(g_fibo_anchor_1 - g_fibo_anchor_2);
    double entry_price, sl_price, tp1_price, tp2_price;
    
    // Entrada ALCISTA (Buy Limit)
    if(g_bias == BIAS_BULLISH)
    {
        entry_price = g_fibo_anchor_1 - (range * (InpFiboEntryLevel / 100.0));
        sl_price = g_fibo_anchor_1 - (range * (InpFiboSLLevel / 100.0));
        tp1_price = g_fibo_anchor_1 - (range * (InpFiboTP1Level / 100.0));
        tp2_price = g_fibo_anchor_1 - (range * (InpFiboTP2Level / 100.0));
        
        double current_low;
        SymbolInfoDouble(_Symbol, SYMBOL_LOW, current_low);
        // No colocar orden si el precio ya pasó el nivel de entrada
        if(current_low < entry_price)
        {
            g_currentState = STATE_DAY_END;
            UpdateStatusPanel("Entry Missed. Price too low.");
            return;
        }

        double stop_loss_pips = (entry_price - sl_price) / _Point;
        double lot_size = CalculateLotSize(stop_loss_pips);
        
        if(lot_size > 0)
        {
            // Colocar 2 órdenes pendientes, cada una con la mitad del lotaje
            trade.BuyLimit(lot_size / 2, entry_price, _Symbol, sl_price, tp1_price, 0, 0, "TP1");
            trade.BuyLimit(lot_size / 2, entry_price, _Symbol, sl_price, tp2_price, 0, 0, "TP2");
            
            if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            {
                g_pending_order_ticket = (long)trade.ResultOrder();
                g_currentState = STATE_TRADE_MANAGEMENT;
                DrawFibo("FiboEntry_", g_pivot_times[1], g_fibo_anchor_1, g_pivot_times[0], g_fibo_anchor_2);
                printf("Órdenes Buy Limit colocadas. Lote: %f, Entrada: %f, SL: %f", lot_size, entry_price, sl_price);
            }
        }
    }
    // Entrada BAJISTA (Sell Limit)
    else if(g_bias == BIAS_BEARISH)
    {
        entry_price = g_fibo_anchor_1 + (range * (InpFiboEntryLevel / 100.0));
        sl_price = g_fibo_anchor_1 + (range * (InpFiboSLLevel / 100.0));
        tp1_price = g_fibo_anchor_1 + (range * (InpFiboTP1Level / 100.0));
        tp2_price = g_fibo_anchor_1 + (range * (InpFiboTP2Level / 100.0));

        double current_high;
        SymbolInfoDouble(_Symbol, SYMBOL_HIGH, current_high);
        // No colocar orden si el precio ya pasó el nivel de entrada
        if(current_high > entry_price)
        {
            g_currentState = STATE_DAY_END;
            UpdateStatusPanel("Entry Missed. Price too high.");
            return;
        }

        double stop_loss_pips = (sl_price - entry_price) / _Point;
        double lot_size = CalculateLotSize(stop_loss_pips);

        if(lot_size > 0)
        {
            // Colocar 2 órdenes pendientes
            trade.SellLimit(lot_size / 2, entry_price, _Symbol, sl_price, tp1_price, 0, 0, "TP1");
            trade.SellLimit(lot_size / 2, entry_price, _Symbol, sl_price, tp2_price, 0, 0, "TP2");

            if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            {
                g_pending_order_ticket = (long)trade.ResultOrder();
                g_currentState = STATE_TRADE_MANAGEMENT;
                DrawFibo("FiboEntry_", g_pivot_times[1], g_fibo_anchor_1, g_pivot_times[0], g_fibo_anchor_2);
                printf("Órdenes Sell Limit colocadas. Lote: %f, Entrada: %f, SL: %f", lot_size, entry_price, sl_price);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 6. Gestiona la operación una vez colocada                        |
//+------------------------------------------------------------------+
void HandleStateTradeManagement(datetime ny_time)
{
    UpdateStatusPanel("Position Open / Pending");

    int total_positions = PositionsTotal();
    int total_orders = OrdersTotal();
    bool active_trade = false;

    // Revisar si hay posiciones abiertas con nuestro Magic Number
    for(int i = total_positions - 1; i >= 0; i--)
    {
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
            active_trade = true;
            break;
        }
    }
    
    // Revisar si hay órdenes pendientes con nuestro Magic Number
    if(!active_trade)
    {
        for(int i = total_orders - 1; i >= 0; i--)
        {
            if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
            {
                active_trade = true;
                break;
            }
        }
    }

    // Si ya no hay órdenes ni posiciones, el ciclo del día terminó
    if(!active_trade)
    {
        g_currentState = STATE_DAY_END;
        UpdateStatusPanel("Trade Cycle Finished");
        printf("El ciclo de trading ha finalizado para hoy.");
    }
    
    // Si la ventana de trading se cierra y la orden pendiente no se activó, la cancelamos
    if(ny_time > StringToTime(TimeToString(ny_time, TIME_DATE) + " " + InpTradingEnd) && total_positions == 0 && total_orders > 0)
    {
        // Cancelar todas las órdenes pendientes de este EA
        for(int i = total_orders - 1; i >= 0; i--)
        {
            ulong ticket = OrderGetTicket(i);
            if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
            {
                trade.OrderDelete(ticket);
            }
        }
        g_currentState = STATE_DAY_END;
        UpdateStatusPanel("Pending Order Cancelled");
        printf("Orden pendiente cancelada por fin de ventana de trading.");
    }
}


//+------------------------------------------------------------------+
//|                       FUNCIONES AUXILIARES                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Resetea las variables para un nuevo día de trading               |
//+------------------------------------------------------------------+
void ResetDailyVariables()
{
    g_currentState = STATE_WAIT_SESSION;
    g_bias = BIAS_NONE;
    g_session_high = 0;
    g_session_low = 0;
    g_session_marked = false;
    g_pending_order_ticket = 0;
    ArrayInitialize(g_pivots, 0);
    ArrayInitialize(g_pivot_times, 0);
    
    // Limpiar objetos del gráfico del día anterior
    ObjectsDeleteAll(0, "Session_");
    ObjectsDeleteAll(0, "Pivot_");
    ObjectsDeleteAll(0, "FiboEntry_");
    
    printf("Variables diarias reseteadas. Esperando nueva sesión.");
}

//+------------------------------------------------------------------+
//| Convierte la hora del servidor a la hora de Nueva York           |
//+------------------------------------------------------------------+
datetime GetNYTime(datetime server_time)
{
    long server_gmt_offset = TerminalInfoInteger(TERMINAL_GMT_OFFSET);
    long ny_gmt_offset = InpNYTimeOffset * 3600;
    return (datetime)(server_time - server_gmt_offset + ny_gmt_offset);
}

//+------------------------------------------------------------------+
//| Convierte la hora de Nueva York a la hora del servidor           |
//+------------------------------------------------------------------+
datetime GetServerTimeFromNY(datetime ny_time)
{
    long server_gmt_offset = TerminalInfoInteger(TERMINAL_GMT_OFFSET);
    long ny_gmt_offset = InpNYTimeOffset * 3600;
    return (datetime)(ny_time + server_gmt_offset - ny_gmt_offset);
}

//+------------------------------------------------------------------+
//| Busca los últimos N pivots del ZigZag                            |
//+------------------------------------------------------------------+
bool FindPivots(int count)
{
    double zigzag_buffer[];
    ArraySetAsSeries(zigzag_buffer, true);
    
    if(CopyBuffer(g_zigzag_handle, 0, 0, 200, zigzag_buffer) <= 0)
        return false;

    int pivots_found = 0;
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    if(CopyRates(_Symbol, _Period, 0, 200, rates) < 200) return false;

    for(int i = 1; i < 200 && pivots_found < count; i++)
    {
        if(zigzag_buffer[i] > 0)
        {
            g_pivots[pivots_found] = zigzag_buffer[i];
            g_pivot_times[pivots_found] = rates[i].time;
            pivots_found++;
        }
    }
    
    return (pivots_found >= count);
}

//+------------------------------------------------------------------+
//| Calcula el tamaño del lote basado en el riesgo                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double stop_loss_pips)
{
    if(stop_loss_pips <= 0) return 0.0;

    double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_amount = account_balance * (InpRiskPercent / 100.0);
    
    double tick_value;
    if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE, tick_value)) return 0.0;
    
    double lot_size = risk_amount / (stop_loss_pips * tick_value);
    
    // Normalizar y verificar límites de lotaje
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot_size = MathFloor(lot_size / lot_step) * lot_step;

    if(lot_size < min_lot) lot_size = min_lot;
    if(lot_size > max_lot) lot_size = max_lot;

    return lot_size;
}

//+------------------------------------------------------------------+
//| Dibuja una línea en el gráfico                                   |
//+------------------------------------------------------------------+
void DrawLine(string name, datetime time1, double price1, datetime time2, double price2, color clr, ENUM_LINE_STYLE style)
{
    ObjectCreate(0, name, OBJ_TREND, 0, time1, price1, time2, price2);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_STYLE, style);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
}

//+------------------------------------------------------------------+
//| Crea una etiqueta de texto para los pivots (H, L, HH, LL)        |
//+------------------------------------------------------------------+
void CreatePivotLabel(datetime time, double price, string text)
{
    string name = "Pivot_" + TimeToString(time);
    ObjectCreate(0, name, OBJ_TEXT, 0, time, price);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_COLOR, InpPivotLabelColor);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
    
    // Ajustar posición para que no se solape con la vela
    bool is_high = (text == "H" || text == "HH");
    ObjectSetInteger(0, name, OBJPROP_ANCHOR, is_high ? ANCHOR_BOTTOM : ANCHOR_TOP);
    ObjectSetDouble(0, name, OBJPROP_PRICE, is_high ? price + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point : price - SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point);
}

//+------------------------------------------------------------------+
//| Dibuja el objeto Fibonacci en el gráfico                         |
//+------------------------------------------------------------------+
void DrawFibo(string name_prefix, datetime time1, double price1, datetime time2, double price2)
{
    string name = name_prefix + TimeToString(TimeCurrent());
    if(!ObjectCreate(0, name, OBJ_FIBO, 0, time1, price1, time2, price2))
    {
        printf("Error al crear el objeto Fibonacci: %d", (int)_LastError);
        return;
    }
    
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrGold);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
    
    // Añadir niveles personalizados
    ObjectSetInteger(0, name, OBJPROP_FIBOLEVELS, 5); // Número de niveles que vamos a definir
    
    // Nivel 0: Entrada
    ObjectSetDouble(0, name, OBJPROP_FIBOLEVEL_VALUE, 0, InpFiboEntryLevel/100.0);
    ObjectSetString(0, name, OBJPROP_FIBOLEVEL_DESCRIPTION, 0, "Entry " + DoubleToString(InpFiboEntryLevel, 1));
    
    // Nivel 1: Stop Loss
    ObjectSetDouble(0, name, OBJPROP_FIBOLEVEL_VALUE, 1, InpFiboSLLevel/100.0);
    ObjectSetString(0, name, OBJPROP_FIBOLEVEL_DESCRIPTION, 1, "SL " + DoubleToString(InpFiboSLLevel, 1));

    // Nivel 2: Take Profit 1
    ObjectSetDouble(0, name, OBJPROP_FIBOLEVEL_VALUE, 2, InpFiboTP1Level/100.0);
    ObjectSetString(0, name, OBJPROP_FIBOLEVEL_DESCRIPTION, 2, "TP1 " + DoubleToString(InpFiboTP1Level, 1));

    // Nivel 3: Take Profit 2
    ObjectSetDouble(0, name, OBJPROP_FIBOLEVEL_VALUE, 3, InpFiboTP2Level/100.0);
    ObjectSetString(0, name, OBJPROP_FIBOLEVEL_DESCRIPTION, 3, "TP2 " + DoubleToString(InpFiboTP2Level, 1));
    
    // Nivel 4: Nivel 0%
    ObjectSetDouble(0, name, OBJPROP_FIBOLEVEL_VALUE, 4, 0.0);
    ObjectSetString(0, name, OBJPROP_FIBOLEVEL_DESCRIPTION, 4, "0.0");
}

//+------------------------------------------------------------------+
//| Crea y actualiza el panel de estado en el gráfico                |
//+------------------------------------------------------------------+
void CreateStatusPanel()
{
    ObjectCreate(0, g_panel_name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, g_panel_name, OBJPROP_CORNER, InpPanelCorner);
    ObjectSetInteger(0, g_panel_name, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, g_panel_name, OBJPROP_YDISTANCE, 15);
    ObjectSetInteger(0, g_panel_name, OBJPROP_BGCOLOR, clrBlack);
    ObjectSetInteger(0, g_panel_name, OBJPROP_BORDER_TYPE, BORDER_FLAT);

    ObjectCreate(0, g_label_name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, g_label_name, OBJPROP_CORNER, InpPanelCorner);
    ObjectSetInteger(0, g_label_name, OBJPROP_XDISTANCE, 15);
    ObjectSetInteger(0, g_label_name, OBJPROP_YDISTANCE, 20);
}

void UpdateStatusPanel(string status_text)
{
    string text = "EA Status: " + status_text;
    ObjectSetString(0, g_label_name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, g_label_name, OBJPROP_COLOR, clrWhite);
    
    // Ajustar el tamaño del fondo
    ObjectSetString(0, g_panel_name, OBJPROP_TEXT, " ");
    ObjectSetInteger(0, g_panel_name, OBJPROP_XSIZE, 250);
    ObjectSetInteger(0, g_panel_name, OBJPROP_YSIZE, 20);
}
//+------------------------------------------------------------------+
