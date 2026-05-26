"""
Servidor puente Python — Conecta la interfaz web con MATLAB
================================================================
USO:  python servidor.py
      (Ejecutar desde la carpeta gemelo_bagazo_v2/)

Funciones:
  1. Sirve los archivos HTML/CSS/JS de la interfaz
  2. API REST para comunicar la interfaz web con MATLAB
  3. MATLAB corre servidor_mpc.m por separado
================================================================
"""

from http.server import HTTPServer, SimpleHTTPRequestHandler
import json
import os
import time

PORT = 8080
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INTERFAZ_DIR = BASE_DIR
CONFIG_FILE = os.path.join(INTERFAZ_DIR, 'config.json')
CMD_FILE = os.path.join(INTERFAZ_DIR, 'comando.json')
RESULT_FILE = os.path.join(INTERFAZ_DIR, 'resultados.json')
STATUS_FILE = os.path.join(INTERFAZ_DIR, 'status.json')
ESTADO_FILE = os.path.join(INTERFAZ_DIR, 'estado_actual.json')

# Limpiar archivos obsoletos al iniciar para evitar comandos fantasma
for stale_file in [STATUS_FILE, CMD_FILE]:
    if os.path.exists(stale_file):
        try:
            os.remove(stale_file)
            print(f"[INIT] Limpiado: {os.path.basename(stale_file)}")
        except:
            pass

class MPCHandler(SimpleHTTPRequestHandler):
    """Handler que sirve archivos estáticos y maneja la API"""
    
    def __init__(self, *args, **kwargs):
        # Servir desde el directorio padre (gemelo_bagazo_v2/)
        super().__init__(*args, directory=os.path.dirname(BASE_DIR), **kwargs)
    
    def do_POST(self):
        """Maneja solicitudes POST de la interfaz"""
        
        if self.path == '/api/batch':
            # Recibir configuración y escribir comando.json para batch
            content_length = int(self.headers['Content-Length'])
            body = self.rfile.read(content_length)
            config = json.loads(body.decode('utf-8'))
            
            cmd_payload = {"cmd": "batch", "config": config}
            with open(CMD_FILE, 'w') as f:
                json.dump(cmd_payload, f, indent=2)
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'ok', 'message': 'Comando BATCH enviado'}).encode())
            print(f"[API] Comando BATCH enviado")
            
        elif self.path == '/api/reset_step':
            content_length = int(self.headers['Content-Length'])
            body = self.rfile.read(content_length)
            config = json.loads(body.decode('utf-8'))
            
            cmd_payload = {"cmd": "reset_step", "config": config}
            with open(CMD_FILE, 'w') as f:
                json.dump(cmd_payload, f, indent=2)
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'ok', 'message': 'Comando RESET enviado'}).encode())
            print(f"[API] Comando RESET enviado")
            
        elif self.path == '/api/step':
            cmd_payload = {"cmd": "step", "config": {}}
            with open(CMD_FILE, 'w') as f:
                json.dump(cmd_payload, f, indent=2)
                
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'ok', 'message': 'Comando STEP enviado'}).encode())
        
        elif self.path == '/api/simular-python':
            # Simulación rápida en Python (sin MATLAB)
            content_length = int(self.headers['Content-Length'])
            body = self.rfile.read(content_length)
            config = json.loads(body.decode('utf-8'))
            
            result = simular_python(config)
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
            
            print(f"[API] Simulación Python completada: X_mpc={result['mpc']['X_final']:.4f}")
        
        else:
            self.send_error(404)
    
    def do_GET(self):
        """Maneja solicitudes GET"""
        
        if self.path == '/api/status':
            # Leer status de MATLAB
            data = {'estado': 'desconectado', 'mensaje': 'MATLAB no conectado'}
            if os.path.exists(STATUS_FILE):
                try:
                    with open(STATUS_FILE, 'r') as f:
                        data = json.load(f)
                except:
                    pass
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())
        
        elif self.path == '/api/resultados':
            # Leer resultados de MATLAB (Batch) — con protección contra JSON truncado
            if os.path.exists(RESULT_FILE):
                try:
                    with open(RESULT_FILE, 'r') as f:
                        data = json.load(f)
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(json.dumps(data).encode())
                except (json.JSONDecodeError, ValueError):
                    # MATLAB aún está escribiendo el archivo
                    self.send_response(503)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(json.dumps({'error': 'Resultados en proceso de escritura, reintentando...'}).encode())
            else:
                self.send_response(404)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({'error': 'Sin resultados'}).encode())
                
        elif self.path == '/api/estado':
            # Leer estado actual de MATLAB (Paso a Paso)
            if os.path.exists(ESTADO_FILE):
                with open(ESTADO_FILE, 'r') as f:
                    data = json.load(f)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())
            else:
                self.send_response(404)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({'error': 'Sin estado actual'}).encode())
        
        elif self.path == '/api/matlab-status':
            # Verificar si MATLAB está conectado
            connected = False
            if os.path.exists(STATUS_FILE):
                try:
                    mod_time = os.path.getmtime(STATUS_FILE)
                    if time.time() - mod_time < 30:  # Actualizado en ultimos 30s (MATLAB hace ping cada 8s)
                        connected = True
                except:
                    pass
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({'connected': connected}).encode())
        
        else:
            # Servir archivos estáticos normalmente
            super().do_GET()
    
    def do_OPTIONS(self):
        """Maneja CORS preflight"""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
    
    def log_message(self, format, *args):
        """Silenciar logs de archivos estáticos"""
        if '/api/' in args[0] if args else '':
            super().log_message(format, *args)


