Welcome to **Aetheris**.

Aetheris is an open-source platform that simplifies air quality monitoring. It's built around the **Aetheris Sensor**, a compact ESP32-based device designed to capture various air quality metrics.

This repository provides all the code and configuration necessary to deploy a complete monitoring network. With a single Docker Compose file, you can set up all the core services, including:

* **Mosquitto:** A lightweight MQTT broker to handle data from all your sensors.
* **InfluxDB:** A time-series database for efficient storage of your air quality data.
* **Grafana:** A powerful analytics and visualization platform to create real-time dashboards.
* **Loki and Alloy:** For log aggregation and monitoring of your services.

By using this setup, you can effortlessly collect, store, and visualize air quality data from an entire network of sensors.


***This repo is under active development. Look out for the first full working setup in upcoming days***
