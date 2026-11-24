// ---------------------------------------------------------------------------
//  Lógica da aplicação (sem dependências externas: o build não baixa nada).
//
//  NA DEMO, é ESTE o arquivo que muda a cada etapa (devops/demo/etapas/):
//  VERSAO e COR aparecem na página "/" e provam qual build está rodando.
// ---------------------------------------------------------------------------
const VERSAO = '1.0';
const COR = '#0066cc'; // azul

function pagamento() {
  return {
    status: 'Aprobado',
    transaccion: Math.floor(Math.random() * 100000),
    mensaje: `Pago procesado con éxito (versión ${VERSAO})`,
    version: VERSAO,
    ambiente: process.env.AMBIENTE || 'local',
  };
}

function saude() {
  return { status: 'ok', version: VERSAO };
}

function pagina() {
  const ambiente = process.env.AMBIENTE || 'local';
  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><title>pagamentos-api</title>
<style>body{margin:0;font-family:sans-serif;background:${COR};color:#fff;
display:flex;align-items:center;justify-content:center;height:100vh;text-align:center}
h1{font-size:4rem;margin:0}p{font-size:1.5rem}</style></head>
<body><div><h1>pagamentos-api v${VERSAO}</h1>
<p>ambiente: <b>${ambiente}</b> · pod: ${process.env.HOSTNAME || '-'}</p></div></body></html>`;
}

module.exports = { VERSAO, COR, pagamento, saude, pagina };
