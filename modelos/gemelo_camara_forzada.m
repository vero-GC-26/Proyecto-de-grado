function [resultado] = gemelo_camara_forzada(params_cin, datos, camara, clima, v_aire_vec)
% GEMELO_CAMARA_FORZADA  Secado forzado 1D — Sherwood + Farrell + Ergun
% Version corregida: Auditoria 2026-03-11
%
% Correcciones:
%   - Altitud de datos.ubicacion (no hardcoded)
%   - dp, v_nat, eta_vent parametrizables desde struct camara
%   - Limite T_wb corregido a T_wb-0.5
%   - Factor solar de constantes_farrell
%   - Criterio Courant para adveccion
%   - Vectorizacion parcial (Farrell, conduccion, Oswin, Page)

%% 1. PARAMETROS DE CAMARA
if nargin < 4 || isempty(clima), clima = []; end
if nargin < 3 || isempty(camara), camara = struct(); end
H0   = campo_o_default(camara,'H',1.0);
A    = campo_o_default(camara,'A',1.0);
N_c  = campo_o_default(camara,'N_capas',20);
rho  = campo_o_default(camara,'rho',120);
dias = campo_o_default(camara,'dias_sim',14);

% CORREGIDO: parametros antes hardcoded
dp       = campo_o_default(camara,'dp',0.010);
v_nat    = campo_o_default(camara,'v_natural',0.001);
eta_vent = campo_o_default(camara,'eta_vent',0.35);  % CORREGIDO: 0.50 -> 0.35

%% 2. AIRE — propiedades a altitud del sitio
% CORREGIDO: altitud de datos.ubicacion (antes hardcoded 1160)
if isfield(datos,'ubicacion') && isfield(datos.ubicacion,'altitud_msnm')
    h_alt = datos.ubicacion.altitud_msnm;
else
    h_alt = 1160;
end
P_atm = 101325*(1-2.2558e-5*h_alt)^5.2559;
rho_aire = P_atm/(287*(22.3+273.15));
mu_aire = 1.81e-5; k_aire = 0.0257; Cp_aire = 1005;
Pr = mu_aire*Cp_aire/k_aire;
Sc = 0.62; Le = Sc/Pr;

%% 3. LECHO
epsilon_0 = 0.60;
beta_shrink = 0.10;

% --- CORRECCION GAP: Perdidas termicas por paredes de la camara ---
% U_paredes = k_pared / espesor. Para madera de 2cm: 0.15/0.02 = 7.5 W/m2K
% A_paredes = perimetro * H (paredes laterales de la camara)
U_paredes = campo_o_default(camara, 'U_paredes', 7.5);  % [W/m2K] coef. global
A_paredes = campo_o_default(camara, 'A_paredes', 4*1*1);  % [m2] area lateral (4 caras × 1m × 1m para camara 1×1×1m)

%% 4. FARRELL
cf = constantes_farrell();
Cp_seco=cf.Cp_seco; Cp_agua=cf.Cp_agua; kappa=cf.kappa;
E_oxi=cf.E_oxi; E_wet=cf.E_wet; R_gas=cf.R_gas;
Q_oxi_ref=cf.Q_oxi_ref; Q_wet_ref=cf.Q_wet_ref; W_crit=cf.W_crit;
E_bio=cf.E_bio; Q_bio_ref=cf.Q_bio_ref;  % Farrell — componente biologica
alpha_abs_techo = cf.alpha_abs_techo;  % CORREGIDO: antes 0.08 hardcoded

%% 5. CINETICA PAGE
k_Page=params_cin.k; n_Page=params_cin.n;
X0=params_cin.X0; Xe=params_cin.Xe;

%% 6. OSWIN — centralizado (ver oswin_params.m)
ow = oswin_params();
oswin_C = ow.C;
oswin_n_s = ow.n_s;

%% 7. ERGUN — fibras (Macdonald 1979)
A_ergun = 180;
B_ergun = 4.0;

