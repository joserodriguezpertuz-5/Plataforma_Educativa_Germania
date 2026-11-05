# 2\. Requerimientos No Funcionales

### RNF-01. Backend Flask

El backend deberá desarrollarse utilizando Flask.

### RNF-02. Arquitectura de capas

El backend deberá utilizar una arquitectura de capas que separe
claramente:

* Controladores.
* Servicios.
* Repositorios.
* Modelos.
* Rutas.
* Configuración.
* Manejo de errores.

### RNF-03. ORM SQLAlchemy

La gestión de la base de datos deberá realizarse mediante SQLAlchemy
ORM.

### RNF-04. Base de datos SQLite

SQLite será la base de datos inicial para persistencia.

### RNF-05. Escalabilidad de base de datos

La capa de persistencia deberá diseñarse de forma que facilite una
migración posterior hacia MySQL o PostgreSQL.

### RNF-06. Frontend React + Next.js

El frontend deberá desarrollarse utilizando React con Next.js.

### RNF-07. Diseño Memphis

La interfaz deberá utilizar **Memphis Design** como línea visual
principal, procurando:

* Composición visual dinámica.
* Formas geométricas.
* Elementos decorativos.
* Colores y contrastes coherentes.
* Jerarquía visual clara.
* Adaptación responsiva.

Los elementos decorativos no deberán afectar la jugabilidad ni la
accesibilidad.

### RNF-08. Diseño responsivo

La interfaz deberá estar optimizada para:

* Escritorio.
* Tabletas.
* Dispositivos móviles.

### RNF-09. Autenticación segura

La autenticación deberá contemplar:

* Google OAuth.
* Credenciales locales.
* Hash seguro de contraseñas.
* Protección de sesiones o tokens.
* Validación de datos.
* Autorización de operaciones.

### RNF-10. Documentación Swagger

La API deberá documentarse mediante Swagger/OpenAPI.

### RNF-11. Espacios para Google AdSense

La interfaz deberá reservar espacios estratégicos para una futura
integración de Google AdSense, como mínimo:

* Header.
* Sidebar.
* Entre juegos.

Los espacios deberán identificarse claramente en el código mediante
comentarios como:

``` html
<!-- ADSENSE\_SLOT\_HEADER -->
<!-- ADSENSE\_SLOT\_SIDEBAR -->
<!-- ADSENSE\_SLOT\_BETWEEN\_GAMES -->
```

La publicidad no deberá interferir con la jugabilidad, los controles, el
temporizador ni los resultados.

### RNF-12. Comunicación en tiempo real

La arquitectura deberá permitir comunicación en tiempo real para los
desafíos multijugador, utilizando una tecnología apropiada, por ejemplo
WebSocket/Socket.IO.

### RNF-13. Seguridad

El sistema deberá contemplar:

* Validación de entradas.
* Control de acceso.
* Protección de credenciales.
* Manejo seguro de sesiones.
* Protección frente a operaciones no autorizadas.
* Manejo controlado de errores.

### RNF-14. Mantenibilidad

La solución deberá mantener separadas las responsabilidades de
presentación, lógica de negocio y persistencia.

### RNF-15. Extensibilidad

La incorporación de nuevos juegos deberá poder realizarse sin modificar
significativamente los módulos centrales del sistema.

### RNF-16. Variables de entorno

Las credenciales, secretos y parámetros sensibles deberán configurarse
mediante variables de entorno y no almacenarse directamente en el código
fuente.

### RNF-17. Manejo de errores

Backend y frontend deberán implementar manejo consistente de errores,
validaciones y estados de carga.

### RNF-18. Rendimiento

Las consultas de puntajes, rankings, usuarios y desafíos deberán
diseñarse para permitir el crecimiento progresivo del sistema,
utilizando índices cuando corresponda.

### RNF-19. Compatibilidad web

La aplicación deberá funcionar correctamente en navegadores web
modernos.

\---

# 

