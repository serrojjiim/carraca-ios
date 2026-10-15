<?php
$ipa = is_file(__DIR__ . '/Carraca.ipa') && is_file(__DIR__ . '/manifest.plist');
$ver = '';
if ($ipa && preg_match('#<key>bundle-version</key>\s*<string>([^<]+)</string>#', file_get_contents(__DIR__ . '/manifest.plist'), $m)) {
    $ver = $m[1];
}
$install = 'itms-services://?action=download-manifest&url=' . rawurlencode('https://carracaservice.duckdns.org/ios/manifest.plist');
?>
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Carraca para iPhone y iPad</title>
<style>
body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#0d0f16;color:#eef1f6}
.w{max-width:520px;margin:0 auto;padding:36px 22px 60px}
h1{font-size:28px;margin:0 0 6px}.sub{color:#a9b1c0;margin:0 0 28px}
.card{background:#171a24;border-radius:16px;padding:20px;margin-bottom:18px}
.card h2{font-size:18px;margin:0 0 8px}.card p,.card li{color:#a9b1c0;line-height:1.5;font-size:15px}
ol{padding-left:20px;margin:8px 0 14px}
.btn{display:block;text-align:center;background:#2eb8d1;color:#061218;font-weight:700;text-decoration:none;padding:15px;border-radius:12px;font-size:17px}
.btn.off{background:#2a2f3c;color:#7c8496;pointer-events:none}
.num{display:inline-block;width:26px;height:26px;border-radius:13px;background:#2eb8d1;color:#061218;text-align:center;font-weight:700;line-height:26px;margin-right:8px}
.note{font-size:13px;color:#7c8496}
</style></head><body><div class="w">
<h1>Carraca</h1>
<p class="sub">App para iPhone y iPad</p>

<div class="card">
<h2><span class="num">1</span>Registra tu dispositivo</h2>
<p>Solo la primera vez. Abre esta pagina en <b>Safari</b> desde el iPhone o iPad donde quieras la app.</p>
<ol>
<li>Pulsa el boton y acepta descargar el perfil.</li>
<li>Ve a <b>Ajustes</b>: arriba aparece <b>Perfil descargado</b>. Pulsa <b>Instalar</b>.</li>
<li>Veras "Dispositivo registrado". Avisa a tu proveedor.</li>
</ol>
<a class="btn" href="udid.mobileconfig">Registrar este dispositivo</a>
<p class="note">El perfil solo envia el identificador del dispositivo; no instala nada.</p>
</div>

<div class="card">
<h2><span class="num">2</span>Instala la app</h2>
<p>Cuando tu dispositivo este dado de alta, pulsa aqui desde Safari.</p>
<?php if ($ipa): ?>
<a class="btn" href="<?= htmlspecialchars($install, ENT_QUOTES) ?>">Instalar Carraca<?= $ver ? ' (v' . htmlspecialchars($ver) . ')' : '' ?></a>
<p class="note">Si al abrirla dice "No se puede instalar", tu dispositivo aun no esta incluido: avisa a tu proveedor.</p>
<?php else: ?>
<a class="btn off">Proximamente</a>
<?php endif; ?>
</div>
</div></body></html>
