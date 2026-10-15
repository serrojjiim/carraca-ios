# Carraca iOS

App nativa para iPhone y iPad (SwiftUI + MobileVLCKit). Habla con el mismo panel que la app
Android (`config.json`, `resume.php`, `deportes_html.php`) y con la API Xtream del servidor.

- Inicio de sesión: servidor opcional (vacío = servidor Carraca leído de `config.json`), usuario y contraseña.
- Directo (categorías, búsqueda, EPG ahora/después), Películas y Series (pósters, ficha, temporadas),
  Seguir viendo sincronizado con Android/Fire, Deportes de hoy.
- Reproductor VLC: TS, MKV, AVI; pistas de audio y subtítulos; reanudar.
- Las listas se guardan 12 h; los reintentos van con pausa (el proveedor banea ráfagas).

## Compilar (sin Mac): Codemagic
`codemagic.yaml` genera el proyecto con XcodeGen, instala VLC con CocoaPods y firma en Ad Hoc.
Necesita en Codemagic: integración App Store Connect llamada **Carraca ASC** y un certificado
Apple Distribution. Resultado: `Carraca.ipa`.

## Distribuir (Ad Hoc)
Página `https://carracaservice.duckdns.org/ios/` (carpeta `server/ios`, desplegada en `/var/www/config/ios`):
1. El iPhone/iPad instala el perfil de registro -> su UDID queda en `data/ios-udids.json`.
2. Se da de alta el UDID en Apple Developer > Devices y se recompila.
3. Se sube `Carraca.ipa` + `manifest.plist` a `/ios/` y se instala desde la misma página.
