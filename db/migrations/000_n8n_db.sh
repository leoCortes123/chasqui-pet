#!/bin/bash
# =============================================================================
# Chasqui Pet — Creación de la base de datos propia de n8n
# -----------------------------------------------------------------------------
# Se ejecuta UNA SOLA VEZ, la primera vez que arranca el contenedor de Postgres
# con el volumen de datos vacío, ANTES de las migraciones del negocio.
#
# El compose lo monta como /docker-entrypoint-initdb.d/000_n8n_db.sh para que
# quede antes de 010_base.sql en el orden alfabético que usa la imagen oficial
# de Postgres. Ver el comentario del servicio "db" en docker-compose.yml.
#
# n8n guarda sus workflows, credenciales y ejecuciones en una base SEPARADA
# ("n8n"), con un usuario propio que NO tiene acceso a la base de negocio. Así,
# comprometer n8n no expone la historia clínica ni la caja, y el respaldo de la
# base de negocio no arrastra el estado interno de n8n.
#
# Nota técnica: la imagen de Postgres ejecuta los .sh de initdb.d directamente
# si tienen permiso de ejecución, y los "sourcea" si no lo tienen. Por eso todo
# el cuerpo vive dentro de una función que corre en subshell: así las opciones
# de shell (set -euo pipefail) nunca se filtran al entrypoint de la imagen.
# =============================================================================

chasquipet_init_n8n() (
    set -euo pipefail

    N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
    N8N_DB_USER="${N8N_DB_USER:-n8n}"
    N8N_DB_PASSWORD="${N8N_DB_PASSWORD:-}"

    echo "[init] Creando la base de datos y el usuario de n8n..."

    if [ -z "$N8N_DB_PASSWORD" ]; then
        echo "[init] ERROR: la variable N8N_DB_PASSWORD está vacía." >&2
        echo "[init] Defínala en el archivo .env y vuelva a crear el volumen pgdata." >&2
        return 1
    fi

    # Rol de n8n. Se conecta como superusuario a la base de mantenimiento.
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
	DO \$\$
	BEGIN
	    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${N8N_DB_USER}') THEN
	        CREATE ROLE ${N8N_DB_USER} WITH LOGIN PASSWORD '${N8N_DB_PASSWORD}';
	    ELSE
	        ALTER ROLE ${N8N_DB_USER} WITH LOGIN PASSWORD '${N8N_DB_PASSWORD}';
	    END IF;
	END
	\$\$;
	EOSQL

    # CREATE DATABASE no admite bloque transaccional ni IF NOT EXISTS.
    existe=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${N8N_DB_NAME}'" \
                  --username "$POSTGRES_USER" --dbname postgres)
    if [ "$existe" != "1" ]; then
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
            -c "CREATE DATABASE ${N8N_DB_NAME} OWNER ${N8N_DB_USER} ENCODING 'UTF8' TEMPLATE template0;"
        echo "[init] Base '${N8N_DB_NAME}' creada."
    else
        echo "[init] La base '${N8N_DB_NAME}' ya existía."
    fi

    # El usuario de n8n manda dentro de su base y de nada más.
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$N8N_DB_NAME" <<-EOSQL
	GRANT ALL PRIVILEGES ON DATABASE ${N8N_DB_NAME} TO ${N8N_DB_USER};
	GRANT ALL ON SCHEMA public TO ${N8N_DB_USER};
	ALTER SCHEMA public OWNER TO ${N8N_DB_USER};
	EOSQL

    # Se le quita el acceso a la base de negocio. No se toca PUBLIC para no
    # interferir con los roles de base de datos que crean las migraciones.
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
        -c "REVOKE ALL ON DATABASE ${POSTGRES_DB} FROM ${N8N_DB_USER};"

    echo "[init] Listo: base '${N8N_DB_NAME}' con usuario '${N8N_DB_USER}', aislada de '${POSTGRES_DB}'."
)

if ! chasquipet_init_n8n; then
    echo "[init] La inicialización de la base de n8n falló. Se aborta el arranque." >&2
    exit 1
fi
unset -f chasquipet_init_n8n
