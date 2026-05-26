% ================================================================
% SERVIDOR MPC — Motor de Simulación para Interfaz Web
% ================================================================
% Este script corre en MATLAB y escucha comandos desde 'comando.json'
% Conecta la UI Web con los GEMELOS DIGITALES REALES (ejecutar_mpc_loop)
% ================================================================

function servidor_mpc()
    fprintf('\n');
    fprintf('================================================================\n');
    fprintf(' SERVIDOR MPC — Motor de Simulación MATLAB (MODO DUAL)\n');
    fprintf(' [Conectado al Kernel Real: ejecutar_mpc_loop.m]\n');
    fprintf('================================================================\n');
    
    % Rutas
    base_dir = fileparts(fileparts(mfilename('fullpath')));
    cmd_file     = fullfile(base_dir, 'interfaz', 'comando.json');
    result_file  = fullfile(base_dir, 'interfaz', 'resultados.json');
    status_file  = fullfile(base_dir, 'interfaz', 'status.json');
    estado_file  = fullfile(base_dir, 'interfaz', 'estado_actual.json');
    
    % Agregar paths
    addpath(fullfile(base_dir, 'modelos'));
    addpath(fullfile(base_dir, 'datos'));
    addpath(fullfile(base_dir, 'mpc'));
    addpath(fullfile(base_dir, 'scripts'));
    
    write_status(status_file, 'listo', 'MATLAB conectado al nucleo MPC. Esperando comandos...', 100);
    
    % CRITICO: Ignorar comando.json viejo que ya exista al arrancar
    % Si el archivo ya existe, registrar su datenum actual para no re-ejecutarlo
    if exist(cmd_file, 'file')
        d_ini = dir(cmd_file);
        last_mod = d_ini.datenum;
        fprintf('  [OK] comando.json existente ignorado (esperando nuevo comando)\n');
    else
        last_mod = 0;
    end    
    % Memoria persistente para Modo En Vivo
    m_viva = struct('inicializado', false);
    
    fprintf('  [OK] Escuchando comandos en: %s\n', cmd_file);
    fprintf('  [OK] Presiona Ctrl+C para detener.\n\n');
    
    last_ping = tic;
    
    while true
        try
            if exist(cmd_file, 'file')
                d = dir(cmd_file);
                if d.datenum > last_mod
                    last_mod = d.datenum;
                    
                    pause(0.5); % Esperar a que Python termine de escribir
                    cmd_data = read_json(cmd_file);
                    cmd = cmd_data.cmd;
                    cfg = cmd_data.config;
                    
                    % Borrar comando inmediatamente para evitar re-ejecucion
                    try delete(cmd_file); catch; end
                    
                    if strcmp(cmd, 'batch')
                        fprintf('  [>>] CMD BATCH: Iniciando %.1f dias con MPC Real\n', cfg.dias);
                        write_status(status_file, 'simulando', 'Inicializando modelos fisicos...', 0);
                        
                        try
                            % Fase 1: Simulacion
                            res = ejecutar_batch(cfg, base_dir, status_file);
                            fprintf('  [OK] Simulacion completa. Escribiendo resultados...\n');
                            
                            % Fase 2: Escribir resultados
                            write_json(result_file, res);
                            fprintf('  [OK] resultados.json escrito (%d bytes)\n', ...
                                dir(result_file).bytes);
                            
                            % Fase 3: Marcar como completado
                            write_status(status_file, 'listo', ...
                                sprintf('Simulacion Batch Completada - Ahorro: %.1f%%', ...
                                res.mpc.ahorro_pct), 100);
                            fprintf('  [OK] Ahorro Energetico MPC: %.1f%%\n\n', res.mpc.ahorro_pct);
                            
                        catch ME_batch
                            fprintf('  [ERROR BATCH] %s\n', ME_batch.message);
                            fprintf('  [ERROR BATCH] en: %s linea %d\n', ...
                                ME_batch.stack(1).name, ME_batch.stack(1).line);
                            write_status(status_file, 'error', ...
                                ['Error en simulacion: ' ME_batch.message], 0);
                        end
                        
                    elseif strcmp(cmd, 'reset_step')
                        fprintf('  [>>] CMD RESET: Inicializando Planta En Vivo\n');
                        m_viva = inicializar_planta_viva(cfg);
                        write_json(estado_file, paquete_estado(m_viva));
                        write_status(status_file, 'listo', 'Planta Inicializada (Hora 0)', 100);
                        
                    elseif strcmp(cmd, 'step')
                        if ~m_viva.inicializado
                            fprintf('  [WARN] Step ignorado, falta reset_step.\n');
                        else
                            m_viva = simular_paso_vivo(m_viva);
                            write_json(estado_file, paquete_estado(m_viva));
                            write_status(status_file, 'listo', sprintf('Hora %d ejecutada', m_viva.hora_actual-1), 100);
                        end
                    end
                    
                    last_ping = tic;
                end
            end
            
            % Ping de vida cada 8s
            if toc(last_ping) > 8
                write_status(status_file, 'listo', 'MATLAB listo', 100);
                last_ping = tic;
            end
            
        catch ME
            fprintf('  [ERROR LOOP] %s\n', ME.message);
            try
                write_status(status_file, 'error', ['Error: ' ME.message], 0);
            catch; end
        end
        pause(1.5);
    end
