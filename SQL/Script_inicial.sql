
CREATE SCHEMA prototipo;

-- Configurar el search_path para que las tablas se creen dentro de ese esquema
-- y se busquen ahí automáticamente
SET search_path TO prototipo, public;

-- 1. Usuarios
CREATE TABLE usuarios (
    id_usuario SERIAL PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    apellido VARCHAR(50) NOT NULL,
    fecha_registro DATE DEFAULT CURRENT_DATE NOT NULL,
    activo BOOLEAN DEFAULT TRUE
);

-- 2. Contactos (RF02, RE02, RN02)
CREATE TABLE usuario_telefonos (
    id_usuario INT REFERENCES usuarios(id_usuario),
    telefono VARCHAR(20),
    PRIMARY KEY (id_usuario, telefono)
);

CREATE TABLE usuario_emails (
    id_usuario INT REFERENCES usuarios(id_usuario),
    email VARCHAR(100),
    PRIMARY KEY (id_usuario, email)
);

-- 3. Categorías (RF03, RE05, RN04)
CREATE TABLE categorias (
    id_categoria SERIAL PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    id_categoria_padre INT REFERENCES categorias(id_categoria)
    -- NOTA: La raíz tendría id_categoria_padre NULL
);

-- 4. Eventos (RF04, RE04)
CREATE TABLE eventos (
    id_evento SERIAL PRIMARY KEY,
    id_usuario_propietario INT NOT NULL REFERENCES usuarios(id_usuario),
    id_categoria INT NOT NULL REFERENCES categorias(id_categoria),
    titulo VARCHAR(100) NOT NULL,
    descripcion TEXT,
    fecha_inicio TIMESTAMP NOT NULL,
    fecha_fin TIMESTAMP NOT NULL,
    CONSTRAINT check_fechas CHECK (fecha_fin > fecha_inicio)
);

-- 5. Participación (RF05, RE01, RN01, RN05)
CREATE TABLE participaciones (
    id_evento INT REFERENCES eventos(id_evento) ON DELETE CASCADE,
    id_invitado INT REFERENCES usuarios(id_usuario),
    rol VARCHAR(50),
    estado_confirmacion VARCHAR(20) DEFAULT 'pendiente',
    PRIMARY KEY (id_evento, id_invitado)
);

