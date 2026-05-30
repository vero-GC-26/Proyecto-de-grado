addpath('..\mpc'); addpath('..\modelos'); addpath('..\scripts'); addpath('..\datos');
try
    cfg_text = fileread('comando.json');
    cmd_data = jsondecode(cfg_text);
    cfg = cmd_data.config;
    
    datos = datos_campo();
    ow = oswin_params();
    HR_eq = datos.ambiente.HR_media;
    
    params_cin.tipo = 'page';
    params_cin.k  = 0.25;
    params_cin.n  = 1.0;
    params_cin.X0 = cfg.X0 / 100;
    params_cin.Xe = ow.C * (HR_eq/100 / (1 - HR_eq/100))^ow.n_s;
    
    camara.H = 1.0;
    camara.A = 1.0;
    camara.N_capas = 20;
    camara.N_capas_mpc = 5;
    camara.rho = 80;
    camara.dias_sim = cfg.dias;
    camara.v_natural = 0.02;
    camara.v_max_fan = 1.00;
    camara.eta_vent = 0.35;
    camara.P_rated = cfg.P_fan;
    camara.dp = 0.010;
    camara.usar_intercambiador = (cfg.use_hx == 1);
    
    mpc_params.Np = 24;
    mpc_params.Nc = 8;
    mpc_params.alpha = 5000;
    mpc_params.beta  = 0.1;
    mpc_params.delta = 500;
    mpc_params.dU_max = 30;
    mpc_params.X_ref = cfg.Xref / 100;
    mpc_params.gamma = 0.5;
    
    opciones = struct();
    if camara.usar_intercambiador
        opciones.usar_hx_fisico = true;
        opciones.params_hx.D_int = 0.076;
        opciones.params_hx.D_ext = 0.089;
        opciones.params_hx.L_tubo = 1.5;
        opciones.params_hx.k_metal = 50;
        opciones.params_hx.T_gases_max = 600;
        
        n_mol = cfg.dias_molienda;
        n_semanas = ceil(cfg.dias / 7);
        dias_vec = [];
        for sem = 1:n_semanas
            dias_vec = [dias_vec, (sem - 1)*7 + (1:n_mol)];
        end
        opciones.params_hx.dias_molienda = dias_vec(dias_vec <= cfg.dias);
        opciones.params_hx.hora_inicio = 4;
        opciones.params_hx.hora_fin = 17;
        opciones.params_hx.T_max_secado = 85;
    end
    
    c = obtener_clima_openmeteo(1.2136, -77.9967, min(cfg.dias, 16));
    N_horas = round(cfg.dias * 24);
    N_tot_req = N_horas + mpc_params.Np;
    if c.n_horas < N_tot_req
        faltantes = N_tot_req - c.n_horas;
        h_dia = mod(c.n_horas : (c.n_horas + faltantes - 1), 24) + 1;
        T_extra = 22 + 5*sin(2*pi*(h_dia-8)/24)';
        HR_extra = 85 - 15*sin(2*pi*(h_dia-8)/24)';
        I_extra = max(0, 800*sin(2*pi*(h_dia-6)/12))';
        c.T_amb = [c.T_amb; T_extra];
        c.HR = [c.HR; HR_extra];
        c.I_solar = [c.I_solar; I_extra];
        c.n_horas = length(c.T_amb);
    end
    clima = c;
    
    opciones.status_file = 'status.json';
    
    [pwm_hist, v_vec, X_hist, T_hist, J_hist, exit_hist, info_stats, estado_final] = ejecutar_mpc_loop(params_cin, datos, camara, clima, mpc_params, N_horas, 'WEB-MPC', opciones);
    
    % Regenerar la trayectoria con camara forzada completa (identico a main_mpc / servidor_mpc)
    % APLICAR HX AL CLIMA ANTES DE LLAMAR GEMELO 20 CAPAS
    clima_replay = clima;
    if camara.usar_intercambiador
        for ih = 1:min(length(v_vec), clima.n_horas)
            [dT_r, dHR_r] = intercambiador_calor(clima_replay.T_amb(ih), clima_replay.HR(ih), v_vec(ih), ih, opciones.params_hx);
            clima_replay.T_amb(ih) = clima_replay.T_amb(ih) + dT_r;
            clima_replay.HR(ih) = min(max(clima_replay.HR(ih) - dHR_r, 0), 100);
        end
    end
    res_mpc = gemelo_camara_forzada(params_cin, datos, camara, clima_replay, v_vec);
    
    W_final_pct = (res_mpc.X_promedio(end) / (1 + res_mpc.X_promedio(end))) * 100;
    E_kWh = res_mpc.E_acum_Wh(end) / 1000;
    
    out.mpc.X_final = res_mpc.X_promedio(end);
    out.mpc.pwm_promedio = mean(pwm_hist);
    out.hugot.W_final_pct = W_final_pct;
    out.mpc.ahorro_pct = 100 * (1 - E_kWh / (cfg.P_fan * 24 * cfg.dias / 1000));
    
    out_str = jsonencode(out);
    fid = fopen('resultados_run_one.json', 'w', 'n', 'UTF-8');
    fprintf(fid, '%s', out_str);
    fclose(fid);
catch ME
    disp(ME.message);
    for k=1:length(ME.stack)
        disp([ME.stack(k).file, ' at line ', num2str(ME.stack(k).line)]);
    end
end