end

% ==================== UTILIDADES ====================
function data = read_json(filepath)
    fid = fopen(filepath, 'r');
    raw = fread(fid, inf, 'char=>char')';
    fclose(fid);
    data = jsondecode(raw);
end

function write_json(filepath, data)
    % Usar fwrite en vez de fprintf para evitar problemas con
    % caracteres especiales (%, \, etc.) en strings grandes
    json_str = jsonencode(data);
    fid = fopen(filepath, 'w');
    fwrite(fid, json_str, 'char');
    fclose(fid);
end

function write_status(filepath, estado, mensaje, pct)
    s.estado = estado;
    s.mensaje = mensaje;
    s.progreso = pct;
    s.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    write_json(filepath, s);
end

% ==================== PREPARAR ENTORNO BASE ====================
% Consistente con main_mpc.m — Auditoria 2026-04-20
function [params_cin, datos, camara, clima, mpc_params, N_horas] = preparar_entorno(cfg)
    datos = datos_campo();
    
    % --- Parametros cineticos (Page) ---
    params_cin.tipo = 'page';
    params_cin.k  = 0.25;
    params_cin.n  = 1.0;
    params_cin.X0 = cfg.X0 / 100;
    
    ow = oswin_params();
    HR_eq = datos.ambiente.HR_media;   % promedio de 3 zonas (datos_campo.m:113)
    params_cin.Xe = ow.C * (HR_eq/100 / (1 - HR_eq/100))^ow.n_s;
    
    % --- Camara de secado (consistente con main_mpc.m) ---
    camara.H = 1.0;               % [m] altura del lecho (gemelo usa 'H', NO 'L')
    camara.A = 1.0;               % [m2] area transversal
    camara.N_capas = 20;          % capas planta (alta fidelidad)
    camara.N_capas_mpc = 5;       % capas modelo interno MPC (rapido)
    camara.rho = 80;              % [kg/m3] densidad aparente
    camara.dias_sim = cfg.dias;
    camara.v_natural = 0.02;      % [m/s] conveccion natural
    camara.v_max_fan = 1.00;      % [m/s] velocidad maxima ventilador
    camara.eta_vent = 0.35;       % eficiencia mecanica ventilador
    camara.P_rated = cfg.P_fan;   % [W] potencia nominal (costo_mpc usa 'P_rated')
    camara.dp = 0.010;            % [m] diametro de particula
    
    % --- Parametros MPC ---
    mpc_params.Np = 24;
    mpc_params.Nc = 8;
    mpc_params.alpha = 5000;
    mpc_params.beta  = 0.1;
    mpc_params.delta = 500;
    mpc_params.dU_max = 30;       % [%/h] slew rate del actuador
    mpc_params.X_ref = cfg.Xref / 100;
    mpc_params.gamma = 0.5;       % Red electrica (penalizacion energia)
    mpc_params.T_max_bagazo = 85; % Limite termico de seguridad (Farrell 1998 revisado)
    
    % --- CRITICO: mpc_paso.m necesita estos 3 campos dentro de mpc_params ---
    mpc_params.params_cin = params_cin;
    mpc_params.datos      = datos;
    mpc_params.camara     = camara;
    
    % Acople del intercambiador desde la UI
    if isfield(cfg, 'use_hx') && cfg.use_hx == 1
        camara.usar_intercambiador = true;
    else
        camara.usar_intercambiador = false;
    end
    
    N_horas = round(cfg.dias * 24);
    
    % Clima real Open-Meteo
    try
        c = obtener_clima_openmeteo(1.2136, -77.9967, min(cfg.dias, 16));
        
        N_tot_req = N_horas + mpc_params.Np;
        % Si faltan horas (es decir, se pidieron más de 16 días), completamos con el modelo sinusoidal
        if c.n_horas < N_tot_req
            faltantes = N_tot_req - c.n_horas;
            
            % Generar horas faltantes continuando desde la hora actual (para que las curvas coincidan con el día)
            % Se asume que el pronóstico terminó a cierta hora, calculamos la hora del día (1 a 24)
            h_dia = mod(c.n_horas : (c.n_horas + faltantes - 1), 24) + 1;
            
            % Modelo sinusoidal matemático sintético
            T_extra = 22 + 5*sin(2*pi*(h_dia-8)/24)';
            HR_extra = 85 - 15*sin(2*pi*(h_dia-8)/24)';
            I_extra = max(0, 800*sin(2*pi*(h_dia-6)/12))';
            
            % Concatenar pronóstico real + modelo matemático a futuro
            c.T_amb = [c.T_amb; T_extra];
            c.HR = [c.HR; HR_extra];
            c.I_solar = [c.I_solar; I_extra];
            c.n_horas = length(c.T_amb);
        end
        clima = c;
    catch
        % Fallback de emergencia 100% promedio (Si no hay Internet desde el inicio)
        N_tot = N_horas + mpc_params.Np;
        h_dia = repmat(1:24, 1, ceil(N_tot/24));
        clima.T_amb = 22 + 5*sin(2*pi*(h_dia(1:N_tot)-8)/24)';
        clima.HR = 85 - 15*sin(2*pi*(h_dia(1:N_tot)-8)/24)';
        clima.I_solar = max(0, 800*sin(2*pi*(h_dia(1:N_tot)-6)/12))';
        clima.n_horas = N_tot;
    end
