#!/usr/bin/env python3
"""
Practica del Parcial 3 - Bases de datos distribuidas en GNS3.

El Usuario se conecta por la red (routers + OSPF) a 4 bases de datos:
    1. SQL Server  (Windows)  192.168.20.10:1433
    2. MariaDB     (Linux)    192.168.30.10:3306
    3. MongoDB     (Linux)    192.168.40.10:27017
    4. PostgreSQL  (Linux)    192.168.50.10:5432

Flujo de la practica:
    - El usuario inserta registros en cualquiera de las 4 bases.
    - La replicacion copia los registros en anillo 1 -> 2 -> 3 -> 4 -> 1
      hasta que las 4 bases tienen exactamente los mismos registros.

Uso:
    python3 practica.py               menu interactivo
    python3 practica.py estado        cuantos registros tiene cada base
    python3 practica.py insertar N "nombre"   inserta en la base N (1-4)
    python3 practica.py demo          inserta 1 registro en cada base (4 en total)
    python3 practica.py replicar      sincroniza las 4 bases en anillo
    python3 practica.py mostrar       lista los registros de cada base
    python3 practica.py limpiar       borra todos los registros de las 4 bases
"""
import sys
import uuid
from datetime import datetime

PWD = "Practica123"          # contraseña de laboratorio (SQL Server usa PWD + "!")
TIMEOUT = 5

BASES = {
    1: {"nombre": "SQL Server", "so": "Windows", "host": "192.168.20.10", "puerto": 1433},
    2: {"nombre": "MariaDB",    "so": "Linux",   "host": "192.168.30.10", "puerto": 3306},
    3: {"nombre": "MongoDB",    "so": "Linux",   "host": "192.168.40.10", "puerto": 27017},
    4: {"nombre": "PostgreSQL", "so": "Ubuntu",  "host": "192.168.50.10", "puerto": 5432},
}
ANILLO = [1, 2, 3, 4]        # orden de replicacion: 1 -> 2 -> 3 -> 4 -> 1


# ---------------------------------------------------------------- conexiones
def conectar(n):
    b = BASES[n]
    if n == 1:
        import pymssql
        return pymssql.connect(server=b["host"], port=b["puerto"], user="sa",
                               password=PWD + "!", database="practica",
                               login_timeout=TIMEOUT, autocommit=True)
    if n == 2:
        import pymysql
        return pymysql.connect(host=b["host"], port=b["puerto"], user="root",
                               password=PWD, database="practica",
                               connect_timeout=TIMEOUT, autocommit=True)
    if n == 3:
        from pymongo import MongoClient
        return MongoClient(f"mongodb://{b['host']}:{b['puerto']}",
                           serverSelectionTimeoutMS=TIMEOUT * 1000)
    if n == 4:
        import psycopg2
        c = psycopg2.connect(host=b["host"], port=b["puerto"], user="postgres",
                             password=PWD, dbname="practica", connect_timeout=TIMEOUT)
        c.autocommit = True
        return c


