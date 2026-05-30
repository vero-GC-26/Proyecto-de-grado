function J = costo_mpc(pwm_vec, estado, clima_futuro, params)
% COSTO_MPC  Funcion de costo J que fmincon minimiza en cada paso MPC
% =========================================================================
% Version v5: Agrega termino de TRACKING hacia X_ref y normaliza energia.
%
% ESTRUCTURA (4 terminos):
%   J = -alpha * (X_ahora - X_predicho(end))   (maximizar progreso)
%     +  delta * max(X_end - X_ref, 0)^2        (tracking al objetivo)
%     +  epsilon * SUM(max(T(i)-T_max,0)^2)     (restriccion termica)
%     +  gamma * E_total / E_ref                 (minimizar energia normalizada)
%     +  beta  * SUM(delta_PWM(i)^2), i=2..Nc   (suavidad INTERNA solamente)
%
% MEJORAS v5 vs v4:
%   - Termino de tracking: penaliza estar LEJOS de X_ref (cuadratico)
%   - E_ref parametrizado: P_rated * 24, no hardcoded
%   - Penalizacion asimetrica: solo penaliza si X > X_ref (no si ya seco)
%
% Ref: Camacho & Bordons (2007) — funcion de costo economica
%      Rawlings, Mayne & Diehl (2017) — terminal cost
%
% V2.3 — JUSTIFICACION DE PESOS (sintonizacion empirica-iterativa):
%   alpha = 50000: Dominante. Maximiza progreso de secado (prioridad #1).
%   delta = 500:  Tracking cuadratico asimetrico hacia X_ref.
%   gamma = 1500: Fuerte penalizacion energia.
%   beta  = 0.1:  Suavidad. Evita chattering sin restringir agilidad.
%   Metodologia: Maciejowski (2002), "Predictive Control with Constraints".
%   Validacion: MPC-Red (gamma=0.5) vs MPC-Solar (gamma=80) convergen.
%   Trabajo futuro: analisis de Pareto formal (requiere >1000 simulaciones).
% =========================================================================

    Np = params.Np;
    Nc = params.Nc;
    
    % --- Extender PWM ---
    pwm_extendido = zeros(Np, 1);
    pwm_extendido(1:Nc) = pwm_vec(:);
    pwm_extendido(Nc+1:Np) = pwm_vec(end);
    
    % --- Inyectar opciones de HX ---
    if isfield(params, 'usar_hx_fisico') && params.usar_hx_fisico
        params.params_cin.usar_hx_fisico = params.usar_hx_fisico;
        params.params_cin.params_hx = params.params_hx;
        params.params_cin.hora_actual = params.hora_actual;
    end
    
    % --- Simular hacia adelante ---
    [X_pred, T_pred, E_pred] = modelo_prediccion_mpc( ...
        estado, pwm_extendido, clima_futuro, ...
        params.params_cin, params.datos, params.camara);
    
    % --- TERMINO 1: Progreso de secado (MAXIMIZAR) ---
    % Revertido: Dejamos que el MPC sea "codicioso" (agresivo) para que seque rapido.
    % La prevencion de sobre-secado se maneja con la Parada Logica (Option B) en el lazo principal.
    progreso = X_pred(1) - X_pred(end);
    J_progreso = -params.alpha * progreso;
    
    % --- TERMINO 2: Tracking al objetivo X_ref (NUEVO en v5) ---
    % Penalizacion cuadratica asimetrica: solo si X > X_ref
    % Esto hace que el MPC BUSQUE llegar a X_ref, no solo "secar lo mas"
    X_ref = params.X_ref;
    delta = campo_def(params, 'delta', 500);
    error_final = max(X_pred(end) - X_ref, 0);
    J_tracking = delta * error_final^2;
    
    % --- TERMINO 3: Suavidad INTERNA (evitar chattering) ---
    delta_pwm = diff(pwm_extendido);
    J_suavidad = params.beta * sum(delta_pwm.^2);
    
    % --- TERMINO 4: Consumo energetico normalizado ---
    E_total = E_pred(end) - E_pred(1);
    % E_ref parametrizado: P_rated * 24h (potencia maxima del ventilador por 1 dia)
    P_rated = campo_def(params.camara, 'P_rated', 50);  % [W]
    E_ref = P_rated * 24;   % [Wh] referencia = 1 dia a PWM=100%
    J_energia = params.gamma * (E_total / E_ref);
    
    % --- TERMINO 5 (NUEVO GAP): Restriccion termica de seguridad ---
    % Penaliza T > T_max para evitar degradacion de fibras, muerte bacteriana
    % prematura, o riesgo de ignicion. Ref: Farrell (1998) — pilas > 85C.
    T_max = campo_def(params, 'T_max_bagazo', 85);  % [C] limite seguro
    epsilon_T = campo_def(params, 'epsilon_T', 200); % peso de penalizacion
    T_exceso = max(T_pred(2:end) - T_max, 0);  % solo penaliza excedentes
    J_termico = epsilon_T * sum(T_exceso.^2);
    
    % --- COSTO TOTAL ---
    J = J_progreso + J_tracking + J_suavidad + J_energia + J_termico;
end

function val = campo_def(s, campo, default)
    if isfield(s, campo), val = s.(campo); else, val = default; end
end
