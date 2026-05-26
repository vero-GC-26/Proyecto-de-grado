# BagazoMPC — Gemelo Digital para Secado de Bagazo de Caña

Plataforma interactiva en tiempo real que integra un **Gemelo Digital** termodinámico y un controlador **Model Predictive Control (MPC)** para optimizar el proceso de secado de bagazo de caña en trapiches paneleros.

Este repositorio contiene exclusivamente el código fuente de la aplicación web y su respectivo backend de simulación matemática.

## Arquitectura del Sistema

El sistema opera bajo una arquitectura de tres capas:
1. **Frontend (Interfaz Web):** Construida con HTML, CSS y JavaScript Vanilla. Muestra gráficas en tiempo real, proyecciones del secado y métricas de impacto económico.
2. **Backend Intermedio (Python/Flask):** Un servidor ligero (`servidor.py`) que aloja la página web y expone una API REST para enrutar los clics del usuario hacia el motor matemático.
3. **Motor Matemático (MATLAB):** Un servidor de simulación en vivo (`servidor_mpc.m`) que ejecuta el modelo fenomenológico (calor y masa) y calcula las señales óptimas del ventilador en función del pronóstico meteorológico.

## 📂 Estructura del Repositorio

* `/interfaz` — Contiene el portal web (`index.html`), el servidor Python y el script conector de MATLAB.
* `/mpc` — Algoritmos del controlador predictivo, optimización convexa y restricciones.
* `/modelos` — Ecuaciones físicas del secador (cinética de Page modificada, ecuaciones de Sherwood, modelo del intercambiador pasivo).
* `/datos` — Bases de datos meteorológicos, integrador de la API de Open-Meteo y curvas empíricas de isotermas de Oswin.

## ⚙️ Instrucciones de Instalación y Uso

Para correr la plataforma con toda su capacidad predictiva:

1. **Clonar o descargar** este repositorio en tu computadora local.
2. **Encender el Motor Matemático:**
   * Abre MATLAB.
   * Navega hasta la carpeta `interfaz/`.
   * Ejecuta el script `servidor_mpc.m`. La consola te indicará que está escuchando.
3. **Encender el Servidor Web:**
   * Abre una terminal (Símbolo del sistema o PowerShell).
   * Navega hasta la carpeta `interfaz/`.
   * Ejecuta el comando: `python servidor.py`
4. **Abrir la Interfaz:**
   * Abre tu navegador web preferido y entra a: `http://localhost:8080/interfaz/index.html`

> **Nota para Hosting (Ej. GitHub Pages):** Puedes alojar la interfaz en GitHub Pages para mostrar su diseño públicamente, pero el botón de "Simular" solo funcionará si en la computadora desde donde se ve la página se están ejecutando los pasos 2 y 3.

## Autores y Licencia
Autora: Yanith Veronica Garcia Castro
Proyecto de Grado - Ingeniería Electrónica.
Universidad de los Andes.