end

% ==================== EJECUCION MODO BATCH ====================
function res = ejecutar_batch(cfg, base_dir, status_file)
    [params_cin, datos, camara, clima, mpc_params, N_horas] = preparar_entorno(cfg);
    
    % 1. Simulacion Natural (PWM=0, v=0 — identico a main_mpc.m linea 111)
    write_status(status_file, 'simulando', 'Simulando Secado Natural...', 5);
    v_nat = zeros(N_horas, 1);  % v=0: sin ventilador (igual que main_mpc.m)
    res_nat = gemelo_camara_forzada(params_cin, datos, camara, clima, v_nat);
    
    % 2. Simulacion Constante (V_aire MAX)
    write_status(status_file, 'simulando', 'Simulando Secado Constante...', 10);
    v_cte = camara.v_max_fan * ones(N_horas, 1);
    
    clima_cte = clima;
    if isfield(cfg, 'use_hx') && cfg.use_hx == 1 && ~isempty(clima) && isfield(clima, 'T_amb')
        % Crear un params_hx temporal para la simulacion constante
        params_hx_cte.D_int   = 0.076;
        params_hx_cte.D_ext   = 0.089;
        params_hx_cte.L_tubo  = 1.5;
        params_hx_cte.k_metal = 50;
        params_hx_cte.T_gases_max = 600;
        params_hx_cte.hora_inicio = 4;
        params_hx_cte.hora_fin    = 17;
        
        if isfield(cfg, 'dias_molienda') && cfg.dias_molienda > 0
            n_mol = cfg.dias_molienda;
            n_semanas = ceil(cfg.dias / 7);
            dias_vec = [];
            for sem = 1:n_semanas
                offset = (sem - 1) * 7;
                dias_vec = [dias_vec, offset + (1:n_mol)];
            end
            params_hx_cte.dias_molienda = dias_vec(dias_vec <= cfg.dias);
        else
            params_hx_cte.dias_molienda = [1,2,3, 8,9,10, 15,16,17, 22,23,24];
        end
        
        for ih = 1:min(N_horas, clima_cte.n_horas)
            [dT_c, dHR_c] = intercambiador_calor( ...
                clima_cte.T_amb(ih), clima_cte.HR(ih), v_cte(ih), ih, params_hx_cte);
            clima_cte.T_amb(ih) = clima_cte.T_amb(ih) + dT_c;
            clima_cte.HR(ih)    = min(max(clima_cte.HR(ih) - dHR_c, 0), 100);
        end
    end
    res_cte = gemelo_camara_forzada(params_cin, datos, camara, clima_cte, v_cte);
    
    % 3. Simulacion MPC
    write_status(status_file, 'simulando', 'Iniciando optimización MPC (Gemelos acoplados)...', 15);
    opciones.status_file = status_file; % Escribirá del 15% al 95%
    
    % Intercambiador de calor (modelo fisico — circuito termico)
    if isfield(cfg, 'use_hx') && cfg.use_hx == 1
        opciones.usar_hx_fisico = true;
        opciones.params_hx.D_int   = 0.076;   % [m] diametro interior tubo 3"
        opciones.params_hx.D_ext   = 0.089;   % [m] diametro exterior
        opciones.params_hx.L_tubo  = 1.5;     % [m] longitud total del serpentin externo (canonico)
        opciones.params_hx.k_metal = 50;      % [W/(m*K)] acero al carbono
        opciones.params_hx.T_gases_max = 600; % [C] gases de combustion (canonico)
        % Dias de molienda: la chimenea solo aporta calor estos dias
        % La molienda dura 3 dias por semana. En 14 dias (2 semanas):
        %   Semana 1: dias 1,2,3 | Semana 2: dias 8,9,10
        % Esto es identico a main_mpc.m linea 169.
        if isfield(cfg, 'dias_molienda') && cfg.dias_molienda > 0
            n_mol = cfg.dias_molienda; % dias de molienda por semana
            n_semanas = ceil(cfg.dias / 7);
            dias_vec = [];
            for sem = 1:n_semanas
                offset = (sem - 1) * 7;
                dias_vec = [dias_vec, offset + (1:n_mol)]; %#ok<AGROW>
            end
            % Filtrar dias que excedan el periodo de simulacion
            opciones.params_hx.dias_molienda = dias_vec(dias_vec <= cfg.dias);
        else
            opciones.params_hx.dias_molienda = [1,2,3, 8,9,10, 15,16,17, 22,23,24]; % default (sync main_mpc.m)
        end
        opciones.params_hx.hora_inicio = 4;   % 4:00 AM
        opciones.params_hx.hora_fin    = 17;  % 5:00 PM
        fprintf('  [HX] Intercambiador ACTIVADO — modelo fisico\n');
    end
    
    tic;
    [pwm_hist, ~, X_hist, T_hist, ~, ~, info_stats, estado_final] = ejecutar_mpc_loop(params_cin, datos, camara, clima, mpc_params, N_horas, 'WEB-MPC', opciones);
    t_sim = toc;
    
    % Construir Resultados Finales JSON
    res.motor = 'matlab-real';
    res.tiempo_simulacion_s = t_sim;
    
    % Natural: exportar con subsampleo hourly (1 punto por hora, no por dia)
    res.natural.X_final = res_nat.X_promedio(end);
    % Subsamplear para que tenga aprox. el mismo # de puntos que MPC
    n_nat = length(res_nat.X_promedio);
    N_sub = max(1, round(n_nat / (N_horas + 1)));
    idx_nat = [1:N_sub:n_nat, n_nat];
    idx_nat = unique(idx_nat);
    res.natural.X_hist = res_nat.X_promedio(idx_nat)';
    
    % Constante: idem
    res.constante.X_final = res_cte.X_promedio(end);
    res.constante.X_hist = res_cte.X_promedio(idx_nat)';
    res.constante.energia_kWh = (cfg.P_fan * N_horas)/1000;
    
    % MPC: Valores temporales del modelo interno (5 capas) 
    % Se sobreescribirán abajo con los de la planta real (20 capas)
    res.mpc.X_hist = X_hist(:)';   
    res.mpc.T_hist = T_hist(:)';   
    res.mpc.pwm_hist = pwm_hist;
    
    % Historias de Controlador de Bajo Nivel (Hardware Real)
    if isfield(info_stats, 'vfd_hist')
        res.mpc.vfd_hist = info_stats.vfd_hist(:)';
        res.mpc.frac_hist = info_stats.frac_hist(:)';
        res.mpc.energia_kWh = sum(cfg.P_fan * (res.mpc.vfd_hist/100).^3 .* res.mpc.frac_hist)/1000;
    else
        res.mpc.energia_kWh = sum(cfg.P_fan * (pwm_hist/100).^3)/1000;
    end
    
    res.mpc.pwm_promedio = mean(pwm_hist);
    res.mpc.ahorro_pct = 0;
    if res.constante.energia_kWh > 0
        res.mpc.ahorro_pct = (1 - res.mpc.energia_kWh / res.constante.energia_kWh) * 100;
    end
    
    % --- PERFIL REAL DE 20 CAPAS ---
    % Ejecutar gemelo de alta fidelidad con el PWM optimo del MPC
    % para obtener el gradiente real de humedad por capa
    write_status(status_file, 'simulando', 'Calculando perfil de capas (20 capas)...', 96);
    v_mpc_vec = (pwm_hist(:)/100) * camara.v_max_fan;
    
    % Si HX activo, modificar clima hora a hora
    clima_replay = clima;
    if isfield(cfg, 'use_hx') && cfg.use_hx == 1 && ~isempty(clima) && isfield(clima, 'T_amb')
        for ih = 1:min(length(v_mpc_vec), clima.n_horas)
            % El aire solo se calienta si el ventilador lo empuja por el intercambiador
            v_replay = v_mpc_vec(ih);
            [dT_r, dHR_r] = intercambiador_calor( ...
                clima_replay.T_amb(ih), clima_replay.HR(ih), v_replay, ih, opciones.params_hx);
            clima_replay.T_amb(ih) = clima_replay.T_amb(ih) + dT_r;
            clima_replay.HR(ih)    = min(max(clima_replay.HR(ih) - dHR_r, 0), 100);
        end
        res.mpc.T_hist_hx = clima_replay.T_amb(1:length(v_mpc_vec))';
    end
    
    res_mpc_20 = gemelo_camara_forzada(params_cin, datos, camara, clima_replay, v_mpc_vec);
    % CRITICO: Resultados del MPC para visualizacion provienen de la planta de 20 capas
    res.mpc.X_hist = res_mpc_20.X_promedio(:)';
    % T_hist debe ser la temperatura promedio del lecho
    res.mpc.T_hist = res_mpc_20.T_promedio(:)'; 
    res.mpc.X_final = res_mpc_20.X_promedio(end);  % Planta real 20 capas
    % Extraer las 20 capas del ultimo instante
    res.mpc.X_capas_final = res_mpc_20.X(end, :);  % Vector 1x20 real
    fprintf('  [AUDIT] X_final modelo 5-capas: %.4f | X_final planta 20-capas: %.4f\n', ...
        X_hist(end), res.mpc.X_final);
    
    % --- HISTORIAL DE ENERGIA ACUMULADA (para grafico comparativo) ---
    % MPC: energia acumulada hora a hora
    E_mpc_acum = zeros(1, N_horas + 1);
    for ih = 1:N_horas
        if isfield(info_stats, 'vfd_hist')
            E_mpc_acum(ih+1) = E_mpc_acum(ih) + cfg.P_fan * (res.mpc.vfd_hist(ih)/100)^3 * res.mpc.frac_hist(ih) / 1000;
        else
            E_mpc_acum(ih+1) = E_mpc_acum(ih) + cfg.P_fan * (pwm_hist(ih)/100)^3 / 1000;
        end
    end
    res.mpc.E_hist = E_mpc_acum;
    % Constante: energia acumulada lineal
    E_cte_acum = linspace(0, res.constante.energia_kWh, N_horas + 1);
    res.constante.E_hist = E_cte_acum;
    
    % ==================== ANALISIS ECONOMICO — HUGOT (1986) ====================
    % Poder Calorifico Inferior (PCI) del bagazo en funcion de la humedad
    % Ref: Hugot, E. (1986). Handbook of Cane Sugar Engineering. 3rd Ed.
    %   PCI = 18309 - 31.14*S - 207.3*W - 196.05*A  [kJ/kg]
    %   S = azucar residual (Brix), A = cenizas
    % Valores tipicos para bagazo colombiano:
    S_brix = 2.5;      % % azucar residual en bagazo
    A_cenizas = 2.5;    % % cenizas (sincronizado con servidor.py)
    masa_lote = cfg.masa; % kg de bagazo por lote (tipico 12 kg)
    
    % Convertir humedad de base seca (X, modelo) a base humeda (W, Hugot)
    % W = X / (1 + X)  * 100 [%]
    X_ini = cfg.X0 / 100;   % humedad inicial en decimal base seca
    X_fin = res.mpc.X_final; % humedad final MPC en decimal base seca
    X_nat = res.natural.X_final; % humedad final sin control
    
    W_ini = (X_ini / (1 + X_ini)) * 100;  % % base humeda
    W_fin = (X_fin / (1 + X_fin)) * 100;
    W_nat = (X_nat / (1 + X_nat)) * 100;
    
    % Ecuacion de Hugot
    PCI_ini = 18309 - 31.14*S_brix - 207.3*W_ini - 196.05*A_cenizas; % kJ/kg
    PCI_fin = 18309 - 31.14*S_brix - 207.3*W_fin - 196.05*A_cenizas;
    PCI_nat = 18309 - 31.14*S_brix - 207.3*W_nat - 196.05*A_cenizas;
    
    % Convertir a MJ/kg
    res.hugot.PCI_inicial_MJ = PCI_ini / 1000;
    res.hugot.PCI_final_MJ   = PCI_fin / 1000;
    res.hugot.PCI_natural_MJ = PCI_nat / 1000;
    res.hugot.ganancia_pct = ((PCI_fin - PCI_ini) / PCI_ini) * 100;
    
    % W en base humeda (para mostrar en UI)
    res.hugot.W_inicial_pct = W_ini;
    res.hugot.W_final_pct   = W_fin;
    
    % ANALISIS ECONOMICO — Escala trapiche (configurable desde UI)
    % Relacion de campo: por cada 1 kg de panela se generan ~3 kg de bagazo
    % Default: 1,950 kg panela × 3 = 5,850 kg bagazo (Ricaurte, Nariño)
    if isfield(cfg, 'panela_kg') && cfg.panela_kg > 0
        masa_trapiche = cfg.panela_kg * 3; % kg bagazo = panela × 3
    else
        masa_trapiche = 5850; % fallback: dato de campo Ricaurte
    end
    
    % Energia termica por lote a escala trapiche [MJ]
    E_termica_ini = (PCI_ini/1000) * masa_trapiche; % MJ (bagazo humedo)
    E_termica_fin = (PCI_fin/1000) * masa_trapiche; % MJ (bagazo seco con MPC)
    delta_E = E_termica_fin - E_termica_ini;     % MJ extra por molienda
    
    % Equivalente en leña ahorrada
    % Datos reales Ricaurte: 1 m3 leña = $100,000 COP, densidad ~400 kg/m3
    % → precio leña = 100,000/400 = 250 COP/kg
    % PCI leña semi-seca (W~20%) ≈ 14 MJ/kg
    PCI_lena = 14;     % MJ/kg
    precio_lena = 250; % COP/kg (dato real: $100,000/m3 ÷ 400 kg/m3)
    
    kg_lena_ahorrada = delta_E / PCI_lena;
    ahorro_combustible_COP = kg_lena_ahorrada * precio_lena;
    
    % Costo electrico del ventilador (escalado a masa trapiche)
    % Factor de escala: (masa_trapiche / masa_simulacion)
    % Un ventilador mas grande (500W) para secar 5850 kg en camara industrial
    tarifa_electrica = 947.34; % COP/kWh (tarifa rural colombiana promedio)
    % Escalar energia: la simulacion usa 50W para cfg.masa kg
    % Para el trapiche: escalar proporcionalmente
    factor_escala = masa_trapiche / masa_lote;
    energia_trapiche_kWh = res.mpc.energia_kWh * factor_escala;
    costo_ventilador_COP = energia_trapiche_kWh * tarifa_electrica;
    
    % Beneficio neto por molienda
    beneficio_neto_COP = ahorro_combustible_COP - costo_ventilador_COP;
    
    % Excedente de biomasa
    ratio_rendimiento = PCI_fin / PCI_ini;
    kg_excedente = masa_trapiche * (1 - 1/ratio_rendimiento);
    ingreso_biomasa = (kg_excedente / 1000) * 120000; % COP
    
    res.hugot.kg_lena_ahorrada = kg_lena_ahorrada;
    res.hugot.ahorro_combustible_COP = ahorro_combustible_COP;
    res.hugot.costo_ventilador_COP = costo_ventilador_COP;
    res.hugot.beneficio_neto_COP = beneficio_neto_COP;
    res.hugot.kg_excedente = kg_excedente;
    res.hugot.ingreso_biomasa_COP = ingreso_biomasa;
    res.hugot.tarifa_electrica = tarifa_electrica;
    res.hugot.masa_trapiche_kg = masa_trapiche;
    
    % Config de retorno (para UI)
    res.config.dias = cfg.dias;
    res.config.X0   = cfg.X0;
    res.config.Xref = cfg.Xref / 100;
    res.config.masa = cfg.masa;
    
    fprintf('  [HUGOT] PCI: %.1f -> %.1f MJ/kg (+%.0f%%)\n', ...
        res.hugot.PCI_inicial_MJ, res.hugot.PCI_final_MJ, res.hugot.ganancia_pct);
    fprintf('  [ECON]  Ahorro combustible: $%.0f COP | Costo ventilador: $%.0f COP | Neto: $%.0f COP\n', ...
        ahorro_combustible_COP, costo_ventilador_COP, beneficio_neto_COP);
