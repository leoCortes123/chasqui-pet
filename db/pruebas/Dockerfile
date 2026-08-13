# =====================================================================
# Chasqui Pet — imagen de pruebas
#
# Postgres 16 con pgTAP. La base de la clínica corre sobre
# `postgres:16-alpine` (docker-compose.yml); aquí se usa la variante
# Debian por una razón práctica: pgTAP no está empaquetado para Alpine y
# sí en el repositorio PGDG que esta imagen ya trae configurado.
#
# La diferencia de sistema operativo no afecta lo que se prueba —las
# reglas viven en plpgsql— pero sí cambia el locale disponible, así que
# el contenedor de pruebas arranca en C.UTF-8 y no en es_CO.UTF-8. Lo
# único sensible a eso es el ORDENAMIENTO de texto, que ninguna de estas
# pruebas ejercita.
# =====================================================================
FROM postgres:16

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-pgtap \
 && rm -rf /var/lib/apt/lists/*