-- 6. Log de Accesos (RF06)
CREATE TABLE log_accesos (
    id_log SERIAL PRIMARY KEY,
    id_usuario INT REFERENCES usuarios(id_usuario),
    fecha_acceso TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Implementación de Cálculos Dinámicos (RF07, RE03, RN03) mediante vistas

-- Vista para Antigüedad
CREATE VIEW vista_antiguedad_usuarios AS
SELECT 
    id_usuario, 
    nombre, 
    fecha_registro,
    age(CURRENT_DATE, fecha_registro) AS antiguedad
FROM usuarios;

-- Vista para Duración de eventos diarios
CREATE VIEW vista_duracion_eventos_diarios AS
SELECT 
    id_usuario_propietario,
    fecha_inicio::DATE AS dia,
    SUM(EXTRACT(EPOCH FROM (fecha_fin - fecha_inicio))/60) AS duracion_total_minutos
FROM eventos
GROUP BY id_usuario_propietario, fecha_inicio::DATE;

--Integridad y Prevención de Ciclos (RE05)
--Para evitar ciclos en la jerarquía de categorías, podemos usar una función 
--que verifique el ancestro antes de insertar o actualizar:

CREATE OR REPLACE FUNCTION evitar_ciclo_categorias()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.id_categoria_padre = NEW.id_categoria THEN
        RAISE EXCEPTION 'Una categoría no puede ser padre de sí misma.';
    END IF;
    -- Aquí se podría añadir una consulta recursiva para validar ancestros, 
    -- pero para Postgres 14 es altamente eficiente usar el camino (path) o este chequeo simple.
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_evitar_ciclo
BEFORE INSERT OR UPDATE ON categorias
FOR EACH ROW EXECUTE FUNCTION evitar_ciclo_categorias();


-- creación del módulo de gestión de ubicaciones (RF08, RE06, RN06)

--ENTIDAD UBICACIÓN (LA TABLA UBICACIONES)
create table ubicaciones ( 
    id_ubicacion serial primary key,
    nombre varchar(100) not null,
    dirección varchar(150) not null,
    ciudad varchar(30) not null,
    capacidad int not null check (capacidad > 0)
); 

-- relación entre EVENTOS y UBICACIONES
alter table eventos 
    add column id_ubicacion int not null references ubicaciones(id_ubicacion); 

-- índices para consultar por las ubicaciones y las fechas 
create index idx_eventos_ubicacion on eventos (id_ubicacion);
create index idx_eventos_fecha on eventos (id_ubicacion, fecha_inicio, fecha_fin);

-- prevención de eventos que pasan a la misma vez (traslapes)
create extension if not existis btree_gist;

alter table eventos 
    add constraint no_traslape_ubicacion
    exclude using gist (
        id_ubicacion with =,
        tsrange (fecha_inicio, fecha_fin) with &&
    );

-- historial de eventos por ubicación para tener en la agenda. 
create view vista_agenda_ubicaciones as 
select 
    u.id_ubicacion,
    u.nombre as ubicacion, 
    e.id_evento,
    e.titulo,
    e.fecha_inicio, 
    e.fecha_fin
from ubicaciones u
join eventos e on e.id_ubicacion = u.id_ubicacion
order by u.id_ubicacion, e.fecha_inicio;

-- demanda de espacios 
create view vista_ranking_ocupacion_ubicaciones as
select 
    u.id_ubicacion,
    u.nombre as ubicacion,
    u.ciudad,
    u.capacidad,
    count(e.id_evento) as total_eventos, 
    coalesce(sum(extract(epoch from (e.fecha_fin - e.fecha_inicio)) /60), 0) as minutos_totales_reservados
from ubicaciones u
left join eventos e on e.id_ubicacion = u.id_ubicacion
group by u.id_ubicacion, u.nombre, u.ciudad, u.capacidad
order by total_eventos desc, minutos_totales_reservados desc; 


-- Módulo de disponibilidad de usuarios y gestión de tiempos
-- primero es la creación del catálogo que nos dice los posibles estados que puede tener una horas (disponible, ocupado, no disponible)
create table tipo_disponibilidad (
    id_tipo serial primary key,
    nombre varchar(20) not null unique -- Aqui es UNIQUE para que no se meta el mismo dos veces
);

insert into tipo_disponibilidad (nombre) values
    ('disponible'),
    ('ocupado'),
    ('no disponible');

--la tabla de disponibilidad de usuarios para que se registre las franjas de tiempo en las que un usiario está libre 

create table disponibilidades (
    id_disponibilidad serial primary key,
    id_usuarios int not null references usuarios(id_usuario),
    id_tipo int not null references tipo_disponibilidad(id_tipo),
    fecha date not null, 
    hora_inicio time not null,
    hora_fin time not null,
    constraint check_hora_fin check (hora_fin > hora_inicio)
-- esto hace no se se puedan guardar franjas donde ya existen 
); 

create index idx_disponibilidades_usuario on disponibilidades (id_usuarios, fecha, hora_inicio, hora_fin);
create index idx_disponibilidades_usuario_rango on disponibilidades (id_usuarios, fecha, hora_inicio,hora_fin);
-- prevención de translapes dentro las franjas
create extension if not exists btree_gist;
alter table disponibilidades 
    add constraint no_traslape_disponibildad
    exclude using gist (
        id_usuarios with =,
        tsrange (hora_inicio, hora_fin) with &&
    );

create view vista_usuarios_libres as 
select 
    u.id_usuario,
    u.nombre,
    u.apellido,
    d.fecha,
    d.hora_inicio,
    d.hora_fin
from usuarios u
join disponibilidades d on d.id_usuario = u.id_usuario
join tipos_disponibilidad t on t.id_tipo = d.id_tipo
where t.nombre = 'disponible'
    and not exists (
        select 1 
        from eventos e
        left join participaciones p on p.id_evento = e.id_evento
        where (e.id_usuario_propietario = u.id_usuario or p.id_invitado = u.id_usuario)
            and tsrange (e.fecha_inicio, e.fecha_fin) &&
                tsrange (d.fecha + d.hora_inicio, d.fecha + d.hora_fin)
    );
