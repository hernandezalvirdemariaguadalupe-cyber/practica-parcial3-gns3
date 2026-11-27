"""Prueba de conexion a las 4 bases de la Practica del Parcial 3."""
PWD = "Practica123"

def probar(nombre, fn):
    try:
        print(f"OK    {nombre}: {fn()}")
    except Exception as e:
        print(f"FALLA {nombre}: {e}")

def sqlserver():
    import pymssql
    with pymssql.connect(server="192.168.20.10", port=1433, user="sa",
                         password=PWD + "!", database="practica", login_timeout=5) as c:
        cur = c.cursor(); cur.execute("SELECT @@VERSION")
        return cur.fetchone()[0].split("\n")[0]

def mariadb():
    import pymysql
    c = pymysql.connect(host="192.168.30.10", user="root", password=PWD,
                        database="practica", connect_timeout=5)
    with c.cursor() as cur:
        cur.execute("SELECT VERSION()")
        return "MariaDB " + cur.fetchone()[0]

def mongodb():
    from pymongo import MongoClient
    cli = MongoClient("mongodb://192.168.40.10:27017", serverSelectionTimeoutMS=5000)
    return "MongoDB " + cli.server_info()["version"]

def postgres():
    import psycopg2
    with psycopg2.connect(host="192.168.50.10", user="postgres", password=PWD,
                          dbname="practica", connect_timeout=5) as c:
        cur = c.cursor(); cur.execute("SHOW server_version")
        return "PostgreSQL " + cur.fetchone()[0]

probar("1 SQL Server (Windows) ", sqlserver)
probar("2 MariaDB    (Linux)   ", mariadb)
probar("3 MongoDB    (Linux)   ", mongodb)
probar("4 PostgreSQL (Linux)   ", postgres)
