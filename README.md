# Optimizador PC

Herramienta para Windows 10/11 en PowerShell y WPF, con interfaz glass y bandeja del sistema.

- Panel en vivo (CPU, RAM, memoria de GPU, disco) y Modo Turbo
- Widget flotante: CPU, RAM y red en tiempo real, con pulsador para liberar la RAM caché
- Diagnóstico de hardware y de dual channel de la RAM
- Ajustes de rendimiento reversibles (guarda un respaldo de los valores originales)
- Procesos, programas de arranque y juegos con impulso automático
- Audio: volumen, silencio y mejoras

## Instalar

Ejecuta `Instalar_OptimizadorPC.bat`. Pide permisos de administrador, instala en
`%LOCALAPPDATA%\Programs\OptimizadorPC` y crea accesos directos en el Escritorio y el menú Inicio.

Para usarlo sin instalar, ejecuta `Iniciar.bat`. Si no abre, `Iniciar (diagnostico).bat` deja la consola visible con el error.

## Probar

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File Probar-Widget.ps1
```

## Notas

- `Instalar_OptimizadorPC.bat` lleva una copia del programa incrustada en base64 al final. Si cambias `OptimizadorPC.ps1`, hay que regenerarla.
- `OptimizadorPC.ps1` debe conservar un solo BOM UTF-8 y los `.bat` sus saltos CRLF; `.gitattributes` evita que git los altere.
- Liberar la RAM caché requiere permisos de administrador. En discos HDD, los programas tardan más en abrirse justo después.