%% 8. GRILLA TEMPORAL
dt=1; N_t=dias*24;
if nargin>=5 && ~isempty(v_aire_vec), v_max_ref=max(v_aire_vec(:));
else, v_max_ref=0.5; end

dz0 = H0/N_c;
alpha_th = kappa/(rho*(Cp_seco*1000+X0*Cp_agua*1000));
dt_four = 0.4*dz0^2/max(alpha_th,1e-15)/3600;
% CORREGIDO: agregar criterio Courant
dt_courant = 0.8*dz0/max(v_max_ref,0.01)/3600;
dt_limit = min(dt_four, dt_courant);
n_sub = max(10, ceil(dt/max(dt_limit,1e-6)));
n_sub = min(n_sub, 2000);
dt_sub = dt/n_sub;

%% 9. VELOCIDAD
if nargin<5||isempty(v_aire_vec), v_aire_vec=0.5*ones(N_t,1); end
if isscalar(v_aire_vec), v_aire_vec=v_aire_vec*ones(N_t,1); end
v_aire_vec=v_aire_vec(:);
if length(v_aire_vec)<N_t
    v_aire_vec=[v_aire_vec; v_aire_vec(end)*ones(N_t-length(v_aire_vec),1)];
end

%% 10. AMBIENTE
T_media=datos.ambiente.T_media; HR_media=datos.ambiente.HR_media;
usar_clima = ~isempty(clima) && isfield(clima,'T_amb');

%% 11. INICIALIZACION
T_bag0=datos.estado_secado.temp_C(1);
X=zeros(N_t+1,N_c); Ts=zeros(N_t+1,N_c);
X(1,:)=X0; Ts(1,:)=T_bag0;
T_amb_v=zeros(N_t+1,1); HR_amb_v=zeros(N_t+1,1); I_sol_v=zeros(N_t+1,1);
Ta_out=zeros(N_t+1,N_c); Wa_out=zeros(N_t+1,N_c); HRa_out=zeros(N_t+1,N_c);
P_turbina=zeros(N_t,1); E_acum=zeros(N_t+1,1);
evap_total=zeros(N_t,1); t_eff_capa=zeros(1,N_c);
H_hist=zeros(N_t+1,1); H_hist(1)=H0;
eps_hist=zeros(N_t+1,1); eps_hist(1)=epsilon_0;
n_clipper = 0;  % V3.1: contador activaciones del clipper de temperatura

fprintf('\n  GEMELO 2 — SHERWOOD + FARRELL + SORCION + SHRINKAGE\n');
fprintf('  %d capas, %d h, %d sub/h, alt=%d msnm, dp=%.3fm, eta=%.2f\n', ...
        N_c, N_t, n_sub, h_alt, dp, eta_vent);

