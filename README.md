# Gemelo Digital y Control Predictivo (MPC) para Secado de Bagazo de Caña

Este repositorio contiene el código fuente desarrollado para el proyecto de grado enfocado en la modernización termodinámica de la agroindustria panelera en Ricaurte, Nariño (Colombia). 

El sistema implementa un **Gemelo Digital fenomenológico de 20 capas** acoplado a un **Controlador Predictivo Basado en Modelos (MPC)**, el cual optimiza en tiempo real el secado de biomasa (bagazo) tomando decisiones de control sobre la señal VFD de un ventilador centrífugo, utilizando pronósticos meteorológicos en vivo mediante la API de Open-Meteo.

## Arquitectura del Proyecto

El repositorio está estructurado en módulos para separar la física del proceso, la lógica de control, y la interfaz de usuario:

### 1. Modelos Termodinámicos (`/modelos`)
Contiene la física de primeros principios del secado.
* `gemelo_camara_forzada.m`: Modelo fenomenológico completo de 20 capas (transferencia de masa, calor y autocalentamiento biológico de Farrell).
* `cinetica_secado.m`: Ecuaciones empíricas de secado (Page, Newton, etc.).
* `intercambiador_calor.m`: Dinámica térmica del intercambiador de calor acoplado al sistema.

### 2. Motor de Control Predictivo (`/mpc`)
Lógica de optimización y horizonte deslizante.
* `ejecutar_mpc_loop.m`: Bucle principal de simulación del MPC a lo largo del tiempo.
* `mpc_paso.m`: Resuelve la optimización matemática (`fmincon`) para un instante $k$.
* `modelo_prediccion_mpc.m`: Modelo interno simplificado (5 capas) que usa el MPC para predecir el futuro de forma rápida.
* `costo_mpc.m`: Función de costo multicriterio (penaliza humedad, consumo energético y oscilaciones del motor).

### 3. Interfaz de Usuario HMI (`/interfaz`)
Dashboard web para monitoreo y control remoto.
* `index.html`: Frontend (HTML/CSS/JS) con gráficas dinámicas de la planta.
* `servidor.py`: Middleware en Python que levanta un servidor HTTP local y comunica la web con MATLAB.
* `servidor_mpc.m`: Archivo de escucha en MATLAB que ejecuta comandos provenientes de la web.

### 4. Scripts de Ejecución (`/scripts`)
Scripts principales para pruebas, validación y demostración.
* `main_mpc.m`: Simulación exhaustiva del sistema MPC contra el Gemelo Digital en diversos escenarios.
* `demo_defensa.m`: Script de demostración en vivo que descarga el clima actual y calcula el plan de secado óptimo instantáneo.
* `validacion_campo.m`: Validación matemática del Gemelo Digital contra datos experimentales tomados en campo.

### 5. Datos y APIs (`/datos`)
* `obtener_clima_openmeteo.m`: Script de conexión a la API REST de Open-Meteo para descargar el pronóstico de radiación, temperatura y humedad.
* `datos_campo.m`: Estructura de datos recopilados en las pruebas de campo en Nariño.

## Requisitos de Ejecución
* **MATLAB R2023a o superior** con el *Optimization Toolbox* (para la función `fmincon`).
* **Python 3.8+** (Para levantar el servidor de la interfaz web localmente).
* Conexión a internet para las peticiones a la API de clima.