def simular_python(cfg):
    """Simulación simplificada en Python (fallback sin MATLAB)"""
    import math
    
    dias = cfg.get('dias', 20)
    Xref = cfg.get('Xref', 15) / 100  # sync main_mpc.m: X_ref = 0.15
    X0 = cfg.get('X0', 88) / 100
    P_fan = cfg.get('P_fan', 50)
    masa = cfg.get('masa', 12)
    gamma = 0.5  # Red electrica (sin opcion solar)
    
    Nhoras = dias * 24
    k0, n_page = 0.045, 0.75
    Ea, R = 30000, 8.314
    v_max = 0.5
    
    # Clima promedio de Ricaurte
    T_base, HR_base = 22.0, 87.0
    
    results = {}
    for scenario in ['natural', 'constante', 'mpc']:
        X = X0
        E = 0
        X_hist = [X]
        pwm_hist = []
        pwm_prev = 30
        
        for h in range(Nhoras):
            T = T_base + 4 * math.sin(2 * math.pi * (h - 6) / 24)
            HR = HR_base - 10 * math.sin(2 * math.pi * (h - 6) / 24)
            HR = max(60, min(100, HR))
            
            if scenario == 'natural':
                pwm = 0
            elif scenario == 'constante':
                pwm = 100
            else:
                # MPC basado en reglas (calibrado desde main_mpc.m)
                dp = max(0, 1 - HR / 100)
                f_src = 1.0  # Red electrica
                if X <= Xref:
                    pwm = 0
                elif dp < 0.03:
                    pwm = 0
                elif dp < 0.08:
                    pwm = round(18 * f_src)
                elif dp < 0.15:
                    pwm = round(36 * f_src)
                elif dp < 0.25:
                    pwm = round(44 * f_src)
                else:
                    pwm = round(38 * f_src)
                pwm_prev = pwm
            
            v = v_max * pwm / 100
            
            T_eff = T
            HR_eff = HR
            use_hx = cfg.get('use_hx', 0)
            dias_molienda = cfg.get('dias_molienda', 3)
            
            dia_actual = (h // 24) + 1
            semana = (dia_actual - 1) // 7
            dia_semana = dia_actual - semana * 7
            hornilla_on = (dia_semana <= dias_molienda) and (4 <= (h % 24) < 17)
            
            if use_hx and hornilla_on and v > 0:
                # Intercambiador_calor.m approximation
                delta_T = min(600 - T, 85 - T) # Limite Farrell 85C
                if delta_T > 0:
                    T_eff = T + delta_T
                    # Tetens eq para psicrometria
                    Psat_amb = 610.78 * math.exp(17.27 * T / (T + 237.3))
                    W_abs = 0.622 * (HR/100 * Psat_amb) / (87700 - HR/100 * Psat_amb)
                    Psat_out = 610.78 * math.exp(17.27 * T_eff / (T_eff + 237.3))
                    HR_new = (W_abs * 87700) / ((0.622 + W_abs) * Psat_out) * 100
                    HR_eff = max(5, min(100, HR_new))
                    
                    if scenario == 'mpc' and T_eff > 85:
                        # Si pasa 85 grados, estrangular ventilador para proteger fibras (Farrell)
                        pwm = max(10, pwm - 20)
                        v = v_max * pwm / 100

            Tk = T_eff + 273.15
            kT = k0 * math.exp(-Ea / R * (1 / Tk - 1 / 298.15))
            dp_sec = max(0, 1 - HR_eff / 100)
            ff = 1 + 2 * v
            # Tuned drying multiplier to match MATLAB 24-day trajectory
            multiplicador = 0.08 if use_hx else 0.04
            dX = -kT * dp_sec * ff * X * multiplicador
            X = max(0, X + dX)
            P = P_fan * (pwm / 100) ** 3
            E += P / 1000
            X_hist.append(X)
            pwm_hist.append(pwm)
        
        agua = masa * (X0 - X) / (1 + X0)
        results[scenario] = {
            'X_final': X,
            'energia_kWh': E,
            'agua_kg': agua,
            'eficiencia': agua / E if E > 0 else 0,
            'X_hist': X_hist[::max(1, len(X_hist) // 200)],
            'pwm_hist': pwm_hist[::max(1, len(pwm_hist) // 200)] if scenario != 'natural' else []
        }
    
    ahorro = 0
    if results['constante']['energia_kWh'] > 0:
        ahorro = (1 - results['mpc']['energia_kWh'] / results['constante']['energia_kWh']) * 100
    
    results['mpc']['ahorro_pct'] = ahorro
    results['mpc']['pwm_promedio'] = sum(pwm_hist) / len(pwm_hist) if pwm_hist else 0
    
    idx = next((i for i, x in enumerate(results['mpc']['X_hist']) if x <= Xref), -1)
    results['mpc']['alcanza_objetivo'] = idx >= 0
    results['mpc']['dias_para_objetivo'] = idx / 24 if idx >= 0 else -1
    
    # --- T_hist: temperatura del lecho (modelo simplificado) ---
    T_hist = []
    for h in range(Nhoras):
        T_amb = T_base + 4 * math.sin(2 * math.pi * (h - 6) / 24)
        T_lecho = T_amb + 3.0  # auto-calentamiento basal
        T_hist.append(round(T_lecho, 1))
    results['mpc']['T_hist'] = T_hist[::max(1, len(T_hist) // 200)]
    
    use_hx = cfg.get('use_hx', 0)
    if use_hx:
        T_hist_hx = []
        dias_molienda = cfg.get('dias_molienda', 3)
        for h in range(Nhoras):
            T_amb = T_base + 4 * math.sin(2 * math.pi * (h - 6) / 24)
            dia_actual = (h // 24) + 1
            semana = (dia_actual - 1) // 7
            dia_semana = dia_actual - semana * 7
            hornilla_on = (dia_semana <= dias_molienda) and (4 <= (h % 24) < 17)
            
            if hornilla_on:
                T_hx = T_amb + min(600 - T_amb, 85 - T_amb)
            else:
                T_hx = T_amb + 3.0
            T_hist_hx.append(round(min(T_hx, 85.0), 1))
        results['mpc']['T_hist_hx'] = T_hist_hx[::max(1, len(T_hist_hx) // 200)]
    
    # --- Hugot PCI & económico (SINCRONIZADO con servidor_mpc.m) ---
    X_mpc_final = results['mpc']['X_final']
    W_ini = X0 / (1 + X0) * 100   # base húmeda %
    W_fin = X_mpc_final / (1 + X_mpc_final) * 100
    S, A = 2.5, 2.5  # sacarosa y cenizas — idéntico a MATLAB
    PCI_ini = (18309 - 31.14 * S - 207.3 * W_ini - 196.05 * A) / 1000  # MJ/kg
    PCI_fin = (18309 - 31.14 * S - 207.3 * W_fin - 196.05 * A) / 1000
    ganancia = (PCI_fin / PCI_ini - 1) * 100 if PCI_ini > 0 else 0
    
    # Masa de bagazo dinámica (sincronizado con MATLAB)
    panela_kg = cfg.get('panela_kg', 1950)
    masa_bagazo = panela_kg * 3  # 1 kg panela ~ 3 kg bagazo
    E_ini = PCI_ini * masa_bagazo  # MJ total con bagazo húmedo
    E_fin = PCI_fin * masa_bagazo
    E_excedente = max(0, E_fin - E_ini)  # MJ extra disponibles
    PCI_lena = 14.0  # MJ/kg — idéntico a MATLAB
    kg_lena = E_excedente / PCI_lena if PCI_lena > 0 else 0
    precio_lena = 250  # COP/kg — idéntico a MATLAB (dato real Ricaurte)
    ahorro_comb = kg_lena * precio_lena
    tarifa = 947.34  # COP/kWh — idéntico a MATLAB (tarifa rural colombiana)
    masa_lote = cfg.get('masa', 12)
    factor_escala = masa_bagazo / masa_lote if masa_lote > 0 else 1
    energia_trapiche_kWh = results['mpc']['energia_kWh'] * factor_escala
    costo_vent = energia_trapiche_kWh * tarifa
    neto = ahorro_comb - costo_vent
    
    results['hugot'] = {
        'PCI_inicial_MJ': round(PCI_ini, 2),
        'PCI_final_MJ': round(PCI_fin, 2),
        'ganancia_pct': round(ganancia, 1),
        'W_inicial_pct': round(W_ini, 1),
        'W_final_pct': round(W_fin, 1),
        'kg_lena_ahorrada': round(kg_lena, 1),
        'kg_excedente': round(E_excedente / PCI_lena, 1) if PCI_lena > 0 else 0,
        'ahorro_combustible_COP': round(ahorro_comb),
        'costo_ventilador_COP': round(costo_vent),
        'beneficio_neto_COP': round(neto),
        'tarifa_electrica': tarifa,
        'masa_trapiche_kg': masa_bagazo
    }
    
    results['config'] = {
        'dias': dias,
        'X0': cfg.get('X0', 88),
        'Xref': cfg.get('Xref', 15) / 100,  # sync main_mpc.m
    }
    
    results['motor'] = 'python'
    results['tiempo_simulacion_s'] = 0.1
    
    return results


if __name__ == '__main__':
    print()
    print('================================================================')
    print(' SERVIDOR WEB — Gemelo Digital Secado de Bagazo')
    print('================================================================')
    print(f'  URL:      http://localhost:{PORT}/interfaz/index.html')
    print(f'  API:      http://localhost:{PORT}/api/status')
    print(f'  MATLAB:   Ejecuta servidor_mpc.m en MATLAB para conectar')
    print()
    print('  Sin MATLAB, la simulación usa el motor Python (simplificado)')
    print('  Con MATLAB, usa el modelo completo (Sherwood + Farrell)')
    print('================================================================')
    print()
    
    server = HTTPServer(('localhost', PORT), MPCHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n  Servidor detenido.')
        server.server_close()