%% 12. BUCLE PRINCIPAL
for i = 1:N_t
    t_horas=(i-1)*dt; t_dias=t_horas/24; h_dia=mod(t_horas,24);

    if usar_clima && (i-1) < clima.n_horas
        idx_c = i;
        T_a = clima.T_amb(idx_c);
        HR_a = clima.HR(idx_c);
        I_sol = clima.I_solar(idx_c);
       else
          T_a = T_media + 4*sin(2*pi*(h_dia-8)/24);
          HR_a = max(min(HR_media - 12*sin(2*pi*(h_dia-8)/24), 98), 55);
          if h_dia >= 6 && h_dia <= 18
              I_sol = 750*sin(pi*(h_dia-6)/12)*0.6;
          else
              I_sol = 0;
          end
    end

    T_amb_v(i)=T_a; HR_amb_v(i)=HR_a; I_sol_v(i)=I_sol;

    % V1.4 CORREGIDO: densidad del aire dinamica (antes fija a 22.3C)
    % Error de ~5% al usar T fija; ahora se recalcula cada hora.
    rho_aire = P_atm / (287 * (T_a + 273.15));

    % --- SHRINKAGE ---
    X_prom_actual = mean(X(i,:));
    H_actual = H0 * (1 - beta_shrink * max(X0 - X_prom_actual, 0) / max(X0, 1e-6));
    H_actual = max(H_actual, H0*0.80);
    epsilon_actual = 1 - (1-epsilon_0) * (H0/H_actual);
    epsilon_actual = max(min(epsilon_actual, 0.85), 0.40);
    dz = H_actual/N_c;
    V_capa = A*dz;
    m_seca_capa = rho*A*(H0/N_c);
    a_v = 6*(1-epsilon_actual)/dp;

    % --- CURVA "STALL" DEL VENTILADOR ---
    v_req = max(v_aire_vec(i), 0);
    P_max_100 = 300; % [Pa] Presion maxima de bloqueo a 100% PWM
    pwm_frac = min(v_req / 1.0, 1.0); % Aproximacion asumiendo v_max = 1.0
    P_max_pwm = P_max_100 * (pwm_frac^2);
    
    dP_L_req = A_ergun*mu_aire*v_req*(1-epsilon_actual)^2/(dp^2*epsilon_actual^3) ...
             + B_ergun*rho_aire*v_req^2*(1-epsilon_actual)/(dp*epsilon_actual^3);
    dP_bed_req = dP_L_req * H_actual;
    
    if dP_bed_req > P_max_pwm && v_req > 1e-3
        % STALL: La resistencia es demasiada. El flujo real cae.
        v_fan = v_req * (P_max_pwm / dP_bed_req)^0.5;
    else
        v_fan = v_req;
    end

    % --- CHANNELING (BYPASS) ---
    % 20% del aire se escapa por caminos preferenciales
    f_bypass = 0.20;
    v_eff = max(v_fan * (1 - f_bypass), v_nat);
    m_dot_aire = rho_aire * v_fan * A;  % Caudal consumiendo energia
    m_dot_eff = rho_aire * v_eff * A;   % Caudal secando biomasa

    % --- Ergun (Real consumido) ---
    if v_fan>1e-6
        dP_L = A_ergun*mu_aire*v_fan*(1-epsilon_actual)^2/(dp^2*epsilon_actual^3) ...
             + B_ergun*rho_aire*v_fan^2*(1-epsilon_actual)/(dp*epsilon_actual^3);
        P_turbina(i)=(v_fan*A)*(dP_L*H_actual)/eta_vent;
    end

    % --- Wakao & Kaguei (con velocidad efectiva) ---
    Re_p = rho_aire*v_eff*dp/mu_aire;
    Nu_p = 2+1.1*Re_p^0.6*Pr^(1/3);
    h_conv = Nu_p*k_aire/dp;
    h_m = h_conv/(rho_aire*Cp_aire*Le^(2/3));

    f_vent = 1/(1+20*v_eff);

    X_cur=X(i,:); Ts_cur=Ts(i,:); evap_hora=0;

    Psat_ent = 610.78*exp(17.27*T_a/(T_a+237.3));
    W_entrada = 0.622*(HR_a/100*Psat_ent)/(P_atm-HR_a/100*Psat_ent);

    % T bulbo humedo — Stull (2011)
    T_wb = T_a*atan(0.151977*(HR_a+8.313659)^0.5) ...
         + atan(T_a+HR_a) - atan(HR_a-1.676331) ...
         + 0.00391838*HR_a^1.5*atan(0.023101*HR_a) - 4.686035;

    %% PRE-CALCULO VECTORIZADO (CORREGIDO: antes dentro del triple bucle)
    Tk_vec=Ts_cur+273.15;
    q_oxi = Q_oxi_ref*exp(-E_oxi./(R_gas.*Tk_vec));
    f_Wv  = 1./(1+(X_cur/W_crit).^2);
    q_wet = Q_wet_ref*X_cur.*exp(-E_wet./(R_gas.*Tk_vec)).*f_Wv;
    % V5.1: Componente biologica de Farrell (antes definida pero no usada)
    % Ref: Farrell et al. — fermentacion microbiana en bagazo humedo
    q_bio = Q_bio_ref*X_cur.*exp(-E_bio./(R_gas.*Tk_vec)).*f_Wv;
    Q_self_vec = (q_oxi + q_wet*f_vent + q_bio*f_vent)*V_capa*3.6;

    dT2=zeros(1,N_c);
    if N_c>1
        dT2(2:N_c-1)=(Ts_cur(3:N_c)-2*Ts_cur(2:N_c-1)+Ts_cur(1:N_c-2))/dz^2;
        dT2(1)=(Ts_cur(2)-Ts_cur(1))/dz^2;
        dT2(N_c)=(Ts_cur(N_c-1)-Ts_cur(N_c))/dz^2;
    end
    Q_cond_vec = kappa*dT2*V_capa*3.6;

    Cp_eff_vec = Cp_seco + X_cur*Cp_agua;
    m_capa_vec = m_seca_capa*(1+X_cur);
    % Ref: Brooker DB, Bakker-Arkema FW, Hall CW (1974). Drying Cereal Grains.
    % Factor de sorcion (1 + 0.38*exp(-0.4*X)): Mujumdar (2006), Tabla 3.2
    h_fg_vec   = (2501-2.361*Ts_cur) .* (1 + 0.38*exp(-0.4*X_cur));

    a_w_vec = zeros(1,N_c);
    mask_pos = X_cur > 1e-6;
    a_w_vec(mask_pos) = 1 ./ (1 + (oswin_C ./ X_cur(mask_pos)).^(1/oswin_n_s));
    a_w_vec = min(max(a_w_vec, 0), 1);

    % CORRECCION ARRHENIUS: k de secado depende de la temperatura del bagazo
    Ea_R = 4000;  % Energia de activacion / R [K] (tipico biomasa)
    T_ref = 22 + 273.15; % T de calibracion original
    k_Page_vec = k_Page * exp(-Ea_R * (1./Tk_vec - 1/T_ref));
    
    t_eff_d_vec = max(t_eff_capa/24, 0.001);
    MR_t_vec = exp(-k_Page_vec.*t_eff_d_vec.^n_Page);
    dMRdt_vec = -k_Page_vec.*n_Page.*t_eff_d_vec.^(n_Page-1).*MR_t_vec;
    m_evap_kin_base = abs(dMRdt_vec*(X0-Xe)/24)*m_seca_capa/3600;

    %% SUB-PASOS
    for s = 1:n_sub
        T_aire_j=T_a; W_aire_j=W_entrada;
        X_new=X_cur; Ts_new=Ts_cur;

        for j = 1:N_c
            Xi=X_cur(j); Tsi=Ts_cur(j);

            Psat_aj = 610.78*exp(17.27*T_aire_j/(T_aire_j+237.3));
            W_sat_aj = 0.622*Psat_aj/(P_atm-Psat_aj);
            if W_sat_aj>1e-8, HR_local=min((W_aire_j/W_sat_aj)*100,100);
            else, HR_local=100; end
            factor_HR = min(max(1-HR_local/100,0)*5,1);

            if Xi>Xe && factor_HR>0.001
                m_evap_kin = m_evap_kin_base(j)*factor_HR;
            else
                m_evap_kin = 0;
            end

            Psat_s = 610.78*exp(17.27*Tsi/(Tsi+237.3));
            W_sat_s = 0.622*Psat_s/(P_atm-Psat_s);
            W_surf = a_w_vec(j) * W_sat_s;
            delta_W = W_surf - W_aire_j;
            m_evap_conv = h_m*a_v*V_capa*rho_aire*delta_W;

            T_interf = 0.5*(T_aire_j+Tsi);
            Psat_interf = 610.78*exp(17.27*T_interf/(T_interf+237.3));
            W_sat_interf = 0.622*Psat_interf/(P_atm-Psat_interf);
            m_evap_air_limit = m_dot_eff * (W_sat_interf - W_aire_j);

            % LIMITE TERMODINAMICO: El aire no puede enfriarse por debajo del bulbo humedo
            m_evap_heat_limit = m_dot_eff * Cp_aire * (T_aire_j - T_wb) / (h_fg_vec(j) * 1000);
            
            % EVAPORACION O CONDENSACION (Re-humidificacion nocturna permitida)
            if delta_W >= 0
                % Evaporacion: min de los limites
                m_evap_j = min([m_evap_kin, m_evap_conv, max(m_evap_air_limit,0), max(m_evap_heat_limit,0)]);
            else
                % CONDENSACION: El bagazo actua como esponja si el aire trae mas humedad.
                % La evaporacion negativa significa que el agua pasa del aire al bagazo.
                % El limite esta dado por el transporte convectivo y el vapor disponible.
                m_cond_air = m_dot_eff * (W_aire_j - W_sat_interf);
                m_cond_conv = h_m * a_v * V_capa * rho_aire * abs(delta_W);
                m_evap_j = -min(max(m_cond_air,0), m_cond_conv);
            end


            dX_j = -m_evap_j*3600*dt_sub/m_seca_capa;
            X_new(j) = max(min(Xi+dX_j, X0*1.10), Xe);

            W_aire_j = W_aire_j + m_evap_j/m_dot_eff;
            T_aire_j = T_aire_j - m_evap_j*h_fg_vec(j)*1000/(m_dot_eff*Cp_aire);
            evap_hora = evap_hora + m_evap_j*3600/n_sub;

            if Xi>Xe && delta_W>=0
                t_eff_capa(j)=t_eff_capa(j)+dt_sub*factor_HR;
            end

            Q_conv_j = h_conv*a_v*V_capa*(T_aire_j-Tsi)*3.6;
            Q_evap_j = m_evap_j*h_fg_vec(j)*3600;

            % CORREGIDO: T_wb+0.5 (antes T_wb+2)
            if Tsi < T_wb+0.5 && m_evap_j > 0
                Q_evap_j = Q_evap_j*max((Tsi-T_wb)/0.5, 0.05);
            end

            % CORREGIDO: alpha_abs_techo de constantes_farrell
            if j==N_c, Q_sol_j=I_sol*A*alpha_abs_techo*3.6; else, Q_sol_j=0; end

            % --- CORRECCION GAP: Perdidas por paredes de la camara ---
            % La perdida total se distribuye uniformemente entre capas
            Q_paredes_j = U_paredes * (A_paredes / N_c) * (Tsi - T_a) * 3.6;  % kJ/h

            dTsdt = (Q_conv_j-Q_evap_j-Q_paredes_j+Q_cond_vec(j)+Q_self_vec(j)+Q_sol_j) ...
                    /(m_capa_vec(j)*Cp_eff_vec(j));
            dTsdt_raw = dTsdt;
            dTsdt = sign(dTsdt)*min(abs(dTsdt), 2.0/dt_sub);
            % V3.1: contabilizar activaciones del clipper
            if abs(dTsdt) < abs(dTsdt_raw) - 1e-10, n_clipper = n_clipper + 1; end
            % V1.2: Limite 80C es salvaguarda Euler. A T_op=22C,
            % Q_Farrell ~1e-9 W/m3 (runaway solo en pilas >3m, Farrell 1998).
            % Limite inferior T_wb-0.5: el bagazo no puede enfriarse por
            % debajo del bulbo humedo (equilibrio evaporativo termodinamico).
            Ts_new(j) = max(min(Tsi+dTsdt*dt_sub, 80), T_wb-0.5);

            if s==n_sub
                Ta_out(i,j)=T_aire_j; Wa_out(i,j)=W_aire_j;
                Psat_diag=610.78*exp(17.27*T_aire_j/(T_aire_j+237.3));
                W_sat_diag=0.622*Psat_diag/(P_atm-Psat_diag);
                if W_sat_diag>1e-8, HRa_out(i,j)=min((W_aire_j/W_sat_diag)*100,100);
                else, HRa_out(i,j)=100; end
            end
        end
        X_cur=X_new; Ts_cur=Ts_new;
    end

    X(i+1,:)=X_cur; Ts(i+1,:)=Ts_cur;
    evap_total(i)=evap_hora;
    E_acum(i+1)=E_acum(i)+P_turbina(i)*dt;  % P[W] × dt[h] = E[Wh]
    H_hist(i+1) = H_actual;
    eps_hist(i+1) = epsilon_actual;

    if mod(i,max(1,round(N_t/10)))==0
        fprintf('    %3.0f%% | dia %2.0f | X=%.3f | v=%.2f | H=%.3fm\n', ...
            100*i/N_t, floor(t_dias)+1, mean(X_cur), v_fan, H_actual);
    end
