function [X_pred, T_pred, E_pred] = modelo_prediccion_mpc(estado, pwm_vec, clima_futuro, params_cin, datos, camara)
% MODELO_PREDICCION_MPC  Modelo rapido para el modelo interno del MPC
% =========================================================================
% Version v5 — Con conveccion simplificada y balance termico mejorado.
%
% MEJORAS v5 vs v4:
%   - Balance termico con conveccion (no solo T_pred = T_amb)
%   - Conduccion simplificada entre capas (1er orden)
%   - Modelo multi-capa reducido (N_c_mpc capas en vez de escalar)
%   - Factor de flujo calibrado contra gemelo_camara_forzada
%   - Isoterma de Oswin para actividad de agua
%
% MODELO:
%   - Cinetica: Page MR(t) = exp(-k*t^n)
%   - Factor de flujo: f_v = 1 + c_v*v^m_v (mayor velocidad -> mas secado)
%   - Factor HR: depende de HR local del aire (Oswin)
%   - Factor T: Arrhenius simplificado
%   - Balance termico: dT/dt = (Q_conv - Q_evap) / (m*Cp)
%   - Energia: P = P_rated * (PWM/100)^3 [ley cubica ventilador DC]
%
% Ref: Arabi & Ghalehno, BioResources 18(1), 2023
%      Mujumdar (2006), Handbook of Industrial Drying
% =========================================================================

    Np = length(pwm_vec);
    v_max = campo_def(camara, 'v_max_fan', 0.5);
    N_c_mpc = campo_def(camara, 'N_capas_mpc', 5);
    
    % --- Ventilador DC realista ---
    P_rated = campo_def(camara, 'P_rated', 50);     % [W]
    
    % Cinetica Page
    k_Page = params_cin.k;
    n_Page = params_cin.n;
    X0 = params_cin.X0;
    Xe = params_cin.Xe;
    
    % Propiedades aire
    h_alt = campo_def(datos.ubicacion, 'altitud_msnm', 1160);
    P_atm = 101325*(1-2.2558e-5*h_alt)^5.2559;
    rho_aire = P_atm/(287*(22.3+273.15));
    Cp_aire = 1005;
    
    % Ambiente
    T_media = campo_def(datos.ambiente, 'T_media', 22.3);
    HR_media = campo_def(datos.ambiente, 'HR_media', 85);
    
    % Lecho
    H = campo_def(camara, 'H', 1.0);
    A = campo_def(camara, 'A', 1.0);
    rho_lecho = campo_def(camara, 'rho', 120);
    dp = campo_def(camara, 'dp', 0.010);
    epsilon_0 = 0.60;  % porosidad inicial
    beta_shrink = 0.10; % factor de contraccion volumetrica
    dz = H / N_c_mpc;
    V_capa = A * dz;
    m_seca_capa = rho_lecho * V_capa;
    a_v = 6*(1-epsilon_0)/dp;
    
    % Propiedades termicas
    Cp_seco = 1.4;   % kJ/(kg*K)
    Cp_agua = 4.186;
    kappa = 0.05;    % W/(m*K) conductividad del lecho
    
    % Coeficiente convectivo (pre-calculado a velocidad media)
    mu_aire = 1.81e-5; k_aire = 0.0257; Pr = 0.708;
    Sc = 0.62; Le = Sc/Pr;
    
    % Estado actual (multi-capa)
    if length(estado.X_capas) >= N_c_mpc
        X_capas = estado.X_capas(1:N_c_mpc);
        T_capas = estado.T_capas(1:N_c_mpc);
    else
        X_capas = mean(estado.X_capas) * ones(1, N_c_mpc);
        T_capas = mean(estado.T_capas) * ones(1, N_c_mpc);
    end
    
    % Tiempo efectivo por capa
    if isfield(estado, 't_eff') && length(estado.t_eff) >= N_c_mpc
        t_eff = estado.t_eff(1:N_c_mpc);
    else
        t_eff = ones(1, N_c_mpc) * 1.0;  % 1 hora por defecto
    end
    
    % Oswin — centralizado (ver oswin_params.m)
    ow = oswin_params();
    oswin_C = ow.C; oswin_n_s = ow.n_s;
    
    % Inicializar salidas (promedios)
    X_pred = zeros(Np+1, 1);
    T_pred = zeros(Np+1, 1);
    E_pred = zeros(Np+1, 1);
    X_pred(1) = mean(X_capas);
    T_pred(1) = mean(T_capas);
    E_pred(1) = 0;
    
    for i = 1:Np
        pwm_i = pwm_vec(i);
        v_req = (pwm_i / 100) * v_max;
        
        % --- STALL VENTILADOR ---
        P_max_100 = 300; % [Pa]
        pwm_frac = pwm_i / 100;
        P_max_pwm = P_max_100 * (pwm_frac^2);
        
        dP_L_req = 180*mu_aire*v_req*(1-epsilon_0)^2/(dp^2*epsilon_0^3) ...
                 + 4.0*rho_aire*v_req^2*(1-epsilon_0)/(dp*epsilon_0^3);
        dP_bed_req = dP_L_req * H;
        
        if dP_bed_req > P_max_pwm && v_req > 1e-3
            v_fan = v_req * (P_max_pwm / dP_bed_req)^0.5;
        else
            v_fan = v_req;
        end
        
        % --- CHANNELING ---
        f_bypass = 0.20;
        v_eff = max(v_fan * (1 - f_bypass), 0.001);
        m_dot_aire = rho_aire * v_fan * A;
        m_dot_eff = rho_aire * v_eff * A;
        
        % --- Condiciones ambientales ---
        if ~isempty(clima_futuro) && isfield(clima_futuro, 'T_amb') && i <= length(clima_futuro.T_amb)
            T_amb = clima_futuro.T_amb(i);
            HR_amb = clima_futuro.HR(i);
        else
            h_dia = mod(i-1, 24);
            T_amb = T_media + 4*sin(2*pi*(h_dia-8)/24);
            HR_amb = max(min(HR_media - 12*sin(2*pi*(h_dia-8)/24), 98), 55);
        end
        
        % --- Aplicacion dinamica de HX (Evita el deadlock del offset-free MPC) ---
        if isfield(params_cin, 'usar_hx_fisico') && params_cin.usar_hx_fisico
            hora_abs = params_cin.hora_actual + i - 1;
            [dT_hx, dHR_hx] = intercambiador_calor(T_amb, HR_amb, v_fan, hora_abs, params_cin.params_hx);
            T_amb = T_amb + dT_hx;
            HR_amb = min(max(HR_amb - dHR_hx, 0), 100);
        end
        
        % --- Coeficiente convectivo (depende de v) ---
        Re_p = rho_aire * v_eff * dp / mu_aire;
        Nu_p = 2 + 1.1 * Re_p^0.6 * Pr^(1/3);
        h_conv = Nu_p * k_aire / dp;
        h_m = h_conv / (rho_aire * Cp_aire * Le^(2/3));
        
        % --- Sub-pasos para estabilidad numerica (V2.1 CORREGIDO) ---
        % Antes: 1 paso/hora (dt=3600s) con error Euler significativo.
        % Ahora: N_sub=4 (dt=900s), reduciendo error ~16x sin impactar
        % excesivamente la velocidad de fmincon (~4x mas lento).
        % V3.3: Este modelo es INTENCIONALMENTE mas simple que
        % gemelo_camara_lite.m (no Farrell, no shrinkage, no condensacion).
        % El Model Mismatch resultante valida la robustez del MPC ante
        % dinamicas no modeladas (Rawlings & Mayne, 2017, Cap. 1.8).
        N_sub_pred = 4;
        dt_sub_pred = 1.0 / N_sub_pred;  % fraccion de 1 hora
        
        Psat_ent = 610.78 * exp(17.27*T_amb/(T_amb+237.3));
        W_entrada = 0.622 * (HR_amb/100 * Psat_ent) / (P_atm - HR_amb/100 * Psat_ent);
        
        % V1.3: T bulbo humedo (Stull 2011) para limite inferior
        T_wb = T_amb*atan(0.151977*(HR_amb+8.313659)^0.5) ...
             + atan(T_amb+HR_amb) - atan(HR_amb-1.676331) ...
             + 0.00391838*HR_amb^1.5*atan(0.023101*HR_amb) - 4.686035;
        
        for s = 1:N_sub_pred
            T_aire = T_amb;
            W_aire = W_entrada;
            X_new = X_capas;
            T_new = T_capas;
            
            for j = 1:N_c_mpc
                Xi = X_capas(j);
                Tsi = T_capas(j);
                
                % --- CORRECCION AUDIT: Porosidad dinamica (shrinkage) ---
                % La contraccion del lecho reduce epsilon cuando X baja
                shrink_factor = 1 - beta_shrink * max(0, 1 - Xi/X0);
                epsilon = epsilon_0 * shrink_factor;
                a_v_j = 6*(1-epsilon)/dp;
                
                % HR local del aire
                Psat_aj = 610.78 * exp(17.27*T_aire/(T_aire+237.3));
                W_sat_aj = 0.622 * Psat_aj / (P_atm - Psat_aj);
                if W_sat_aj > 1e-8
                    HR_local = min((W_aire / W_sat_aj) * 100, 100);
                else
                    HR_local = 100;
                end
                factor_HR = min(max(1 - HR_local/100, 0) * 5, 1);
                
                % Tasa cinetica con Page
                t_eff_d = max(t_eff(j)/24, 0.001);
                if Xi > Xe + 0.001 && factor_HR > 0.001
                    MR_t = exp(-k_Page * t_eff_d^n_Page);
                    dMRdt = -k_Page * n_Page * t_eff_d^(n_Page-1) * MR_t;
                    m_evap_kin = abs(dMRdt * (X0 - Xe) / 24) * m_seca_capa / 3600 * factor_HR;
                else
                    m_evap_kin = 0;
                end
                
                % Limite convectivo (Sherwood simplificado)
                Psat_s = 610.78 * exp(17.27*Tsi/(Tsi+237.3));
                W_sat_s = 0.622 * Psat_s / (P_atm - Psat_s);
                % Actividad de agua (Oswin)
                if Xi > 1e-6
                    a_w = 1 / (1 + (oswin_C / Xi)^(1/oswin_n_s));
                else
                    a_w = 0;
                end
                W_surf = a_w * W_sat_s;
                delta_W = W_surf - W_aire;
                m_evap_conv = h_m * a_v_j * V_capa * rho_aire * max(delta_W, 0);
                
                % Limite del aire
                T_interf = 0.5 * (T_aire + Tsi);
                Psat_interf = 610.78 * exp(17.27*T_interf/(T_interf+237.3));
                W_sat_interf = 0.622 * Psat_interf / (P_atm - Psat_interf);
                m_evap_air_limit = m_dot_eff * (W_sat_interf - W_aire);
                
                % LIMITE TERMODINAMICO
                h_fg_j = (2501 - 2.361*Tsi) * (1 + 0.38 * exp(-0.4 * Xi));
                m_evap_heat_limit = m_dot_eff * Cp_aire * (T_aire - T_wb) / (h_fg_j * 1000);
                
                if delta_W >= 0
                    m_evap_j = min([m_evap_kin, m_evap_conv, max(m_evap_air_limit,0), max(m_evap_heat_limit,0)]);
                else
                    m_cond_air = m_dot_eff * (W_aire - W_sat_interf);
                    m_cond_conv = h_m * a_v_j * V_capa * rho_aire * abs(delta_W);
                    m_evap_j = -min(max(m_cond_air,0), m_cond_conv);
                end
                
                % Actualizar humedad (ESCALADO por sub-paso)
                dX_j = -m_evap_j * 3600 * dt_sub_pred / m_seca_capa;
                X_new(j) = max(Xi + dX_j, Xe);
                
                % Actualizar aire
                h_fg = (2501 - 2.361*Tsi) * (1 + 0.38 * exp(-0.4 * Xi));  % kJ/kg
                W_aire = W_aire + m_evap_j / m_dot_eff;
                T_aire = T_aire - m_evap_j * h_fg * 1000 / (m_dot_eff * Cp_aire);
                
                % Actualizar tiempo efectivo (ESCALADO por sub-paso)
                if Xi > Xe && delta_W >= 0
                    t_eff(j) = t_eff(j) + factor_HR * dt_sub_pred;
                end
                
                % --- Balance termico simplificado (ESCALADO por sub-paso) ---
                Cp_eff = Cp_seco + Xi * Cp_agua;
                m_capa = m_seca_capa * (1 + Xi);
                Q_conv = h_conv * a_v_j * V_capa * (T_aire - Tsi) * 3.6;  % kJ/h
                Q_evap = m_evap_j * h_fg * 3600;  % kJ/h
                
                % Conduccion simplificada (1er orden)
                if j > 1 && j < N_c_mpc
                    Q_cond = kappa * (T_capas(j+1) - 2*Tsi + T_capas(j-1)) / dz^2 * V_capa * 3.6;
                elseif j == 1 && N_c_mpc > 1
                    Q_cond = kappa * (T_capas(2) - Tsi) / dz^2 * V_capa * 3.6;
                elseif j == N_c_mpc && N_c_mpc > 1
                    Q_cond = kappa * (T_capas(N_c_mpc-1) - Tsi) / dz^2 * V_capa * 3.6;
                else
                    Q_cond = 0;
                end
                
                dTdt = (Q_conv - Q_evap + Q_cond) / (m_capa * Cp_eff);
                dTdt = sign(dTdt) * min(abs(dTdt), 2.0 / dt_sub_pred);
                % V1.3 CORREGIDO: T_wb-0.5 (antes T_amb-5)
                T_new(j) = max(min(Tsi + dTdt * dt_sub_pred, 80), T_wb - 0.5);
            end
            
            X_capas = X_new;
            T_capas = T_new;
        end
        
        X_pred(i+1) = mean(X_capas);
        T_pred(i+1) = mean(T_capas);
        
        % --- Potencia del ventilador (ley cubica DC) ---
        % NOTA: La planta (gemelo_camara_forzada.m) calcula la potencia con
        % Ergun (caida de presion real del lecho poroso). Este modelo interno
        % usa la ley cubica P = P_rated*(PWM/100)^3 por simplicidad y velocidad.
        % El mismatch energetico resultante es INTENCIONAL y aceptable:
        %   - gamma=0.5 (peso de energia en J) hace que J_energia sea <<1%
        %     del costo total, por lo que la discrepancia no afecta la decision.
        %   - Ref: Rawlings & Mayne (2017), Cap. 1.8 — model mismatch tolerado
        %     siempre que el termino dominante (secado, alpha=5000) sea fiel.
        P_vent = P_rated * (pwm_i / 100)^3;   % [W]
        E_pred(i+1) = E_pred(i) + P_vent;      % [Wh] (1 hora)
    end
end

function val = campo_def(s, campo, default)
    if isfield(s, campo), val = s.(campo); else, val = default; end
end
