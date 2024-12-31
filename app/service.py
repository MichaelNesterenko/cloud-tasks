from http.server import HTTPServer, BaseHTTPRequestHandler

import os

from google.cloud.sql.connector import Connector, IPTypes
import pymysql

class Server(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/plain")
        self.end_headers()
        self.wfile.write (b"database payload\n")
        with Server.getSqlConnection() as conn:
            query = conn.cursor()
            query.execute("select tst, value from app.payload")
            for row in query.fetchall():
                self.wfile.write(bytes(f"when:{row[0]} value:{row[1]}\n", "utf-8"))
            
    
    @staticmethod
    def getSqlConnection() -> pymysql.connections.Connection:
        return Server.getSqlDirectConnection() if os.environ['db_connection_type'] == 'direct' else Server.getSqlProxyConnection()

    @staticmethod
    def getSqlDirectConnection() -> pymysql.connections.Connection:
        return pymysql.connect(
            host = os.environ['db_host'],
            user = os.environ['db_user'],
            password = os.environ['db_pass'],
            db = os.environ['db_name']
        )

    @staticmethod
    def getSqlProxyConnection() -> pymysql.connections.Connection:
        return Connector().connect(
            instance_connection_string = os.environ['db_host'],
            driver = "pymysql",
            user = os.environ['db_user'],
            db = os.environ['db_name'],
            enable_iam_auth = True,
            ip_type = IPTypes.PRIVATE,
        )


if __name__ == "__main__":
    ws = HTTPServer(("0.0.0.0", 8080), Server)
    try:
        ws.serve_forever()
    except KeyboardInterrupt:
        pass
    ws.server_close()
