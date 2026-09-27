# Guía: Prisma y Docker en esta API

Explicación de cómo funcionan Prisma (migraciones, shadow database, configuración) y Docker (build, ejecución, Compose) aplicados a esta API de tareas.

## Índice

- [Prisma](#prisma)
  - [1. Cómo funcionan las migraciones](#1-cómo-funcionan-las-migraciones)
  - [2. Shadow database](#2-shadow-database)
  - [3. Extensiones y configuraciones aplicadas](#3-extensiones-y-configuraciones-aplicadas)
- [Docker](#docker)
  - [4. Build de la imagen](#4-build-de-la-imagen)
  - [5. Ejecutar un contenedor y mapear puertos](#5-ejecutar-un-contenedor-y-mapear-puertos)
  - [6. Base de datos en otro contenedor con Docker Compose](#6-base-de-datos-en-otro-contenedor-con-docker-compose)

---

# Prisma

## 1. Cómo funcionan las migraciones

### La idea

Hay dos fuentes de información que pueden no coincidir:

- **Lo que querés tener:** `prisma/schema.prisma`.
- **Lo que la base ya tiene:** el historial de migraciones aplicadas.

Una migración es **el SQL que lleva la base de un estado al siguiente**, guardado en un archivo y versionado en Git.

### Qué pasa al ejecutar `prisma migrate dev --name init`

1. **Lee la configuración.** Toma `prisma7.config.ts`, que carga `.env` y le da la URL de la base, la ruta del schema y la carpeta de migraciones.
2. **Reconstruye el estado actual.** Aplica todas las migraciones existentes en `prisma/migrations/` sobre una **shadow database**. Si no hay ninguna, el estado actual es "vacío".
3. **Compara.** Calcula la diferencia entre ese estado y `schema.prisma`; por ejemplo, ve que falta la tabla `tasks`.
4. **Genera el SQL.** Crea este archivo:

   ```
   prisma/migrations/
   ├── 20260928120000_init/
   │   └── migration.sql
   └── migration_lock.toml      ← indica el motor (postgresql); evita mezclar motores
   ```

   Con este contenido, derivado del modelo `Task`:

   ```sql
   CREATE TABLE "tasks" (
       "id" SERIAL NOT NULL,
       "title" TEXT NOT NULL,
       "description" TEXT,
       "completed" BOOLEAN NOT NULL DEFAULT false,
       "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
       "updatedAt" TIMESTAMP(3) NOT NULL,
       CONSTRAINT "tasks_pkey" PRIMARY KEY ("id")
   );
   ```

5. **Aplica el SQL** en la base de desarrollo.
6. **Lo registra** en una tabla que Prisma crea en la base, `_prisma_migrations`:

   | migration_name      | checksum  | finished_at      | ... |
   | ------------------- | --------- | ---------------- | --- |
   | 20260928120000_init | a1b2c3... | 2026-09-28 12:00 |     |

   El `checksum` es un hash del archivo SQL. Si alguien edita una migración que ya se aplicó, Prisma lo detecta.

> En **Prisma 7**, `migrate dev` ya no ejecuta `prisma generate` automáticamente. Si cambiás el schema, tenés que regenerar el cliente vos, con `npm run prisma:generate`.

### `updatedAt` no lo maneja la base

En el SQL, `updatedAt` no tiene `DEFAULT` ni un trigger. El atributo `@updatedAt` hace que **el cliente de Prisma** complete la fecha en cada `update()`. Si se modifica la tabla con SQL directo, ese campo no se actualiza.

### `migrate dev` y `migrate deploy`

|                       | `migrate dev`                                        | `migrate deploy`                                               |
| --------------------- | ---------------------------------------------------- | -------------------------------------------------------------- |
| Entorno               | Tu máquina                                           | CI/CD o producción                                             |
| ¿Genera SQL nuevo?    | Sí                                                   | **Nunca**                                                      |
| ¿Usa shadow database? | Sí                                                   | No                                                             |
| ¿Detecta drift?       | Sí, y puede ofrecer **borrar la base**               | No                                                             |
| Qué hace              | Compara, genera y aplica                             | Aplica las migraciones pendientes según `_prisma_migrations`   |

**Drift** significa que la base tiene cambios que no están en ninguna migración, por ejemplo si alguien creó una columna a mano. En desarrollo, `migrate dev` ofrece hacer un reset. Por eso **nunca se ejecuta `migrate dev` contra producción**.

### El ciclo completo

```
tu máquina:  cambiás schema.prisma → migrate dev → se genera migration.sql → commit
pipeline:    npm ci → build → migrate deploy (aplica lo pendiente) → arranca la app
```

Otros comandos útiles:

- `prisma migrate status`: muestra qué migraciones están aplicadas y cuáles faltan.
- `prisma migrate reset`: borra la base, reaplica todas las migraciones y corre el seed. Es solo para desarrollo.
- `prisma db push`: sincroniza el schema **sin crear migraciones**. Sirve para prototipar, no para un proyecto con despliegues.

Scripts disponibles en `package.json`:

| Script                            | Comando                 |
| --------------------------------- | ----------------------- |
| `npm run prisma:generate`         | `prisma generate`       |
| `npm run prisma:migrate:dev`      | `prisma migrate dev`    |
| `npm run prisma:migrate:deploy`   | `prisma migrate deploy` |
| `postinstall` (automático)        | `prisma generate`       |

---

## 2. Shadow database

Es una **base temporal** que `migrate dev` crea, usa y borra en cada ejecución.

**Para qué sirve:** Prisma necesita saber cómo queda la base después de aplicar todas las migraciones existentes. No puede confiar en la base de desarrollo, porque podría tener drift. Entonces:

```
1. CREATE DATABASE prisma_migrate_shadow_db_xxxx
2. Aplica ahí todas las migraciones, de la primera a la última
3. Compara ese resultado con: a) schema.prisma      → genera la nueva migración
                              b) la base de desarrollo → detecta drift
4. DROP DATABASE prisma_migrate_shadow_db_xxxx
```

Además, así se verifica que las migraciones **se pueden reproducir desde cero**, que es exactamente lo que va a pasar en una base nueva de producción.

**Requisito:** el usuario de la base necesita permiso para `CREATE DATABASE`.

- Con un Postgres en Docker, el usuario `postgres` es superusuario, así que funciona sin configurar nada.
- En bases gestionadas en la nube, sin ese permiso, se crea una base vacía aparte y se indica en `prisma7.config.ts`:

  ```ts
  datasource: {
    url: process.env.DATABASE_URL,
    shadowDatabaseUrl: process.env.SHADOW_DATABASE_URL,
  }
  ```

**Solo la usa `migrate dev`.** `migrate deploy` no la necesita, así que no hace falta configurarla en producción.

---

## 3. Extensiones y configuraciones aplicadas

"Extensiones" puede significar dos cosas, y **esta app no usa ninguna de las dos**:

- **Client Extensions** (`prisma.$extends(...)`): permiten agregar al cliente métodos propios, campos calculados o middleware en las queries, por ejemplo soft delete o logs.
- **Extensiones de PostgreSQL** (`uuid-ossp`, `pgvector`, etc.): se declaran en el schema con `extensions = [...]`.

Esto es lo que **sí** está configurado:

### `schema.prisma`: generator

```prisma
generator client {
  provider            = "prisma-client"
  output              = "../src/generated/prisma"
  moduleFormat        = "cjs"
  importFileExtension = "js"
}
```

| Opción                       | Qué hace                                                                                | Por qué está así                                                                                                                                                                 |
| ---------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `provider = "prisma-client"` | Usa el generador nuevo de Prisma 7, que produce **archivos TypeScript** dentro del proyecto | El generador anterior (`prisma-client-js`) generaba JavaScript dentro de `node_modules/.prisma`.                                                                                  |
| `output`                     | Indica dónde se genera el cliente                                                        | Dentro de `src/`, para que `nest build` lo compile a `dist/` junto con el resto del código. Si queda fuera de `src/`, la estructura de `dist/` cambia y `start:prod` deja de funcionar. |
| `moduleFormat = "cjs"`       | Genera `require` y no `import`                                                           | NestJS compila a CommonJS. Si se mezclan formatos, la app no arranca.                                                                                                             |
| `importFileExtension = "js"` | Hace que los imports internos terminen en `.js`                                          | Sin esta opción, Prisma deduce la extensión desde `tsconfig.json`. En Docker, `tsconfig.json` todavía no existe cuando corre `prisma generate`, así que generaba imports `.ts` y la app fallaba. |

El cliente generado (`src/generated/prisma/`) **no se versiona**: está en `.gitignore` y se regenera en cada `npm install` gracias al script `postinstall`.

### `schema.prisma`: datasource y modelo

```prisma
datasource db { provider = "postgresql" }   // la URL no va acá en Prisma 7
model Task { ... @@map("tasks") }            // tabla "tasks" en la base, modelo "Task" en el código
```

### `prisma7.config.ts`: configuración del **CLI**

Lo usan `migrate`, `generate` y `studio`. **La app en ejecución no lo usa.** Define la URL de la base (que toma de `.env` con `dotenv`), la ruta del schema y la carpeta de migraciones.

### Driver adapter: configuración del **runtime**

```ts
new PrismaClient({ adapter: new PrismaPg({ connectionString: process.env.DATABASE_URL }) })
```

Las versiones anteriores de Prisma incluían un **binario en Rust** (el "query engine") que hacía de intermediario con la base. Prisma 7 lo eliminó: el cliente arma el SQL en JavaScript y lo envía a través de un **driver nativo de Node**, en este caso `pg`, usando el adaptador `@prisma/adapter-pg`. Por eso la imagen de Docker no necesita binarios específicos de cada plataforma.

Hay **dos lugares que leen `DATABASE_URL`**: el CLI a través de `prisma7.config.ts` y la app a través de `PrismaService`. Los dos toman la misma variable de entorno.

---

# Docker

## 4. Build de la imagen

### Imagen y contenedor

- **Imagen:** una plantilla de solo lectura. Contiene el sistema de archivos, las dependencias y el comando de arranque. Es como una **clase**.
- **Contenedor:** una instancia de la imagen en ejecución, con su propio proceso, red y capa escribible. Es como un **objeto**. De una misma imagen se pueden levantar muchos contenedores.

### `docker build -t tasks-api .`

- `.` es el **contexto de build**: la carpeta que se envía al motor de Docker. Todo lo que **no** está excluido en `.dockerignore` se envía, por eso ese archivo importa.
- `-t tasks-api` le pone un nombre a la imagen. Se le puede agregar una versión, por ejemplo `tasks-api:1.0.0`. Si no se indica, se usa `:latest`.

### `.dockerignore`

Sin este archivo, `COPY . .` metería en la imagen `node_modules` y `dist` locales, el `.env` con secretos y la carpeta `.git`. En este proyecto excluye todo eso, además de las skills de IA, los tests y el README. Solo se mantiene `.env.example`.

### Capas y caché

Cada instrucción (`FROM`, `COPY`, `RUN`) crea una **capa**. Docker reutiliza una capa si ni esa instrucción ni los archivos que usa cambiaron, y en cuanto una capa cambia, se reconstruyen todas las siguientes. Por eso el Dockerfile está ordenado así:

```dockerfile
COPY package*.json prisma7.config.ts ./   # cambia poco
COPY prisma ./prisma
RUN npm ci                                # lento, pero queda en caché si lo anterior no cambió
COPY . .                                  # cambia en cada edición de código
RUN npm run build                         # solo se reconstruye desde acá
```

Si solo se toca un controller, `npm ci` no se vuelve a ejecutar.

### Multi-stage build

```
┌─ builder ───────────────────────┐      ┌─ runner (imagen final) ───────┐
│ node + TODAS las dependencias   │      │ node + solo dependencias prod │
│ código fuente TS                │ ───► │ dist/  (copiado del builder)  │
│ prisma CLI, typescript, nest... │ dist │ USER node                     │
│ → npm run build                 │      │ CMD node dist/main            │
└─────────────────────────────────┘      └───────────────────────────────┘
       se descarta                               es lo que se publica
```

- **`builder`:** instala todas las dependencias (el `postinstall` genera el cliente de Prisma) y compila a `dist/`.
- **`runner`:** instala solo dependencias de producción con `npm ci --omit=dev --ignore-scripts`. `--ignore-scripts` evita el `postinstall`, que fallaría porque `prisma` es una dependencia de desarrollo; no hace falta, porque el cliente ya viene compilado dentro de `dist/`. Corre como el usuario `node`, sin privilegios de root.

La imagen final no incluye el código TypeScript, el compilador ni el CLI de Prisma. Es más chica y más segura.

Comandos útiles:

```bash
docker images                  # listar imágenes
docker history tasks-api       # ver las capas y su tamaño
```

---

## 5. Ejecutar un contenedor y mapear puertos

```bash
docker run -d --name api -p 8080:3000 --env-file .env tasks-api
```

| Flag                               | Qué hace                                                |
| ---------------------------------- | ------------------------------------------------------- |
| `-d`                               | Lo ejecuta en segundo plano (*detached*)                |
| `--name api`                       | Le da un nombre, para no usar el ID                     |
| `-p 8080:3000`                     | Mapea **`puerto_de_tu_máquina:puerto_del_contenedor`** |
| `-e VAR=valor` / `--env-file .env` | Inyecta variables de entorno al arrancar                |
| `--rm`                             | Borra el contenedor cuando se detiene                   |

Las variables de entorno se pasan al ejecutar el contenedor. **Nunca van dentro de la imagen.**

### Cómo funciona el mapeo de puertos

El contenedor tiene **su propia red aislada**. La app de NestJS escucha en el puerto 3000 **dentro** del contenedor. Desde la máquina host no se puede acceder, salvo que se publique:

```
navegador → localhost:8080 ──(-p 8080:3000)──► contenedor:3000 → NestJS
```

- Con `-p 8080:3000` se entra por `http://localhost:8080/docs`.
- `EXPOSE 3000` en el Dockerfile **no publica nada**. Solo documenta en qué puerto escucha la app. Lo que abre el puerto es `-p`.

### `localhost` dentro de un contenedor

Dentro de un contenedor, `localhost` es **el propio contenedor**, no la máquina host. Si se le pasa el `.env` local:

```
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/tasks_db
```

la app va a buscar un Postgres **dentro de su propio contenedor**, donde no hay ninguno. Esto se resuelve con Docker Compose, en la sección siguiente.

Comandos útiles:

```bash
docker ps                  # contenedores en ejecución
docker logs -f api         # ver los logs en vivo
docker exec -it api sh     # abrir una terminal dentro del contenedor
docker stop api && docker rm api
```

---

## 6. Base de datos en otro contenedor con Docker Compose

### El concepto

Compose levanta **varios contenedores** desde un archivo, y los conecta a una **red compartida** en la que **cada servicio es accesible por su nombre**. Si el servicio se llama `db`, la app se conecta a `db:5432`.

### Ejemplo de `docker-compose.yml` para esta app

```yaml
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: tasks_db
    ports:
      - "5432:5432"                     # opcional: para acceder desde la máquina host
    volumes:
      - pgdata:/var/lib/postgresql/data # para que los datos persistan
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d tasks_db"]
      interval: 5s
      timeout: 3s
      retries: 10

  migrate:
    build:
      context: .
      target: builder                   # usa la etapa que SÍ tiene el CLI de Prisma
    command: npx prisma migrate deploy
    environment:
      DATABASE_URL: postgresql://postgres:postgres@db:5432/tasks_db
    depends_on:
      db:
        condition: service_healthy

  api:
    build: .                            # por defecto usa la última etapa (runner)
    ports:
      - "3000:3000"
    environment:
      PORT: 3000
      DATABASE_URL: postgresql://postgres:postgres@db:5432/tasks_db
    depends_on:
      migrate:
        condition: service_completed_successfully

volumes:
  pgdata:
```

### Cada parte

**`db`**

- Usa la imagen oficial de Postgres. Las variables `POSTGRES_*` crean el usuario y la base la primera vez que arranca.
- **Volumen `pgdata`:** el sistema de archivos de un contenedor se pierde cuando se borra el contenedor. El volumen guarda los datos fuera de él, así que sobreviven a `docker compose down`. Solo `docker compose down -v` los borra.
- **`healthcheck`:** que el contenedor esté iniciado no significa que Postgres ya acepte conexiones. `pg_isready` lo comprueba.

**`migrate`**

- La imagen final no tiene el CLI de Prisma. Este servicio usa la etapa `builder` del mismo Dockerfile (`target: builder`), que sí lo tiene, y corre `migrate deploy`.
- Se ejecuta **una vez y termina**. Solo arranca cuando la base está sana (`service_healthy`).

**`api`**

- Arranca solo si las migraciones terminaron bien (`service_completed_successfully`). El orden queda así:

  ```
  db (healthy) → migrate (exit 0) → api
  ```

- **`DATABASE_URL` usa `db` como host, no `localhost`.** Ese es el nombre del servicio en la red de Compose.

### Dos URLs según desde dónde te conectes

| Desde                                            | Host                                      | URL                                                      |
| ------------------------------------------------ | ----------------------------------------- | -------------------------------------------------------- |
| Otro contenedor (`api`, `migrate`)               | `db`                                      | `postgresql://postgres:postgres@db:5432/tasks_db`        |
| La máquina host (`npm run start:dev`, `migrate dev`) | `localhost`, gracias a `ports: 5432:5432` | `postgresql://postgres:postgres@localhost:5432/tasks_db` |

El `.env` local coincide con la segunda fila. Por eso las variables de los contenedores van en el propio `docker-compose.yml` y no toman ese archivo.

### Flujo de trabajo

```bash
# 1. Levantar solo la base
docker compose up -d db

# 2. Crear la primera migración desde la máquina host (usa .env → localhost:5432)
npm run prisma:migrate:dev -- --name init
#    → genera prisma/migrations/..._init/migration.sql (esto se commitea)

# 3. Levantar todo: base → migraciones → API
docker compose up --build

# 4. Probar
#    http://localhost:3000/docs

# 5. Apagar (conservando los datos) / apagar y borrar los datos
docker compose down
docker compose down -v
```

El paso 2 se hace **desde la máquina host y no con Compose**. `migrate dev` es la herramienta de desarrollo que **genera** migraciones y usa la shadow database. El servicio `migrate` de Compose solo corre `migrate deploy`, que **aplica** las migraciones ya generadas, igual que en producción.
