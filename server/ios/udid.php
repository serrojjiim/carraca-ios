<?php
// Recibe la respuesta del perfil "Profile Service" de iOS y guarda el UDID del
// dispositivo en data/ios-udids.json (para darlo de alta en Apple Developer).
$raw = file_get_contents('php://input');
$f = ['UDID' => '', 'PRODUCT' => '', 'VERSION' => '', 'DEVICE_NAME' => ''];
if ($raw !== false) {
    $a = strpos($raw, '<?xml');
    $b = strpos($raw, '</plist>');
    if ($a !== false && $b !== false) {
        $p = @simplexml_load_string(substr($raw, $a, $b - $a + 8));
        if ($p && isset($p->dict)) {
            $key = null;
            foreach ($p->dict->children() as $node) {
                if ($node->getName() === 'key') {
                    $key = (string)$node;
                } elseif ($key !== null) {
                    if (array_key_exists($key, $f)) {
                        $f[$key] = trim((string)$node);
                    }
                    $key = null;
                }
            }
        }
    }
}
if (!preg_match('/^[0-9A-Fa-f-]{20,48}$/', $f['UDID'])) {
    http_response_code(400);
    exit('UDID no valido');
}
$file = __DIR__ . '/../data/ios-udids.json';
$list = is_readable($file) ? (json_decode(file_get_contents($file), true) ?: []) : [];
$list[$f['UDID']] = [
    'udid'    => $f['UDID'],
    'product' => $f['PRODUCT'],
    'name'    => $f['DEVICE_NAME'],
    'ios'     => $f['VERSION'],
    'fecha'   => date('c'),
];
file_put_contents($file, json_encode($list, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), LOCK_EX);
// iOS exige un 301 para abrir la pagina de confirmacion en Safari.
header('Location: https://carracaservice.duckdns.org/ios/gracias.php?p=' . urlencode($f['PRODUCT']), true, 301);
