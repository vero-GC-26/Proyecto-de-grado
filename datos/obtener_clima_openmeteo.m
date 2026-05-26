function clima = obtener_clima_openmeteo(lat, lon, dias)
% OBTENER_CLIMA_OPENMETEO Descarga pronostico horario de Open-Meteo
% clima = obtener_clima_openmeteo(lat, lon, dias)
%
% Descarga temperatura, humedad y radiacion solar para las coordenadas dadas.
% Utilizado para simular el aire ambiente que ingresa a la camara de secado.

    if nargin < 3, dias = 14; end
    if nargin < 1
        lat = 1.6333;
        lon = -77.9833;
    end

    dias = min(dias, 16);

    url = sprintf('https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&hourly=temperature_2m,relative_humidity_2m,direct_normal_irradiance&forecast_days=%d&timezone=auto', lat, lon, dias);

    try
        options = weboptions('Timeout', 15);
        datos_api = webread(url, options);

        clima.fuente = 'Open-Meteo API';
        clima.n_horas = length(datos_api.hourly.temperature_2m);
        clima.T_amb = double(datos_api.hourly.temperature_2m(:));
        clima.HR = double(datos_api.hourly.relative_humidity_2m(:));
        clima.I_solar = double(datos_api.hourly.direct_normal_irradiance(:));

        clima.T_amb = fillmissing(clima.T_amb, 'previous');
        clima.HR = fillmissing(clima.HR, 'previous');
        clima.I_solar = fillmissing(clima.I_solar, 'constant', 0);

        % Validar rangos fisicos
        clima.T_amb = max(min(clima.T_amb, 50), -10);
        clima.HR = max(min(clima.HR, 100), 0);
        clima.I_solar = max(clima.I_solar, 0);
    catch ME
        warning('OPENMETEO:ErrorConexion', ...
            'No se pudo conectar a Open-Meteo: %s. Se usaran datos sinusoidales de campo.', ...
            ME.message);
        clima = [];
    end
end