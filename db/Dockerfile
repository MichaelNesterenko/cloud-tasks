from gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1 as cloud-sql-proxy 

from python:3.12-alpine3.20

copy --from=cloud-sql-proxy /cloud-sql-proxy /app/
copy . /app/
run python -m venv /app/.venv && /app/.venv/bin/pip install -r /app/requirements.txt

entrypoint [ "/bin/sh", "-c", "/app/cloud-sql-proxy $1 & sleep 10 && cd /app && .venv/bin/yoyo apply -b -vv -c yoyo.ini -d mysql://$APP_DB_MIGRATION_USERNAME:$APP_DB_MIGRATION_PASSWORD@localhost/$2", "--" ]