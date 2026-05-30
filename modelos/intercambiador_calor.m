function [delta_T, delta_HR, info] = intercambiador_calor(T_amb, HR_amb, v_aire, hora_sim, params_hx)
% INTERCAMBIADOR_CALOR  Modelo fisico del intercambiador chimenea-aire
% =========================================================================
% Calcula el incremento de temperatura (delta_T) y la reduccion de humedad
% relativa (delta_HR) que experimenta el aire de secado al pasar por un
% tubo de acero enrollado en espiral (serpentin) alrededor de la superficie
% EXTERIOR de la chimenea de ladrillo del trapiche.
%
% DISEÑO FISICO:
%   La chimenea del trapiche es de ladrillo (arcilla cocida). Los gases de
%   combustion (~350°C) fluyen por el interior. El calor atraviesa la pared
%   de ladrillo y calienta la superficie exterior. Un tubo de acero
%   enrollado en contacto directo con la superficie exterior del ladrillo
%   absorbe ese calor. El ventilador empuja aire frio por dentro del tubo,
%   calentandolo antes de inyectarlo a la camara de secado.
%
% MODELO: Circuito termico de resistencias (analogia electrica-termica)
%
%   T_gases ──[R_ladrillo]──[R_contacto]──[R_wall]──[R_aire]── T_aire_out
%
%   Donde:
%     R_ladrillo = Conduccion a traves de la pared de ladrillo de la chimenea
%     R_contacto = Resistencia de contacto termico ladrillo-acero
%     R_wall     = Conduccion a traves de la pared del tubo de acero
%     R_aire     = Conveccion interna (pared del tubo → aire de secado)
%
%   Analogia electrica:
%     Temperatura  ↔  Voltaje [V]
%     Flujo calor  ↔  Corriente [A]
%     R_termica    ↔  Resistencia [Ω]
%     Fuente calor ↔  Fuente de corriente
%
% CORRELACIONES USADAS:
%   - Conduccion en ladrillo: Ley de Fourier (pared plana)
%     R = espesor / (k_ladrillo * A)
%     Ref: Incropera, Cap. 3 (One-Dimensional Steady-State Conduction)
%
%   - Contacto termico ladrillo-acero: coeficiente empirico
%     R = 1 / (h_contacto * A)
%     Ref: Incropera, Tabla 3.2 (Thermal contact resistance)
%
%   - Conveccion interna (aire forzado en tubo): Dittus-Boelter (1930)
%     Nu = 0.023 * Re^0.8 * Pr^0.4
%     Ref: Incropera, Cap. 8, Ec. 8.60
%     Valida para: Re > 10000, L/D > 10, 0.6 < Pr < 160
%
% PSICROMETRIA:
%   Calentar aire sin agregar vapor (proceso a W constante) reduce la HR
%   porque la presion de saturacion P_sat(T) crece exponencialmente con T.
%   Se usa la ecuacion de Tetens (Antoine simplificada):
%     P_sat(T) = 610.78 * exp(17.27*T / (T + 237.3))  [Pa]
%
% HORARIO DE MOLIENDA:
%   La chimenea solo emite calor durante la molienda. Segun datos de campo
%   del trapiche en Ricaurte, Narino:
%     - 3 dias por semana
%     - De madrugada (~4am) a ~5pm (17h)
%   Fuera de este horario: T_gases = T_amb (sin combustion), delta_T = 0.
%
% ENTRADAS:
%   T_amb    - Temperatura ambiente [°C]
%   HR_amb   - Humedad relativa ambiente [%]
%   v_aire   - Velocidad del aire en el tubo (del ventilador MPC) [m/s]
%   hora_sim - Hora de simulacion (1..N_horas, donde hora 1 = inicio)
%   params_hx - (opcional) struct con parametros geometricos:
%     .D_int            - Diametro interior del tubo [m] (default: 0.076)
%     .D_ext            - Diametro exterior del tubo [m] (default: 0.089)
%     .L_tubo           - Longitud total de la espiral [m] (default: 1.5)
%     .k_metal          - Conductividad del tubo [W/(m*K)] (default: 50)
%     .espesor_ladrillo - Espesor de la pared de ladrillo [m] (default: 0.08)
%     .k_ladrillo       - Conductividad del ladrillo [W/(m*K)] (default: 0.9)
%     .h_contacto       - Coef. contacto ladrillo-acero [W/(m^2*K)] (default: 10)
%     .T_gases_max      - Temperatura maxima de gases [°C] (default: 600)
%     .dias_molienda    - Dias de molienda [1-indexed] (default: [1,2,3,8,9,10,15,16,17,22,23,24])
%     .hora_inicio      - Hora inicio molienda (default: 4)
%     .hora_fin         - Hora fin molienda (default: 17)
%
% SALIDAS:
%   delta_T  - Incremento de temperatura del aire [°C] (>= 0)
%   delta_HR - Reduccion de humedad relativa [puntos porcentuales] (>= 0)
%   info     - Struct con detalles del calculo:
%     .Q_total     - Flujo de calor transferido [W]
%     .R_ladrillo, .R_contacto, .R_wall, .R_aire, .R_total
%     .h_contacto, .h_cold - Coeficientes [W/(m^2*K)]
%     .T_aire_out  - Temperatura del aire a la salida [°C]
%     .hornilla_on - true si la hornilla esta encendida
%     .T_gases     - Temperatura de gases usada [°C]
%
% Ref: Incropera & DeWitt (2011). "Fundamentals of Heat and Mass Transfer"
%      Cengel & Cimbala (2014). "Fluid Mechanics", 3rd ed.
% =========================================================================

    if nargin < 5, params_hx = struct(); end

    %% ================================================================
    %  1. PARAMETROS GEOMETRICOS DEL TUBO Y LA CHIMENEA
    % =================================================================
    % Tubo de acero al carbono comercial enrollado en espiral alrededor
    % de la chimenea de ladrillo del trapiche.
    % Tubo disponible en ferreterias de Pasto y Tumaco (Colombia).
    
    D_int   = campo_def(params_hx, 'D_int',   0.076);   % [m] 3" schedule 40
    D_ext   = campo_def(params_hx, 'D_ext',   0.089);   % [m]
    L_tubo  = campo_def(params_hx, 'L_tubo',  1.5);     % [m] canonico: 1.5m serpentin
    k_metal = campo_def(params_hx, 'k_metal', 50);      % [W/(m*K)] acero carbono
    
    % --- Propiedades de la chimenea de ladrillo ---
    % Chimenea tipica de trapiche panelero en Narino: paredes de ladrillo
    % de arcilla cocida (ladrillo comun/macizo), espesor ~8 cm.
    % Ref: Incropera, Tabla A.3 — Building brick: k = 0.72-1.0 W/(m*K)
    % A alta temperatura (>200°C), k aumenta ligeramente. Usamos 0.9.
    espesor_ladrillo = campo_def(params_hx, 'espesor_ladrillo', 0.08);  % [m]
    k_ladrillo       = campo_def(params_hx, 'k_ladrillo', 0.9);        % [W/(m*K)]
    
    % --- Coeficiente de contacto termico ladrillo-acero ---
    % Contacto entre superficie rugosa de ladrillo y tubo de acero.
    % Sin pasta termica, con abrazaderas metalicas para presionar.
    % Ref: Incropera, Tabla 3.2 — Interfaces rugosas: 5-25 W/(m^2*K)
    % Usamos 10000 W/(m^2*K) (contacto perfecto al estar embebido en cemento/mortero).
    h_contacto = campo_def(params_hx, 'h_contacto', 10000);  % [W/(m^2*K)]

    % --- Factor de ensuciamiento (fouling) ---
    % Acumulacion de hollin, ceniza y polvo de bagazo degrada la
    % transferencia termica con el tiempo. Factor 0-1 (1 = limpio).
    % Ref: Incropera, Tabla 13.1 — Fouling factors for industrial HX
    % Recomendacion: limpiar cada 2-3 semanas de operacion.
    f_fouling = campo_def(params_hx, 'f_fouling', 0.85);  % 15% degradacion tipica

    % Areas de transferencia
    A_ext = pi * 0.6 * L_tubo;   % [m^2] area de toda la chimenea envuelta en la camisa
    A_int = pi * D_int * L_tubo;   % [m^2] area interior (lado aire)

    %% ================================================================
    %  2. HORARIO DE MOLIENDA — ¿Esta la chimenea encendida?
    % =================================================================
    % El trapiche de Ricaurte opera 3 dias/semana, de ~4am a ~5pm.
    % Fuera de ese horario, los gases en la chimenea estan a T ambiente.
    
    T_gases_max    = campo_def(params_hx, 'T_gases_max', 600);  % [°C]
    dias_molienda  = campo_def(params_hx, 'dias_molienda', [1,2,3,8,9,10,15,16,17,22,23,24]);
    hora_inicio    = campo_def(params_hx, 'hora_inicio', 4);    % 4:00 AM
    hora_fin       = campo_def(params_hx, 'hora_fin', 17);      % 5:00 PM
    
    % Determinar dia y hora del dia desde la hora de simulacion
    dia_actual  = floor((hora_sim - 1) / 24) + 1;
    hora_del_dia = mod(hora_sim - 1, 24);  % 0..23
    
    % ¿Es dia de molienda Y esta dentro del horario?
    es_dia_molienda = any(dia_actual == dias_molienda);
    es_hora_activa  = (hora_del_dia >= hora_inicio) && (hora_del_dia < hora_fin);
    hornilla_on = es_dia_molienda && es_hora_activa;
    
    if hornilla_on
        T_gases = T_gases_max;
    elseif es_dia_molienda && (hora_del_dia >= hora_fin)
        % INERCIA TERMICA: La chimenea no se enfria de inmediato
        horas_apagado = hora_del_dia - hora_fin;
        tau_chimenea = 3.0; % [horas] Constante de tiempo de enfriamiento de la mamposteria
        T_gases = T_amb + (T_gases_max - T_amb) * exp(-horas_apagado / tau_chimenea);
    else
        T_gases = T_amb;   % Sin combustion: gases a temperatura ambiente
    end

    %% ================================================================
    %  3. CASO TRIVIAL: chimenea apagada o ventilador apagado
    % =================================================================
    % Si la chimenea esta apagada → sin fuente de calor.
    % Si el ventilador esta apagado (PWM=0, v_aire≈0) → no hay flujo
    % forzado a traves del tubo del serpentin. La conveccion natural
    % (v_nat ≈ 0.02 m/s) entra directamente a la camara de secado SIN
    % pasar por el serpentin de la chimenea, por lo tanto no se calienta.
    %
    % Fisicamente: el serpentin es un circuito paralelo al ambiente.
    % Solo cuando el ventilador esta encendido, este empuja aire POR
    % DENTRO del tubo que envuelve la chimenea. Sin ventilador, el aire
    % simplemente entra por las rendijas de la camara a T ambiente.
    
    ventilador_encendido = v_aire >= 0.001;  % Umbral: 0.2% de v_max (permite gradientes fmincon al 1% PWM)
    
    if ~hornilla_on || T_gases <= T_amb + 1 || ~ventilador_encendido
        delta_T  = 0;
        delta_HR = 0;
        info.Q_total = 0; info.R_hollin = Inf; info.R_ladrillo = Inf; info.R_contacto = Inf;
        info.R_wall = 0; info.R_aire = Inf; info.R_total = Inf;
        info.h_contacto = 0; info.h_cold = 0;
        info.T_aire_out = T_amb; info.hornilla_on = hornilla_on;
        info.T_gases = T_gases;
        info.ventilador_encendido = ventilador_encendido;
        return;
    end

    %% ================================================================
    %  4. PROPIEDADES DEL AIRE (lado frio — interior del tubo)
    % =================================================================
    % Evaluadas a temperatura promedio del aire (T_amb como primera
    % aproximacion; en un diseno riguroso se iteraria).
    
    % Presion atmosferica a 1160 msnm (Ricaurte)
    P_atm = 101325 * (1 - 2.2558e-5 * 1160)^5.2559;  % [Pa] = ~87700 Pa
    
    % Propiedades del aire a ~22°C (temperatura media de Ricaurte)
    rho_aire  = P_atm / (287 * (T_amb + 273.15));  % [kg/m^3]
    mu_aire   = 1.81e-5;      % [Pa*s] viscosidad dinamica
    k_aire    = 0.0257;       % [W/(m*K)] conductividad termica
    Cp_aire   = 1005;         % [J/(kg*K)] calor especifico
    Pr_aire   = mu_aire * Cp_aire / k_aire;  % ~0.71

    %% ================================================================
    %  5. RESISTENCIA R_ladrillo: CONDUCCION A TRAVES DE LA CHIMENEA
    % =================================================================
    % La chimenea del trapiche es de ladrillo de arcilla cocida.
    % Los gases calientes (~350°C) fluyen por el interior; el calor debe
    % atravesar la pared de ladrillo antes de llegar al tubo de acero
    % enrollado por fuera.
    %
    % Aproximacion de pared plana (el radio de la chimenea >> espesor):
    %   R_ladrillo = espesor / (k_ladrillo * A_contacto)
    %
    % Donde A_contacto = A_ext del tubo (area de la espiral en contacto
    % con la superficie del ladrillo).
    %
    % Ref: Incropera, Cap. 3, Ec. 3.4 (Plane wall conduction)
    %      k_ladrillo = 0.72-1.0 W/(m*K) para ladrillo comun
    %      (Incropera, Tabla A.3 - Building materials)
    
    R_ladrillo = espesor_ladrillo / (k_ladrillo * A_ext);  % [K/W]
    
    % --- RESISTENCIA DEL HOLLIN (AISLANTE BRUTAL) ---
    % El hollin depositado en la cara interna de la chimenea tiene
    % una conductividad termica muy baja (~0.06 W/mK).
    espesor_hollin = campo_def(params_hx, 'espesor_hollin', 0.002);  % [m] 2mm por defecto
    k_hollin       = campo_def(params_hx, 'k_hollin', 0.06);         % [W/(m*K)]
    
    R_hollin = espesor_hollin / (k_hollin * A_ext);  % [K/W]

    %% ================================================================
    %  6. RESISTENCIA R_contacto: INTERFAZ LADRILLO-ACERO
    % =================================================================
    % Resistencia de contacto termico entre la superficie rugosa y porosa
    % del ladrillo y el tubo de acero liso. El tubo se fija con abrazaderas
    % metalicas que lo presionan contra el ladrillo.
    %
    % Factores que aumentan esta resistencia:
    %   - Rugosidad alta del ladrillo (porosidad superficial)
    %   - Sin pasta termica ni relleno conductivo
    %   - Geometria cilindro-sobre-plano (contacto lineal, no de area)
    %
    % Factores que la reducen:
    %   - Alta temperatura (contribucion radiativa significativa a >200C)
    %   - Presion de las abrazaderas
    %
    % Valor: h_contacto = 10 W/(m^2*K) ?" conservador.
    % Ref: Incropera, Tabla 3.2; Madhusudana (2014) "Thermal Contact
    %      Conductance", Springer. Para interfaces rugosas sin relleno.
    
    R_contacto = 1 / (h_contacto * f_fouling * A_ext);  % [K/W] (fouling degrada contacto)

    %% ================================================================
    %  7. RESISTENCIA R_wall: CONDUCCION A TRAVES DEL TUBO DE ACERO
    % =================================================================
    % Para un cilindro hueco:
    %   R_wall = ln(D_ext/D_int) / (2*pi*k_metal*L)
    %
    % Para acero (k=50 W/(m*K)) y espesor de 6.5 mm, esta resistencia
    % es MUCHO menor que R_ladrillo, R_contacto y R_aire (~10^-4 K/W).
    % Se incluye por completitud academica.
    
    R_wall = log(D_ext / D_int) / (2 * pi * k_metal * L_tubo);  % [K/W]

    %% ================================================================
    %  8. RESISTENCIA R_aire: CONVECCION INTERNA (pared tubo → aire)
    % =================================================================
    % Correlacion de DITTUS-BOELTER (1930) para flujo interno turbulento:
    %
    %   Nu_D = 0.023 * Re_D^0.8 * Pr^0.4
    %
    % Condiciones de validez:
    %   Re > 10000 (turbulento)
    %   L/D > 10   (flujo desarrollado)
    %   0.6 < Pr < 160
    %
    % Para nuestro tubo: L/D = 1.5/0.076 = 19.7 > 10 ✓
    %                    Pr_aire = 0.71                ✓
    %
    % Si Re < 10000 (laminar), usamos Nu = 3.66 (tubo con T_pared cte).
    % Ref: Incropera, Ec. 8.55
    
    v_aire_eff = max(v_aire, 0.001); % CORRECCIÓN DE DINÁMICA DE FLUIDOS (Ecuación de Continuidad):
    % v_aire es la velocidad en la cámara (A = 1 m^2). Para hallar la velocidad 
    % dentro del tubo de 3 pulgadas, multiplicamos por la relación de áreas.
    A_camara = 1.0; % [m^2]
    A_tubo_int = (pi/4) * D_int^2; % [m^2]
    v_tubo = v_aire_eff * (A_camara / A_tubo_int); % [m/s]
    
    Re_int = rho_aire * v_tubo * D_int / mu_aire;
    
    if Re_int >= 10000
        % Dittus-Boelter (turbulento, calentamiento → exponente 0.4)
        Nu_int = 0.023 * Re_int^0.8 * Pr_aire^0.4;
    elseif Re_int >= 2300
        % Zona de transicion — interpolacion lineal
        Nu_lam = 3.66;
        Nu_turb = 0.023 * 10000^0.8 * Pr_aire^0.4;
        f_turb = (Re_int - 2300) / (10000 - 2300);
        Nu_int = Nu_lam * (1 - f_turb) + Nu_turb * f_turb;
    else
        % Laminar: Nu = 3.66 (T_pared constante, flujo desarrollado)
        Nu_int = 3.66;
    end
    
    h_cold = Nu_int * k_aire / D_int;   % [W/(m^2*K)]
    
    R_aire = 1 / (h_cold * A_int);      % [K/W]

    %% ================================================================
    %  9. CIRCUITO TERMICO COMPLETO — Ley de Ohm termica
    % =================================================================
    %
    %   Q = (T_gases - T_amb) / R_total    [Analogia: I = V / R]
    %
    %   T_aire_out = T_amb + Q * R_aire    [Analogia: V_salida = I * R_carga]
    %
    % Esto es exactamente como un divisor de voltaje:
    %   T_aire_out = T_amb + (T_gases - T_amb) * R_aire / R_total
    %
    % Nota: R_aire (conveccion interna) es la resistencia DOMINANTE
    % del circuito (~2.3 K/W vs ~0.2-0.4 K/W para las demas). Esto
    % significa que el cuello de botella es la capacidad del aire de
    % absorber calor, no la transferencia a traves del ladrillo.
    % Consecuencia practica: variaciones moderadas en R_ladrillo o
    % R_contacto apenas afectan el delta_T final.
    
    R_total = R_hollin + R_ladrillo + R_contacto + R_wall + R_aire;  % [K/W]
    
    % Flujo de calor total transferido
    Q_total = (T_gases - T_amb) / R_total;   % [W]
    
    % Temperatura del aire a la salida de la MEZCLA (Tubo + Bypass)
    % El ventilador mueve un caudal total basado en el area de la camara (1.0 m^2)
    A_camara = 1.0;
    m_dot_camara = rho_aire * v_aire_eff * A_camara;  % [kg/s] Caudal total en la camara
    
    if m_dot_camara > 1e-6
        delta_T_mix = Q_total / (m_dot_camara * Cp_aire);  % [°C]
    else
        delta_T_mix = 0;
    end
    
    % --- PROTECCION TERMICA DE FIBRAS (Farrell 1998) ---
    % Limite: T_aire_entrada_camara <= 85°C para no quemar el bagazo
    T_max_secado = campo_def(params_hx, 'T_max_secado', 85);  % [°C]
    delta_T = min(delta_T_mix, max(T_max_secado - T_amb, 0));
    
    T_aire_hx = T_amb + delta_T;
    % --- PÉRDIDA DE CALOR EN LOS DUCTOS (Duct Heat Loss) ---
    % El aire caliente viaja por un ducto hasta la base de la cámara.
    % T_entrada = T_amb + (T_hx - T_amb) * exp(-UA / (m_dot * Cp))
    L_ducto = campo_def(params_hx, 'L_ducto', 5.0);       % [m]
    D_ducto = campo_def(params_hx, 'D_ducto', 0.1);       % [m] PVC estandar 4 pulgadas
    U_ducto = campo_def(params_hx, 'U_ducto', 5.0);       % [W/(m^2*K)] Coef. global de PVC no aislado
    A_ducto = pi * D_ducto * L_ducto;                     % [m^2] Area de transferencia del ducto
    
    if m_dot_camara > 1e-6
        T_aire_out = T_amb + (T_aire_hx - T_amb) * exp(-U_ducto * A_ducto / (m_dot_camara * Cp_aire));
    else
        T_aire_out = T_amb;
    end

    %% ================================================================
    %  9b. FUNCION DE TRANSFERENCIA G(s) = K / (tau*s + 1)
    % =================================================================
    % El circuito termico con capacitancia termica genera un sistema de
    % PRIMER ORDEN, identico a un circuito RC electrico.
    %
    % Para este sistema, la capacitancia dominante es la del ladrillo
    % (masa significativa) y la del tubo de acero. Sin embargo, como
    % el ladrillo ya esta en regimen permanente (la chimenea lleva horas
    % encendida cuando arranca el secado), la dinamica transitoria
    % relevante es solo la del tubo de acero.
    %
    % Funcion de transferencia simplificada:
    %   G(s) = Delta_T_aire(s) / Theta_gases(s) = K / (tau*s + 1)
    %
    % Donde:
    %   R_hot  = R_ladrillo + R_contacto  (resistencia del lado caliente)
    %   K      = R_aire / R_total         [ganancia DC, adimensional]
    %   tau    = C_th * R_hot*R_aire/(R_hot+R_aire) [cte de tiempo, s]
    %   C_th   = m_tubo * Cp_acero        [capacitancia termica, J/K]
    %
    % JUSTIFICACION del regimen estacionario:
    %   tau ≈ 5-15 minutos << 1 hora (paso del MPC)
    %   Por lo tanto, G(s→0) = K es una aproximacion excelente.
    %   El tubo alcanza el 99% de su temperatura final en 5*tau,
    %   mucho antes de que el MPC tome su siguiente decision.
    %
    % Ref: Incropera Cap. 5 (Transient Conduction)
    %      Ogata (2010), "Modern Control Engineering", 5th ed, Cap. 3
    
    % --- Capacitancia termica del tubo de acero ---
    rho_acero = 7800;    % [kg/m^3] densidad del acero al carbono
    Cp_acero  = 500;     % [J/(kg*K)] calor especifico del acero
    vol_tubo  = (pi/4) * (D_ext^2 - D_int^2) * L_tubo;  % [m^3]
    m_tubo    = rho_acero * vol_tubo;                      % [kg]
    C_th      = m_tubo * Cp_acero;                         % [J/K]
    
    % --- Resistencia equivalente del lado caliente ---
    R_hot = R_ladrillo + R_contacto;  % [K/W]
    
    % --- Constante de tiempo ---
    R_eq = (R_hot * R_aire) / (R_hot + R_aire);  % [K/W] paralelo
    tau  = C_th * R_eq;                           % [s]
    
    % --- Ganancia DC ---
    K_dc = 1 / (R_total * m_dot_camara * Cp_aire);  % [adimensional]
    
    % --- Verificacion: delta_T_estacionario = K_dc * (T_gases - T_amb) ---
    % Esto debe coincidir con delta_T_max calculado arriba.
    % Usar valor absoluto y maximo para evitar ganancias negativas
    K_dc = max(K_dc, 0);

    %% ================================================================
    %  9c. APLICACION DE LA DINAMICA (Aproximacion de Euler 1D temporal)
    % =================================================================
    %
    % T_hx(t) = T_hx(t-dt) + (dt/tau) * ( K_dc*(T_gases - T_amb) - (T_hx(t-dt) - T_amb) )
    %
    % NOTA: En este modelo no estamos llevando el estado iterativo T_hx(t-dt),
    % sino devolviendo la respuesta cuasi-estacionaria. Si se desea dinamica
    % real transitoria (ej. al encender la chimenea), se debe modificar
    % para recibir el T_hx anterior como entrada de estado.
    % Por ahora, devolvemos el valor T_aire_out directo.
    % 
    % Pero por si se necesita para control, calculamos el "Heat Rate" Q_hx:
    Q_hx = Q_total; % [W]

    
    %% ================================================================
    %  10. EMPAQUETADO DE RESULTADOS
    % =================================================================
    % 
    % Se retornan como salidas directas:
    %   dT_hx : Aumento de temperatura [C]
    %   dHR_hx: Disminucion de humedad relativa [puntos %]
    %
    % La estructura 'info' contiene diagnosticos.

    info.T_aire_in   = T_amb;         % [C]
    info.HR_aire_in  = HR_amb;        % [%]
    info.T_aire_out  = T_aire_out;    % [C]
    info.T_gases     = T_gases;       % [C]
    info.hornilla_on = hornilla_on;
    info.m_dot_aire  = m_dot_camara;  % [kg/s] 
    
    %% ================================================================
    %  11. PSICROMETRIA — Reduccion de HR
    % =================================================================
    % Calentar aire sin agregar vapor es un proceso a HUMEDAD ABSOLUTA
    % CONSTANTE (W = cte). Pero como P_sat(T) aumenta con T, la HR baja.
    %
    % Paso 1: Calcular W original (humedad absoluta del aire ambiente)
    %   P_sat(T_amb)
    %   W = 0.622 * (HR/100 * P_sat) / (P_atm - HR/100 * P_sat)
    %
    % Paso 2: Calcular nueva HR a T_aire_out manteniendo W constante
    %   P_sat(T_out)
    %   HR_new = (W * P_atm) / ((0.622 + W) * P_sat(T_out)) * 100
    
    % Presion de saturacion a T ambiente (ecuacion de Tetens/Antoine)
    Psat_amb = 610.78 * exp(17.27 * T_amb / (T_amb + 237.3));
    
    % Humedad absoluta del aire ambiente [kg_vapor / kg_aire_seco]
    W_abs = 0.622 * (HR_amb/100 * Psat_amb) / (P_atm - HR_amb/100 * Psat_amb);
    
    % Presion de saturacion a la nueva temperatura
    Psat_out = 610.78 * exp(17.27 * T_aire_out / (T_aire_out + 237.3));
    
    % Nueva HR a T_aire_out (W se conserva)
    HR_new = (W_abs * P_atm) / ((0.622 + W_abs) * Psat_out) * 100;
    HR_new = max(min(HR_new, 100), 5);  % Limites fisicos
    
    delta_HR = HR_amb - HR_new;  % Reduccion de HR [puntos porcentuales]
    delta_HR = max(delta_HR, 0);

    %% ================================================================
    %  11. INFORMACION DE DIAGNOSTICO
    % =================================================================
    info.Q_total     = Q_total;       % [W]
    info.R_hollin    = R_hollin;      % [K/W]
    info.R_ladrillo  = R_ladrillo;    % [K/W]
    info.R_contacto  = R_contacto;    % [K/W]
    info.R_wall      = R_wall;        % [K/W]
    info.R_aire      = R_aire;        % [K/W]
    info.R_total     = R_total;       % [K/W]
    info.R_hot       = R_hot;         % [K/W] ladrillo + contacto
    info.h_contacto  = h_contacto;    % [W/(m^2*K)]
    info.h_cold      = h_cold;        % [W/(m^2*K)]
    info.Re_int      = Re_int;        % [-]
    info.Nu_int      = Nu_int;        % [-]
    info.T_aire_out  = T_aire_out;    % [°C]
    info.T_gases     = T_gases;       % [°C]
    info.hornilla_on = hornilla_on;
    info.m_dot_aire  = m_dot_camara;  % [kg/s]
    info.delta_T     = delta_T;       % [°C]
    info.delta_HR    = delta_HR;      % [puntos %]
    info.W_abs       = W_abs;         % [kg/kg]
    info.HR_new      = HR_new;        % [%]
    
    % Funcion de transferencia G(s) = K_dc / (tau*s + 1)
    info.C_th        = C_th;          % [J/K] capacitancia termica del tubo
    info.tau         = tau;           % [s] constante de tiempo
    info.tau_min     = tau / 60;      % [min] constante de tiempo
    info.K_dc        = K_dc;          % [-] ganancia DC
    info.m_tubo      = m_tubo;        % [kg] masa del tubo
    info.R_eq        = R_eq;          % [K/W] resistencia equivalente paralelo

end

function val = campo_def(s, campo, default)
    if isfield(s, campo), val = s.(campo); else, val = default; end
end
