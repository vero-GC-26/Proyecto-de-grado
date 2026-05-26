%% datos_campo.m
% Datos experimentales de secado de bagazo - Ricaurte, Nariño
% Recolectados en campo entre Dic 2025 y Ene 2026
% Coordenadas: 1.2136°N, -77.9967°W, 1160 msnm (Vereda San Pablo)

function datos = datos_campo()

    %% ====================================================================
    %  CURVA DE SECADO (peso vs días)
    %  Muestra de bagazo secándose en pila bajo condiciones naturales
    %  ====================================================================
    datos.secado.fechas = {'09/12/2025','12/12/2025','17/12/2025', ...
                           '21/12/2025','23/12/2025','25/12/2025', ...
                           '28/12/2025','03/01/2026','07/01/2026'};
    datos.secado.dias   = [1, 4, 9, 13, 15, 17, 19, 25, 32];
    datos.secado.peso_g = [203.57, 161.5, 137.3, 134.6, 129.2, 125.6, 123.0, 120.3, 114.0];
    
    % Humedad total reportada
    datos.secado.humedad_total_pct = 46.728972;
    
    % Cálculos derivados
    % Peso seco estimado (asumiendo equilibrio al día 32)
    datos.secado.peso_seco_g = datos.secado.peso_g(end);  % 114 g
    
    % Contenido de humedad en base seca X = (m_total - m_seca) / m_seca
    datos.secado.X = (datos.secado.peso_g - datos.secado.peso_seco_g) ...
                      / datos.secado.peso_seco_g;  % [kg_agua/kg_seco]
    
    % Humedad de equilibrio (última medición)
    datos.secado.Xe = 0;  % Referencia al peso seco final
    
    % Moisture Ratio: MR = (X - Xe) / (X0 - Xe)
    X0 = datos.secado.X(1);
    Xe = datos.secado.Xe;
    datos.secado.MR = (datos.secado.X - Xe) / (X0 - Xe);
    
    %% ====================================================================
    %  CONDICIONES AMBIENTALES - ZONA DE MOLIENDA
    %  ====================================================================
    datos.zona_molienda.temperatura = [24.6, 23.6, 23.1, 23.3, 22.2, ...
                                       22.0, 22.0, 21.9, 21.9, 21.9, 22.0];
    datos.zona_molienda.humedad_rel = [81, 79, 78, 78, 78, 79, 79, 80, 80, 80, 80];
    
    % Estadísticas
    datos.zona_molienda.T_media = mean(datos.zona_molienda.temperatura);
    datos.zona_molienda.HR_media = mean(datos.zona_molienda.humedad_rel);
    
    %% ====================================================================
    %  CONDICIONES AMBIENTALES - ZONA A 15m DEL TRAPICHE
    %  ====================================================================
    datos.zona_15m.temperatura = [24.3, 23.3, 23.1, 22.0, 21.3, ...
                                  21.3, 21.3, 21.1, 21.1, 21.1, 21.1];
    datos.zona_15m.humedad_rel = [79, 77, 76, 77, 78, 79, 80, 81, 82, 83, 83];
    
    datos.zona_15m.T_media = mean(datos.zona_15m.temperatura);
    datos.zona_15m.HR_media = mean(datos.zona_15m.humedad_rel);
    
    %% ====================================================================
    %  CONDICIONES AMBIENTALES - ZONA DE BAGAZO RECIÉN MOLIDO
    %  ====================================================================
    datos.zona_bagazo.temperatura = [21.7, 21.6, 21.5, 21.6, 21.6, ...
                                     21.7, 21.8, 22.0, 22.3, 22.5, 22.5];
    datos.zona_bagazo.humedad_rel = [85, 85, 85, 85, 85, 86, 86, 86, 86, 86, 86];
    
    datos.zona_bagazo.T_media = mean(datos.zona_bagazo.temperatura);
    datos.zona_bagazo.HR_media = mean(datos.zona_bagazo.humedad_rel);
    
    %% ====================================================================
    %  TEMPERATURA POR ESTADO DE SECADO
    %  ====================================================================
    datos.estado_secado.objeto   = {'Bagazo recien salido', ...
                                    'Bagazo una semana despues', ...
                                    'Bagazo seco bajo techo'};
    datos.estado_secado.dia      = [1, 8, 30];
    datos.estado_secado.temp_C   = [21, 24, 25];
    
    %% ====================================================================
    %  DATOS PPM - ZONA A 15m DEL TRAPICHE
    %  ====================================================================
    datos.ppm_15m.valores = [37,37,37,37,35,37,37,38,37,37,37,37,37, ...
                             37,37,37,38,37,37,37,37,37,37,37,37,38,37];
    datos.ppm_15m.media = mean(datos.ppm_15m.valores);
    
    %% ====================================================================
    %  DATOS PPM - ZONA DENTRO DEL TRAPICHE
    %  ====================================================================
    datos.ppm_trapiche.valores = [35,34,35,35,35,35,35,34,36,35,35, ...
                                  34,35,36,35,35,36,35,35,35,34,35, ...
                                  36,36,35,36,36,36,35,35,35];
    datos.ppm_trapiche.media = mean(datos.ppm_trapiche.valores);
    
    %% ====================================================================
    %  DATOS PPM - ZONA DE SALIDA DE HUMO (combustión)
    %  ====================================================================
    datos.ppm_humo.valores = [106,112,120,118,108,100,119,126,154,149, ...
                              128,156,146,145,145,143,153,131,122,107, ...
                              101,95,147,166,225,126,192,251,214,194, ...
                              172,156,143,161,175,327,297,334,311,332, ...
                              316,307,286,256,254,245,209,199,203,209, ...
                              204,199,256,337,339,306,257,240,219];
    datos.ppm_humo.media = mean(datos.ppm_humo.valores);
    datos.ppm_humo.max = max(datos.ppm_humo.valores);
    
    %% ====================================================================
    %  CONDICIONES PROMEDIO PARA SIMULACIÓN
    %  ====================================================================
    % Promedio ponderado de las 3 zonas para T y HR ambiente
    T_todas = [datos.zona_molienda.T_media, datos.zona_15m.T_media, ...
               datos.zona_bagazo.T_media];
    HR_todas = [datos.zona_molienda.HR_media, datos.zona_15m.HR_media, ...
                datos.zona_bagazo.HR_media];
    
    datos.ambiente.T_media = mean(T_todas);   % °C
    datos.ambiente.HR_media = mean(HR_todas);  % %
    datos.ambiente.T_rango = [min(T_todas), max(T_todas)];
    datos.ambiente.HR_rango = [min(HR_todas), max(HR_todas)];
    
    %% Coordenadas geográficas — Vereda San Pablo, Ricaurte, Nariño
    datos.ubicacion.latitud = 1.2136;           % °N (grados decimales)
    datos.ubicacion.longitud = -77.9967;        % °O (grados decimales)
    datos.ubicacion.altitud_msnm = 1160;        % m sobre nivel del mar
    datos.ubicacion.nombre = 'San Pablo, Ricaurte, Nariño, Colombia';

end