def preparar(n, con):
    """Crea la tabla/coleccion 'registros' si no existe."""
    if n == 3:
        return  # MongoDB crea la coleccion al insertar
    cur = con.cursor()
    if n == 1:
        cur.execute("""
            IF OBJECT_ID('dbo.registros', 'U') IS NULL
            CREATE TABLE dbo.registros (
                id      CHAR(36)     PRIMARY KEY,
                nombre  VARCHAR(100) NOT NULL,
                origen  VARCHAR(20)  NOT NULL,
                creado  DATETIME2    NOT NULL)""")
    else:
        tipo_fecha = "DATETIME" if n == 2 else "TIMESTAMP"
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS registros (
                id      CHAR(36)     PRIMARY KEY,
                nombre  VARCHAR(100) NOT NULL,
                origen  VARCHAR(20)  NOT NULL,
                creado  {tipo_fecha} NOT NULL)""")


# ------------------------------------------------------------ operaciones CRUD
def leer(n, con):
    """Devuelve {id: registro} con todos los registros de la base n."""
    if n == 3:
        docs = con["practica"]["registros"].find()
        return {d["_id"]: {"id": d["_id"], "nombre": d["nombre"],
                           "origen": d["origen"], "creado": d["creado"]} for d in docs}
    cur = con.cursor()
    cur.execute("SELECT id, nombre, origen, creado FROM registros ORDER BY creado")
    return {r[0]: {"id": r[0], "nombre": r[1], "origen": r[2], "creado": r[3]}
            for r in cur.fetchall()}


def escribir(n, con, reg):
    if n == 3:
        con["practica"]["registros"].insert_one(
            {"_id": reg["id"], "nombre": reg["nombre"],
             "origen": reg["origen"], "creado": reg["creado"]})
        return
    marca = "%s"  # pymssql, pymysql y psycopg2 usan %s
    con.cursor().execute(
        f"INSERT INTO registros (id, nombre, origen, creado) VALUES ({marca},{marca},{marca},{marca})",
        (reg["id"], reg["nombre"], reg["origen"], reg["creado"]))


def borrar_todo(n, con):
    if n == 3:
        con["practica"]["registros"].delete_many({})
    else:
        con.cursor().execute("DELETE FROM registros")


# ------------------------------------------------------------------- comandos
class Bases:
    """Abre las 4 conexiones una sola vez y las cierra al final."""
    def __enter__(self):
        self.con = {}
        for n in ANILLO:
            try:
                self.con[n] = conectar(n)
                preparar(n, self.con[n])
            except Exception as e:
                print(f"  [!] No se pudo conectar a {etiqueta(n)}: {e}")
        return self

    def __exit__(self, *_):
        for c in self.con.values():
            try:
                c.close()
            except Exception:
                pass


def etiqueta(n):
    b = BASES[n]
    return f"{n} {b['nombre']} ({b['so']}, {b['host']})"


def estado():
    with Bases() as bs:
        print("\nRegistros por base:")
        for n in ANILLO:
            if n in bs.con:
                print(f"  {etiqueta(n):45s} -> {len(leer(n, bs.con[n]))} registros")
            else:
                print(f"  {etiqueta(n):45s} -> SIN CONEXION")


def insertar(n, nombre):
    reg = {"id": str(uuid.uuid4()), "nombre": nombre,
           "origen": BASES[n]["nombre"], "creado": datetime.now().replace(microsecond=0)}
    with Bases() as bs:
        escribir(n, bs.con[n], reg)
    print(f"  + '{nombre}' insertado en {etiqueta(n)}")


def demo():
    print("\nInsertando 1 registro en cada base (4 en total)...")
    for n in ANILLO:
        insertar(n, f"Registro desde {BASES[n]['nombre']}")
    estado()


def replicar():
    """Replica en anillo 1->2->3->4->1. Dos vueltas garantizan que todas converjan."""
    with Bases() as bs:
        activos = [n for n in ANILLO if n in bs.con]
        if len(activos) < len(ANILLO):
            print("  [!] Faltan bases; se replica solo entre las disponibles.")
        datos = {n: leer(n, bs.con[n]) for n in activos}
        total = 0
        print("\nReplicando en anillo:")
        for vuelta in (1, 2):
            for i, origen in enumerate(activos):
                destino = activos[(i + 1) % len(activos)]
                faltan = [r for k, r in datos[origen].items() if k not in datos[destino]]
                for r in faltan:
                    escribir(destino, bs.con[destino], r)
                    datos[destino][r["id"]] = r
                total += len(faltan)
                if faltan or vuelta == 1:
                    print(f"  vuelta {vuelta}: {BASES[origen]['nombre']:10s} -> "
                          f"{BASES[destino]['nombre']:10s} copio {len(faltan)} registros")
        print(f"\nReplicacion terminada: {total} copias.")
        for n in activos:
            print(f"  {etiqueta(n):45s} -> {len(datos[n])} registros")


def mostrar():
    with Bases() as bs:
        for n in ANILLO:
            if n not in bs.con:
                continue
            regs = sorted(leer(n, bs.con[n]).values(), key=lambda r: str(r["creado"]))
            print(f"\n== {etiqueta(n)}: {len(regs)} registros")
            for r in regs:
                print(f"   {str(r['creado']):19s}  {r['nombre']:35s} (origen: {r['origen']})")


def limpiar():
    with Bases() as bs:
        for n, c in bs.con.items():
            borrar_todo(n, c)
            print(f"  - {etiqueta(n)} vaciada")


# ----------------------------------------------------------------------- menu
def menu():
    opciones = {
        "1": ("Ver estado (registros por base)", estado),
        "2": ("Insertar un registro en una base", None),
        "3": ("Demo: 1 registro en cada base", demo),
        "4": ("Replicar en anillo 1->2->3->4->1", replicar),
        "5": ("Mostrar registros de cada base", mostrar),
        "6": ("Limpiar las 4 bases", limpiar),
        "0": ("Salir", None),
    }
    while True:
        print("\n=== Practica Parcial 3: bases distribuidas ===")
        for k, (txt, _) in opciones.items():
            print(f"  {k}) {txt}")
        op = input("Opcion: ").strip()
        if op == "0":
            break
        if op == "2":
            n = int(input("  Base (1=SQL Server, 2=MariaDB, 3=MongoDB, 4=PostgreSQL): "))
            insertar(n, input("  Nombre del registro: ").strip() or "sin nombre")
        elif op in opciones:
            opciones[op][1]()


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        menu()
    elif args[0] == "insertar" and len(args) >= 3:
        insertar(int(args[1]), " ".join(args[2:]))
    elif args[0] in ("estado", "demo", "replicar", "mostrar", "limpiar"):
        globals()[args[0]]()
    else:
        print(__doc__)
