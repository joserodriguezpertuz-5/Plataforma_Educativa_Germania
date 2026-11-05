-- =====================================================================
--  SENA - Plataforma web para institución educativa rural
--  Base de datos: colegio_rural  (MariaDB 10.5+ / MySQL 8.0.16+)
--  Versión: 2.1 (provisional, corrige y endurece la v2.0)
--
--  CAMBIOS RESPECTO A v2.0
--   [1] alerta: las FK id_usuario_creador / id_usuario_atiende usan ON UPDATE RESTRICT.
--       Con ON UPDATE CASCADE el CREATE TABLE fallaba (MySQL 8: error 3823,
--       MariaDB: error 1901) porque esas columnas se usan en un CHECK.
--   [2] calificacion: trg_calificacion_bu ya no permite cambiar estudiante, asignacion ni periodo.
--   [3] v_inasistencia_periodo: si falta 'peso_retraso' usa 0.5 (antes la vista quedaba vacía).
--   [4] asistencia: la fecha debe coincidir con el día de la semana del horario y caer dentro
--       de un periodo del año del curso; las validaciones también corren en UPDATE.
--   [5] periodo: no se permiten periodos con fechas solapadas dentro del mismo año lectivo.
--   [6] usuario/estudiante/profesor/acudiente: el rol del usuario debe corresponder a la tabla
--       a la que se vincula, y el documento del acudiente debe coincidir con el de su usuario.
--   [7] estudiante_acudiente: máximo un acudiente principal por estudiante.
--       horario: sin cruces de profesor ni de curso en el mismo año lectivo.
--   [8] periodo_auditoria: ahora la escribe un trigger al cambiar periodo.estado
--       (ver CONTRATO CON EL BACKEND más abajo).
--   [9] asistencia: índice (id_horario, fecha) para listar una clase por día.
--   [10] alerta: no se duplican alertas automáticas pendientes iguales.
--   [11] SET NAMES utf8mb4 al inicio (evita tildes rotas al importar).
--
--  CONTRATO CON EL BACKEND (cambio de comportamiento, leer antes de integrar)
--   Para cerrar o reabrir un periodo el backend debe, en la MISMA conexión y transacción:
--       SET @id_usuario_actual = <id del usuario que autoriza>;
--       SET @justificacion_periodo = '<motivo>';
--       UPDATE periodo SET estado = 'cerrado' WHERE id_periodo = ?;
--   El trigger valida las dos variables y escribe periodo_auditoria. El backend YA NO
--   debe insertar en periodo_auditoria (se duplicaría el registro).
--
--  NO CAMBIADO (pendiente de validar con el colegio): escala de notas 0.0-5.0 con un decimal.
--
--  Convenciones:
--   * Todas las llaves foráneas: ON DELETE RESTRICT ON UPDATE CASCADE
--     (excepto las dos de alerta indicadas en [1]).
--   * Comentarios "SUPUESTO:" = decisión tomada donde el proyecto NO DEFINE la regla.
--   * Los triggers y procedimientos requieren DELIMITER; si importas con phpMyAdmin (XAMPP)
--     usa la pestaña "Importar" y el script funciona tal cual.
--   * Sin tildes ni eñes en identificadores ni valores ENUM.
-- =====================================================================

SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS colegio_rural
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE colegio_rural;

SET FOREIGN_KEY_CHECKS = 0;
DROP VIEW  IF EXISTS v_inasistencia_periodo;
DROP TABLE IF EXISTS alerta, registro_acceso, asistencia, calificacion_auditoria, calificacion,
                     horario, matricula, asignacion, materia, curso, periodo_auditoria, periodo,
                     anio_lectivo, estudiante_acudiente, acudiente, profesor, estudiante, sede,
                     usuario, rol, parametro_sistema;
SET FOREIGN_KEY_CHECKS = 1;

DROP PROCEDURE IF EXISTS sp_validar_periodo;
DROP PROCEDURE IF EXISTS sp_validar_horario;
DROP PROCEDURE IF EXISTS sp_validar_asistencia;
DROP PROCEDURE IF EXISTS sp_validar_rol_usuario;
DROP PROCEDURE IF EXISTS sp_validar_acudiente;
DROP PROCEDURE IF EXISTS sp_validar_principal;

-- ---------------------------------------------------------------------
-- 1. SEGURIDAD Y USUARIOS
-- ---------------------------------------------------------------------

-- Catálogo de roles (reemplaza el ENUM: agregar un rol es un INSERT, no un ALTER)
CREATE TABLE rol (
  id_rol      TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  codigo      VARCHAR(30)  NOT NULL,
  nombre      VARCHAR(60)  NOT NULL,
  descripcion VARCHAR(200) NULL,
  PRIMARY KEY (id_rol),
  UNIQUE KEY uq_rol_codigo (codigo)
) ENGINE=InnoDB;

