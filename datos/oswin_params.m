function p = oswin_params()
% OSWIN_PARAMS  Parametros centralizados de la isoterma de Oswin
% =========================================================================
% Isoterma de sorcion de Oswin para bagazo de cana de azucar:
%
%   Xe = C * (HR / (1 - HR))^n_s
%
% Donde:
%   Xe  = humedad de equilibrio [kg_agua/kg_seco]
%   HR  = humedad relativa del aire [fraccion, 0-1]
%   C   = constante de Oswin
%   n_s = exponente de Oswin
%
% Calibracion basada en:
%   - Arabi & Ghalehno, BioResources 18(1), 2023 (biomasa fibrosa)
%   - Rango validado: HR = 0.30 a 0.95
%   - Xe(HR=0.81) = 0.134 kg/kg (consistente con datos experimentales)
%
% IMPORTANTE: Todos los modelos del proyecto deben usar esta funcion
%             para garantizar consistencia termodinamica.
%
% Uso:
%   p = oswin_params();
%   Xe = p.C * (HR / (1 - HR))^p.n_s;
% =========================================================================

    p.C   = 0.08;    % Constante de Oswin [-]
    p.n_s = 0.35;    % Exponente de Oswin [-]
    
    % Referencia para verificacion rapida:
    % A HR=60%: Xe = 0.08 * (0.6/0.4)^0.35 = 0.097
    % A HR=81%: Xe = 0.08 * (0.81/0.19)^0.35 = 0.134
    % A HR=92%: Xe = 0.08 * (0.92/0.08)^0.35 = 0.191

end
