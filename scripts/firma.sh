#!/usr/bin/env bash
# Firma para Codemagic: descarga (o crea) certificado + perfil por la API de App Store Connect
# y escribe equipo/perfil directamente en project.yml (antes de xcodegen).
# Uso: scripts/firma.sh appstore|adhoc
set -euo pipefail
TIPO="${1:-appstore}"
BUNDLE="com.carraca.smarter"
case "$TIPO" in
  appstore) PTYPE=IOS_APP_STORE ;;
  adhoc)    PTYPE=IOS_APP_ADHOC ;;
  *) echo "tipo desconocido: $TIPO"; exit 1 ;;
esac

if [ -z "${CERTIFICATE_PRIVATE_KEY:-}" ]; then
  echo "ERROR: falta la variable CERTIFICATE_PRIVATE_KEY."
  echo "En Codemagic > app > Environment variables: nombre CERTIFICATE_PRIVATE_KEY,"
  echo "grupo carraca_firma, valor = contenido completo de certificado.key (BEGIN ... END)."
  exit 1
fi
echo "CERTIFICATE_PRIVATE_KEY presente ($(printf '%s' "$CERTIFICATE_PRIVATE_KEY" | head -1))"

keychain initialize
app-store-connect fetch-signing-files "$BUNDLE" --type "$PTYPE" --create   --certificate-key=@env:CERTIFICATE_PRIVATE_KEY
keychain add-certificates

# Xcode 16+ guarda los perfiles en UserData; versiones anteriores en MobileDevice.
DIR1="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
DIR2="$HOME/Library/MobileDevice/Provisioning Profiles"
echo "== Perfiles descargados =="; ls -la "$DIR1" "$DIR2" 2>/dev/null || true

PROFILE=""; NEWEST=0
for f in "$DIR1"/*.mobileprovision "$DIR2"/*.mobileprovision; do
  [ -f "$f" ] || continue
  security cms -D -i "$f" > /tmp/p.plist 2>/dev/null || continue
  APPID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" /tmp/p.plist 2>/dev/null || true)
  [[ "$APPID" == *".$BUNDLE" ]] || continue
  HAS_DEV=0; /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" /tmp/p.plist >/dev/null 2>&1 && HAS_DEV=1
  if [ "$TIPO" = appstore ] && [ $HAS_DEV = 1 ]; then continue; fi
  if [ "$TIPO" = adhoc ] && [ $HAS_DEV = 0 ]; then continue; fi
  M=$(stat -f %m "$f"); if [ "$M" -ge "$NEWEST" ]; then NEWEST=$M; PROFILE="$f"; fi
done
[ -n "$PROFILE" ] || { echo "No se encontro perfil $PTYPE para $BUNDLE"; exit 1; }

security cms -D -i "$PROFILE" > /tmp/p.plist
UUID=$(/usr/libexec/PlistBuddy -c "Print :UUID" /tmp/p.plist)
NAME=$(/usr/libexec/PlistBuddy -c "Print :Name" /tmp/p.plist)
TEAM=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" /tmp/p.plist)
echo "== Perfil elegido: $NAME ($UUID), equipo $TEAM =="

python3 - "$TEAM" "$UUID" <<'PY'
import sys
team, uuid = sys.argv[1], sys.argv[2]
p = "project.yml"; s = open(p).read()
lines = (f'        CODE_SIGN_STYLE: Manual\n'
         f'        DEVELOPMENT_TEAM: {team}\n'
         f'        PROVISIONING_PROFILE_SPECIFIER: "{uuid}"\n'
         f'        CODE_SIGN_IDENTITY: "Apple Distribution"\n')
import re
s, n = re.subn(r"^        # SIGNING.*\n", lines, s, count=1, flags=re.M)
assert n == 1, "falta la marca # SIGNING en project.yml"
open(p, "w").write(s)
print("project.yml firmado")
PY
grep -n "DEVELOPMENT_TEAM\|PROVISIONING_PROFILE_SPECIFIER\|CODE_SIGN" project.yml
