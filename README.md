# rc-audio

Audio del sistema en Mac para el monitor en vivo de [Remote Cut](https://remotecut.pages.dev): captura lo
que suena en el Mac con ScreenCaptureKit (macOS 13 o más nuevo) y lo entrega al plugin de Premiere, que lo
manda al celular. Es el equivalente en Mac de `loopback.cs` (Windows).

- Salida: una línea `frecuencia canales bits` y después PCM float32 intercalado por stdout.
- Permiso: usa el de **Grabación de pantalla** de Premiere (el mismo que necesita el video).
- Se compila gratis en las máquinas Mac de GitHub Actions (`.github/workflows/build.yml`) y cada versión
  queda publicada como release de este repositorio. El instalador de Remote Cut para Mac la descarga y
  verifica su suma SHA-256.
