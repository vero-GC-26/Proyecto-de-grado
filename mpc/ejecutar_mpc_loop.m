function [pwm_hist, v_vec, X_hist, T_hist, J_hist, exit_hist, info_stats, estado_final] = ...
    ejecutar_mpc_loop(params_cin, datos, camara, clima, mpc_params, N_horas, etiqueta, opciones)
% EJECUTAR_MPC_LOOP  Bucle MPC reutilizable para diferentes configuraciones
% =========================================================================
% Version v5 — Con ruido de medicion, estadisticas de convergencia,
%               y soporte para aire precalentado (intercambiador).
%
% V4.3 — NOTA DE VIABILIDAD INDUSTRIAL:
%   En despliegue real (ESP32 + WiFi rural), si se pierde conexion a
%   Open-Meteo, el MPC puede operar en modo offline usando el ultimo
%   pronostico valido (clima_futuro del paso anterior). Si la desconexion
%   supera 24h, se recomienda fallback a PWM conservador constante (15%)
%   hasta restaurar conectividad. El MPC opera cada hora, asi que una
%   latencia de red de 50-200ms es completamente irrelevante.
%
% ENTRADAS:
%   params_cin  - Parametros cineticos (Page)
%   datos       - Datos de campo
%   camara      - Configuracion de la camara
%   clima       - Datos climaticos (Open-Meteo o [])
%   mpc_params  - Parametros del MPC (alpha, beta, gamma, delta, Np, Nc, etc.)
%   N_horas     - Numero total de horas a simular
%   etiqueta    - String para identificar el escenario en consola
%   opciones    - (NUEVO) struct con:
%     .ruido_X    - desviacion estandar del ruido en X [kg/kg] (default 0)
%     .ruido_T    - desviacion estandar del ruido en T [C] (default 0)
%     .delta_T_HX - incremento de T por intercambiador de calor [C] (default 0)
%     .delta_HR_HX- reduccion de HR por intercambiador [%] (default 0)
%
% SALIDAS:
%   pwm_hist    - Historial de PWM optimo [N_horas x 1]
%   v_vec       - Velocidades para gemelo_camara_forzada [N_horas x 1]
%   X_hist      - Trayectoria de humedad [(N_horas+1) x 1]
%   T_hist      - Trayectoria de temperatura [(N_horas+1) x 1]
%   J_hist      - Historial de costo J [N_horas x 1]
%   exit_hist   - Historial de exitflag [N_horas x 1]
%   info_stats  - (NUEVO) struct con estadisticas:
%     .n_eval_hist     - evaluaciones fmincon por paso
%     .t_paso_hist     - tiempo [s] por paso MPC
%     .t_total         - tiempo total MPC [s]
%     .n_convergidos   - pasos con exitflag > 0
%     .pct_convergidos - porcentaje de convergencia
% =========================================================================

    if nargin < 7, etiqueta = 'MPC'; end
    if nargin < 8, opciones = struct(); end
    
    % Opciones de ruido
    ruido_X   = campo_def(opciones, 'ruido_X', 0);
    ruido_T   = campo_def(opciones, 'ruido_T', 0);
    delta_T_HX  = campo_def(opciones, 'delta_T_HX', 0);
    delta_HR_HX = campo_def(opciones, 'delta_HR_HX', 0);
    
    % NUEVO: Intercambiador de calor con modelo fisico
    usar_hx_fisico = campo_def(opciones, 'usar_hx_fisico', false);
    params_hx = campo_def(opciones, 'params_hx', struct());
    
    N_c_lite = 5;
    
    % Inicializar estado
    if isfield(opciones, 'estado_inicial') && ~isempty(opciones.estado_inicial)
        estado = opciones.estado_inicial;
    else
        estado.X_capas = params_cin.X0 * ones(1, N_c_lite);
        estado.T_capas = datos.estado_secado.temp_C(1) * ones(1, N_c_lite);
        estado.t_eff   = zeros(1, N_c_lite);
        estado.pwm_anterior = 0;
    end
    
    hora_inicio = campo_def(opciones, 'hora_inicio', 1);
    
    % Vectores de salida
    pwm_hist  = zeros(N_horas, 1);
    X_hist    = zeros(N_horas + 1, 1);
    T_hist    = zeros(N_horas + 1, 1);
    J_hist    = zeros(N_horas, 1);
    exit_hist = zeros(N_horas, 1);
    v_vec     = zeros(N_horas, 1);
    
    pwm_hist  = zeros(N_horas, 1);
    frac_hist = zeros(N_horas, 1);
    
    % Estadisticas de rendimiento (NUEVO v5)
    n_eval_hist = zeros(N_horas, 1);
    t_paso_hist = zeros(N_horas, 1);
    
    X_hist(1) = params_cin.X0;
    T_hist(1) = datos.estado_secado.temp_C(1);
    
    % Camara lite para avanzar 1 hora
    camara_lite_1h = camara;
    camara_lite_1h.N_capas = N_c_lite;
    camara_lite_1h.dias_sim = 1/24;
    camara_lite_1h.t_eff_init = zeros(1, N_c_lite);
    
    % Copia local de mpc_params (para semilla caliente)
    mp = mpc_params;
    mp.params_cin = params_cin;
    mp.datos = datos;
    mp.camara = camara;
    
    % --- CORRECCION GAP: Inicializar variables (feedback removido) ---
    
    t_total_start = tic;
    
    for k = 1:N_horas
        hora_actual = hora_inicio + k - 1;
        dia = floor((hora_actual-1)/24) + 1;
        
        % Clima futuro (con posible modificacion por intercambiador)
        if ~isempty(clima) && isfield(clima, 'T_amb')
            idx_ini = hora_actual;
            idx_fin = min(hora_actual + mp.Np - 1, clima.n_horas);
            cf.T_amb   = clima.T_amb(idx_ini:idx_fin);
            cf.HR      = clima.HR(idx_ini:idx_fin);
            cf.I_solar = clima.I_solar(idx_ini:idx_fin);
            
            % Sanitizacion NaN (proteccion contra fallas de Open-Meteo)
            cf.T_amb(isnan(cf.T_amb))     = datos.ambiente.T_media;
            cf.HR(isnan(cf.HR))           = datos.ambiente.HR_media;
            cf.I_solar(isnan(cf.I_solar)) = 0;
            
            % NOTA ARQUITECTURAL CORREGIDA:
            % Anteriormente, el HX NO se pasaba al modelo interno del MPC bajo la
            % asuncion de que el offset-free MPC lo compensaria como "rechazo a perturbacion".
            % SIN EMBARGO, esto creaba un deadlock (bloqueo) en clima lluvioso severo (ej. HR=95%):
            % El MPC creia ciegamente que el aire siempre estaba a 95% HR, por lo que determinaba
            % que prender el ventilador solo enfriaria/mojaria el bagazo gastando energia (PWM=0).
            % Al nunca prender el ventilador, el HX nunca se activaba en la planta real.
            %
            % FIX: El HX se evalua *DINAMICAMENTE* dentro del modelo interno del MPC (costo_mpc.m)
            % para cada candidato de PWM. Asi, el MPC sabe: "Si PWM=0, aire frio; si PWM=50%, aire caliente".
            % Esto rompe el deadlock sin crear incentivos perversos.
            if ~usar_hx_fisico && (delta_T_HX ~= 0 || delta_HR_HX ~= 0)
                % Modelo simplificado (constante) — retrocompatible
                cf.T_amb = cf.T_amb + delta_T_HX;
                cf.HR    = min(max(cf.HR - delta_HR_HX, 0), 100);
            end
            
            while length(cf.T_amb) < mp.Np
                cf.T_amb   = [cf.T_amb;   cf.T_amb(end)];
                cf.HR      = [cf.HR;      cf.HR(end)];
                cf.I_solar = [cf.I_solar; cf.I_solar(end)];
            end
            cf.n_horas = mp.Np;
        else
            cf = [];
        end
        
        % --- CORRECCION GAP: Fail-safe para pronostico obsoleto ---
        % Si el clima esta desactualizado (>12h), el MPC pasa a modo
        % conservador para evitar decisiones basadas en datos caducados.
        % Ref: IEC 61508 — Functional Safety (principio fail-safe)
        clima_obsoleto = false;
        if ~isempty(clima) && isfield(clima, 'timestamp_descarga')
            horas_desde_descarga = (now - clima.timestamp_descarga) * 24;
            if horas_desde_descarga > 12
                clima_obsoleto = true;
            end
        end
        
        % Semilla caliente
        if isfield(mp, 'pwm_semilla_prev')
            mp.pwm_semilla = mp.pwm_semilla_prev;
        end
        
        % Pasar HX dinamicamente al MPC
        mp.usar_hx_fisico = usar_hx_fisico;
        if usar_hx_fisico
            mp.params_hx = params_hx;
            mp.hora_actual = hora_actual;
        end
        
        % --- Agregar ruido de medicion al estado (NUEVO v5) ---
        estado_medido = estado;
        if ruido_X > 0
            estado_medido.X_capas = max(estado.X_capas + ruido_X * randn(1, N_c_lite), 0);
        end
        if ruido_T > 0
            estado_medido.T_capas = estado.T_capas + ruido_T * randn(1, N_c_lite);
        end
        
        % --- CORRECCION AUDIT: Feedback de pronostico (rechazo a perturbaciones) ---
        % (Se ha eliminado la retroalimentación errónea que causaba inestabilidad en el secado)
        
        % Optimizar (con estado ruidoso, como en la realidad)
        t_paso_start = tic;
        if clima_obsoleto
            % FAIL-SAFE: PWM conservador sin pronostico valido
            pwm_opt = 15;  % secado suave minimo
            J_opt = NaN;
            info.exitflag = -99;  % codigo especial: modo offline
            info.pwm_semilla_next = 15 * ones(mp.Nc, 1);
            info.n_evaluaciones = 0;
            if mod(k, 24) == 0
                fprintf('  [%s] *** FAIL-SAFE ACTIVO: Pronostico obsoleto (>12h) — PWM=15%% ***\n', etiqueta);
            end
        else
            [pwm_opt, J_opt, info] = mpc_paso(estado_medido, cf, mp);
        end
        
        % --- Condicion de Parada Logica PERSISTENTE ---
        % v5.3 FIX: Se usa un flag 'lote_terminado' que, una vez activado,
        % NO puede ser revertido por el warm start del optimizador.
        % Este es el comportamiento correcto de un sistema industrial: 
        % cuando el operario apaga la maquina, NO se vuelve a encender sola.
        if ~exist('lote_terminado', 'var')
            lote_terminado = false;
        end
        if mean(estado.X_capas) <= mp.X_ref
            lote_terminado = true;
        end
        if lote_terminado
            pwm_opt = 0;
            J_opt = 0;
            info.n_evaluaciones = 0;
            info.pwm_semilla_next = zeros(mp.Nc, 1);  % Semilla 0 para siguiente paso
            mp.pwm_semilla_prev = zeros(mp.Nc, 1);    % Limpiar warm start corrupto
            if mod(k, 24) == 0 || mean(estado.X_capas) <= mp.X_ref
                fprintf('  [%s] *** LOTE TERMINADO (X=%.4f <= %.4f) — Ventilador APAGADO ***\n', ...
                    etiqueta, mean(estado.X_capas), mp.X_ref);
            end
        end
        t_paso_hist(k) = toc(t_paso_start);
        
        mp.pwm_semilla_prev = info.pwm_semilla_next;
        n_eval_hist(k) = info.n_evaluaciones;
        
        % Guardar
        pwm_hist(k) = pwm_opt;
        J_hist(k) = J_opt;
        exit_hist(k) = info.exitflag;
        
        % Controlador de Bajo Nivel (Ráfagas PWM)
        pwm_stall_limit = 20; % Límite físico para vencer Stall
        if pwm_opt > 0 && pwm_opt < pwm_stall_limit
            pwm_real = pwm_stall_limit;
            frac_activa = pwm_opt / pwm_stall_limit;
        else
            pwm_real = pwm_opt;
            frac_activa = 1.0;
        end
        
        pwm_hist(k) = pwm_real;
        frac_hist(k) = frac_activa;
        v_vec(k) = (pwm_opt / 100) * camara.v_max_fan; % Velocidad promedio
        
        % Extraer clima de la hora actual
        if ~isempty(clima) && isfield(clima, 'T_amb') && hora_actual <= clima.n_horas
            cl_base.T_amb   = clima.T_amb(hora_actual);
            cl_base.HR      = clima.HR(hora_actual);
            cl_base.I_solar = clima.I_solar(hora_actual);
            cl_base.n_horas = 1;
        else
            cl_base = [];
        end
        
        % Simular la planta con la velocidad promedio (equivalente físico de la ráfaga)
        % Se usa v_mpc_promedio para mantener la integridad de la cuadrícula temporal (dt=1h)
        % La termodinámica se conserva idéntica al ciclo de ráfagas.
        v_mpc_promedio = (pwm_opt / 100) * camara.v_max_fan;
        
        if ~isempty(cl_base)
            cl_1h = cl_base;
            if usar_hx_fisico
                [dT_k, dHR_k] = intercambiador_calor(cl_1h.T_amb, cl_1h.HR, v_mpc_promedio, hora_actual, params_hx);
                cl_1h.T_amb = cl_1h.T_amb + dT_k;
                cl_1h.HR    = min(max(cl_1h.HR - dHR_k, 0), 100);
            elseif delta_T_HX ~= 0 || delta_HR_HX ~= 0
                cl_1h.T_amb = cl_1h.T_amb + delta_T_HX;
                cl_1h.HR    = min(max(cl_1h.HR - delta_HR_HX, 0), 100);
            end
        else
            cl_1h = [];
        end
        
        params_1h = params_cin;
        params_1h.X0 = mean(estado.X_capas);
        
        res_1h = gemelo_camara_lite(params_1h, datos, camara_lite_1h, cl_1h, v_mpc_promedio);
        
        estado.X_capas = res_1h.X(2, :);
        estado.T_capas = res_1h.Ts(2, :);
        camara_lite_1h.t_eff_init = res_1h.t_eff_capa;
        
        estado.pwm_anterior = pwm_opt;
        
        X_hist(k+1) = mean(estado.X_capas);
        T_hist(k+1) = mean(estado.T_capas);
        
        % (Predicción guardada removida por corrección de feedback)
        
        if mod(k, 24) == 0 || k == 1
            fprintf('  [%s] Dia %2d | Hora %3d (Sim %3d/%d) | PWM=%5.1f%% | X=%.4f | J=%.2f | t=%.0fms\n', ...
                etiqueta, dia, hora_actual, k, N_horas, pwm_opt, X_hist(k+1), J_opt, t_paso_hist(k)*1000);
        end
        
        % Escribir status si se solicito (NUEVO P/ INTERFAZ WEB)
        if isfield(opciones, 'status_file') && ~isempty(opciones.status_file)
            pct = round(100 * k / N_horas);
            s_msg = sprintf('Progreso: %d%% — Dia %d, Hora %d', pct, dia, hora_actual);
            % No sobre-escribimos archivo demasiado rapido
            if mod(k, max(1, round(N_horas/20))) == 0 || k == N_horas
                escribir_status_json(opciones.status_file, 'simulando', s_msg, pct);
            end
        end
    end
    
    t_total = toc(t_total_start);
    
    % Enviar estado final
    estado_final = estado;
    
    % --- Estadisticas de rendimiento (NUEVO v5) ---
    info_stats.n_eval_hist     = n_eval_hist;
    info_stats.t_paso_hist     = t_paso_hist;
    info_stats.t_total         = t_total;
    info_stats.t_promedio_paso = mean(t_paso_hist);
    info_stats.n_convergidos   = sum(exit_hist > 0);
    info_stats.pct_convergidos = 100 * sum(exit_hist > 0) / N_horas;
    info_stats.eval_promedio   = mean(n_eval_hist);
    
    % Añadir historiales de hardware para la UI
    info_stats.pwm_hist = pwm_hist;
    info_stats.frac_hist = frac_hist;
    
    if ruido_X > 0 || ruido_T > 0
        fprintf('  [%s] Ruido: sigma_X=%.4f, sigma_T=%.1f\n', etiqueta, ruido_X, ruido_T);
    end
    fprintf('  [%s] Convergencia: %d/%d pasos (%.1f%%)\n', ...
        etiqueta, info_stats.n_convergidos, N_horas, info_stats.pct_convergidos);
    fprintf('  [%s] Tiempo MPC: %.1f s total, %.0f ms/paso promedio\n', ...
        etiqueta, t_total, info_stats.t_promedio_paso*1000);
end

function val = campo_def(s, campo, default)
    if isfield(s, campo), val = s.(campo); else, val = default; end
end

function escribir_status_json(filepath, estado, mensaje, pct)
    s.estado = estado;
    s.mensaje = mensaje;
    s.progreso = pct;
    s.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    json_str = jsonencode(s);
    try
        fid = fopen(filepath, 'w', 'n', 'UTF-8');
        if fid > 0
            fprintf(fid, '%s', json_str);
            fclose(fid);
        end
    catch
    end
end