end

%% COMPLETAR
T_amb_v(end)=T_amb_v(end-1); HR_amb_v(end)=HR_amb_v(end-1);
I_sol_v(end)=I_sol_v(end-1);
Ta_out(end,:)=Ta_out(end-1,:); Wa_out(end,:)=Wa_out(end-1,:);
HRa_out(end,:)=HRa_out(end-1,:);

%% EMPAQUETAR
z_centros = ((1:N_c)'-0.5)*(H_hist(end)/N_c);
tiempo_h=(0:N_t)'*dt; c_mid=max(1,round(N_c/2));
resultado.tiempo_horas=tiempo_h; resultado.tiempo_dias=tiempo_h/24;
resultado.z_centros=z_centros;
resultado.dz=H_hist(end)/N_c; resultado.N_capas=N_c;
resultado.X=X; resultado.Ts=Ts;
resultado.X_promedio=mean(X,2); resultado.T_promedio=mean(Ts,2);
resultado.X_superficie=X(:,N_c); resultado.X_centro=X(:,c_mid);
resultado.X_base=X(:,1);
resultado.T_superficie=Ts(:,N_c); resultado.T_centro=Ts(:,c_mid);
resultado.T_base=Ts(:,1);
resultado.Ta_out=Ta_out; resultado.Wa_out=Wa_out; resultado.HRa_out=HRa_out;
resultado.T_ambiente=T_amb_v; resultado.HR_ambiente=HR_amb_v;
resultado.I_solar=I_sol_v;
resultado.peso_kg=rho*A*H0*(1+resultado.X_promedio);
resultado.peso_g=resultado.peso_kg*1000;
resultado.evap_kg_h=[evap_total; 0];
resultado.v_aire=[v_aire_vec(1:N_t); v_aire_vec(end)];
resultado.P_turbina=[P_turbina; 0];
resultado.E_acum_Wh=E_acum; resultado.E_acum_kWh=E_acum/1000;
resultado.camara=camara; resultado.params=params_cin;
resultado.MR_promedio=max((resultado.X_promedio-Xe)/(X0-Xe),0);
resultado.H_lecho=H_hist; resultado.epsilon=eps_hist;

agua_evap = resultado.peso_kg(1)-resultado.peso_kg(end);
fprintf('\n  X: %.4f -> %.4f | Agua: %.1f kg | E: %.2f kWh | H: %.3f->%.3fm\n', ...
    resultado.X_promedio(1), resultado.X_promedio(end), agua_evap, ...
    resultado.E_acum_kWh(end), H0, H_hist(end));
% V3.1: Diagnostico del clipper de temperatura
if n_clipper > 0
    fprintf('  [CLIPPER] %d activaciones en %d horas (%d sub-pasos/h)\n', ...
        n_clipper, N_t, n_sub);
end
resultado.n_clipper = n_clipper;
end

function val = campo_o_default(s, campo, default)
    if isfield(s,campo), val=s.(campo); else, val=default; end
end
