from python:3.12-alpine3.20

add requirements.txt service.py /app/
run python -m venv /app/.venv && /app/.venv/bin/pip install -r /app/requirements.txt

entrypoint ["/app/.venv/bin/python", "/app/service.py"]