end

% ==================== EJECUCION MODO EN VIVO (STEP) ====================
function m = inicializar_planta_viva(cfg)
    [params_cin, datos, camara, clima, mpc_params, N_horas] = preparar_entorno(cfg);
    
    m.inicializado = true;
    m.cfg = cfg;
    m.N_horas = N_horas;
    m.hora_actual = 1;
    m.params_cin = params_cin;
    m.datos = datos;
    m.camara = camara;
    m.clima = clima;
    m.mpc_params = mpc_params;
    
    % Historial web
    m.X_hist = [cfg.X0/100];
    m.pwm_hist = [];
    m.E_acum = 0;
    
    % Estado del Gemelo
    m.estado_interno = [];
end

function m = simular_paso_vivo(m)
    if m.hora_actual > m.N_horas
        return;
    end
    
    opciones.hora_inicio = m.hora_actual;
    if ~isempty(m.estado_interno)
        opciones.estado_inicial = m.estado_interno;
    end
    
    % Ejecutar exactamente 1 paso usando la arquitectura de ejecutar_mpc_loop
    [pwm_paso, ~, X_paso, ~, ~, ~, ~, estado_nx] = ejecutar_mpc_loop(...
        m.params_cin, m.datos, m.camara, m.clima, m.mpc_params, 1, 'VIVO', opciones);
        
    m.estado_interno = estado_nx;
    m.X_hist(end+1) = X_paso(end);
    m.pwm_hist(end+1) = pwm_paso(1);
    
    m.E_acum = m.E_acum + (m.cfg.P_fan * (pwm_paso(1)/100)^3)/1000;
    
    m.hora_actual = m.hora_actual + 1;
end

function data = paquete_estado(m)
    data.dia = floor((m.hora_actual-1)/24) + 1;
    data.hora_dia = mod(m.hora_actual-1, 24);
    data.hora_absoluta = m.hora_actual - 1;
    data.X_actual = m.X_hist(end);
    data.T_amb = m.clima.T_amb(m.hora_actual);
    data.HR_amb = m.clima.HR(m.hora_actual);
    if isempty(m.pwm_hist)
        data.pwm = 0;
    else
        data.pwm = m.pwm_hist(end);
    end
    data.E_acumulada = m.E_acum;
    data.X_hist = m.X_hist;
    data.pwm_hist = m.pwm_hist;
end

