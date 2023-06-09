# Dockerfile
FROM python:3.8-slim-buster

WORKDIR /app

RUN apt-get update && apt-get install -y git

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY ./app/main.py .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