CREATE TABLE usuario (
  id_usuario      INT NOT NULL AUTO_INCREMENT,
  id_rol          TINYINT UNSIGNED NOT NULL,
  tipo_documento  ENUM('RC','TI','CC','CE','PEP','PPT','NUIP','otro') NOT NULL,
  documento       VARCHAR(20)  NOT NULL,
  nombre          VARCHAR(100) NOT NULL,
  apellido        VARCHAR(100) NOT NULL,
  email           VARCHAR(150) NULL,                 -- NULL permitido: muchos estudiantes rurales no tienen correo
  contrasena      VARCHAR(255) NOT NULL,             -- hash bcrypt/Argon2, nunca texto plano
  telefono        VARCHAR(15)  NULL,
  fecha_creacion  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  estado          ENUM('activo','inactivo') NOT NULL DEFAULT 'activo',   -- borrado lógico
  PRIMARY KEY (id_usuario),
  UNIQUE KEY uq_usuario_documento (tipo_documento, documento),           -- RF-01: validación de duplicados (Tipo + Número)
  UNIQUE KEY uq_usuario_email (email),                                   -- MySQL/MariaDB permiten varios NULL en UNIQUE
  CONSTRAINT fk_usuario_rol FOREIGN KEY (id_rol) REFERENCES rol (id_rol)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- Parámetros configurables (los umbrales NO se quedan escritos en el código)
CREATE TABLE parametro_sistema (
  clave       VARCHAR(50)  NOT NULL,
  valor       VARCHAR(100) NOT NULL,
  descripcion VARCHAR(200) NULL,
  PRIMARY KEY (clave)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. ESTRUCTURA INSTITUCIONAL
-- ---------------------------------------------------------------------

CREATE TABLE sede (
  id_sede      SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  nombre       VARCHAR(100) NOT NULL,
  codigo_dane  VARCHAR(15)  NULL,
  direccion    VARCHAR(200) NULL,
  es_principal BOOLEAN      NOT NULL DEFAULT FALSE,
  estado       ENUM('activa','inactiva') NOT NULL DEFAULT 'activa',
  PRIMARY KEY (id_sede),
  UNIQUE KEY uq_sede_nombre (nombre)
) ENGINE=InnoDB;

CREATE TABLE anio_lectivo (
  id_anio      SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  anio         SMALLINT UNSIGNED NOT NULL,
  fecha_inicio DATE NOT NULL,
  fecha_fin    DATE NOT NULL,
  estado       ENUM('activo','cerrado') NOT NULL DEFAULT 'activo',
  PRIMARY KEY (id_anio),
  UNIQUE KEY uq_anio (anio),
  CONSTRAINT ck_anio_fechas CHECK (fecha_fin > fecha_inicio)
) ENGINE=InnoDB;

-- SUPUESTO: de 1 a 4 periodos por año (el modelo v1 ya lo asumía); validar con el colegio.
-- Los solapes de fechas dentro de un mismo año se bloquean con trg_periodo_bi / trg_periodo_bu.
CREATE TABLE periodo (
  id_periodo   INT NOT NULL AUTO_INCREMENT,
  id_anio      SMALLINT UNSIGNED NOT NULL,
  numero       TINYINT UNSIGNED NOT NULL,
  fecha_inicio DATE NOT NULL,
  fecha_fin    DATE NOT NULL,
  estado       ENUM('abierto','cerrado') NOT NULL DEFAULT 'abierto',   -- RF-04: cierre/reapertura
  PRIMARY KEY (id_periodo),
  UNIQUE KEY uq_periodo (id_anio, numero),
  CONSTRAINT ck_periodo_numero CHECK (numero BETWEEN 1 AND 4),
  CONSTRAINT ck_periodo_fechas CHECK (fecha_fin > fecha_inicio),
  CONSTRAINT fk_periodo_anio FOREIGN KEY (id_anio) REFERENCES anio_lectivo (id_anio)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- Bitácora de cierre/reapertura de periodos (RF-04).
-- v2.1: la escribe el trigger trg_periodo_au; el backend NO debe insertar aquí.
CREATE TABLE periodo_auditoria (
  id_auditoria  BIGINT NOT NULL AUTO_INCREMENT,
  id_periodo    INT NOT NULL,
  id_usuario    INT NOT NULL,
  accion        ENUM('cierre','reapertura') NOT NULL,
  justificacion VARCHAR(255) NOT NULL,
  fecha_hora    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id_auditoria),
  CONSTRAINT fk_peraud_periodo FOREIGN KEY (id_periodo) REFERENCES periodo (id_periodo)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_peraud_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- SUPUESTO: un curso pertenece a UNA sede y a UN año lectivo (así "6°A" 2026 y "6°A" 2027 son filas distintas).
-- grado: 0 = Transición, 1..11 = grados. 'nombre' se conserva por si hay grupos multigrado.
CREATE TABLE curso (
  id_curso INT NOT NULL AUTO_INCREMENT,
  id_sede  SMALLINT UNSIGNED NOT NULL,
  id_anio  SMALLINT UNSIGNED NOT NULL,
  nombre   VARCHAR(50) NOT NULL,
  grado    TINYINT UNSIGNED NOT NULL,
  jornada  ENUM('manana','tarde','unica') NOT NULL,
  PRIMARY KEY (id_curso),
  UNIQUE KEY uq_curso_nombre (id_sede, id_anio, nombre),
  UNIQUE KEY uq_curso_anio (id_curso, id_anio),            -- permite la FK compuesta desde matricula
  CONSTRAINT ck_curso_grado CHECK (grado BETWEEN 0 AND 11),
  CONSTRAINT fk_curso_sede FOREIGN KEY (id_sede) REFERENCES sede (id_sede)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_curso_anio FOREIGN KEY (id_anio) REFERENCES anio_lectivo (id_anio)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE materia (
  id_materia INT NOT NULL AUTO_INCREMENT,
  nombre     VARCHAR(100) NOT NULL,
  PRIMARY KEY (id_materia),
  UNIQUE KEY uq_materia_nombre (nombre)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. PERSONAS (extienden a USUARIO)
-- ---------------------------------------------------------------------

CREATE TABLE estudiante (
  id_estudiante    INT NOT NULL AUTO_INCREMENT,
  id_usuario       INT NOT NULL,
  direccion        VARCHAR(200) NULL,
  fecha_nacimiento DATE NOT NULL,
  PRIMARY KEY (id_estudiante),
  UNIQUE KEY uq_estudiante_usuario (id_usuario),
  CONSTRAINT fk_estudiante_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE profesor (
  id_profesor  INT NOT NULL AUTO_INCREMENT,
  id_usuario   INT NOT NULL,
  especialidad VARCHAR(100) NOT NULL,
  PRIMARY KEY (id_profesor),
  UNIQUE KEY uq_profesor_usuario (id_usuario),
  CONSTRAINT fk_profesor_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- El acudiente es una persona propia (no un campo de texto del estudiante).
-- id_usuario es opcional: solo lo tiene si se le crea acceso de consulta.
-- Si tiene id_usuario, tipo_documento y documento deben coincidir con los del usuario (trigger).
CREATE TABLE acudiente (
  id_acudiente   INT NOT NULL AUTO_INCREMENT,
  id_usuario     INT NULL,
  tipo_documento ENUM('CC','CE','PEP','PPT','TI','otro') NOT NULL,
  documento      VARCHAR(20)  NOT NULL,
  nombre         VARCHAR(100) NOT NULL,
  apellido       VARCHAR(100) NOT NULL,
  telefono       VARCHAR(15)  NOT NULL,
  email          VARCHAR(150) NULL,
  direccion      VARCHAR(200) NULL,
  PRIMARY KEY (id_acudiente),
  UNIQUE KEY uq_acudiente_documento (tipo_documento, documento),
  UNIQUE KEY uq_acudiente_usuario (id_usuario),
  CONSTRAINT fk_acudiente_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- SUPUESTO: un estudiante puede tener varios acudientes y un acudiente varios estudiantes (hermanos).
-- Regla en BD: máximo UN acudiente con es_principal = TRUE por estudiante (trigger).
-- Regla de aplicación: cada estudiante debe tener AL MENOS uno principal (la BD no puede forzarlo).
CREATE TABLE estudiante_acudiente (
  id_estudiante INT NOT NULL,
  id_acudiente  INT NOT NULL,
  parentesco    ENUM('madre','padre','abuelo_a','tio_a','hermano_a','tutor_legal','otro') NOT NULL,
  es_principal  BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (id_estudiante, id_acudiente),
  CONSTRAINT fk_ea_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiante (id_estudiante)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_ea_acudiente FOREIGN KEY (id_acudiente) REFERENCES acudiente (id_acudiente)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4. ACADÉMICO
-- ---------------------------------------------------------------------

-- Un profesor puede dictar varias materias en varios cursos (muchas filas por profesor).
-- SUPUESTO: una misma materia en un mismo curso la dicta UN solo profesor (UNIQUE materia+curso).
-- Si pueden compartirla, cambiar a UNIQUE (id_profesor, id_materia, id_curso).
CREATE TABLE asignacion (
  id_asignacion INT NOT NULL AUTO_INCREMENT,
  id_profesor   INT NOT NULL,
  id_materia    INT NOT NULL,
  id_curso      INT NOT NULL,
  PRIMARY KEY (id_asignacion),
  UNIQUE KEY uq_asignacion (id_materia, id_curso),
  CONSTRAINT fk_asig_profesor FOREIGN KEY (id_profesor) REFERENCES profesor (id_profesor)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_asig_materia FOREIGN KEY (id_materia) REFERENCES materia (id_materia)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_asig_curso FOREIGN KEY (id_curso) REFERENCES curso (id_curso)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- SUPUESTO: un estudiante tiene UNA matrícula por año lectivo (cambiar de curso = actualizar id_curso).
-- id_anio se repite aquí a propósito: la FK compuesta (id_curso, id_anio) garantiza que
-- el año de la matrícula coincide con el año del curso.
-- Data-Light: no se guardan archivos; solo el indicador de documentación física entregada.
CREATE TABLE matricula (
  id_matricula  INT NOT NULL AUTO_INCREMENT,
  id_estudiante INT NOT NULL,
  id_curso      INT NOT NULL,
  id_anio       SMALLINT UNSIGNED NOT NULL,
  fecha         DATE NOT NULL,
  estado        ENUM('activa','retirada','finalizada') NOT NULL DEFAULT 'activa',
  documentacion_fisica_entregada BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (id_matricula),
  UNIQUE KEY uq_matricula_anio (id_estudiante, id_anio),
  CONSTRAINT fk_mat_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiante (id_estudiante)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_mat_curso_anio FOREIGN KEY (id_curso, id_anio) REFERENCES curso (id_curso, id_anio)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- SUPUESTO (v2.1): en un mismo año lectivo un profesor no puede estar en dos clases a la misma
-- hora, ni un curso tener dos clases a la misma hora (trg_horario_bi / trg_horario_bu).
-- El proyecto no define choques de aula; si hace falta, se agrega aparte.
CREATE TABLE horario (
  id_horario    INT NOT NULL AUTO_INCREMENT,
  id_asignacion INT NOT NULL,
  dia_semana    ENUM('lunes','martes','miercoles','jueves','viernes') NOT NULL,
  hora_inicio   TIME NOT NULL,
  hora_fin      TIME NOT NULL,
  aula          VARCHAR(20) NULL,
  PRIMARY KEY (id_horario),
  UNIQUE KEY uq_horario (id_asignacion, dia_semana, hora_inicio),
  CONSTRAINT ck_horario_horas CHECK (hora_fin > hora_inicio),
  CONSTRAINT fk_horario_asig FOREIGN KEY (id_asignacion) REFERENCES asignacion (id_asignacion)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- SUPUESTO: escala 0.0 a 5.0 con un decimal (la del modelo v1); validar con el SIEE del colegio.
CREATE TABLE calificacion (
  id_calificacion     INT NOT NULL AUTO_INCREMENT,
  id_estudiante       INT NOT NULL,
  id_asignacion       INT NOT NULL,
  id_periodo          INT NOT NULL,
  nota                DECIMAL(3,1) NOT NULL,
  fecha_registro      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_modificacion  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  id_usuario_registro INT NOT NULL,          -- el backend lo actualiza con el usuario que EDITA la nota
  motivo_modificacion VARCHAR(255) NULL,     -- el backend lo llena al corregir una nota
  PRIMARY KEY (id_calificacion),
  UNIQUE KEY uq_calificacion (id_estudiante, id_asignacion, id_periodo),
  CONSTRAINT ck_calif_nota CHECK (nota BETWEEN 0.0 AND 5.0),
  CONSTRAINT fk_calif_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiante (id_estudiante)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_calif_asignacion FOREIGN KEY (id_asignacion) REFERENCES asignacion (id_asignacion)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_calif_periodo FOREIGN KEY (id_periodo) REFERENCES periodo (id_periodo)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_calif_usuario FOREIGN KEY (id_usuario_registro) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- RNF-01: toda edición de nota queda registrada (la llenan los triggers de más abajo).
CREATE TABLE calificacion_auditoria (
  id_auditoria    BIGINT NOT NULL AUTO_INCREMENT,
  id_calificacion INT NOT NULL,
  id_usuario      INT NOT NULL,
  accion          ENUM('registro','modificacion') NOT NULL,
  id_estudiante   INT NOT NULL,
  nota_anterior   DECIMAL(3,1) NULL,
  nota_nueva      DECIMAL(3,1) NOT NULL,
  motivo          VARCHAR(255) NULL,
  fecha_hora      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id_auditoria),
  KEY ix_calaud_calificacion (id_calificacion),
  CONSTRAINT fk_calaud_calificacion FOREIGN KEY (id_calificacion) REFERENCES calificacion (id_calificacion)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_calaud_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_calaud_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiante (id_estudiante)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- RF-02: el estado se calcula en el backend con hora_llegada y los parámetros de gracia:
--   0-15 min = presente | 16-30 min = retraso | más de 30 min = ausente.
-- fecha_actualizacion permite resolver conflictos al sincronizar desde modo offline.
CREATE TABLE asistencia (
  id_asistencia       INT NOT NULL AUTO_INCREMENT,
  id_estudiante       INT NOT NULL,
  id_horario          INT NOT NULL,
  fecha               DATE NOT NULL,
  estado              ENUM('presente','retraso','ausente','excusa') NOT NULL,
  hora_llegada        TIME NULL,
  observacion         VARCHAR(255) NULL,
  id_usuario_registro INT NOT NULL,
  fecha_registro      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_asistencia),
  UNIQUE KEY uq_asistencia (id_estudiante, id_horario, fecha),   -- también hace idempotente la sincronización offline
  KEY ix_asistencia_fecha (fecha),
  KEY ix_asistencia_horario_fecha (id_horario, fecha),           -- v2.1: listar una clase en un día
  CONSTRAINT fk_asis_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiante (id_estudiante)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_asis_horario FOREIGN KEY (id_horario) REFERENCES horario (id_horario)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_asis_usuario FOREIGN KEY (id_usuario_registro) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 5. SEGURIDAD Y PERMANENCIA ESCOLAR
-- ---------------------------------------------------------------------

-- PROVISIONAL: el proyecto NO define cómo se registran entradas/salidas ni qué hace "no autorizada" a una salida.
-- 'autorizado' solo aplica a salidas (NULL en entradas).
-- 'ubicacion' es dato sensible (menores de edad): acceso por rol y, de ser posible, cifrado.
CREATE TABLE registro_acceso (
  id_registro         INT NOT NULL AUTO_INCREMENT,
  id_estudiante       INT NOT NULL,
  fecha_hora          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  tipo_evento         ENUM('entrada','salida') NOT NULL,
  ubicacion           VARCHAR(100) NULL,
  autorizado          BOOLEAN NULL,
  id_usuario_registro INT NOT NULL,
  id_usuario_autoriza INT NULL,
  observacion         VARCHAR(255) NULL,
  PRIMARY KEY (id_registro),
  KEY ix_acceso_estudiante_fecha (id_estudiante, fecha_hora),
  CONSTRAINT ck_acceso_autorizado CHECK (tipo_evento = 'salida' OR autorizado IS NULL),
  CONSTRAINT fk_acc_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiante (id_estudiante)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_acc_registra FOREIGN KEY (id_usuario_registro) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_acc_autoriza FOREIGN KEY (id_usuario_autoriza) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- Semáforo IVE: verde / amarillo / naranja (docente) / rojo (rector).
-- Las alertas automáticas no tienen id_usuario_creador; las manuales sí.
-- v2.1 [1]: las FK de id_usuario_creador e id_usuario_atiende usan ON UPDATE RESTRICT porque
-- esas columnas aparecen en un CHECK y el motor no permite CASCADE en ellas.
CREATE TABLE alerta (
  id_alerta               INT NOT NULL AUTO_INCREMENT,
  id_estudiante           INT NOT NULL,
  id_periodo              INT NULL,
  tipo_alerta             ENUM('inasistencia_reiterada','bajo_rendimiento','salida_no_autorizada','emergencia','otro') NOT NULL,
  nivel_riesgo            ENUM('verde','amarillo','naranja','rojo') NOT NULL,
  origen                  ENUM('automatica','manual') NOT NULL,
  porcentaje_inasistencia DECIMAL(5,2) NULL,
  valor_ive               DECIMAL(5,2) NULL,
  descripcion             VARCHAR(255) NULL,
  fecha                   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  estado                  ENUM('pendiente','atendida','descartada') NOT NULL DEFAULT 'pendiente',
  id_usuario_creador      INT NULL,
  id_usuario_atiende      INT NULL,
  fecha_atencion          DATETIME NULL,
  observacion_atencion    VARCHAR(255) NULL,
  PRIMARY KEY (id_alerta),
  KEY ix_alerta_estudiante (id_estudiante, fecha),
  KEY ix_alerta_estado (estado, nivel_riesgo),
  CONSTRAINT ck_alerta_creador CHECK (origen = 'automatica' OR id_usuario_creador IS NOT NULL),
  CONSTRAINT ck_alerta_atencion CHECK (estado = 'pendiente' OR (id_usuario_atiende IS NOT NULL AND fecha_atencion IS NOT NULL)),
  CONSTRAINT fk_alerta_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiante (id_estudiante)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_alerta_periodo FOREIGN KEY (id_periodo) REFERENCES periodo (id_periodo)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_alerta_creador FOREIGN KEY (id_usuario_creador) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_alerta_atiende FOREIGN KEY (id_usuario_atiende) REFERENCES usuario (id_usuario)
    ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 6. VISTA: % de inasistencia ponderada por estudiante y periodo (base del IVE de asistencia)
--    ausente = 1, retraso = peso_retraso (0.5), presente/excusa = 0.
--    SUPUESTO: la excusa NO cuenta como inasistencia; el denominador son las clases con registro.
--    El backend compara porcentaje_inasistencia con umbral_ive_naranja / umbral_ive_rojo.
--    v2.1 [3]: el peso se lee con un agregado que SIEMPRE devuelve una fila; si falta
--    'peso_retraso' en parametro_sistema se usa 0.5 en lugar de dejar la vista vacía.
-- ---------------------------------------------------------------------
CREATE VIEW v_inasistencia_periodo AS
SELECT a.id_estudiante,
       p.id_periodo,
       COUNT(*) AS clases_registradas,
       SUM(CASE a.estado WHEN 'ausente' THEN 1 WHEN 'retraso' THEN pr.peso ELSE 0 END) AS inasistencias_ponderadas,
       ROUND(100 * SUM(CASE a.estado WHEN 'ausente' THEN 1 WHEN 'retraso' THEN pr.peso ELSE 0 END) / COUNT(*), 2) AS porcentaje_inasistencia
  FROM asistencia a
  JOIN horario h    ON h.id_horario = a.id_horario
  JOIN asignacion s ON s.id_asignacion = h.id_asignacion
  JOIN curso c      ON c.id_curso = s.id_curso
  JOIN periodo p    ON p.id_anio = c.id_anio AND a.fecha BETWEEN p.fecha_inicio AND p.fecha_fin
  CROSS JOIN (SELECT COALESCE(MAX(CASE WHEN clave = 'peso_retraso' THEN CAST(valor AS DECIMAL(4,2)) END), 0.5) AS peso
                FROM parametro_sistema) pr
 GROUP BY a.id_estudiante, p.id_periodo;

-- ---------------------------------------------------------------------
-- 7. PROCEDIMIENTOS DE VALIDACIÓN (los llaman los triggers para no repetir código)
-- ---------------------------------------------------------------------
DELIMITER //

-- [5] Periodos del mismo año lectivo no pueden solaparse.
CREATE PROCEDURE sp_validar_periodo(IN p_id_periodo INT, IN p_id_anio SMALLINT UNSIGNED,
                                    IN p_ini DATE, IN p_fin DATE)
BEGIN
  DECLARE v_n INT DEFAULT 0;
  SELECT COUNT(*) INTO v_n
    FROM periodo
   WHERE id_anio = p_id_anio
     AND id_periodo <> p_id_periodo
     AND p_ini <= fecha_fin AND p_fin >= fecha_inicio;
  IF v_n > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las fechas del periodo se solapan con otro periodo del mismo anio lectivo';
  END IF;
END//

-- [7] Sin cruces de profesor ni de curso en el mismo año lectivo.
-- p_dia = índice del ENUM dia_semana (1 = lunes ... 5 = viernes), se compara como número.
CREATE PROCEDURE sp_validar_horario(IN p_id_horario INT, IN p_id_asignacion INT,
                                    IN p_dia TINYINT, IN p_ini TIME, IN p_fin TIME)
BEGIN
  DECLARE v_prof  INT;
  DECLARE v_curso INT;
  DECLARE v_anio  SMALLINT UNSIGNED;
  DECLARE v_n     INT DEFAULT 0;

  SELECT s.id_profesor, s.id_curso, c.id_anio INTO v_prof, v_curso, v_anio
    FROM asignacion s
    JOIN curso c ON c.id_curso = s.id_curso
   WHERE s.id_asignacion = p_id_asignacion;

  SELECT COUNT(*) INTO v_n
    FROM horario h
    JOIN asignacion s ON s.id_asignacion = h.id_asignacion
    JOIN curso c      ON c.id_curso = s.id_curso
   WHERE c.id_anio = v_anio
     AND h.id_horario <> p_id_horario
     AND h.dia_semana + 0 = p_dia
     AND p_ini < h.hora_fin AND p_fin > h.hora_inicio
     AND s.id_profesor = v_prof;
  IF v_n > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El profesor ya tiene otra clase que se cruza en ese horario';
  END IF;

  SELECT COUNT(*) INTO v_n
    FROM horario h
    JOIN asignacion s ON s.id_asignacion = h.id_asignacion
   WHERE s.id_curso = v_curso
     AND h.id_horario <> p_id_horario
     AND h.dia_semana + 0 = p_dia
     AND p_ini < h.hora_fin AND p_fin > h.hora_inicio;
  IF v_n > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El curso ya tiene otra clase que se cruza en ese horario';
  END IF;
END//

-- [4] Asistencia: matrícula activa, día de la semana correcto y fecha dentro de un periodo.
CREATE PROCEDURE sp_validar_asistencia(IN p_id_estudiante INT, IN p_id_horario INT, IN p_fecha DATE)
BEGIN
  DECLARE v_n INT DEFAULT 0;

  SELECT COUNT(*) INTO v_n
    FROM horario h
    JOIN asignacion s ON s.id_asignacion = h.id_asignacion
    JOIN matricula m  ON m.id_curso = s.id_curso
   WHERE h.id_horario = p_id_horario
     AND m.id_estudiante = p_id_estudiante
     AND m.estado = 'activa';
  IF v_n = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El estudiante no tiene matricula activa en el curso de este horario';
  END IF;

  -- WEEKDAY(): 0 = lunes ... 6 = domingo; el ENUM dia_semana va de 1 (lunes) a 5 (viernes).
  SELECT COUNT(*) INTO v_n
    FROM horario
   WHERE id_horario = p_id_horario
     AND dia_semana + 0 = WEEKDAY(p_fecha) + 1;
  IF v_n = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La fecha no corresponde al dia de la semana de este horario';
  END IF;

  SELECT COUNT(*) INTO v_n
    FROM horario h
    JOIN asignacion s ON s.id_asignacion = h.id_asignacion
    JOIN curso c      ON c.id_curso = s.id_curso
    JOIN periodo p    ON p.id_anio = c.id_anio
   WHERE h.id_horario = p_id_horario
     AND p_fecha BETWEEN p.fecha_inicio AND p.fecha_fin;
  IF v_n = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La fecha no esta dentro de ningun periodo del anio lectivo del curso';
  END IF;
END//

-- [6] El usuario vinculado debe tener uno de los roles permitidos.
CREATE PROCEDURE sp_validar_rol_usuario(IN p_id_usuario INT, IN p_rol_a VARCHAR(30),
                                        IN p_rol_b VARCHAR(30), IN p_mensaje VARCHAR(100))
BEGIN
  DECLARE v_codigo VARCHAR(30);
  SELECT r.codigo INTO v_codigo
    FROM usuario u
    JOIN rol r ON r.id_rol = u.id_rol
   WHERE u.id_usuario = p_id_usuario;
  IF v_codigo IS NULL OR (v_codigo <> p_rol_a AND (p_rol_b IS NULL OR v_codigo <> p_rol_b)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = p_mensaje;
  END IF;
END//

-- [6] Acudiente con acceso: rol 'acudiente' y mismo documento que su usuario.
CREATE PROCEDURE sp_validar_acudiente(IN p_id_usuario INT, IN p_tipo VARCHAR(10), IN p_documento VARCHAR(20))
BEGIN
  DECLARE v_n INT DEFAULT 0;
  IF p_id_usuario IS NOT NULL THEN
    CALL sp_validar_rol_usuario(p_id_usuario, 'acudiente', NULL, 'El usuario vinculado al acudiente debe tener rol acudiente');
    SELECT COUNT(*) INTO v_n
      FROM usuario u
     WHERE u.id_usuario = p_id_usuario
       AND u.documento = p_documento
       AND u.tipo_documento = p_tipo;
    IF v_n = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El documento del acudiente no coincide con el de su usuario';
    END IF;
  END IF;
END//

-- [7] Máximo un acudiente principal por estudiante.
CREATE PROCEDURE sp_validar_principal(IN p_id_estudiante INT, IN p_id_acudiente INT, IN p_es_principal BOOLEAN)
BEGIN
  DECLARE v_n INT DEFAULT 0;
  IF p_es_principal THEN
    SELECT COUNT(*) INTO v_n
      FROM estudiante_acudiente
     WHERE id_estudiante = p_id_estudiante
       AND es_principal = TRUE
       AND id_acudiente <> p_id_acudiente;
    IF v_n > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El estudiante ya tiene un acudiente principal';
    END IF;
  END IF;
END//

-- ---------------------------------------------------------------------
-- 8. TRIGGERS DE INTEGRIDAD Y AUDITORÍA
-- ---------------------------------------------------------------------

-- Calificación: el periodo debe ser del año del curso, estar abierto y el estudiante estar matriculado en el curso.
CREATE TRIGGER trg_calificacion_bi BEFORE INSERT ON calificacion
FOR EACH ROW
BEGIN
  DECLARE v_ok INT DEFAULT 0;

  SELECT COUNT(*) INTO v_ok
    FROM periodo p
    JOIN asignacion s ON s.id_asignacion = NEW.id_asignacion
    JOIN curso c      ON c.id_curso = s.id_curso AND c.id_anio = p.id_anio
   WHERE p.id_periodo = NEW.id_periodo;
  IF v_ok = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El periodo no pertenece al año lectivo del curso de la asignacion';
  END IF;

  SELECT COUNT(*) INTO v_ok FROM periodo WHERE id_periodo = NEW.id_periodo AND estado = 'abierto';
  IF v_ok = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Periodo cerrado: se requiere reapertura autorizada';
  END IF;

  SELECT COUNT(*) INTO v_ok
    FROM matricula m
    JOIN asignacion s ON s.id_curso = m.id_curso
   WHERE m.id_estudiante = NEW.id_estudiante
     AND s.id_asignacion = NEW.id_asignacion
     AND m.estado IN ('activa','finalizada');
  IF v_ok = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El estudiante no esta matriculado en el curso de esta asignacion';
  END IF;
END//

-- Calificación: no se puede editar si el periodo está cerrado, y una nota no se puede
-- "mover" a otro estudiante, asignación o periodo (v2.1 [2]). Como la llave no cambia,
-- revisar el periodo NEW equivale a revisar el OLD.
CREATE TRIGGER trg_calificacion_bu BEFORE UPDATE ON calificacion
FOR EACH ROW
BEGIN
  DECLARE v_ok INT DEFAULT 0;

  IF NEW.id_estudiante <> OLD.id_estudiante
     OR NEW.id_asignacion <> OLD.id_asignacion
     OR NEW.id_periodo <> OLD.id_periodo THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se puede cambiar estudiante, asignacion ni periodo de una nota';
  END IF;

  SELECT COUNT(*) INTO v_ok FROM periodo WHERE id_periodo = NEW.id_periodo AND estado = 'abierto';
  IF v_ok = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Periodo cerrado: se requiere reapertura autorizada';
  END IF;
END//

-- Auditoría de notas (RNF-01): ID_Usuario, fecha/hora, nota anterior y nota nueva.
CREATE TRIGGER trg_calificacion_ai AFTER INSERT ON calificacion
FOR EACH ROW
BEGIN
  INSERT INTO calificacion_auditoria
    (id_calificacion, id_usuario, accion, id_estudiante, nota_anterior, nota_nueva, motivo)
  VALUES
    (NEW.id_calificacion, NEW.id_usuario_registro, 'registro', NEW.id_estudiante, NULL, NEW.nota, NEW.motivo_modificacion);
END//

CREATE TRIGGER trg_calificacion_au AFTER UPDATE ON calificacion
FOR EACH ROW
BEGIN
  IF NOT (OLD.nota <=> NEW.nota) THEN
    INSERT INTO calificacion_auditoria
      (id_calificacion, id_usuario, accion, id_estudiante, nota_anterior, nota_nueva, motivo)
    VALUES
      (NEW.id_calificacion, NEW.id_usuario_registro, 'modificacion', NEW.id_estudiante, OLD.nota, NEW.nota, NEW.motivo_modificacion);
  END IF;
END//

-- Asistencia (v2.1 [4]): en INSERT siempre se valida; en UPDATE solo si cambia estudiante,
-- horario o fecha (así se puede corregir el estado de una asistencia aunque la matrícula
-- cambie después).
CREATE TRIGGER trg_asistencia_bi BEFORE INSERT ON asistencia
FOR EACH ROW
BEGIN
  CALL sp_validar_asistencia(NEW.id_estudiante, NEW.id_horario, NEW.fecha);
END//

CREATE TRIGGER trg_asistencia_bu BEFORE UPDATE ON asistencia
FOR EACH ROW
BEGIN
  IF NOT (OLD.id_estudiante <=> NEW.id_estudiante
          AND OLD.id_horario <=> NEW.id_horario
          AND OLD.fecha <=> NEW.fecha) THEN
    CALL sp_validar_asistencia(NEW.id_estudiante, NEW.id_horario, NEW.fecha);
  END IF;
END//

-- Periodo (v2.1 [5] y [8]): sin solapes; el cambio de estado exige usuario y justificación
-- (variables de sesión) y queda registrado en periodo_auditoria.
CREATE TRIGGER trg_periodo_bi BEFORE INSERT ON periodo
FOR EACH ROW
BEGIN
  CALL sp_validar_periodo(NEW.id_periodo, NEW.id_anio, NEW.fecha_inicio, NEW.fecha_fin);
END//

CREATE TRIGGER trg_periodo_bu BEFORE UPDATE ON periodo
FOR EACH ROW
BEGIN
  CALL sp_validar_periodo(NEW.id_periodo, NEW.id_anio, NEW.fecha_inicio, NEW.fecha_fin);
  IF NOT (OLD.estado <=> NEW.estado) THEN
    IF @id_usuario_actual IS NULL OR @justificacion_periodo IS NULL OR TRIM(@justificacion_periodo) = '' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Para cerrar o reabrir un periodo defina @id_usuario_actual y @justificacion_periodo';
    END IF;
  END IF;
END//

CREATE TRIGGER trg_periodo_au AFTER UPDATE ON periodo
FOR EACH ROW
BEGIN
  IF NOT (OLD.estado <=> NEW.estado) THEN
    INSERT INTO periodo_auditoria (id_periodo, id_usuario, accion, justificacion)
    VALUES (NEW.id_periodo, @id_usuario_actual,
            IF(NEW.estado = 'cerrado', 'cierre', 'reapertura'), @justificacion_periodo);
  END IF;
END//

-- Horario (v2.1 [7]): sin cruces de profesor ni de curso.
CREATE TRIGGER trg_horario_bi BEFORE INSERT ON horario
FOR EACH ROW
BEGIN
  CALL sp_validar_horario(NEW.id_horario, NEW.id_asignacion, NEW.dia_semana + 0, NEW.hora_inicio, NEW.hora_fin);
END//

CREATE TRIGGER trg_horario_bu BEFORE UPDATE ON horario
FOR EACH ROW
BEGIN
  CALL sp_validar_horario(NEW.id_horario, NEW.id_asignacion, NEW.dia_semana + 0, NEW.hora_inicio, NEW.hora_fin);
END//

-- Roles coherentes con la tabla de la persona (v2.1 [6]).
-- SUPUESTO: un profesor puede tener rol 'docente' o 'rector' (en sedes rurales el rector suele dictar clase).
CREATE TRIGGER trg_estudiante_bi BEFORE INSERT ON estudiante
FOR EACH ROW
BEGIN
  CALL sp_validar_rol_usuario(NEW.id_usuario, 'estudiante', NULL, 'El usuario vinculado al estudiante debe tener rol estudiante');
END//

CREATE TRIGGER trg_estudiante_bu BEFORE UPDATE ON estudiante
FOR EACH ROW
BEGIN
  CALL sp_validar_rol_usuario(NEW.id_usuario, 'estudiante', NULL, 'El usuario vinculado al estudiante debe tener rol estudiante');
END//

CREATE TRIGGER trg_profesor_bi BEFORE INSERT ON profesor
FOR EACH ROW
BEGIN
  CALL sp_validar_rol_usuario(NEW.id_usuario, 'docente', 'rector', 'El usuario vinculado al profesor debe tener rol docente o rector');
END//

CREATE TRIGGER trg_profesor_bu BEFORE UPDATE ON profesor
FOR EACH ROW
BEGIN
  CALL sp_validar_rol_usuario(NEW.id_usuario, 'docente', 'rector', 'El usuario vinculado al profesor debe tener rol docente o rector');
END//

CREATE TRIGGER trg_acudiente_bi BEFORE INSERT ON acudiente
FOR EACH ROW
BEGIN
  CALL sp_validar_acudiente(NEW.id_usuario, NEW.tipo_documento, NEW.documento);
END//

CREATE TRIGGER trg_acudiente_bu BEFORE UPDATE ON acudiente
FOR EACH ROW
BEGIN
  CALL sp_validar_acudiente(NEW.id_usuario, NEW.tipo_documento, NEW.documento);
END//

-- Si el usuario ya está vinculado a estudiante/profesor/acudiente, no se le puede
-- cambiar a un rol incompatible. Limitación: si se edita el documento del usuario,
-- hay que actualizar también el del acudiente (el usuario es la fuente de verdad).
CREATE TRIGGER trg_usuario_bu BEFORE UPDATE ON usuario
FOR EACH ROW
BEGIN
  DECLARE v_codigo VARCHAR(30);
  DECLARE v_n INT DEFAULT 0;
  IF NEW.id_rol <> OLD.id_rol THEN
    SELECT codigo INTO v_codigo FROM rol WHERE id_rol = NEW.id_rol;

    SELECT COUNT(*) INTO v_n FROM estudiante WHERE id_usuario = NEW.id_usuario;
    IF v_n > 0 AND v_codigo <> 'estudiante' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario esta vinculado a un estudiante: su rol debe ser estudiante';
    END IF;

    SELECT COUNT(*) INTO v_n FROM profesor WHERE id_usuario = NEW.id_usuario;
    IF v_n > 0 AND v_codigo NOT IN ('docente','rector') THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario esta vinculado a un profesor: su rol debe ser docente o rector';
    END IF;

    SELECT COUNT(*) INTO v_n FROM acudiente WHERE id_usuario = NEW.id_usuario;
    IF v_n > 0 AND v_codigo <> 'acudiente' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario esta vinculado a un acudiente: su rol debe ser acudiente';
    END IF;
  END IF;
END//

-- Un solo acudiente principal por estudiante (v2.1 [7]).
CREATE TRIGGER trg_ea_bi BEFORE INSERT ON estudiante_acudiente
FOR EACH ROW
BEGIN
  CALL sp_validar_principal(NEW.id_estudiante, NEW.id_acudiente, NEW.es_principal);
END//

CREATE TRIGGER trg_ea_bu BEFORE UPDATE ON estudiante_acudiente
FOR EACH ROW
BEGIN
  CALL sp_validar_principal(NEW.id_estudiante, NEW.id_acudiente, NEW.es_principal);
END//

-- Alertas automáticas: no se repite una alerta pendiente igual (v2.1 [10]).
-- El backend puede consultar antes, o capturar este error (SQLSTATE 45000) y seguir.
CREATE TRIGGER trg_alerta_bi BEFORE INSERT ON alerta
FOR EACH ROW
BEGIN
  DECLARE v_n INT DEFAULT 0;
  IF NEW.origen = 'automatica' AND NEW.estado = 'pendiente' THEN
    SELECT COUNT(*) INTO v_n
      FROM alerta
     WHERE id_estudiante = NEW.id_estudiante
       AND (id_periodo <=> NEW.id_periodo)
       AND tipo_alerta = NEW.tipo_alerta
       AND nivel_riesgo = NEW.nivel_riesgo
       AND origen = 'automatica'
       AND estado = 'pendiente';
    IF v_n > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ya existe una alerta automatica pendiente igual para este estudiante';
    END IF;
  END IF;
END//

DELIMITER ;

-- ---------------------------------------------------------------------
-- 9. DATOS SEMILLA
-- ---------------------------------------------------------------------
INSERT INTO rol (codigo, nombre, descripcion) VALUES
 ('administrador','Administrador','Acceso total al sistema'),
 ('rector','Rector','Autoridad máxima: auditorías, reapertura de periodos, alertas rojas'),
 ('administrativo','Administrativo (Secretaría)','Inscripción de estudiantes y verificación de documentación física'),
 ('docente','Docente','Asistencia y calificaciones de sus grupos; alertas naranja'),
 ('estudiante','Estudiante','Consulta de horarios, notas y boletines (solo lectura)'),
 ('acudiente','Acudiente','Consulta de información del estudiante a su cargo (solo lectura)');

INSERT INTO parametro_sistema (clave, valor, descripcion) VALUES
 ('umbral_ive_naranja','10','% de inasistencia ponderada que dispara alerta naranja (docente)'),
 ('umbral_ive_rojo','15','% de inasistencia ponderada que dispara alerta roja (rector)'),
 ('peso_retraso','0.5','Cuánto cuenta un retraso como inasistencia'),
 ('gracia_presente_min','15','Minutos desde el inicio de clase para contar como presente'),
 ('gracia_retraso_min','30','Minutos desde el inicio de clase hasta los que se cuenta como retraso; después es ausente');
