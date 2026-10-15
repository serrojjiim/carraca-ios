<?php $p = htmlspecialchars($_GET['p'] ?? '', ENT_QUOTES); ?>
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Carraca - Dispositivo registrado</title>
<style>
body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#0d0f16;color:#eef1f6;display:flex;min-height:100vh;align-items:center;justify-content:center}
.c{max-width:420px;padding:32px 24px;text-align:center}.ok{font-size:64px;color:#2eb8d1}h1{font-size:24px;margin:10px 0}
p{color:#a9b1c0;line-height:1.5}.n{color:#eef1f6;font-weight:600}
</style></head><body><div class="c">
<div class="ok">&#10003;</div>
<h1>Dispositivo registrado</h1>
<p>Tu <span class="n"><?= $p ?: 'dispositivo' ?></span> ya esta apuntado.</p>
<p>Puedes borrar el perfil en <b>Ajustes &gt; General &gt; VPN y gestion de dispositivos</b> (ya no hace falta).</p>
<p>Cuando la app este lista para tu dispositivo te avisaremos y podras instalarla desde <b>carracaservice.duckdns.org/ios</b>.</p>
</div></body></html>
